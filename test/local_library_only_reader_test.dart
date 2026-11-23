import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _places = {
  'lib/strategy/local_library.dart',
  'lib/strategy/local_library_view.dart',
};
const _opensAndMigrates = {'lib/main.dart'};
const _namesTheBoxes = 'lib/const/hive_boxes.dart';
const _migrations = 'lib/migrations/';
const _fixture = 'test/fixtures/library_reads/outside_reader.dart';
const _libraryModels = {'StrategyData', 'Folder'};
const _boxNames = {'strategiesBox', 'foldersBox'};
const _boxFileNames = {'strategy_box', 'folder_box'};

String get _dartSdk {
  final parts = p.split(p.dirname(Platform.resolvedExecutable));
  final cache = parts.lastIndexOf('cache');
  return p.joinAll([...parts.take(cache + 1), 'dart-sdk']);
}

String _repoPath(String path) => p.split(path).join('/');

bool _mayTouchTheBoxes(String path) =>
    _places.contains(path) ||
    _opensAndMigrates.contains(path) ||
    path == _namesTheBoxes ||
    path.startsWith(_migrations);

bool _isLibraryModel(DartType? type) =>
    type is InterfaceType &&
    _libraryModels.contains(type.getDisplayString().replaceFirst('?', ''));

bool _isLibraryBox(DartType? type) =>
    type is InterfaceType &&
    [type, ...type.allSupertypes].any(
      (candidate) => _libraryModels.any(
        (model) => candidate.getDisplayString() == 'BoxBase<$model>',
      ),
    );

bool _mentionsLibraryBox(DartType? type) =>
    _isLibraryBox(type) ||
    (type is InterfaceType && type.typeArguments.any(_mentionsLibraryBox)) ||
    (type is FunctionType && _mentionsLibraryBox(type.returnType));

bool _mayBeARecord(DartType? type) =>
    _isLibraryModel(type) || type is DynamicType;

bool _isABoxName(String? text) =>
    text != null && _boxFileNames.contains(text.toLowerCase());

String? _textOf(Expression expression, Set<String> aliases) =>
    switch (expression) {
      SimpleStringLiteral(:final value) => value,
      AdjacentStrings(:final strings) => switch ([
          for (final part in strings) _textOf(part, aliases),
        ]) {
          final parts when parts.every((part) => part != null) => parts.join(),
          _ => null,
        },
      BinaryExpression(
        :final leftOperand,
        :final operator,
        :final rightOperand,
      )
          when operator.lexeme == '+' =>
        switch ((
          _textOf(leftOperand, aliases),
          _textOf(rightOperand, aliases),
        )) {
          (final left?, final right?) => left + right,
          _ => null,
        },
      ParenthesizedExpression(:final expression) =>
        _textOf(expression, aliases),
      PrefixedIdentifier(:final identifier) ||
      PropertyAccess(propertyName: final identifier)
          when _boxNames.contains(identifier.name) =>
        _boxFileNames.elementAt(
          _boxNames.toList().indexOf(identifier.name),
        ),
      SimpleIdentifier(:final name) when aliases.contains(name) =>
        _boxFileNames.first,
      _ => null,
    };

final class _AliasFinder extends RecursiveAstVisitor<void> {
  _AliasFinder(this.aliases);

  final Set<String> aliases;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (node.initializer case final value?
        when _isABoxName(_textOf(value, aliases))) {
      aliases.add(node.name.lexeme);
    }
    super.visitVariableDeclaration(node);
  }
}

final class _ReadFinder extends RecursiveAstVisitor<void> {
  _ReadFinder(this.unit, this.path, this.aliases);

  final ResolvedUnitResult unit;
  final String path;
  final Set<String> aliases;
  final found = <(int, String)>{};

