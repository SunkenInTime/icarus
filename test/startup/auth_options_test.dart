import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/dev/drive/drive_session.dart';
import 'package:icarus/startup/app_instance.dart';
import 'package:icarus/startup/cloud_bootstrap.dart';

void main() {
  const separate = SeparateInstance('/tmp/icarus-separate-auth');

  test(
      'the installed app gives Supabase its default storage for the session '
      'and the sign-in flow', () {
    final options = authOptionsFor(const InstalledApp(), driveBuild: false);

    expect(options.localStorage, isNull);
    expect(options.pkceAsyncStorage, isNull);
  });

  test('a separate instance gives Supabase files in its folder for both', () {
    final options = authOptionsFor(separate, driveBuild: false);

    expect(options.localStorage, isA<FileSessionStorage>());
    expect(options.pkceAsyncStorage, isA<FileAuthFlowStorage>());
  });

  test(
      'a driver build keeps the session file its runner names, and a '
      'separate one keeps its sign-in flow in its folder', () {
    final options = authOptionsFor(separate, driveBuild: true);

    expect(options.localStorage, isA<DriveSessionStorage>());
    expect(options.pkceAsyncStorage, isA<FileAuthFlowStorage>());
  });
}
