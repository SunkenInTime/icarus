import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _funnel = 'lib/strategy/local_library.dart';
const _fixture = 'test/fixtures/library_writes/outside_writer.dart';
const _libraryModels = {'StrategyData', 'Folder'};
const _boxWrites = {
  'put',
  'putAt',
  'putAll',
  'add',
  'addAll',
  'delete',
  'deleteAt',
  'deleteAll',
  'clear',
  'compact',
  'deleteFromDisk',
};
const _recordWrites = {'save', 'delete'};

String get _dartSdk => p.join(
      p.dirname(Platform.resolvedExecutable).split('/bin/cache/').first,
      'bin',
      'cache',
      'dart-sdk',
    );

bool _isLibraryModel(DartType? type) =>
    type is InterfaceType &&
    _libraryModels.contains(
      type.getDisplayString().replaceFirst(RegExp(r'\?$'), ''),
    );

bool _isLibraryBox(DartType? type) =>
    type is InterfaceType &&
    [type, ...type.allSupertypes].any(
      (candidate) => _libraryModels.any(
        (model) => candidate.getDisplayString() == 'BoxBase<$model>',
      ),
    );

final class _WriteFinder extends RecursiveAstVisitor<void> {
  _WriteFinder(this.unit, this.path);

  final ResolvedUnitResult unit;
  final String path;
  final found = <String>[];

  void _check(Expression? target, SimpleIdentifier name) {
    final type = target?.staticType;
    final write = (_boxWrites.contains(name.name) && _isLibraryBox(type)) ||
        (_recordWrites.contains(name.name) && _isLibraryModel(type));
    if (!write) return;
    final line = unit.lineInfo.getLocation(name.offset).lineNumber;
    found.add('$path:$line ${name.name}');
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _check(node.realTarget, node.methodName);
    super.visitMethodInvocation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (node.staticType is FunctionType) {
      _check(node.realTarget, node.propertyName);
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.staticType is FunctionType) {
      _check(node.prefix, node.identifier);
    }
    super.visitPrefixedIdentifier(node);
  }
}

Future<List<String>> _writesIn(List<String> roots) async {
  final repo = Directory.current.path;
  final collection = AnalysisContextCollection(
    includedPaths: [for (final root in roots) p.join(repo, root)],
    sdkPath: _dartSdk,
  );
  final found = <String>[];
  for (final context in collection.contexts) {
    final files = context.contextRoot.analyzedFiles().where(
          (file) => file.endsWith('.dart') && !file.endsWith('.g.dart'),
        );
    for (final file in files) {
      final path = p.relative(file, from: repo);
      if (path == _funnel) continue;
      final unit = await context.currentSession.getResolvedUnit(file);
      if (unit is! ResolvedUnitResult) {
        fail('$path did not resolve: $unit');
      }
      final finder = _WriteFinder(unit, path);
      unit.unit.accept(finder);
      found.addAll(finder.found);
    }
  }
  return found;
}

void main() {
  late List<String> writes;

  setUpAll(() async {
    writes = await _writesIn(['lib', _fixture]);
  });

  test('only LocalLibrary writes the strategies and folders boxes', () {
    expect(writes.where((write) => write.startsWith('lib/')), isEmpty);
  });

  test('the check sees every way to write those boxes', () {
    expect(writes.where((write) => write.startsWith(_fixture)), [
      '$_fixture:9 put',
      '$_fixture:10 putAll',
      '$_fixture:11 delete',
      '$_fixture:12 deleteAll',
      '$_fixture:13 clear',
      '$_fixture:14 put',
      '$_fixture:15 delete',
      '$_fixture:16 save',
      '$_fixture:17 delete',
      '$_fixture:18 save',
    ]);
  });
}
