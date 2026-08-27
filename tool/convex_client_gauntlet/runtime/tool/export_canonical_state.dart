import 'dart:io';

import 'package:dartvex/dartvex.dart';
import 'package:supabase/supabase.dart';

import 'package:icarus_convex_runtime_gauntlet/workload.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run tool/export_canonical_state.dart <output>');
    exitCode = 64;
    return;
  }
  final environment = Platform.environment;
  final supabase = SupabaseClient(
    environment['SUPABASE_URL']!,
    environment['SUPABASE_KEY']!,
    authOptions: const AuthClientOptions(
      authFlowType: AuthFlowType.implicit,
      autoRefreshToken: false,
    ),
  );
  final auth = await supabase.auth.signInWithPassword(
    email: environment['TEST_EMAIL']!,
    password: environment['TEST_PASSWORD']!,
  );
  final session = auth.session ?? (throw StateError('Sign-in failed'));
  final convex = ConvexClient(environment['CONVEX_URL']!);
  await convex.setAuth(session.accessToken);
  try {
    final snapshot = await convex.query('strategy:getFullSnapshot', {
      'strategyPublicId': strategyId(0),
    });
    final folders = await convex.query('folders:listAll', {'scope': 'all'});
    final canonical = canonicalSnapshot(
      seed: 0,
      snapshot: snapshot,
      folders: folders,
    );
    await File(
      arguments.single,
    ).writeAsString(canonicalJson(canonical), flush: true);
    stdout.writeln(canonicalHash(canonical));
  } finally {
    await convex.close();
    await supabase.dispose();
  }
}
