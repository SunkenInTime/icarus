import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';

final class StrictGenerationResult {
  const StrictGenerationResult({
    required this.rawExitCode,
    required this.exitCode,
    required this.logs,
    required this.errors,
    required this.diagnostics,
  });

  final int rawExitCode;
  final int exitCode;
  final List<String> logs;
  final List<String> errors;
  final List<String> diagnostics;

  bool get accepted => exitCode == 0;
}

Future<StrictGenerationResult> runStrictConvexCodegen({
  required String specFile,
  required Directory outputDirectory,
  required Iterable<String> stableModulePaths,
}) async {
  final logs = <String>[];
  final errors = <String>[];
  final rawExitCode = await runConvexCodegen(
    <String>[
      'generate',
      '--spec-file',
      specFile,
      '--output',
      outputDirectory.path,
    ],
    log: logs.add,
    errorLog: errors.add,
  );

  final diagnostics = <String>[];
  if (rawExitCode != 0) {
    diagnostics.add('Dartvex generation exited $rawExitCode.');
  }
  diagnostics.addAll(
    <String>[...logs, ...errors].where((line) => line.contains('Warning:')),
  );

  if (rawExitCode == 0) {
    for (final modulePath in stableModulePaths) {
      final module = File('${outputDirectory.path}/$modulePath');
      if (!module.existsSync()) {
        diagnostics.add('Stable generated module is missing: $modulePath');
        continue;
      }
      final source = module.readAsStringSync();
      for (final match in RegExp(
        r'(?:Future|Stream)<dynamic>\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(',
      ).allMatches(source)) {
        diagnostics.add(
          '$modulePath: public method ${match.group(1)} has an unexpected '
          'dynamic result.',
        );
      }
    }
  }

  return StrictGenerationResult(
    rawExitCode: rawExitCode,
    exitCode: diagnostics.isEmpty ? 0 : (rawExitCode == 0 ? 2 : rawExitCode),
    logs: List.unmodifiable(logs),
    errors: List.unmodifiable(errors),
    diagnostics: List.unmodifiable(diagnostics),
  );
}
