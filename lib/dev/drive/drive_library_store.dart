import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/library_migration.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus/startup/launch_clock.dart';
import 'package:icarus_library/icarus_library.dart';

final class StoreStepFailed implements Exception {
  StoreStepFailed(this.problems);

  final List<String> problems;

  @override
  String toString() => problems.join('; ');
}

String switchName(LibraryStoreSwitch choice) => switch (choice) {
      StoreSwitchOff() => 'off',
      StoreSwitchStore() => 'store',
    };

Future<String> firstFrameLine(ProviderContainer c) async {
  while (c.read(firstFrameProvider) is FirstFrameNotYet) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final drawn = c.read(firstFrameProvider) as FirstFrameDrawn;
  return 'FIRSTFRAME ${drawn.afterLaunch.inMilliseconds} ms '
      'store=${switchName(c.read(libraryStoreSwitchProvider))}';
}

Future<String?> closeStoreLine(ProviderContainer c) async {
  if (c.read(libraryStoreProvider) is! LibraryStoreReady) return null;
  await c.read(libraryStoreProvider.notifier).close();
  return switch (c.read(libraryStoreProvider)) {
    LibraryStoreClosed(released: Released()) => 'STORE closed',
    LibraryStoreClosed(released: ReleaseFailed(:final failure)) =>
      'FAIL STORE closed with a failure: '
          '${storageFailureWords(failure, StoreStep.release)} ($failure)',
    final other => 'FAIL STORE did not close: $other',
  };
}

List<String> migrationLines(
  ProviderContainer c, {
  required Map<String, Object?> expected,
}) {
  final atStart = c.read(libraryMigrationProvider);
  final state = switch (atStart?.migration) {
    null => 'none',
    MigrationFinishedNow() => 'finishedNow',
    MigrationWasFinished() => 'wasFinished',
    MigrationStopped() => 'stopped',
    MigrationRecordUnreadable() => 'unreadable',
    MigrationNotRun() => 'notRun',
  };
  final left = switch (atStart?.migration) {
    MigrationFinishedNow(:final record) || MigrationWasFinished(:final record) =>
      [for (final entry in [...record.strategies, ...record.folders]) entry],
    _ => const <LeftBehind>[],
  };
  final list = switch (c.read(libraryStoreProvider)) {
    LibraryStoreReady(store: LibraryStore(library: LibraryOpen(:final list))) =>
      list,
    _ => null,
  };
  final inStore = list == null
      ? null
      : list.strategies.where((summary) => summary.sync is KeptHere).length;
  final onStore = c.read(libraryOnStoreProvider);
  final actual = <String, Object?>{
    'state': state,
    'inStore': inStore,
    'foldersInStore': list?.folders.length,
    'leftBehind': left.length,
    'served': onStore is LibraryServedFromStore,
    'tries': switch (onStore) {
      LibraryNotServed(:final tries) => tries,
      _ => null,
    },
  };
  final lines = [
    'STORE move at start: $state, $inStore strategies and '
        '${list?.folders.length} folders in the store, '
        '${left.length} left behind',
    if (atStart?.migration case MigrationFinishedNow(:final record, :final took))
      'STORE move took '
          '${record.finishedAt.difference(record.startedAt).inMilliseconds} ms: '
          'copying the records ${took.copying.inMilliseconds} ms, bringing '
          'them up to date ${took.upgrading.inMilliseconds} ms, converting '
          'them to rows ${took.converting.inMilliseconds} ms, '
          '${took.commits} commits ${took.committing.inMilliseconds} ms',
    switch (onStore) {
      null => 'STORE library: not on the store',
      LibraryServedFromStore(:final loading) =>
        'STORE library: served from the store, loaded in '
            '${loading.inMilliseconds} ms',
      LibraryNotServed(:final why, :final tries) =>
        'STORE library: not served after $tries tries, $why',
    },
    for (final entry in left)
      'STORE left behind ${entry.publicId} "${entry.name}": ${entry.reason}',
  ];
  final problems = [
    for (final MapEntry(:key, :value) in expected.entries)
      if (actual[key] != value) '$key is ${actual[key]}, expected $value',
  ];
  if (problems.isNotEmpty) throw StoreStepFailed([...lines, ...problems]);
  return lines;
}
