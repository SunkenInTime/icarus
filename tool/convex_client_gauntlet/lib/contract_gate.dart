import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'strict_codegen.dart';

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

  Future<StrictGenerationResult> generate(String fixtureName) async {
    return runStrictConvexCodegen(
      specFile: '${root.path}/fixtures/$fixtureName',
      outputDirectory: generated,
      stableModulePaths: const <String>['modules/folders.dart'],
    );
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
    final firstGenerationHash = _snapshotSha256(firstGeneration);

    final secondGenerationResult = await generate(
      'folders_list_for_parent.json',
    );
    final secondGeneration = _directorySnapshot(generated);
    final secondGenerationHash = _snapshotSha256(secondGeneration);
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
    final resultRenameGeneration = await generate(
      'folders_result_renamed.json',
    );
    final resultFieldAnalysis = await analyzeCaller();

    final missingReturnGeneration = await generate(
      'folders_missing_return.json',
    );

    final unsupportedGeneration = await generate(
      'folders_unsupported_validator.json',
    );
    final unsupportedSource = File(
      '${generated.path}/modules/folders.dart',
    ).readAsStringSync();

    final functionRenameCaught =
        functionRenameGeneration.accepted &&
        functionRenameAnalysis.exitCode != 0;
    final argumentRenameCaught =
        argumentRenameGeneration.accepted &&
        argumentRenameAnalysis.exitCode != 0;
    final resultRenameCaught =
        resultRenameGeneration.accepted &&
        !resultIsDynamic &&
        resultFieldAnalysis.exitCode != 0;
    final missingReturnRejected = !missingReturnGeneration.accepted;
    final unsupportedRejected = !unsupportedGeneration.accepted;
    final baselineCompiles =
        baselineGeneration.accepted && baselineAnalysis.exitCode == 0;
    final gatePassed =
        baselineCompiles &&
        functionRenameCaught &&
        argumentRenameCaught &&
        resultRenameCaught &&
        missingReturnRejected &&
        unsupportedRejected &&
        deterministic;

    final report = <String, Object?>{
      'schemaVersion': 2,
      'evaluation': 'convex_dart_client_contract_gate',
      'baseCommit': _gitBaseCommit(root),
      'adapterCandidate': 'dartvex',
      'sdkVersion': _dartvexVersion,
      'codegenVersion': _dartvexCodegenVersion,
      'platform': _platformName(),
      'dartVersion': Platform.version,
      'fixture': 'folders:listForParent',
      'baselineCompiles': baselineCompiles,
      'baselineAnalysisExitCode': baselineAnalysis.exitCode,
      'baselineAnalysisDiagnostics': _sanitizeDiagnostics(<String>[
        baselineAnalysis.output,
      ], root),
      'checks': <Map<String, Object?>>[
        <String, Object?>{
          'id': 'function_rename',
          'required': 'old_generated_method_fails_analysis',
          'status': functionRenameCaught ? 'pass' : 'fail',
          'generationExitCode': functionRenameGeneration.exitCode,
          'rawGenerationExitCode': functionRenameGeneration.rawExitCode,
          'analysisExitCode': functionRenameAnalysis.exitCode,
        },
        <String, Object?>{
          'id': 'argument_rename',
          'required': 'old_named_argument_fails_analysis',
          'status': argumentRenameCaught ? 'pass' : 'fail',
          'generationExitCode': argumentRenameGeneration.exitCode,
          'rawGenerationExitCode': argumentRenameGeneration.rawExitCode,
          'analysisExitCode': argumentRenameAnalysis.exitCode,
        },
        <String, Object?>{
          'id': 'result_field_rename',
          'required': 'old_result_field_fails_analysis',
          'status': resultRenameCaught ? 'pass' : 'fail',
          'generationExitCode': resultRenameGeneration.exitCode,
          'rawGenerationExitCode': resultRenameGeneration.rawExitCode,
          'analysisExitCode': resultFieldAnalysis.exitCode,
          'generatedReturnType': resultIsDynamic ? 'dynamic' : 'typed',
          'detail': resultIsDynamic
              ? 'The generated result is unexpectedly dynamic.'
              : 'The explicit return is typed and the renamed result rejects the unchanged caller.',
        },
        <String, Object?>{
          'id': 'missing_return_schema',
          'required': 'strict_generation_rejects_public_dynamic_result',
          'status': missingReturnRejected ? 'pass' : 'fail',
          'generationExitCode': missingReturnGeneration.exitCode,
          'rawGenerationExitCode': missingReturnGeneration.rawExitCode,
          'diagnostics': _sanitizeDiagnostics(
            missingReturnGeneration.diagnostics,
            root,
          ),
        },
        <String, Object?>{
          'id': 'unsupported_validator',
          'required': 'generation_stops_with_function_and_field_path',
          'status': unsupportedRejected ? 'pass' : 'fail',
          'generationExitCode': unsupportedGeneration.exitCode,
          'rawGenerationExitCode': unsupportedGeneration.rawExitCode,
          'generatedFieldType':
              unsupportedSource.contains('dynamic futureField')
              ? 'dynamic'
              : 'not_dynamic',
          'diagnostics': _sanitizeDiagnostics(
            unsupportedGeneration.diagnostics,
            root,
          ),
        },
        <String, Object?>{
          'id': 'deterministic_regeneration',
          'required': 'second_generation_has_no_diff',
          'status': deterministic ? 'pass' : 'fail',
          'firstSha256': firstGenerationHash,
          'secondSha256': secondGenerationHash,
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

String _snapshotSha256(Map<String, List<int>> snapshot) {
  final bytes = BytesBuilder(copy: false);
  for (final entry in snapshot.entries) {
    bytes
      ..add(utf8.encode(entry.key))
      ..addByte(0)
      ..add(entry.value)
      ..addByte(0);
  }
  return sha256.convert(bytes.takeBytes()).toString();
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
  return result.first.publicId;
}
''';
