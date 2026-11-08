import 'dart:convert';
import 'dart:io';

import 'strict_codegen.dart';

/// Asks whether Dartvex's generator can stand in for Icarus's own generator
/// on the real contract: every client-callable function in
/// `convex/function_spec.json`, not a one-function fixture.
///
/// Each public function is generated alone so one refusal does not hide the
/// rest, then the whole spec is generated once to catch module-level failures.
/// A function is `typed` only when generation exits zero with no warning and
/// its generated module contains no `dynamic` anywhere: not in the method
/// result and not in a nested result or argument model.
Future<Map<String, Object?>> evaluateFullSpecGate({
  required File specFile,
  required Directory scratch,
  bool analyze = false,
}) async {
  final spec = jsonDecode(specFile.readAsStringSync()) as Map<String, Object?>;
  final functions = (spec['functions']! as List<Object?>)
      .cast<Map<String, Object?>>();
  final public =
      functions
          .where(
            (function) =>
                (function['visibility'] as Map<String, Object?>?)?['kind'] ==
                'public',
          )
          .toList()
        ..sort(
          (left, right) => (left['identifier']! as String).compareTo(
            right['identifier']! as String,
          ),
        );

  // Icarus's scrubbed snapshot drops the deployment URL. Dartvex requires the
  // key but only copies it into a comment, so a placeholder changes no type.
  Map<String, Object?> specWith(List<Map<String, Object?>> chosen) =>
      <String, Object?>{
        'url': 'https://placeholder.convex.cloud',
        'functions': chosen,
      };

  if (scratch.existsSync()) {
    scratch.deleteSync(recursive: true);
  }
  scratch.createSync(recursive: true);

  Future<_Generation> generate(
    String name,
    List<Map<String, Object?>> chosen,
  ) async {
    final input = File('${scratch.path}/$name.json')
      ..writeAsStringSync(jsonEncode(specWith(chosen)));
    final output = Directory('${scratch.path}/$name');
    final result = await runStrictConvexCodegen(
      specFile: input.path,
      outputDirectory: output,
      stableModulePaths: const <String>[],
    );
    return _Generation(result, output);
  }

  final rows = <Map<String, Object?>>[];
  for (final function in public) {
    final identifier = function['identifier']! as String;
    final generation = await generate('one', <Map<String, Object?>>[function]);
    final result = generation.result;
    final refusal = <String>[
      ...result.logs,
      ...result.errors,
    ].where((line) => !line.contains('Warning:') && line.trim().isNotEmpty);
    final warnings = result.diagnostics
        .where((line) => line.contains('Warning:'))
        .toList();
    final dynamicLines = result.rawExitCode == 0
        ? _untypedPublicDeclarations(generation.output)
        : const <String>[];
    final moduleBytes = result.rawExitCode == 0
        ? _moduleFiles(
            generation.output,
          ).fold<int>(0, (sum, file) => sum + file.lengthSync())
        : null;
    final String status;
    if (result.rawExitCode != 0) {
      status = 'refused';
    } else if (warnings.isNotEmpty || dynamicLines.isNotEmpty) {
      status = 'degraded';
    } else {
      status = 'typed';
    }
    rows.add(<String, Object?>{
      'function': identifier.replaceFirst('.js:', ':'),
      'functionType': function['functionType'],
      'status': status,
      if (status == 'refused') 'refusal': refusal.join('\n'),
      if (warnings.isNotEmpty) 'warnings': warnings,
      if (dynamicLines.isNotEmpty) 'untypedPublicDeclarations': dynamicLines,
      'generatedModuleBytes': ?moduleBytes,
    });
  }

  final generated = public.where((function) {
    final name = (function['identifier']! as String).replaceFirst('.js:', ':');
    return rows.any(
      (row) => row['function'] == name && row['status'] != 'refused',
    );
  }).toList();
  final whole = await generate('whole', public);
  final withoutRefused = await generate('without_refused', generated);
  final bindingBytes = withoutRefused.result.rawExitCode == 0
      ? withoutRefused.output
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .fold<int>(0, (sum, file) => sum + file.lengthSync())
      : null;
  final analysisClock = Stopwatch()..start();
  final withoutRefusedAnalysis =
      analyze && withoutRefused.result.rawExitCode == 0
      ? await Process.run(Platform.resolvedExecutable, <String>[
          'analyze',
          withoutRefused.output.path,
        ])
      : null;
  analysisClock.stop();

  int count(String status) =>
      rows.where((row) => row['status'] == status).length;

  final report = <String, Object?>{
    'publicFunctions': public.length,
    'typed': count('typed'),
    'degraded': count('degraded'),
    'refused': count('refused'),
    'wholeSpec': <String, Object?>{
      'rawGenerationExitCode': whole.result.rawExitCode,
      'output': <String>[
        ...whole.result.logs,
        ...whole.result.errors,
      ].where((line) => line.trim().isNotEmpty).toList(),
    },
    'withoutRefused': <String, Object?>{
      'functions': generated.length,
      'rawGenerationExitCode': withoutRefused.result.rawExitCode,
      'generatedDartBytes': bindingBytes,
      'analysisExitCode': withoutRefusedAnalysis?.exitCode,
      'analysisMs': withoutRefusedAnalysis == null
          ? null
          : analysisClock.elapsedMilliseconds,
    },
    'functions': rows,
  };
  scratch.deleteSync(recursive: true);
  return report;
}

/// Generated public declarations whose type lets an untyped value reach the
/// caller: a public field, getter or method typed `dynamic`, `Object`,
/// `Object?`, or a collection of those. Private `_encode`/`_decode` helpers
/// and `dynamic raw` decoder parameters are Dartvex's JSON plumbing and never
/// reach a caller, so they are not counted. Neither is an enum's `value`
/// field: Dartvex stores each case's wire literal there as `Object?`, while
/// the result field itself has the enum's type.
List<String> _untypedPublicDeclarations(Directory output) {
  final untyped = RegExp(r'\b(dynamic|Object\??)(?=[\s>,])');
  final declaration = RegExp(
    r'^(?:final\s+|static\s+|late\s+)*([A-Za-z_][\w<>?, ]*?)\s+([A-Za-z][\w$]*)\s*(?:;|\(|=>|\{|$)',
  );
  final lines = <String>[];
  for (final file in _moduleFiles(output)) {
    final relative = _relative(output, file);
    var inEnum = false;
    for (final line in file.readAsLinesSync()) {
      if (line.startsWith('enum ')) {
        inEnum = true;
      } else if (line == '}') {
        inEnum = false;
      }
      if (inEnum || (!line.contains('dynamic') && !line.contains('Object'))) {
        continue;
      }
      final trimmed = line.trim();
      final match = declaration.firstMatch(trimmed);
      if (match == null) {
        continue;
      }
      final type = match.group(1)!;
      if (type == 'return' || type.startsWith('_')) {
        continue;
      }
      if (untyped.hasMatch('$type ')) {
        lines.add('$relative: $trimmed');
      }
    }
  }
  return lines;
}

List<File> _moduleFiles(Directory output) =>
    output
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => _relative(output, file).startsWith('modules/'))
        .toList()
      ..sort((left, right) => left.path.compareTo(right.path));

String _relative(Directory output, File file) =>
    file.path.substring(output.path.length + 1).replaceAll(r'\', '/');

final class _Generation {
  const _Generation(this.result, this.output);

  final StrictGenerationResult result;
  final Directory output;
}
