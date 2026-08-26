import 'dart:convert';
import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';

const _dartvexVersion = '0.2.0';
const _dartvexCodegenVersion = '0.2.0';

final class ContractGateResult {
  ContractGateResult({required this.report});

  final Map<String, Object?> report;

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(report);
}

Future<ContractGateResult> evaluateContractGate({String? packageRoot}) async {
  final root = Directory(packageRoot ?? Directory.current.path).absolute;
  final generated = Directory('${root.path}/lib/_probe_generated');
  final caller = File('${root.path}/lib/_probe_caller.dart');

  Future<_Generation> generate(String fixtureName) async {
    final logs = <String>[];
    final errors = <String>[];
    final exitCode = await runConvexCodegen(
      <String>[
        'generate',
        '--spec-file',
        '${root.path}/fixtures/$fixtureName',
        '--output',
        generated.path,
      ],
      log: logs.add,
      errorLog: errors.add,
    );
    return _Generation(exitCode: exitCode, logs: logs, errors: errors);
  }

  Future<_Analysis> analyzeCaller() async {
    final process = await Process.run(Platform.resolvedExecutable, <String>[
      'analyze',
      caller.path,
      generated.path,
    ], workingDirectory: root.path);
    return _Analysis(
      exitCode: process.exitCode,
      output: '${process.stdout}${process.stderr}'.trim(),
    );
  }

  try {
    if (generated.existsSync()) {
      generated.deleteSync(recursive: true);
    }
    if (caller.existsSync()) {
      caller.deleteSync();
    }

    final baselineGeneration = await generate('folders_list_for_parent.json');
    caller.writeAsStringSync(_oldCaller);
    final baselineAnalysis = await analyzeCaller();
    final baselineSource = File(
      '${generated.path}/modules/folders.dart',
    ).readAsStringSync();
    final resultIsDynamic = baselineSource.contains(
      'Future<dynamic> listForParent',
    );
    final firstGeneration = _directorySnapshot(generated);

    final secondGenerationResult = await generate(
      'folders_list_for_parent.json',
    );
    final secondGeneration = _directorySnapshot(generated);
    final deterministic =
        secondGenerationResult.exitCode == 0 &&
        _snapshotsEqual(firstGeneration, secondGeneration);

    final functionRenameGeneration = await generate(
      'folders_function_renamed.json',
    );
    final functionRenameAnalysis = await analyzeCaller();

    final argumentRenameGeneration = await generate(
      'folders_argument_renamed.json',
    );
    final argumentRenameAnalysis = await analyzeCaller();

    await generate('folders_list_for_parent.json');
    final resultFieldAnalysis = await analyzeCaller();

    final unsupportedGeneration = await generate(
      'folders_unsupported_validator.json',
    );
    final unsupportedSource = File(
      '${generated.path}/modules/folders.dart',
    ).readAsStringSync();

    final functionRenameCaught =
        functionRenameGeneration.exitCode == 0 &&
        functionRenameAnalysis.exitCode != 0;
    final argumentRenameCaught =
        argumentRenameGeneration.exitCode == 0 &&
        argumentRenameAnalysis.exitCode != 0;
    final resultRenameCaught =
        !resultIsDynamic && resultFieldAnalysis.exitCode != 0;
    final unsupportedRejected = unsupportedGeneration.exitCode != 0;
    final baselineCompiles =
        baselineGeneration.exitCode == 0 && baselineAnalysis.exitCode == 0;
    final gatePassed =
        baselineCompiles &&
        functionRenameCaught &&
        argumentRenameCaught &&
        resultRenameCaught &&
        unsupportedRejected &&
        deterministic;

    final report = <String, Object?>{
      'schemaVersion': 1,
      'evaluation': 'convex_dart_client_contract_gate',
      'baseCommit': _gitBaseCommit(root),
      'adapterCandidate': 'dartvex',
      'sdkVersion': _dartvexVersion,
      'codegenVersion': _dartvexCodegenVersion,
      'platform': _platformName(),
      'dartVersion': Platform.version,
      'fixture': 'folders:listForParent',
      'baselineCompiles': baselineCompiles,
      'checks': <Map<String, Object?>>[
        <String, Object?>{
          'id': 'function_rename',
          'required': 'old_generated_method_fails_analysis',
          'status': functionRenameCaught ? 'pass' : 'fail',
          'generationExitCode': functionRenameGeneration.exitCode,
          'analysisExitCode': functionRenameAnalysis.exitCode,
        },
        <String, Object?>{
          'id': 'argument_rename',
          'required': 'old_named_argument_fails_analysis',
          'status': argumentRenameCaught ? 'pass' : 'fail',
          'generationExitCode': argumentRenameGeneration.exitCode,
          'analysisExitCode': argumentRenameAnalysis.exitCode,
        },
        <String, Object?>{
          'id': 'result_field_rename',
          'required': 'old_result_field_fails_analysis',
          'status': resultRenameCaught ? 'pass' : 'fail',
          'analysisExitCode': resultFieldAnalysis.exitCode,
          'generatedReturnType': resultIsDynamic ? 'dynamic' : 'typed',
          'detail': resultIsDynamic
              ? 'The unvalidated Convex result is absent from function-spec and the old dynamic field access still analyzes.'
              : 'The generated result is typed.',
        },
        <String, Object?>{
          'id': 'unsupported_validator',
          'required': 'generation_stops_with_function_and_field_path',
          'status': unsupportedRejected ? 'pass' : 'fail',
          'generationExitCode': unsupportedGeneration.exitCode,
          'generatedFieldType':
              unsupportedSource.contains('dynamic futureField')
              ? 'dynamic'
              : 'not_dynamic',
          'diagnostics': _sanitizeDiagnostics(<String>[
            ...unsupportedGeneration.logs,
            ...unsupportedGeneration.errors,
          ], root),
        },
        <String, Object?>{
          'id': 'deterministic_regeneration',
          'required': 'second_generation_has_no_diff',
          'status': deterministic ? 'pass' : 'fail',
          'changedFiles': _changedFiles(firstGeneration, secondGeneration),
        },
      ],
      'gatePassed': gatePassed,
      'decision': gatePassed
          ? 'continue_runtime_gauntlet'
          : 'keep_convex_flutter',
      'runtimeGauntlet': <String, Object?>{
        'status': gatePassed ? 'pending' : 'skipped',
        'reason': gatePassed ? null : 'compile_time_contract_gate_failed',
        'correctnessSeedsRun': 0,
        'operationsRun': 0,
        'pairedProfileRuns': 0,
        'p95RemoteConvergenceMs': null,
        'peakMemoryBytes': null,
      },
    };
    return ContractGateResult(report: report);
  } finally {
    if (generated.existsSync()) {
      generated.deleteSync(recursive: true);
    }
    if (caller.existsSync()) {
      caller.deleteSync();
    }
  }
}

