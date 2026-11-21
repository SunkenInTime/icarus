import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

String get _dartSdk {
  final parts = p.split(p.dirname(Platform.resolvedExecutable));
  final cache = parts.lastIndexOf('cache');
  return p.joinAll([...parts.take(cache + 1), 'dart-sdk']);
}

final class _Parses extends RecursiveAstVisitor<void> {
  _Parses(this.unitPath);

  final String Function(AstNode node) unitPath;
  final gates = <String>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'parse' &&
        node.realTarget?.toSource() == 'LibraryStoreLaunch') {
      final gate = node.argumentList.arguments
          .whereType<NamedExpression>()
          .singleWhere((argument) => argument.name.label.name == 'mayShadow')
          .expression;
      gates.add('${unitPath(node)} ${gate.toSource()}');
    }
    super.visitMethodInvocation(node);
  }
}

Future<ParsedUnitResult> _parse(
  AnalysisContextCollection collection,
  String path,
) async {
  final file = p.normalize(p.join(Directory.current.path, path));
  final unit = collection.contextFor(file).currentSession.getParsedUnit(file);
  if (unit is! ParsedUnitResult) fail('$path did not parse: $unit');
  return unit;
}

String _initializerOf(ParsedUnitResult unit, String name) =>
    unit.unit.declarations
        .whereType<TopLevelVariableDeclaration>()
        .expand((declaration) => [
              for (final variable in declaration.variables.variables)
                if (variable.name.lexeme == name &&
                    declaration.variables.isConst)
                  variable.initializer!.toSource(),
            ])
        .single;

bool _declares(ParsedUnitResult unit, String name) => unit.unit.declarations
    .whereType<TopLevelVariableDeclaration>()
    .expand((declaration) => declaration.variables.variables)
    .any((variable) => variable.name.lexeme == name);

List<String> _imports(ParsedUnitResult unit) => [
      for (final directive in unit.unit.directives.whereType<ImportDirective>())
        [
          directive.uri.stringValue!,
          for (final combinator in directive.combinators) combinator.toSource(),
        ].join(' '),
    ];

void main() {
  test(
      'the release entry point can reach shadow only through a compile-time define or a debug build',
      () async {
    final collection = AnalysisContextCollection(
      includedPaths: [p.join(Directory.current.path, 'lib')],
      sdkPath: _dartSdk,
    );
    final gates = <String>[];
    for (final context in collection.contexts) {
      for (final file in context.contextRoot.analyzedFiles()) {
        if (!file.endsWith('.dart') || file.endsWith('.g.dart')) continue;
        final unit = context.currentSession.getParsedUnit(file);
        if (unit is! ParsedUnitResult) continue;
        final path =
            p.split(p.relative(file, from: Directory.current.path)).join('/');
        final parses = _Parses((_) => path);
        unit.unit.accept(parses);
        gates.addAll(parses.gates);
      }
    }
    expect(gates, ['lib/main.dart shadowReachable']);

    final main = await _parse(collection, 'lib/main.dart');
    expect(_declares(main, 'shadowReachable'), isFalse);
    expect(
      _imports(main),
      contains('package:icarus/library_store/library_store_switch.dart'),
    );

    final gate = await _parse(
      collection,
      'lib/library_store/library_store_switch.dart',
    );
    expect(
      _initializerOf(gate, 'shadowReachable'),
      '!kIsWeb && (driveBuild || kDebugMode)',
    );
    expect(
        _imports(gate),
        containsAll([
          "package:flutter/foundation.dart show kDebugMode, kIsWeb",
          'package:icarus/config/drive_build.dart',
        ]));
    for (final name in ['kDebugMode', 'kIsWeb', 'driveBuild']) {
      expect(_declares(gate, name), isFalse, reason: name);
    }
    final drive = await _parse(collection, 'lib/config/drive_build.dart');
    expect(
      _initializerOf(drive, 'driveBuild'),
      "bool.fromEnvironment('ICARUS_DRIVE')",
    );
  });
}
