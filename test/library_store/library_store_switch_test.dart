import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/startup/hive_store_launch.dart';

void main() {
  test('the store is off when nothing asks for it', () {
    final launch = LibraryStoreLaunch.parse(const ['a.ica'], mayShadow: true);
    expect(launch.choice, isA<StoreSwitchOff>());
    expect(launch.otherArgs, ['a.ica']);
    expect(ProviderContainer().read(libraryStoreSwitchProvider),
        isA<StoreSwitchOff>());
  });

  test(
      'a driver or debug build can ask for shadow, and the option never reaches the files to open',
      () {
    final launch = LibraryStoreLaunch.parse(
      const ['--hive-store-dir=/tmp/s', '--library-store=shadow', 'a.ica'],
      mayShadow: true,
    );
    expect(launch.choice, isA<StoreSwitchShadow>());
    expect(launch.otherArgs, ['--hive-store-dir=/tmp/s', 'a.ica']);
  });

  test('a shipped build stays off whatever it is asked, and still starts', () {
    for (final value in ['shadow', 'on', '']) {
      final launch = LibraryStoreLaunch.parse(
        ['--library-store=$value', '--library-store=shadow', 'a.ica'],
        mayShadow: false,
      );
      expect(launch.choice, isA<StoreSwitchOff>(), reason: value);
      expect(launch.otherArgs, ['a.ica'], reason: value);
    }
  });

  test('an unknown value or a second option is refused', () {
    expect(
      () => LibraryStoreLaunch.parse(const ['--library-store=on'],
          mayShadow: true),
      throwsA(isA<LibraryStoreLaunchException>()),
    );
    expect(
      () => LibraryStoreLaunch.parse(
        const ['--library-store=off', '--library-store=shadow'],
        mayShadow: true,
      ),
      throwsA(isA<LibraryStoreLaunchException>()),
    );
  });

  test(
      'every argument the switch does not own reaches the file-open parser unchanged and in order',
      () {
    const args = [
      r'C:\Strats\B site.ica',
      '--library-store=shadow',
      '--hive-store-dir=/tmp/store',
      '--library-storex=1',
      '--library-store',
      'shadow',
      '/home/me/a.ica',
    ];
    final launch = LibraryStoreLaunch.parse(args, mayShadow: true);
    expect(launch.otherArgs, [
      r'C:\Strats\B site.ica',
      '--hive-store-dir=/tmp/store',
      '--library-storex=1',
      '--library-store',
      'shadow',
      '/home/me/a.ica',
    ]);
    expect(HiveStoreLaunch.parse(launch.otherArgs).fileOpenArgs, [
      r'C:\Strats\B site.ica',
      '--library-storex=1',
      '--library-store',
      'shadow',
      '/home/me/a.ica',
    ]);
  });
}
