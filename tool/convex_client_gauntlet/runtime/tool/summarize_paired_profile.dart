import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

void main(List<String> args) {
  if (args.length != 4) {
    stderr.writeln(
      'Usage: dart run tool/summarize_paired_profile.dart '
      '<raw-dir> <bundle-bytes> <native-framework-bytes> '
      '<app-framework-bytes>',
    );
    exitCode = 64;
    return;
  }

  final rawDirectory = Directory(args[0]);
  final order = File(
    '${rawDirectory.path}/order.tsv',
  ).readAsLinesSync().skip(1).where((line) => line.trim().isNotEmpty);
  final samples = <Map<String, Object?>>[];

  for (final line in order) {
    final [trialText, position, adapter, reportName, timeName] = line.split(
      '\t',
    );
    final report =
        jsonDecode(File('${rawDirectory.path}/$reportName').readAsStringSync())
            as Map<String, Object?>;
    final seed =
        (report['seeds'] as List<Object?>).single as Map<String, Object?>;
    final auth = seed['auth'] as Map<String, Object?>;
    final timing = _parseTime(
      File('${rawDirectory.path}/$timeName').readAsStringSync(),
    );
    final runnerSeconds = (report['wallClockMs'] as num).toDouble() / 1000;
    final cpuPercent =
        100 * (timing.userSeconds + timing.systemSeconds) / runnerSeconds;

    samples.add({
      'trial': int.parse(trialText),
      'position': position,
      'adapter': adapter,
      'status': report['status'],
      'reportFile': reportName,
      'timeFile': timeName,
      'remoteConvergenceMs': seed['remoteConvergenceMs'],
      'reconnectToLiveMs': seed['reconnectToLiveMs'],
      'authFreshTokenAcceptedMs': auth['freshTokenAcceptedMs'],
      'authRecoveryMs': auth['recoveryMs'],
      'maxRssBytes': timing.maxRssBytes,
      'averageProcessCpuPercent': cpuPercent,
      'bytesSent': report['bytesSent'],
      'bytesReceived': report['bytesReceived'],
      'transferredBytes':
          (report['bytesSent'] as int) + (report['bytesReceived'] as int),
      'runnerWallClockMs': report['wallClockMs'],
      'processRealSeconds': timing.realSeconds,
      'processUserSeconds': timing.userSeconds,
      'processSystemSeconds': timing.systemSeconds,
    });
  }

  final commits = samples
      .map(
        (sample) =>
            jsonDecode(
                  File(
                    '${rawDirectory.path}/${sample['reportFile']}',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>,
      )
      .map((report) => report['gitCommit'])
      .toSet();
  final firstReport =
      jsonDecode(
            File(
              '${rawDirectory.path}/${samples.first['reportFile']}',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;

  final output = <String, Object?>{
    'schemaVersion': 1,
    'status': samples.every((sample) => sample['status'] == 'passed')
        ? 'passed'
        : 'failed',
    'gitCommit': commits.length == 1 ? commits.single : commits.toList(),
    'deployment': firstReport['deployment'],
    'trialCountPerAdapter': samples.length ~/ 2,
    'pairing': 'alternating first position by trial',
    'profileMode': 'Flutter macOS profile build',
    'cpuDefinition':
        '(process user seconds + system seconds) / runner wall-clock seconds',
    'transferDefinition':
        'application JSON bytes recorded by the neutral transport; excludes '
        'WebSocket framing and protocol metadata',
    'percentileDefinition': 'nearest-rank p95',
    'machine': firstReport['machine'],
    'toolVersions': {
      'flutter': '3.41.1 stable',
      'dart': '3.11.0 macos_arm64',
      'rustc': '1.90.0 stable',
      'node': '23.11.0',
      'convexCli': '1.45.0',
      'dartvex': '0.2.0',
      'convexFlutter': '3.0.1 + Icarus patch',
      'convexRust': '0.10.4 + Icarus patch',
      'flutterRustBridge': '2.11.1 pinned',
    },
    'desktopTargets': {
      'packageSupported': ['macos', 'windows', 'linux'],
      'measured': ['macos (universal arm64 + x86_64 build, arm64 host run)'],
      'notMeasured': [
        'windows (requires Windows host)',
        'linux (requires Linux host)',
      ],
    },
    'buildSize': {
      'sharedHarnessBundleBytes': int.parse(args[1]),
      'convexFlutterNativeFrameworkExecutableBytes': int.parse(args[2]),
      'sharedAppFrameworkExecutableBytes': int.parse(args[3]),
      'candidateIsolatedBundleBytes': null,
      'note':
          'The same harness bundle contains both adapters; only the native '
          'convex_flutter framework is candidate-specific.',
    },
    'summary': {
      for (final adapter in ['dartvex', 'convex_flutter'])
        adapter: _summary(
          samples.where((sample) => sample['adapter'] == adapter).toList(),
        ),
    },
    'samples': samples,
  };

  stdout.writeln(const JsonEncoder.withIndent('  ').convert(output));
}

Map<String, Object?> _summary(List<Map<String, Object?>> samples) {
  const fields = [
    'remoteConvergenceMs',
    'reconnectToLiveMs',
    'authFreshTokenAcceptedMs',
    'authRecoveryMs',
    'maxRssBytes',
    'averageProcessCpuPercent',
    'bytesSent',
    'bytesReceived',
    'transferredBytes',
    'runnerWallClockMs',
  ];
  return {
    for (final field in fields)
      field: _statistics(
        samples.map((sample) => (sample[field] as num).toDouble()).toList(),
      ),
  };
}

Map<String, Object?> _statistics(List<double> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  final median = sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
  final p95Index = math.max(0, (0.95 * sorted.length).ceil() - 1);
  return {
    'median': median,
    'p95': sorted[p95Index],
    'min': sorted.first,
    'max': sorted.last,
    'values': values,
  };
}

_ProcessTiming _parseTime(String raw) {
  double value(String label) => double.parse(
    RegExp(
      '^$label ([0-9.]+)\\s*\$',
      multiLine: true,
    ).firstMatch(raw)!.group(1)!,
  );
  final rss = int.parse(
    RegExp(
      r'^\s*([0-9]+)\s+maximum resident set size\s*$',
      multiLine: true,
    ).firstMatch(raw)!.group(1)!,
  );
  return _ProcessTiming(
    realSeconds: value('real'),
    userSeconds: value('user'),
    systemSeconds: value('sys'),
    maxRssBytes: rss,
  );
}

final class _ProcessTiming {
  const _ProcessTiming({
    required this.realSeconds,
    required this.userSeconds,
    required this.systemSeconds,
    required this.maxRssBytes,
  });

  final double realSeconds;
  final double userSeconds;
  final double systemSeconds;
  final int maxRssBytes;
}