String _gitBaseCommit(Directory root) {
  final result = Process.runSync('git', <String>[
    'merge-base',
    'HEAD',
    'origin/icarus-cloud',
  ], workingDirectory: root.path);
  if (result.exitCode != 0) {
    throw StateError('Unable to resolve the Icarus base commit.');
  }
  return result.stdout.toString().trim();
}

String _platformName() {
  final match = RegExp(r'on "([^"]+)"').firstMatch(Platform.version);
  final rawArchitecture = match?.group(1) ?? 'unknown';
  final architecture = rawArchitecture.replaceFirst(
    '${Platform.operatingSystem}_',
    '',
  );
  return '${Platform.operatingSystem}-$architecture';
}

List<String> _sanitizeDiagnostics(List<String> diagnostics, Directory root) =>
    diagnostics
        .map((message) => message.replaceAll(root.path, '<gauntlet-root>'))
        .toList(growable: false);

Map<String, List<int>> _directorySnapshot(Directory directory) {
  final snapshot = <String, List<int>>{};
  final files =
      directory
          .listSync(recursive: true)
          .whereType<File>()
          .toList(growable: false)
        ..sort((left, right) => left.path.compareTo(right.path));
  for (final file in files) {
    final relative = file.path.substring(directory.path.length + 1);
    snapshot[relative] = file.readAsBytesSync();
  }
  return snapshot;
}

bool _snapshotsEqual(
  Map<String, List<int>> left,
  Map<String, List<int>> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    final other = right[entry.key];
    if (other == null || !_bytesEqual(entry.value, other)) {
      return false;
    }
  }
  return true;
}

List<String> _changedFiles(
  Map<String, List<int>> left,
  Map<String, List<int>> right,
) {
  final paths = <String>{...left.keys, ...right.keys}.toList()..sort();
  return paths
      .where((path) {
        final leftBytes = left[path];
        final rightBytes = right[path];
        return leftBytes == null ||
            rightBytes == null ||
            !_bytesEqual(leftBytes, rightBytes);
      })
      .toList(growable: false);
}

bool _bytesEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

final class _Generation {
  const _Generation({
    required this.exitCode,
    required this.logs,
    required this.errors,
  });

  final int exitCode;
  final List<String> logs;
  final List<String> errors;
}

final class _Analysis {
  const _Analysis({required this.exitCode, required this.output});

  final int exitCode;
  final String output;
}

const _oldCaller = '''
import '_probe_generated/api.dart';

Future<String> readFirstFolderPublicId(ConvexApi api) async {
  final result = await api.folders.listForParent(
    parentFolderPublicId: const Optional.of('parent-folder'),
  );
  return result.first.publicId as String;
}
''';
