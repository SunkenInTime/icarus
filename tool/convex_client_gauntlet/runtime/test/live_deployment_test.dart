// Runs the gauntlet in a `flutter test` process, so a plain Linux runner can
// run it without building the nested app. The native bridge comes from a
// cargo build named by FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR.
// tool/run_with_local_deployment.mjs sets everything this reads.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus_convex_runtime_gauntlet/auth.dart';
import 'package:icarus_convex_runtime_gauntlet/runner.dart';
import 'package:icarus_convex_runtime_gauntlet/transport.dart';

String _setting(String name) => Platform.environment[name] ?? '';

void main() {
  final deploymentUrl = _setting('CONVEX_URL');

  test(
    'the gauntlet reaches a checkpoint or passes',
    () async {
      // convex_flutter watches the app lifecycle through WidgetsBinding. The
      // test binding also fakes every HttpClient, which would stop the
      // Dartvex verifier's WebSocket, so the real one is put back.
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null;

      final adapter = _setting('ADAPTER').isEmpty
          ? 'convex_flutter'
          : _setting('ADAPTER');
      final runner = GauntletRunner(
        adapter: adapter,
        deploymentUrl: deploymentUrl,
        account: gauntletAuthFromSettings(_setting),
        seedCount: int.tryParse(_setting('SEED_COUNT')) ?? 50,
        gitCommit: _setting('GIT_COMMIT'),
        transportFactory: () async => switch (adapter) {
          'dartvex' => DartvexTransport(deploymentUrl),
          'convex_flutter' => ConvexFlutterTransport.create(deploymentUrl),
          _ => throw StateError('Unknown adapter: $adapter'),
        },
      );
      if (_setting('RESET_PROGRESS') == '1') await runner.resetProgress();
      final report = await runner.run(
        allowCheckpoint: _setting('ALLOW_CHECKPOINT') != '0',
      );
      final reportPath = _setting('REPORT_PATH');
      if (reportPath.isNotEmpty) {
        await File(reportPath).writeAsString(jsonEncode(report), flush: true);
      }
      expect(
        report['status'],
        anyOf('passed', 'checkpoint'),
        reason: '${report['losingCondition']}: ${report['message']}',
      );
    },
    timeout: Timeout.none,
    skip: deploymentUrl.isEmpty
        ? 'Run through tool/run_with_local_deployment.mjs'
        : false,
  );
}
