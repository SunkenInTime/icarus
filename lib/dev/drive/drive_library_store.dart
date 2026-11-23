import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/dev/drive/drive_action_ops.dart';
import 'package:icarus/dev/drive/drive_screens.dart';
import 'package:icarus/library_store/hive_naming.dart';
import 'package:icarus/library_store/library_listing.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/startup/launch_clock.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:path/path.dart' as path;

final class StoreStepFailed implements Exception {
  StoreStepFailed(this.problems);

  final List<String> problems;

  @override
  String toString() => problems.join('; ');
}

String switchName(LibraryStoreSwitch choice) => switch (choice) {
      StoreSwitchOff() => 'off',
      StoreSwitchShadow() => 'shadow',
      StoreSwitchMirror() => 'mirror',
      StoreSwitchRead() => 'read',
      StoreSwitchOps() => 'ops',
    };

Future<String> firstFrameLine(ProviderContainer c) async {
  while (c.read(firstFrameProvider) is FirstFrameNotYet) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final drawn = c.read(firstFrameProvider) as FirstFrameDrawn;
  return 'FIRSTFRAME ${drawn.afterLaunch.inMilliseconds} ms '
      'store=${switchName(c.read(libraryStoreSwitchProvider))}';
}

Future<ShadowState> _settled(ProviderContainer c, Duration patience) async {
  final running = c.read(shadowProvider.notifier).running ??
      (throw StoreStepFailed(['the shadow copy never started']));
  await running.timeout(
    patience,
    onTimeout: () => throw StoreStepFailed([
      'the shadow copy did not finish in ${patience.inSeconds} s: '
          '${_describeState(c.read(shadowProvider))}',
    ]),
  );
  return c.read(shadowProvider);
}

String _describeState(ShadowState state) => switch (state) {
      ShadowIdle() => 'not started',
      ShadowCopying(:final done, :final total) => 'copying $done of $total',
      ShadowChecking() => 'checking',
      ShadowFinished() => 'finished',
      ShadowNotOpened(:final opened) => _describeOpened(opened),
    };

String _describeOpened(LibraryStoreOpened opened) => switch (opened) {
      LibraryStoreReady() => 'opened',
      LibraryStoreHeldElsewhere() => 'held by another instance of the app',
      LibraryStoreRefused(:final failure) =>
        'refused: ${storageFailureWords(failure, StoreStep.opening)} ($failure)',
      LibraryStoreTooSmall(:final maxKeyLength) =>
        'the engine holds keys of only $maxKeyLength characters',
    };

int _bytes(File file) => file.existsSync() ? file.lengthSync() : 0;

String _sizes(File store) {
  final hiveDirectory = store.parent.parent;
  final hive = hiveDirectory
      .listSync()
      .whereType<File>()
      .where((file) => path.extension(file.path) == '.hive')
      .fold(0, (sum, file) => sum + file.lengthSync());
  return 'STORE file ${_bytes(store)} bytes, log ${_bytes(File('${store.path}-wal'))} '
      'bytes; Hive files $hive bytes';
}

int _count<T>(List<Object> items) => items.whereType<T>().length;

