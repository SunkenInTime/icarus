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

  for (final mayShadow in [true, false]) {
    test(
        'the removed read mode is still taken and stays off '
        '(mayShadow: $mayShadow), so its flag is never opened as a file', () {
      final launch = LibraryStoreLaunch.parse(
        const ['--library-store=store', '--library-store=read', 'a.ica'],
        mayShadow: mayShadow,
      );
      expect(launch.choice, isA<StoreSwitchOff>());
      expect(launch.otherArgs, ['a.ica']);
    });
  }

  test(
      'a driver or debug build can ask for the library to run on the store; '
      'a build that may not stays off and drops the flag', () {
    expect(
      LibraryStoreLaunch.parse(const ['--library-store=store'], mayShadow: true)
          .choice,
      isA<StoreSwitchStore>(),
    );
    final refused = LibraryStoreLaunch.parse(
      const ['--library-store=store', 'a.ica'],
      mayShadow: false,
    );
    expect(refused.choice, isA<StoreSwitchOff>());
    expect(refused.otherArgs, ['a.ica']);
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

  test(
      'the cloud store is off when nothing asks for it, whatever the library store is',
      () {
    final launch = LibraryStoreLaunch.parse(
      const ['--library-store=shadow', 'a.ica'],
      mayShadow: true,
    );
    expect(launch.cloud, isA<CloudStoreOff>());
  });

  test(
      'an unknown cloud store value stops the launch as a usage error, and '
      'send is still its own flag', () {
    for (final value in ['shadow', 'mirror', '']) {
      expect(
        () => LibraryStoreLaunch.parse(
          ['${LibraryStoreLaunch.cloudStoreFlag}$value', 'a.ica'],
          mayShadow: true,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            '--cloud-store has no value "$value"; it takes send',
          ),
        ),
      );
    }

    final both = LibraryStoreLaunch.parse(
      const ['--cloud-store=send', '--library-store=mirror'],
      mayShadow: true,
    );
    expect(both.cloud, isA<CloudStoreSend>());
    expect(both.choice, isA<StoreSwitchMirror>());
    expect(both.otherArgs, isEmpty);
  });

  test(
      'a build that may not shadow keeps the cloud store off and drops the '
      'two flags main dropped; any other value is passed on as main passed it',
      () {
    for (final flag in [
      LibraryStoreLaunch.cloudSendFlag,
      LibraryStoreLaunch.cloudShadowFlag,
    ]) {
      final launch = LibraryStoreLaunch.parse(
        [flag, 'a.ica'],
        mayShadow: false,
      );
      expect(launch.cloud, isA<CloudStoreOff>(), reason: flag);
      expect(launch.otherArgs, ['a.ica'], reason: flag);
    }
    final other = '${LibraryStoreLaunch.cloudStoreFlag}mirror';
    final launch = LibraryStoreLaunch.parse([other, 'a.ica'], mayShadow: false);
    expect(launch.cloud, isA<CloudStoreOff>());
    expect(launch.otherArgs, [other, 'a.ica']);
  });
}
