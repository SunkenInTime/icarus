import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/startup/launch_clock.dart';
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
              'problems ${checked.folderProblems.length}; unplaced rows '
              '${checked.unplaced.length}; ${took.inMilliseconds} ms',
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
              FolderNotInHive(:final folderId) =>
                'STORE folder not in Hive $folderId',
            },
          for (final row in checked.unplaced)
            'STORE unplaced ${row.ref}: ${row.problem}',
        ],
    };

List<String> _describeCopy(ShadowRun run) {
  final copy = run.copy;
  final strategies = copy.strategies;
  final folders = copy.folders;
  return [
    'STORE copy ${switch (copy) {
      ShadowCopyFinished() => 'finished',
      ShadowCopyStopped(:final stop) => 'stopped: $stop',
    }}: copied ${_count<StrategyCopied>(strategies)}, unchanged '
        '${_count<StrategyUnchanged>(strategies)}, took the Hive version '
        '${_count<StrategyTookHiveVersion>(strategies)}, removed with Hive '
        '${_count<StrategyRemovedWithHive>(strategies)}, not mirrored '
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

Future<List<String>> waitForShadowStore(
  ProviderContainer c, {
  required Duration patience,
  required Map<String, Object?> expected,
}) async {
  final state = await _settled(c, patience);
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
  final problems = [
    if (run.copy case ShadowCopyStopped(:final stop)) 'the copy stopped: $stop',
    if (origin is StorageCreated &&
        strategies.any((strategy) =>
            strategy is! StrategyCopied && strategy is! StrategyNotMirrored))
      'the library was created, yet the copy found strategies already in it',
    if (_count<StrategyNotMirrored>(strategies) case final n when n > 0)
      '$n strategies not mirrored',
    if (_count<FolderNotCopied>(run.copy.folders) case final n when n > 0)
      '$n folders not copied',
    switch (run.check) {
      StoreChecked(isExact: true) => null,
      StoreChecked() => 'the store differs from Hive',
      StoreNotChecked(:final failure) => 'the check failed: '
          '${storageFailureWords(failure, StoreStep.read)} ($failure)',
    },
    if (libraryChanged.isNotEmpty)
      'library boxes changed: ${libraryChanged.join(', ')}',
    if (run.libraryBoxWrites > 0)
      'the library boxes were written ${run.libraryBoxWrites} times',
    for (final MapEntry(:key, :value) in expected.entries)
      if (counts[key] != value) '$key is ${counts[key]}, expected $value',
  ].nonNulls.toList();
  if (problems.isNotEmpty) throw StoreStepFailed([...lines, ...problems]);
  return lines;
}

Future<List<String>> checkStoreAgain(ProviderContainer c) async {
  final store = switch (c.read(libraryStoreProvider)) {
    LibraryStoreReady(:final store) => store,
    final other => throw StoreStepFailed(['the store is $other']),
  };
  final clock = Stopwatch()..start();
  final check = await c.read(shadowProvider.notifier).checkAgain(store);
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
