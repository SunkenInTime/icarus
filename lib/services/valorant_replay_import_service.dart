import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class ValorantReplayImportResult {
  const ValorantReplayImportResult({
    required this.trackPath,
    required this.diagnosticsPath,
    required this.reportPath,
    required this.completeMarkerPath,
    required this.parserFingerprint,
    required this.stdout,
    required this.stderr,
  });

  final String trackPath;
  final String diagnosticsPath;
  final String reportPath;
  final String completeMarkerPath;
  final String parserFingerprint;
  final String stdout;
  final String stderr;
}

class ValorantReplayImportException implements Exception {
  const ValorantReplayImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ValorantReplayImportService {
  static const _toolRelativePath = 'tools/valorant_replay_probe';
  static const _extractorScript = 'extract_native_track.mjs';
  static const _cacheVersion = 'native-v8-state-and-rpc-lifecycle';
  static const _minimumAbilitySchemaVersion = 2;
  static const _cacheMaxAge = Duration(days: 7);

  Future<ValorantReplayImportResult> extractNativeTrack(
    String vrfPath, {
    void Function(String message)? onProgress,
  }) async {
    final replayFile = File(vrfPath);
    if (!await replayFile.exists()) {
      throw ValorantReplayImportException('Replay file not found: $vrfPath');
    }

    final toolDirectory = await _findToolDirectory();
    final parserFingerprint = await _computeParserFingerprint(toolDirectory);
    final outputPaths = await _createOutputPaths(vrfPath, parserFingerprint);
    await _cleanOldImports(outputPaths.outputDirectory);
    if (await outputPaths.isComplete(
          cacheVersion: _cacheVersion,
          parserFingerprint: parserFingerprint,
        ) &&
        await _hasRequiredAbilitySchema(outputPaths.trackPath)) {
      onProgress?.call('Using validated replay cache...');
      return ValorantReplayImportResult(
        trackPath: outputPaths.trackPath,
        diagnosticsPath: outputPaths.diagnosticsPath,
        reportPath: outputPaths.reportPath,
        completeMarkerPath: outputPaths.completeMarkerPath,
        parserFingerprint: parserFingerprint,
        stdout: 'Reused validated replay cache.',
        stderr: '',
      );
    }

    onProgress?.call('Preparing replay parser...');
    final nodeExecutable = await _findNodeExecutable();
    onProgress?.call('Checking parser dependencies...');
    await _ensureToolDependencies(toolDirectory);

    final process = await Process.start(
      nodeExecutable,
      [
        p.join(toolDirectory.path, _extractorScript),
        replayFile.absolute.path,
        '--out',
        outputPaths.trackPath,
        '--diagnostics',
        outputPaths.diagnosticsPath,
        '--report-out',
        outputPaths.reportPath,
      ],
      workingDirectory: toolDirectory.path,
    );

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      stdoutBuffer.writeln(line);
      _forwardExtractorProgress(line, onProgress);
    });
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      stderrBuffer.writeln(line);
      _forwardExtractorProgress(line, onProgress);
    });
    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);

    final stdout = stdoutBuffer.toString();
    final stderr = stderrBuffer.toString();
    if (exitCode != 0) {
      throw ValorantReplayImportException(
        [
          'VRF import failed with exit code $exitCode.',
          if (stderr.trim().isNotEmpty) _tail(stderr),
          if (stdout.trim().isNotEmpty) _tail(stdout),
        ].join('\n'),
      );
    }

    if (!await File(outputPaths.trackPath).exists()) {
      throw const ValorantReplayImportException(
        'VRF import finished, but no replay track was written.',
      );
    }
    if (!await _hasRequiredAbilitySchema(outputPaths.trackPath)) {
      throw const ValorantReplayImportException(
        'VRF import produced a movement track without the required replay-native ability action schema.',
      );
    }
    return ValorantReplayImportResult(
      trackPath: outputPaths.trackPath,
      diagnosticsPath: outputPaths.diagnosticsPath,
      reportPath: outputPaths.reportPath,
      completeMarkerPath: outputPaths.completeMarkerPath,
      parserFingerprint: parserFingerprint,
      stdout: stdout,
      stderr: stderr,
    );
  }

  Future<void> markTrackAccepted(ValorantReplayImportResult result) async {
    try {
      await File(result.completeMarkerPath).writeAsString(
        jsonEncode({
          'cacheVersion': _cacheVersion,
          'parserFingerprint': result.parserFingerprint,
        }),
        flush: true,
      );
    } on FileSystemException {
      // Cache persistence is optional; the decoded track is already valid.
    }
  }

  Future<void> invalidateCachedTrack(ValorantReplayImportResult result) async {
    try {
      final marker = File(result.completeMarkerPath);
      if (await marker.exists()) await marker.delete();
    } on FileSystemException {
      // A failed parse is already surfaced to the user; invalidation is best-effort.
    }
  }

  Future<bool> _hasRequiredAbilitySchema(String trackPath) async {
    RandomAccessFile? handle;
    try {
      final file = File(trackPath);
      handle = await file.open();
      final prefixLength = math.min(await file.length(), 256 * 1024);
      final prefix = utf8.decode(
        await handle.read(prefixLength),
        allowMalformed: true,
      );
      final schemaMatch = RegExp(
        r'"abilitySchemaVersion"\s*:\s*(\d+)',
      ).firstMatch(prefix);
      final schemaVersion = int.tryParse(schemaMatch?.group(1) ?? '');
      return schemaVersion != null &&
          schemaVersion >= _minimumAbilitySchemaVersion &&
          RegExp(r'"characterAbilityCastInfo"\s*:\s*true').hasMatch(prefix) &&
          RegExp(r'"actorChannelOpenClose"\s*:\s*true').hasMatch(prefix) &&
          RegExp(r'"equippableStateTransitions"\s*:\s*true').hasMatch(prefix) &&
          RegExp(r'"abilityLifecycleRpcEvents"\s*:\s*true').hasMatch(prefix) &&
          RegExp(r'"canonicalAbilityActions"\s*:\s*true').hasMatch(prefix);
    } on FileSystemException {
      return false;
    } finally {
      await handle?.close();
    }
  }

  Future<Directory> _findToolDirectory() async {
    final roots = <String>[
      p.dirname(Platform.resolvedExecutable),
      Directory.current.absolute.path,
    ];

    for (final root in roots) {
      final match = _walkUpForToolDirectory(root);
      if (match != null) return Directory(match);
    }

    throw const ValorantReplayImportException(
      'Could not find tools/valorant_replay_probe. Run the app from the Icarus repo checkout.',
    );
  }

  String? _walkUpForToolDirectory(String startPath) {
    var current = Directory(startPath).absolute.path;
    for (var depth = 0; depth < 12; depth += 1) {
      final toolDir = p.join(current, _toolRelativePath);
      final scriptPath = p.join(toolDir, _extractorScript);
      if (File(scriptPath).existsSync()) return toolDir;

      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return null;
  }

  Future<String> _findNodeExecutable() async {
    for (final candidate
        in Platform.isWindows ? ['node.exe', 'node'] : ['node']) {
      try {
        final result = await Process.run(candidate, ['--version']);
        if (result.exitCode == 0) return candidate;
      } on ProcessException {
        // Try the next candidate.
      }
    }

    throw const ValorantReplayImportException(
      'Node.js was not found on PATH. Install Node.js 20+ to import .vrf replays.',
    );
  }

  Future<void> _ensureToolDependencies(Directory toolDirectory) async {
    final oozPackage = Directory(
      p.join(toolDirectory.path, 'node_modules', 'ooz-wasm'),
    );
    final zstdPackage = Directory(
      p.join(toolDirectory.path, 'node_modules', 'zstddec'),
    );
    if (await oozPackage.exists() && await zstdPackage.exists()) return;

    final packageLock = File(p.join(toolDirectory.path, 'package-lock.json'));
    final packageJson = File(p.join(toolDirectory.path, 'package.json'));
    if (!await packageJson.exists()) {
      throw ValorantReplayImportException(
        'Could not find ${packageJson.path}. Run the app from the Icarus repo checkout.',
      );
    }

    final executableDirectory = p.dirname(Platform.resolvedExecutable);
    if (p.isWithin(executableDirectory, toolDirectory.path)) {
      throw const ValorantReplayImportException(
        'The installed replay parser is missing its bundled decoder dependencies. Reinstall Icarus.',
      );
    }

    final npmExecutable = await _findNpmExecutable();
    final installArgs = [
      if (await packageLock.exists()) 'ci' else 'install',
      '--no-audit',
      '--no-fund',
    ];
    final result = await Process.run(
      npmExecutable,
      installArgs,
      workingDirectory: toolDirectory.path,
    );

    if (result.exitCode != 0) {
      final stdout = '${result.stdout}';
      final stderr = '${result.stderr}';
      throw ValorantReplayImportException(
        [
          'VRF import needs Node dependencies, but npm ${installArgs.first} failed with exit code ${result.exitCode}.',
          'Run: npm --prefix "${toolDirectory.path}" ${installArgs.first}',
          if (stderr.trim().isNotEmpty) _tail(stderr),
          if (stdout.trim().isNotEmpty) _tail(stdout),
        ].join('\n'),
      );
    }
  }

  Future<String> _findNpmExecutable() async {
    for (final candidate
        in Platform.isWindows ? ['npm.cmd', 'npm.exe', 'npm'] : ['npm']) {
      try {
        final result = await Process.run(candidate, ['--version']);
        if (result.exitCode == 0) return candidate;
      } on ProcessException {
        // Try the next candidate.
      }
    }

    throw const ValorantReplayImportException(
      'npm was not found on PATH. Install Node.js/npm to import .vrf replays.',
    );
  }

  Future<String> _computeParserFingerprint(Directory toolDirectory) async {
    const relativeFiles = [
      'extract_native_track.mjs',
      'extract_track.mjs',
      'verified_ability_lifecycle_registry.json',
      'analyze_component_data_stream_native.mjs',
      'valorant_seeded_payload_transform.mjs',
      'package-lock.json',
      'static_decoder_indexes/static_decoder_index_summary.json',
      'static_decoder_indexes/agent_primary_index.json',
      'static_decoder_indexes/ability_actor_index.json',
      'static_decoder_indexes/ability_identity_index.json',
      'static_decoder_indexes/ability_spawn_graph_edges.jsonl',
    ];
    var hash = 0x811c9dc5;

    void addBytes(Iterable<int> bytes) {
      for (final byte in bytes) {
        hash ^= byte;
        hash = (hash * 0x01000193) & 0xffffffff;
      }
    }

    for (final relativePath in relativeFiles) {
      addBytes(utf8.encode(relativePath));
      final file = File(
        p.joinAll([toolDirectory.path, ...relativePath.split('/')]),
      );
      if (!await file.exists()) {
        addBytes(const [0]);
        continue;
      }
      await for (final chunk in file.openRead()) {
        addBytes(chunk);
      }
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  Future<_ReplayImportOutputPaths> _createOutputPaths(
    String vrfPath,
    String parserFingerprint,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final replayStat = await File(vrfPath).stat();
    final replayName = p.basenameWithoutExtension(vrfPath);
    final safeName = replayName.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
    final fingerprint = [
      replayStat.size,
      replayStat.modified.millisecondsSinceEpoch,
      _cacheVersion,
      parserFingerprint,
    ].join('-');
    final outputDir = Directory(
      p.join(tempDir.path, 'icarus_replay_imports', '$safeName-$fingerprint'),
    );
    await outputDir.create(recursive: true);

    final basePath = p.join(outputDir.path, safeName);
    return _ReplayImportOutputPaths(
      outputDirectory: outputDir.path,
      trackPath: '$basePath.native_component.track.json',
      diagnosticsPath: '$basePath.diagnostics.json',
      reportPath: '$basePath.native_report.json',
      completeMarkerPath: '$basePath.complete',
    );
  }

  Future<void> _cleanOldImports(String activeDirectoryPath) async {
    final root = Directory(p.dirname(activeDirectoryPath));
    if (!await root.exists()) return;
    final cutoff = DateTime.now().subtract(_cacheMaxAge);
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory ||
            p.equals(entity.path, activeDirectoryPath)) {
          continue;
        }
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete(recursive: true);
        }
      }
    } on FileSystemException {
      // Cache cleanup is best-effort and must never block a replay import.
    }
  }
}

