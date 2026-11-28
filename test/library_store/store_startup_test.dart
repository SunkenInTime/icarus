import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/dev/drive/drive_cloud_store.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/store_startup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('with the cloud store flag off, start-up creates nothing of it', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('icarus-startup-');
    });
    tearDown(() => directory.delete(recursive: true));

    test('neither flag: no store, no sender, no driver lines', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final stores = openStores(
        container,
        LibraryStoreLaunch.parse(const [], mayShadow: true),
        hiveDirectory: directory.path,
        build: 'b',
      );
      beginCloudSender(container, stores, build: 'b');
      final log = CloudStoreLog();

      expect(stores.opening, isNull);
      expect(container.exists(cloudSenderProvider), isFalse);
      expect(log.drain(container), isEmpty);
      expect(await log.end(container, lastStep: DateTime.now()), isEmpty);
      expect(await log.readBack(container), isEmpty);
      expect(container.exists(cloudSenderProvider), isFalse);
    });

    test(
        'the library on the store opens the store through its move, still '
        'with no sender', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final stores = openStores(
        container,
        LibraryStoreLaunch.parse(
          const ['--library-store=store'],
          mayShadow: true,
        ),
        hiveDirectory: directory.path,
        build: 'b',
        alreadyOpening: container
            .read(libraryStoreProvider.notifier)
            .open(libraryStoreFile(directory.path)),
      );
      beginCloudSender(container, stores, build: 'b');
      await stores.opening;

      expect(container.exists(cloudSenderProvider), isFalse);
      await container.read(libraryStoreProvider.notifier).close();
    });
  });
}
