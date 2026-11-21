import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/startup/hive_store_launch.dart';

void main() {
  test('the store is off when nothing asks for it', () {
    final launch = LibraryStoreLaunch.parse(const ['a.ica'], mayShadow: true);
    expect(launch.choice, isA<StoreSwitchOff>());
    expect(launch.otherArgs, ['a.ica']);
    expect(
      ProviderContainer().read(libraryStoreSwitchProvider),
      isA<StoreSwitchOff>(),
    );
  });

  test(
      'a driver or debug build can ask for shadow, and the flag never reaches the files to open',
      () {
    final launch = LibraryStoreLaunch.parse(
      const ['--hive-store-dir=/tmp/s', '--library-store=shadow', 'a.ica'],
      mayShadow: true,
    );
    expect(launch.choice, isA<StoreSwitchShadow>());
    expect(launch.otherArgs, ['--hive-store-dir=/tmp/s', 'a.ica']);
  });

  test(
      'a build that may not shadow stays off when given the flag, and still drops it',
      () {
    final launch = LibraryStoreLaunch.parse(
      const ['--library-store=shadow', 'a.ica'],
      mayShadow: false,
    );
    expect(launch.choice, isA<StoreSwitchOff>());
    expect(launch.otherArgs, ['a.ica']);
  });

  test(
      'only the exact flags are the switch\'s: everything else reaches the file-open parser unchanged and in order',
      () {
    const args = [
      r'C:\Strats\B site.ica',
      '--library-store=off.ica',
      '--library-store=on',
      '--hive-store-dir=/tmp/store',
      '--library-store',
      'shadow',
      '--library-store=shadow',
      '/home/me/a.ica',
    ];
    final launch = LibraryStoreLaunch.parse(args, mayShadow: true);
    expect(launch.choice, isA<StoreSwitchShadow>());
    expect(launch.otherArgs, [
      r'C:\Strats\B site.ica',
      '--library-store=off.ica',
      '--library-store=on',
      '--hive-store-dir=/tmp/store',
      '--library-store',
      'shadow',
      '/home/me/a.ica',
    ]);
    expect(HiveStoreLaunch.parse(launch.otherArgs).fileOpenArgs, [
      r'C:\Strats\B site.ica',
      '--library-store=off.ica',
      '--library-store=on',
      '--library-store',
      'shadow',
      '/home/me/a.ica',
    ]);
  });
}