List<String> describeCheck(StoreCheck check, Duration took) => switch (check) {
      StoreChangedDuringCheck(:final checked, :final notices) => [
          'STORE check not exact: Hive changed during it ($notices notices)',
          ...describeCheck(checked, took),
        ],
      StoreNotChecked(:final failure) => [
          'STORE check could not read: '
              '${storageFailureWords(failure, StoreStep.read)} ($failure)',
        ],
      final StoreChecked checked => [
          'STORE check Hive ${checked.hiveStrategies} strategies '
              '${checked.hiveFolders} folders; the same in the store '
              '${checked.sameStrategies} strategies ${checked.sameFolders} '
              'folders; differences '
              '${_count<StrategyDiffers>(checked.strategies)}; missing '
              '${_count<StrategyMissingFromStore>(checked.strategies)}; '
              'unreadable '
              '${_count<StrategyUnreadableInStore>(checked.strategies)}; '
              'not in Hive ${_count<StrategyNotInHive>(checked.strategies)}; '
              'not mirrored ${checked.notMirrored.length}; folder '
              'problems ${checked.folderProblems.length}; names this build '
              'does not know ${checked.foreignNames.length}; unplaced rows '
              '${checked.unplaced.length}; kept on Hive '
              '${checked.keptOnHive.strategies.kept.length} strategies '
              '${checked.keptOnHive.folders.kept.length} folders; '
              '${took.inMilliseconds} ms',
          for (final (kind, names) in [
            ('strategy', checked.keptOnHive.strategies),
            ('folder', checked.keptOnHive.folders),
          ])
            for (final (:key, :id, :reason) in names.kept)
              'STORE kept on Hive $kind $id at key $key: $reason',
          for (final problem in checked.strategyProblems)
            ...switch (problem) {
              StrategySame() => const <String>[],
              StrategyDiffers(:final strategyId, :final rows, :final fields) =>
                [
                  for (final difference in [...rows, ...fields])
                    'STORE difference $strategyId $difference',
                ],
              StrategyNotConverted(:final strategyId, :final problems) => [
                  'STORE not converted $strategyId: '
                      '${problems.map((p) => p.runtimeType).join(', ')}',
                ],
              StrategyRowsNotEncodable(:final strategyId, :final notText) => [
                  'STORE not encodable $strategyId: $notText'
                ],
              StrategyWriteRefused(:final strategyId, :final reason) => [
                  'STORE write refused $strategyId: $reason',
                ],
              StrategyNotListed(:final strategyId) => [
                  'STORE not listed $strategyId',
                ],
              StrategyMissingFromStore(:final strategyId) => [
                  'STORE missing $strategyId',
                ],
              StrategyUnreadableInStore(:final strategyId, :final stored) => [
                  'STORE unreadable $strategyId: $stored',
                ],
              StrategyNotInHive(:final strategyId) => [
                  'STORE not in Hive $strategyId',
                ],
              StrategyKeptInCloud(:final strategyId) => [
                  'STORE kept in the cloud, so not mirrored: $strategyId',
                ],
            },
          for (final problem in checked.folderProblems)
            switch (problem) {
              FolderSame(:final folderId) => 'STORE folder $folderId same',
              FolderDiffers(:final folderId, :final fields) =>
                'STORE folder differs $folderId: ${fields.join(', ')}',
              FolderMissingFromStore(:final folderId) =>
                'STORE folder missing $folderId',
              FolderUnreadableInStore(:final folderId, :final problem) =>
                'STORE folder unreadable $folderId: $problem',
              FolderWriteRefused(:final folderId, :final reason) =>
                'STORE folder write refused $folderId: $reason',
              FolderNotInHive(:final folderId) =>
                'STORE folder not in Hive $folderId',
            },
          for (final row in checked.unplaced)
            'STORE unplaced ${row.ref}: ${row.problem}',
          for (final name in checked.foreignNames)
            'STORE a name this build does not know: $name',
        ],
    };

List<String> _describeCopy(ShadowRun run) {
  final copy = run.copy;
  final strategies = copy.strategies;
  final folders = copy.folders;
  return [
    'STORE copy ${switch (copy) {
      ShadowCopyFinished() => 'finished',
      ShadowCopyRaced(:final hiveWrites) =>
        'finished while Hive changed ($hiveWrites writes), so it may not reflect Hive',
      ShadowCopyStopped(:final stop) => 'stopped: $stop',
      ShadowCopyFaulted(:final error) => 'met an error: $error',
    }}: copied ${_count<StrategyCopied>(strategies)}, unchanged '
        '${_count<StrategyUnchanged>(strategies)}, took the Hive version '
        '${_count<StrategyTookHiveVersion>(strategies)}, removed with Hive '
        '${_count<StrategyRemovedWithHive>(strategies)}, waited for Hive '
        '${_count<StrategyWaitsForHive>(strategies)}, not mirrored '
        '${_count<StrategyNotMirrored>(strategies)}; folders copied '
        '${_count<FolderCopied>(folders)}, unchanged '
        '${_count<FolderUnchanged>(folders)}, removed '
        '${_count<FolderRemovedWithHive>(folders)}, not copied '
        '${_count<FolderNotCopied>(folders)}; ${run.copyTook.inMilliseconds} '
        'ms',
    'STORE while copying: ${run.uiDuringCopy}',
    'STORE while checking: ${run.uiDuringCheck}',
    for (final strategy in strategies)
      if (strategy case StrategyNotMirrored(:final strategyId, :final reason))
        'STORE not mirrored $strategyId: $reason',
    for (final folder in folders)
      if (folder case FolderNotCopied(:final folderId, :final reason))
        'STORE folder not copied $folderId: $reason',
  ];
}

