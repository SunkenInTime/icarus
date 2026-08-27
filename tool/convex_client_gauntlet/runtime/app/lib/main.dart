import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:icarus_convex_runtime_gauntlet/runner.dart';
import 'package:icarus_convex_runtime_gauntlet/transport.dart';

String _setting(String name) =>
    Platform.environment[name] ?? String.fromEnvironment(name);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final deploymentUrl = _setting('CONVEX_URL');
    final adapterName = _setting('ADAPTER');
    final supabaseUrl = _setting('SUPABASE_URL');
    final supabaseKey = _setting('SUPABASE_KEY');
    final email = _setting('TEST_EMAIL');
    final password = _setting('TEST_PASSWORD');
    if ([
      deploymentUrl,
      adapterName,
      supabaseUrl,
      supabaseKey,
      email,
      password,
    ].any((value) => value.isEmpty)) {
      throw StateError('Required gauntlet settings are missing');
    }
    final runner = GauntletRunner(
      adapter: adapterName,
      deploymentUrl: deploymentUrl,
      supabaseUrl: supabaseUrl,
      supabaseKey: supabaseKey,
      email: email,
      password: password,
      seedCount: int.tryParse(_setting('SEED_COUNT')) ?? 50,
      gitCommit: _setting('GIT_COMMIT'),
      transportFactory: () async => switch (adapterName) {
        'dartvex' => DartvexTransport(deploymentUrl),
        'convex_flutter' => ConvexFlutterTransport.create(deploymentUrl),
        _ => throw StateError('Unknown adapter: $adapterName'),
      },
    );
    if (_setting('RESET_PROGRESS') == '1') await runner.resetProgress();
    final report = await runner.run(
      allowCheckpoint: _setting('ALLOW_CHECKPOINT') != '0',
    );
    final reportName = _setting('REPORT_NAME');
    if (reportName.isNotEmpty) {
      final reportFile = File('${Directory.systemTemp.path}/$reportName.json');
      await reportFile.writeAsString(jsonEncode(report), flush: true);
      stdout.writeln(
        'GAUNTLET_RESULT:${jsonEncode(<String, Object?>{'status': report['status'], 'adapter': report['adapter'], 'reportPath': reportFile.path})}',
      );
    } else {
      stdout.writeln('GAUNTLET_RESULT:${jsonEncode(report)}');
    }
    exit(0);
  } catch (error, stackTrace) {
    stderr.writeln('GAUNTLET_ERROR:$error');
    stderr.writeln(stackTrace);
    exit(1);
  }
}
