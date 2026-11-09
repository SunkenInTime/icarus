// Runs the save-path gauntlet (gauntlet.dart) in a `flutter test` process.
// tool/convex_client_gauntlet/runtime/tool/run_with_local_deployment.mjs
// starts the throwaway deployment, mints the tokens, sets everything this
// reads, and starts the test again after its checkpoint: that is the process
// restart. The native bridge comes from a cargo build named by
// FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'gauntlet.dart';

String _setting(String name) => Platform.environment[name] ?? '';

void main() {
  final deploymentUrl = _setting('CONVEX_URL');

  test(
    'the save path keeps its promise under faults',
    () async {
      // convex_flutter watches the app lifecycle through WidgetsBinding. The
      // test binding also fakes every HttpClient, which would stop the
      // gauntlet's own reads of the server, so the real one is put back.
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = null;

      final gauntlet = SavePathGauntlet(
        deploymentUrl: deploymentUrl,
        backendPort: Uri.parse(deploymentUrl).port,
        accountId: _setting('GAUNTLET_ACCOUNT_SUBJECT'),
        accessToken: _setting('GAUNTLET_ACCESS_TOKEN'),
        refreshedAccessToken: _setting('GAUNTLET_REFRESHED_ACCESS_TOKEN'),
        stateDirectory: _setting('GAUNTLET_STATE_DIR'),
        seedCount: int.tryParse(_setting('SEED_COUNT')) ?? 3,
        allowCheckpoint: _setting('ALLOW_CHECKPOINT') != '0',
      );
      if (_setting('RESET_PROGRESS') == '1') await gauntlet.reset();
      final report = await gauntlet.run();
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
        ? 'Run through '
            'tool/convex_client_gauntlet/runtime/tool/run_with_local_deployment.mjs'
        : false,
  );
}
