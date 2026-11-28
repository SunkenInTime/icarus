import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/store_library.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus_library/icarus_library.dart';

typedef MigrationAtStart = ({
  LibraryMigration migration,
  String oldLibraryFolder,
});

final libraryMigrationProvider = StateProvider<MigrationAtStart?>(
  (ref) => null,
);

sealed class LibraryOnStore {
  const LibraryOnStore();
}

final class LibraryServedFromStore extends LibraryOnStore {
  const LibraryServedFromStore(this.loading);

  final Duration loading;
}

final class LibraryNotServed extends LibraryOnStore {
  const LibraryNotServed({
    required this.why,
    required this.oldLibraryFolder,
    required this.tryAgain,
    required this.tries,
  });

  final String why;
  final int tries;
  final String oldLibraryFolder;
  final Future<void> Function() tryAgain;
}

final libraryOnStoreProvider = StateProvider<LibraryOnStore?>((ref) => null);

Future<Future<LibraryStoreOpened>?> openLibraryOnStore(
  ProviderContainer container,
  LibraryStoreLaunch launch, {
  required String? hiveDirectory,
  required bool allowsLocalLibrary,
  required String build,
  required Future<void> Function() bringUpToDate,
  required void Function() servedAgain,
}) async {
  Future<Future<LibraryStoreOpened>?> move() => moveLibraryIntoStore(
        container,
        launch,
        hiveDirectory: hiveDirectory,
        allowsLocalLibrary: allowsLocalLibrary,
        build: build,
      );
  var tries = 1;
  late final Future<void> Function() tryAgain;
  Future<void>? trying;
  Future<void> tryOnce() async {
    tries++;
    await container.read(libraryStoreProvider.notifier).close();
    await move();
    if (await _serve(container, tryAgain, tries) is LibraryServedFromStore) {
      await bringUpToDate();
      servedAgain();
    }
  }

  tryAgain = () => trying ??= tryOnce().whenComplete(() => trying = null);
  final opening = await move();
  if (opening != null) await _serve(container, tryAgain, tries);
  return opening;
}

Future<LibraryOnStore> _serve(
  ProviderContainer container,
  Future<void> Function() tryAgain,
  int tries,
) async {
  final atStart = container.read(libraryMigrationProvider)!;
  final String why;
  switch (atStart.migration) {
    case MigrationWasFinished() || MigrationFinishedNow():
      switch (container.read(libraryStoreProvider)) {
        case LibraryStoreReady(:final store):
          final loading = Stopwatch()..start();
          switch (await StoreLibrary.load(
            store,
            lost: (why) => _notServed(container, atStart, why, tryAgain, tries),
          )) {
            case StoreLibraryLoaded(:final library):
              LocalLibrary.source = LibraryInStore(library);
              return container.read(libraryOnStoreProvider.notifier).state =
                  LibraryServedFromStore(loading.elapsed);
            case StoreLibraryNotLoaded(why: final notLoaded):
              why = notLoaded;
          }
        case final other:
          why = 'the store is not open: $other';
      }
    case MigrationStopped(:final failure):
      why = 'the copy stopped: $failure';
    case MigrationRecordUnreadable(:final problem):
      why = 'the record of the copy cannot be read: $problem';
    case MigrationNotRun(why: final notRun):
      why = notRun;
  }
  return _notServed(container, atStart, why, tryAgain, tries);
}

LibraryNotServed _notServed(
  ProviderContainer container,
  MigrationAtStart atStart,
  String why,
  Future<void> Function() tryAgain,
  int tries,
) {
  LocalLibrary.source = const LibraryNotOpened();
  AppErrorReporter.reportError(
    "The library couldn't be opened from its new storage: $why",
    source: 'main.libraryOnStore',
    promptUser: false,
  );
  return container.read(libraryOnStoreProvider.notifier).state =
      LibraryNotServed(
    why: why,
    oldLibraryFolder: atStart.oldLibraryFolder,
    tryAgain: tryAgain,
    tries: tries,
  );
}

Future<Future<LibraryStoreOpened>?> moveLibraryIntoStore(
  ProviderContainer container,
  LibraryStoreLaunch launch, {
  required String? hiveDirectory,
  required bool allowsLocalLibrary,
  required String build,
}) async {
  if (!libraryGoesToStore(
        launch,
        hiveDirectory: hiveDirectory,
        allowsLocalLibrary: allowsLocalLibrary,
      ) ||
      hiveDirectory == null) {
    return null;
  }
  final opening = container.read(libraryStoreProvider.notifier).open(
        libraryStoreFile(hiveDirectory),
        build: launch.cloud is CloudStoreSend ? build : '',
      );
  final migration = switch (await opening) {
    LibraryStoreReady(
      store: LibraryStore(migration: final MigrationFinished record)
    ) =>
      MigrationWasFinished(record),
    LibraryStoreReady(
      store: LibraryStore(migration: MigrationUnreadable(:final problem)),
    ) =>
      MigrationRecordUnreadable(problem),
    LibraryStoreReady(:final store) =>
      await _copyFromHive(store, hiveDirectory),
    final notReady => MigrationNotRun('the store did not open: $notReady'),
  };
  container.read(libraryMigrationProvider.notifier).state = (
    migration: migration,
    oldLibraryFolder: hiveDirectory,
  );
  return opening;
}

bool libraryGoesToStore(
  LibraryStoreLaunch launch, {
  required String? hiveDirectory,
  required bool allowsLocalLibrary,
}) =>
    launch.choice is StoreSwitchStore &&
    allowsLocalLibrary &&
    hiveDirectory != null;

Future<LibraryMigration> _copyFromHive(
  LibraryStore store,
  String hiveDirectory,
) async {
  if (!LocalLibrary.hiveFilesIn(hiveDirectory)) {
    return migrateLibraryIntoStore(store, strategies: [], folders: []);
  }
  await LocalLibrary.openHiveBoxes();
  return migrateLibraryIntoStore(
    store,
    strategies: _ownIdFirst([
      for (final (:key, :strategy) in const LocalLibrary().hiveStrategyRecords)
        (own: '$key' == strategy.id, record: strategy),
    ]),
    folders: _ownIdFirst([
      for (final (:key, :folder) in const LocalLibrary().hiveFolderRecords)
        (own: '$key' == folder.id, record: folder),
    ]),
  );
}

Future<void> recordLeftBehindClosed(
  ProviderContainer container,
  MigrationFinished record,
) async {
  if (container.read(libraryStoreProvider)
      case LibraryStoreReady(:final store)) {
    switch (await store.recordMigration(record.closedLeftBehind())) {
      case Saved() || NothingToSave():
        break;
      case Refused() || NotSaved() || SaveInDoubt():
        AppErrorReporter.reportError(
          "Couldn't record that the left-behind dialog was closed; it shows "
          'again next start',
          source: 'main.libraryOnStore',
          promptUser: false,
        );
    }
  }
}

List<T> _ownIdFirst<T>(List<({bool own, T record})> records) => [
      for (final entry in records)
        if (entry.own) entry.record,
      for (final entry in records)
        if (!entry.own) entry.record,
    ];