Future<ShadowState> _settledHidden(
  ProviderContainer c,
  Duration patience,
) async {
  final binding = WidgetsBinding.instance;
  binding
    ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
    ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  try {
    return await _settled(c, patience);
  } finally {
    binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }
}

Future<List<String>> waitForShadowStore(
  ProviderContainer c, {
  required Duration patience,
  required Map<String, Object?> expected,
  required bool hidden,
}) async {
  final state =
      hidden ? await _settledHidden(c, patience) : await _settled(c, patience);
  final run = switch (state) {
    ShadowFinished(:final run) => run,
    ShadowNotOpened(:final opened) =>
      throw StoreStepFailed(['the store ${_describeOpened(opened)}']),
    ShadowIdle() ||
    ShadowCopying() ||
    ShadowChecking() =>
      throw StoreStepFailed(['the shadow copy is ${_describeState(state)}']),
  };
  final (file, origin) = switch (c.read(libraryStoreProvider)) {
    LibraryStoreReady(:final file, :final origin) => (file, origin),
    final other => throw StoreStepFailed(['the store is $other']),
  };
  final originName = switch (origin) {
    StorageCreated() => 'created',
    StorageExisted() => 'existed',
  };
  final libraryChanged = run.libraryBoxesChanged;
  final othersChanged = run.otherHiveFilesChanged;
  final lines = [
    'STORE opened ${file.path}; the library $originName',
    _sizes(file),
    ..._describeCopy(run),
    ...describeCheck(run.check, run.checkTook),
    'STORE Hive files ${run.hiveFiles} read before and after; library '
        'boxes ${libraryChanged.isEmpty ? 'unchanged' : 'changed: ${libraryChanged.join(', ')}'}; '
        'writes to them seen ${run.libraryBoxWrites}; '
        'boxes the copy never opens, written by the rest of the app: '
        '${othersChanged.isEmpty ? 'none' : othersChanged.join(', ')}',
  ];
  final strategies = run.copy.strategies;
  final counts = <String, Object>{
    'origin': originName,
    'copied': _count<StrategyCopied>(strategies),
    'unchanged': _count<StrategyUnchanged>(strategies),
    'tookHiveVersion': _count<StrategyTookHiveVersion>(strategies),
    'removedWithHive': _count<StrategyRemovedWithHive>(strategies),
  };
  final mirroring = c.read(shadowProvider.notifier).mode is Mirroring;
  final problems = [
    if (run.copy case ShadowCopyStopped(:final stop)) 'the copy stopped: $stop',
    if (run.copy case ShadowCopyFaulted(:final error))
      'the copy met an error: $error',
    if (run.copy case ShadowCopyRaced(:final hiveWrites) when !mirroring)
      'Hive changed while the copy ran ($hiveWrites writes)',
    if (origin is StorageCreated &&
        strategies.any((strategy) =>
            strategy is! StrategyCopied &&
            strategy is! StrategyNotMirrored &&
            strategy is! StrategyWaitsForHive))
      'the library was created, yet the copy found strategies already in it',
    if (_count<StrategyNotMirrored>(strategies) case final n when n > 0)
      '$n strategies not mirrored',
    if (_count<FolderNotCopied>(run.copy.folders) case final n when n > 0)
      '$n folders not copied',
    switch (run.check) {
      StoreChecked(isExact: true) => null,
      StoreChecked() => 'the store differs from Hive',
      StoreChangedDuringCheck() => 'Hive changed during the check',
      StoreNotChecked(:final failure) => 'the check failed: '
          '${storageFailureWords(failure, StoreStep.read)} ($failure)',
    },
    if (libraryChanged.isNotEmpty && !mirroring)
      'library boxes changed: ${libraryChanged.join(', ')}',
    if (run.libraryBoxWrites > 0 && !mirroring)
      'the library boxes were written ${run.libraryBoxWrites} times',
    for (final MapEntry(:key, :value) in expected.entries)
      if (counts[key] != value) '$key is ${counts[key]}, expected $value',
  ].nonNulls.toList();
  if (problems.isNotEmpty) throw StoreStepFailed([...lines, ...problems]);
  return lines;
}

