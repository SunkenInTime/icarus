import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/strategy/local_library.dart';

typedef MigrationAtStart = ({
  LibraryMigration migration,
  String oldLibraryFolder,
});

final libraryMigrationProvider = StateProvider<MigrationAtStart?>(
  (ref) => null,
);

Future<Future<LibraryStoreOpened>?> moveLibraryIntoStore(
  ProviderContainer container,
  LibraryStoreLaunch launch, {
  required String? hiveDirectory,
  required bool allowsLocalLibrary,
  required String build,
}) async {
  if (launch.choice is! StoreSwitchStore ||
      !allowsLocalLibrary ||
      hiveDirectory == null) {
    return null;
  }
  final opening = container.read(libraryStoreProvider.notifier).open(
        libraryStoreFile(hiveDirectory),
        build: launch.cloud is CloudStoreSend ? build : '',
      );
  final migration = switch (await opening) {
    LibraryStoreReady(:final store) => await migrateLibraryIntoStore(
        store,
        strategies: _ownIdFirst([
          for (final (:key, :strategy)
              in const LocalLibrary().storedStrategyRecords)
            (own: '$key' == strategy.id, record: strategy),
        ]),
        folders: _ownIdFirst([
          for (final (:key, :folder)
              in const LocalLibrary().storedFolderRecords)
            (own: '$key' == folder.id, record: folder),
        ]),
      ),
    final notReady => MigrationNotRun('the store did not open: $notReady'),
  };
  container.read(libraryMigrationProvider.notifier).state = (
    migration: migration,
    oldLibraryFolder: hiveDirectory,
  );
  return opening;
}

List<T> _ownIdFirst<T>(List<({bool own, T record})> records) => [
      for (final entry in records)
        if (entry.own) entry.record,
      for (final entry in records)
        if (!entry.own) entry.record,
    ];