  void _found(AstNode node, String what) =>
      found.add((unit.lineInfo.getLocation(node.offset).lineNumber, what));

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_mentionsLibraryBox(node.staticType)) _found(node, 'box');
    if (_boxNames.contains(node.name)) _found(node, 'box name');
    if (node.name == 'box' &&
        switch (node.parent) {
          PrefixedIdentifier(:final prefix) => _mayBeARecord(prefix.staticType),
          PropertyAccess(:final realTarget) =>
            _mayBeARecord(realTarget.staticType),
          _ => false,
        }) {
      _found(node, 'record box');
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitArgumentList(ArgumentList node) {
    for (final argument in node.arguments) {
      if (_isABoxName(_textOf(argument, aliases))) {
        _found(argument, 'box name');
      }
    }
    super.visitArgumentList(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (_isABoxName(node.value)) _found(node, 'box name');
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_mentionsLibraryBox(node.staticType)) _found(node, 'box');
    if (node.methodName.name == 'get' &&
        node.realTarget?.staticType is DynamicType) {
      _found(node.methodName, 'held box');
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitFunctionReference(FunctionReference node) {
    if (_mentionsLibraryBox(node.staticType)) _found(node, 'box');
    super.visitFunctionReference(node);
  }

  @override
  void visitNamedType(NamedType node) {
    if (_mentionsLibraryBox(node.type)) _found(node, 'box type');
    super.visitNamedType(node);
  }
}

Future<Map<String, List<(int, String)>>> _readsIn(List<String> roots) async {
  final repo = Directory.current.path;
  final collection = AnalysisContextCollection(
    includedPaths: [
      for (final root in roots) p.normalize(p.join(repo, root)),
    ],
    sdkPath: _dartSdk,
  );
  final found = <String, List<(int, String)>>{};
  final units = <(String, ResolvedUnitResult)>[];
  for (final context in collection.contexts) {
    final files = context.contextRoot.analyzedFiles().where(
          (file) => file.endsWith('.dart') && !file.endsWith('.g.dart'),
        );
    for (final file in files) {
      final path = _repoPath(p.relative(file, from: repo));
      if (_mayTouchTheBoxes(path)) continue;
      final unit = await context.currentSession.getResolvedUnit(file);
      if (unit is! ResolvedUnitResult) {
        fail('$path did not resolve: $unit');
      }
      units.add((path, unit));
    }
  }
  final aliases = <String>{};
  for (final (_, unit) in units) {
    unit.unit.accept(_AliasFinder(aliases));
  }
  for (final (path, unit) in units) {
    final finder = _ReadFinder(unit, path, aliases);
    unit.unit.accept(finder);
    if (finder.found.isNotEmpty) {
      found[path] = finder.found.toList()
        ..sort((a, b) =>
            a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    }
  }
  return found;
}

void main() {
  late Map<String, List<(int, String)>> reads;

  setUpAll(() async {
    reads = await _readsIn(['lib', _fixture]);
  });

  test(
      'only LocalLibrary and LocalLibraryView reach the strategies and folders boxes',
      () {
    expect(
      {
        for (final MapEntry(:key, :value) in reads.entries)
          if (key.startsWith('lib/')) key: value,
      },
      isEmpty,
    );
  });

  test(
      'in read mode the list and folders are drawn by a file the check covers, and it reaches no box',
      () {
    const listing = 'lib/library_store/library_listing.dart';
    expect(File(listing).existsSync(), isTrue);
    expect(_mayTouchTheBoxes(listing), isFalse);
    expect(reads[listing], isNull);
  });

  test('the check sees each way of reaching those boxes that its fixture holds',
      () {
    expect(reads[_fixture], [
      (8, 'box name'),
      (11, 'box'),
      (11, 'box name'),
      (12, 'box'),
      (12, 'box name'),
      (13, 'box name'),
      (14, 'record box'),
      (15, 'record box'),
      (16, 'box name'),
      (17, 'box name'),
      (18, 'box name'),
      (19, 'box'),
      (20, 'box'),
      (20, 'box name'),
      (21, 'record box'),
      (24, 'box'),
      (24, 'box type'),
      (26, 'box type'),
      (27, 'box'),
      (30, 'box name'),
      (31, 'box name'),
      (32, 'box name'),
      (33, 'box name'),
      (34, 'held box'),
    ]);
  });
}
