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
const _recordTypes = {..._libraryModels, 'HiveObject', 'HiveObjectMixin'};
const _boxNames = {'strategiesBox', 'foldersBox'};
const _typedOpeners = {'box', 'openBox'};

String get _dartSdk {
  final parts = p.split(p.dirname(Platform.resolvedExecutable));
  final cache = parts.lastIndexOf('cache');
  return p.joinAll([...parts.take(cache + 1), 'dart-sdk']);
}

String _repoPath(String path) => p.split(path).join('/');

String _nameOf(InterfaceType type) =>
    type.getDisplayString().replaceFirst(RegExp(r'\?$'), '');

bool _isLibraryModel(DartType? type) =>
    type is InterfaceType && _libraryModels.contains(_nameOf(type));

bool _isRecord(DartType? type) =>
    type is DynamicType ||
    type is InterfaceType && _recordTypes.contains(_nameOf(type));

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

  void _found(AstNode node, String what) {
    final line = unit.lineInfo.getLocation(node.offset).lineNumber;
    found.add('$path:$line $what');
  }

  void _check(Expression? target, SimpleIdentifier name) {
    final type = target?.staticType;
    final write = (_boxWrites.contains(name.name) && _isLibraryBox(type)) ||
        (_recordWrites.contains(name.name) && _isRecord(type)) ||
        (name.name == 'box' && _isLibraryModel(type));
    if (write) _found(name, name.name);
  }

  bool _openedTyped(PrefixedIdentifier node) {
    final call = node.parent?.parent;
    if (call is! MethodInvocation || node.parent is! ArgumentList) {
      return false;
    }
    if (call.target case SimpleIdentifier(name: 'Hive')) {
      if (call.methodName.name == 'isBoxOpen') return true;
      final types = call.typeArguments?.arguments ?? const [];
      return _typedOpeners.contains(call.methodName.name) &&
          types.length == 1 &&
          _libraryModels.contains(types.single.toSource());
    }
    return false;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _check(node.realTarget, node.methodName);
    super.visitMethodInvocation(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (node.staticType is FunctionType || node.propertyName.name == 'box') {
      _check(node.realTarget, node.propertyName);
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.staticType is FunctionType || node.identifier.name == 'box') {
      _check(node.prefix, node.identifier);
    }
    if (node.prefix.name == 'HiveBoxNames' &&
        _boxNames.contains(node.identifier.name) &&
        !_openedTyped(node)) {
      _found(node, 'box name');
    }
    super.visitPrefixedIdentifier(node);
  }
}

Future<List<String>> _writesIn(List<String> roots) async {
  final repo = Directory.current.path;
  final collection = AnalysisContextCollection(
    includedPaths: [
      for (final root in roots) p.normalize(p.join(repo, root)),
    ],
    sdkPath: _dartSdk,
  );
  final found = <String>[];
  for (final context in collection.contexts) {
    final files = context.contextRoot.analyzedFiles().where(
          (file) => file.endsWith('.dart') && !file.endsWith('.g.dart'),
        );
    for (final file in files) {
      final path = _repoPath(p.relative(file, from: repo));
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
      '$_fixture:29 delete',
      '$_fixture:30 save',
      '$_fixture:31 box',
      '$_fixture:32 box name',
      '$_fixture:33 box name',
    ]);
  });
}