class _ReplayImportOutputPaths {
  const _ReplayImportOutputPaths({
    required this.outputDirectory,
    required this.trackPath,
    required this.diagnosticsPath,
    required this.reportPath,
    required this.completeMarkerPath,
  });

  final String outputDirectory;
  final String trackPath;
  final String diagnosticsPath;
  final String reportPath;
  final String completeMarkerPath;

  Future<bool> isComplete({
    required String cacheVersion,
    required String parserFingerprint,
  }) async {
    final artifacts = [trackPath, diagnosticsPath, reportPath];
    for (final path in artifacts) {
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) return false;
    }

    final marker = File(completeMarkerPath);
    if (!await marker.exists()) return false;
    try {
      final decoded = jsonDecode(await marker.readAsString());
      return decoded is Map<String, dynamic> &&
          decoded['cacheVersion'] == cacheVersion &&
          decoded['parserFingerprint'] == parserFingerprint;
    } on FormatException {
      return false;
    } on FileSystemException {
      return false;
    }
  }
}

void _forwardExtractorProgress(
  String line,
  void Function(String message)? onProgress,
) {
  const prefix = '[icarus-replay] ';
  if (line.startsWith(prefix)) {
    onProgress?.call(line.substring(prefix.length).trim());
  }
}

String _tail(String value, {int maxLines = 12}) {
  final lines = value.trim().split(RegExp(r'\r?\n'));
  return lines.length <= maxLines
      ? lines.join('\n')
      : lines.sublist(lines.length - maxLines).join('\n');
}