Future<List<String>> checkStoreAgain(ProviderContainer c) async {
  final ready = switch (c.read(libraryStoreProvider)) {
    final LibraryStoreReady ready => ready,
    final other => throw StoreStepFailed(['the store is $other']),
  };
  final clock = Stopwatch()..start();
  final check = await c.read(shadowProvider.notifier).checkAgain(ready);
  final lines = describeCheck(check, clock.elapsed);
  if (check case StoreChecked(isExact: true)) return lines;
  throw StoreStepFailed(lines);
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

String _describePhase(MirrorPhase phase) => switch (phase) {
      MirrorWaitingForStore() => 'waiting for the store',
      MirrorFollowing() => 'following saves',
      MirrorHeld() => 'held',
      MirrorStopped(:final stop) => 'stopped: $stop',
    };

String holdStore(ProviderContainer c) =>
    switch (c.read(shadowProvider.notifier).mode) {
      ShadowOnly() => throw StoreStepFailed(['the store is not mirroring']),
      Mirroring(:final mirror) => () {
          mirror.hold();
          return 'STORE mirror ${_describePhase(mirror.phase)}';
        }(),
    };

Future<List<String>> mirrorEndLines(ProviderContainer c) async {
  final StoreMirror mirror;
  switch (c.read(shadowProvider.notifier).mode) {
    case ShadowOnly():
      return const [];
    case Mirroring(mirror: final following):
      mirror = following;
  }
  final ready = switch (c.read(libraryStoreProvider)) {
    final LibraryStoreReady ready => ready,
    final other => throw StoreStepFailed(['the store is $other']),
  };
  switch (mirror.phase) {
    case MirrorHeld():
      return [
        'STORE mirror held with ${mirror.pending} changes not written to the '
            'store; the next start brings it up to date',
      ];
    case MirrorWaitingForStore() || MirrorStopped():
      throw StoreStepFailed(['STORE mirror ${_describePhase(mirror.phase)}']);
    case MirrorFollowing():
      break;
  }
  final clock = Stopwatch()..start();
  await mirror.drained().timeout(
        const Duration(seconds: 120),
        onTimeout: () => throw StoreStepFailed([
          'STORE mirror did not drain in 120 s: ${mirror.pending} pending',
        ]),
      );
  final drainedAfter = clock.elapsed;
  final endSave = await saveOpenLocalStrategy(c, mirror);
  await mirror.releaseTakenUp();
  final checkClock = Stopwatch()..start();
  final check = await c.read(shadowProvider.notifier).checkAgain(ready);
  final lines = [
    'STORE mirror ${_describePhase(mirror.phase)}; ${mirror.batches} batches '
        'written after saves; drained ${drainedAfter.inMilliseconds} ms after '
        'the script ended',
    if (endSave != null) endSave,
    ...actionOpsEndLines(mirror),
    ...describeCheck(check, checkClock.elapsed),
  ];
  if (check case StoreChecked(isExact: true)) return lines;
  if (check case final StoreChecked checked
      when storeRefusalsExpected.isNotEmpty &&
          _exactBut(checked, storeRefusalsExpected)) {
    return [
      ...lines,
      'STORE exact but for the strategies the script expects the store to '
          'refuse: ${(storeRefusalsExpected.toList()..sort()).join(', ')}',
    ];
  }
  throw StoreStepFailed([...lines, 'the store differs from Hive']);
}

var storeRefusalsExpected = <String>{};

bool _exactBut(StoreChecked check, Set<String> refused) =>
    check.foreignNames.isEmpty &&
    check.unplaced.isEmpty &&
    check.folderProblems.isEmpty &&
    check.sameFolders == check.hiveFolders &&
    setEquals({for (final c in check.notMirrored) c.strategyId}, refused) &&
    setEquals(
        {for (final c in check.strategyProblems) c.strategyId}, refused) &&
    check.sameStrategies == check.hiveStrategies - refused.length;

StoreLibraryListing? _storeListing(ProviderContainer c) =>
    switch (c.read(localLibraryListingProvider)) {
      final StoreLibraryListing listing => listing,
      _ => null,
    };

String? listSourceName(ProviderContainer c) =>
    switch (_storeListing(c)?.source) {
      ListFromStore() => 'the store',
      ListFromHive() => 'Hive',
      null => null,
    };

String? _keptBecause(BoxNames names, String id) => [
      for (final record in names.kept)
        if (record.id == id) 'kept on Hive: ${record.reason}',
    ].firstOrNull;

String _refusalOf(LibraryStore store, StoreMirror mirror, String strategyId) =>
    switch (mirror.refusedStrategies[strategyId]) {
      final reason? => '$reason',
      null => _keptBecause(mirror.reads.names.strategies, strategyId) ??
          switch (store.summaryOf(strategyId)?.sync) {
            null || KeptHere() => 'this build cannot show its stored summary',
            _ => 'kept in the cloud, so not mirrored',
          },
    };

String _folderRefusalOf(StoreMirror mirror, String folderId) =>
    switch (mirror.refusedFolders[folderId]) {
      final reason? => '$reason',
      null => _keptBecause(mirror.reads.names.folders, folderId) ??
          'this build cannot show its stored row',
    };

Future<List<String>> waitForStoreList(
  ProviderContainer c, {
  required Duration patience,
  required Map<String, Object?> expected,
}) async {
  final listing = _storeListing(c) ??
      (throw StoreStepFailed(
          ['this run does not read the list from the store']));
  final deadline = DateTime.now().add(patience);
  while (listing.source is! ListFromStore) {
    if (DateTime.now().isAfter(deadline)) {
      final phase = switch (c.read(shadowProvider.notifier).mode) {
        Mirroring(:final mirror) => _describePhase(mirror.phase),
        ShadowOnly() => 'not mirroring',
      };
      throw StoreStepFailed([
        'the list was still drawn from Hive after ${patience.inSeconds} s; '
            'the mirror is $phase; '
            '${_describeState(c.read(shadowProvider))}',
      ]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final (:store, :mirror) = switch (listing.source) {
    ListFromStore(:final store, :final mirror) => (
        store: store,
        mirror: mirror
      ),
    ListFromHive() => throw StateError('the list went back to Hive'),
  };
  final strategies = listing.strategiesNotInStore;
  final folders = listing.foldersNotInStore;
  final counts = <String, Object>{
    'rebuiltAtOpen': store.summariesRebuiltAtOpen,
    'fromHive': strategies.length,
    'foldersFromHive': folders.length,
  };
  final lines = [
    'STORE list drawn from the store ${listing.firstFromStore!.inMilliseconds} '
        'ms after launch; summaries rebuilt at open '
        '${store.summariesRebuiltAtOpen}; not in the store '
        '${strategies.length} strategies, ${folders.length} folders',
    for (final id in strategies.toList()..sort())
      'STORE listed from Hive $id: ${_refusalOf(store, mirror, id)}',
    for (final id in folders.toList()..sort())
      'STORE folder listed from Hive $id: ${_folderRefusalOf(mirror, id)}',
  ];
  final problems = [
    for (final MapEntry(:key, :value) in expected.entries)
      if (counts[key] != value) '$key is ${counts[key]}, expected $value',
  ];
  if (problems.isNotEmpty) throw StoreStepFailed([...lines, ...problems]);
  return lines;
}

typedef GridSources = ({
  bool readMode,
  List<GridRow> fromStore,
  List<GridRow> fromHive,
});

GridSources? gridSources(ProviderContainer c) {
  final listing = _storeListing(c);
  if (listing == null) return null;
  final rows = gridRowsOnScreen();
  return (
    readMode: listing.source is ListFromStore,
    fromStore: [
      for (final row in rows)
        if (listing.drewFromStore(row.row)) row,
    ],
    fromHive: [
      for (final row in rows)
        if (!listing.drewFromStore(row.row)) row,
    ],
  );
}

List<String> gridLines(String label, GridSources grid) {
  int count(List<GridRow> rows, String kind) =>
      rows.where((row) => row.kind == kind).length;
  return [
    'GRID $label from the store ${count(grid.fromStore, 'strategy')} '
        'strategies, ${count(grid.fromStore, 'folder')} folders; from Hive '
        '${count(grid.fromHive, 'strategy')} strategies, '
        '${count(grid.fromHive, 'folder')} folders',
    if (grid.readMode)
      for (final row in grid.fromHive)
        'GRID $label from Hive ${row.kind} "${row.name}"',
  ];
}

Future<void> _nextFrame() {
  SchedulerBinding.instance.scheduleFrame();
  return SchedulerBinding.instance.endOfFrame;
}

Future<List<String>> waitForGridFromStore(
  ProviderContainer c, {
  required String label,
  Duration patience = const Duration(seconds: 2),
}) async {
  final listing = _storeListing(c) ??
      (throw StoreStepFailed(
          ['this run does not read the list from the store']));
  bool onlyMarkedFromHive(GridSources grid) => grid.fromHive.every(
        (row) => switch (row.kind) {
          'strategy' => listing.strategiesNotInStore.contains(row.id),
          _ => listing.foldersNotInStore.contains(row.id),
        },
      );
  final deadline = DateTime.now().add(patience);
  while (true) {
    await _nextFrame();
    final grid = gridSources(c)!;
    if (grid.fromStore.isNotEmpty && onlyMarkedFromHive(grid)) {
      return gridLines(label, grid);
    }
    if (DateTime.now().isAfter(deadline)) {
      throw StoreStepFailed([
        ...gridLines(label, grid),
        'the grid on screen was not built from store rows '
            '${patience.inMilliseconds} ms after the list was drawn from the '
            'store',
      ]);
    }
  }
}

Future<GridRow> waitForGridRowFromStore(
  ProviderContainer c, {
  required String name,
  required Duration patience,
}) async {
  final listing = _storeListing(c) ??
      (throw StoreStepFailed(
          ['this run does not read the list from the store']));
  final deadline = DateTime.now().add(patience);
  while (true) {
    await _nextFrame();
    final named = [
      for (final row in gridRowsOnScreen())
        if (row.name == name) row,
    ];
    if (named case [final row] when listing.drewFromStore(row.row)) return row;
    if (DateTime.now().isAfter(deadline)) {
      throw StoreStepFailed([
        switch (named) {
          [] => '"$name" is not on the grid on screen',
          [_] => '"$name" is on the grid on screen from a Hive row',
          _ => '"$name" is on the grid on screen ${named.length} times',
        },
      ]);
    }
  }
}

void holdListAtLaunch(ProviderContainer c) => _storeListing(c)?.holdOnHive();

String holdListOnHive(ProviderContainer c) {
  final listing = _storeListing(c) ??
      (throw StoreStepFailed(
          ['this run does not read the list from the store']));
  listing.holdOnHive();
  return 'STORE list held on Hive; it is drawn from ${listSourceName(c)}';
}

String letListGo(ProviderContainer c) {
  final listing = _storeListing(c) ??
      (throw StoreStepFailed(
          ['this run does not read the list from the store']));
  listing.letGo();
  return 'STORE list let go';
}

enum MirrorWait { notMirroring, drained, stillBusy }

Future<MirrorWait> mirrorDrained(ProviderContainer c) async {
  if (c.read(shadowProvider.notifier).mode case Mirroring(:final mirror)
      when mirror.phase is MirrorFollowing) {
    final drained = await mirror
        .drained()
        .then((_) => true)
        .timeout(const Duration(seconds: 30), onTimeout: () => false);
    if (!drained) return MirrorWait.stillBusy;
    await WidgetsBinding.instance.endOfFrame;
    return MirrorWait.drained;
  }
  return MirrorWait.notMirroring;
}

List<String> listEndLines(ProviderContainer c) {
  final listing = _storeListing(c);
  if (listing == null) return const [];
  final line = 'STORE list drawn from ${listSourceName(c)} at the end; it '
      'moved ${listing.switches} times';
  return switch ((listing.source, c.read(shadowProvider.notifier).mode)) {
    (ListFromStore(), _) => [line],
    (ListFromHive(), Mirroring(mirror: StoreMirror(phase: MirrorHeld()))) => [
        line,
      ],
    (ListFromHive(), _) => throw StoreStepFailed([
        line,
        'the run reads the list from the store, yet it ended drawn from Hive',
      ]),
  };
}
