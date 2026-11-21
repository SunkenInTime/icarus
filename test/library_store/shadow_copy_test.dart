import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_record.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'hive_scratch.dart';

Future<void> _still() async {}

StrategyData strategyNumbered(int n, {String? folder}) =>
    generatedStrategy(Optionals.set).copyWith(
      id: 'strategy-$n',
      name: 'Strategy $n',
      folderID: folder,
      lastEdited: DateTime(2026, 5, n + 1, 10, 30, 15, 123, 456),
    );

List<Folder> get folders => [
      Folder(
        name: 'Retakes',
        id: 'folder-1',
        dateCreated: DateTime(2025, 2, 3, 4, 5, 6, 7),
        color: FolderColor.custom,
        customColor: const Color(0x8022C55E),
      ),
      Folder(
        name: 'Ascent',
        id: 'folder-2',
        parentID: 'folder-1',
        dateCreated: DateTime(2025, 2, 4),
        color: FolderColor.blue,
      ),
    ];

List<StrategyData> get strategies => [
      for (var n = 0; n < 6; n++)
        strategyNumbered(n,
            folder: n == 1 ? 'folder-2' : (n.isEven ? 'folder-1' : null)),
    ];

Future<LibraryStore> openOn(MemoryStorage storage) async => switch (
        await LibraryStore.open(MemoryEngine(storage), canRead: appCanRead)) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };

Future<ShadowCopy> copyNow(LibraryStore store) =>
    copyHiveIntoStore(hiveLibraryNow(), store, breathe: _still);

Future<StoreChecked> checkNow(LibraryStore store) async => switch (
        await checkStoreAgainstHive(hiveLibraryNow(), store, breathe: _still)) {
      final StoreChecked checked => checked,
      StoreNotChecked(:final failure) => throw StateError('$failure'),
    };

Map<Type, int> kinds(List<Object> results) {
  final counts = <Type, int>{};
  for (final result in results) {
    counts[result.runtimeType] = (counts[result.runtimeType] ?? 0) + 1;
  }
  return counts;
}

Box<StrategyData> get strategyBox =>
    Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-shadow-copy-');
    await openScratchHive(directory, strategies: strategies, folders: folders);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
      'every strategy and folder is copied, reads back the same, and not one Hive file changes',
      () async {
    final before = await filesUnder(directory);
    final store = await openOn(MemoryStorage());
    final copy = await copyNow(store);
    expect(copy, isA<ShadowCopyFinished>());
    expect(kinds(copy.strategies), {StrategyCopied: strategies.length});
    expect(kinds(copy.folders), {FolderCopied: folders.length});
    final check = await checkNow(store);
    expect(check.isExact, isTrue,
        reason: '${check.strategyProblems} ${check.folderProblems}');
    expect(check.sameStrategies, strategies.length);
    expect(check.sameFolders, folders.length);
    await store.close();
    expect(await filesUnder(directory), before);
  });

  test('the store remembers the digest of each Hive record it copied',
      () async {
    final store = await openOn(MemoryStorage());
    await copyNow(store);
    final list = (store.library as LibraryOpen).list;
    expect(list.hiveRecords.keys.toSet(), {for (final s in strategies) s.id});
    for (final strategy in hiveLibraryNow().strategies) {
      expect(
          list.hiveRecords[strategy.id]!.digest, hiveRecordDigestOf(strategy));
    }
    await store.close();
  });

  test('a second start finds nothing to copy and writes nothing', () async {
    final storage = MemoryStorage();
    final first = await openOn(storage);
    await copyNow(first);
    await first.close();
    final written = storage.contents;
    final second = await openOn(storage);
    final again = await copyNow(second);
    expect(kinds(again.strategies), {StrategyUnchanged: strategies.length});
    expect(kinds(again.folders), {FolderUnchanged: folders.length});
    await second.close();
    expect(storage.contents, written);
  });

  test(
      'stopped before any commit lands, the next start finishes with the same store as a run never stopped',
      () async {
    final whole = MemoryStorage();
    final uninterrupted = await openOn(whole);
    await copyNow(uninterrupted);
    await uninterrupted.close();
    final commits = strategies.length + folders.length;
    for (var cut = 0; cut < commits; cut++) {
      final storage = MemoryStorage();
      final stopped = switch (await LibraryStore.open(
        _CutEngine(MemoryEngine(storage), after: cut),
        canRead: appCanRead,
      )) {
        StoreOpened(:final store) => store,
        StoreNotOpened(:final problem) => throw StateError('$problem'),
      };
      final partial = await copyNow(stopped);
      expect(partial, isA<ShadowCopyStopped>(), reason: 'cut at $cut');
      await stopped.close();
      final resumed = await openOn(storage);
      final finished = await copyNow(resumed);
      expect(finished, isA<ShadowCopyFinished>(), reason: 'cut at $cut');
      expect(finished.strategies.whereType<StrategyNotCopied>(), isEmpty);
      expect((await checkNow(resumed)).isExact, isTrue, reason: 'cut at $cut');
      await resumed.close();
      expect(storage.contents, whole.contents, reason: 'cut at $cut');
    }
  });

  test(
      'a Hive record changed since the copy, with the store copy untouched, is taken into the store',
      () async {
    final store = await openOn(MemoryStorage());
    await copyNow(store);
    final edited = strategyBox
        .get('strategy-2')!
        .copyWith(name: 'Renamed in an older build');
    await strategyBox.put(edited.id, edited);
    final again = await copyNow(store);
    expect(kinds(again.strategies),
        {StrategyUnchanged: strategies.length - 1, StrategyTookHiveVersion: 1});
    expect(
        again.strategies.whereType<StrategyTookHiveVersion>().single.strategyId,
        'strategy-2');
    final check = await checkNow(store);
    expect(check.isExact, isTrue, reason: '${check.strategyProblems}');
    await store.close();
  });

  test(
      'stopped between removing the old copy and adding Hive\'s version, the next start copies it again as new',
      () async {
    final storage = MemoryStorage();
    final first = await openOn(storage);
    await copyNow(first);
    await first.close();
    final edited = strategyBox
        .get('strategy-2')!
        .copyWith(name: 'Renamed in an older build');
    await strategyBox.put(edited.id, edited);
    final cut = switch (await LibraryStore.open(
      _CutEngine(MemoryEngine(storage), after: 1),
      canRead: appCanRead,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };
    final stopped = await copyNow(cut);
    expect(stopped, isA<ShadowCopyStopped>());
    final list = (cut.library as LibraryOpen).list;
    expect(
        list.strategies.map((s) => s.publicId), isNot(contains('strategy-2')));
    expect(list.hiveRecords.containsKey('strategy-2'), isFalse);
    await cut.close();
    final resumed = await openOn(storage);
    final again = await copyNow(resumed);
    expect(again, isA<ShadowCopyFinished>());
    expect(
        again.strategies.whereType<StrategyCopied>().map((s) => s.strategyId),
        ['strategy-2']);
    expect(kinds(again.strategies),
        {StrategyUnchanged: strategies.length - 1, StrategyCopied: 1});
    expect((await checkNow(resumed)).isExact, isTrue);
    await resumed.close();
  });

  test(
      'a strategy changed in Hive and in the store is kept on both sides and reported',
      () async {
    final store = await openOn(MemoryStorage());
    await copyNow(store);
    final saved = await store.commit(
      'strategy-3',
      const StrategyPatchOp(
          opId: 'op-1',
          expectedStrategyRevision: 1,
          name: 'Renamed in the store'),
    );
    expect(saved, isA<Saved<Committed, CommitRefusal>>());
    final edited =
        strategyBox.get('strategy-3')!.copyWith(name: 'Renamed in Hive');
    await strategyBox.put(edited.id, edited);
    final again = await copyNow(store);
    final both =
        again.strategies.whereType<StrategyChangedOnBothSides>().single;
    expect(both.strategyId, 'strategy-3');
    expect(both.hiveNow, hiveRecordDigestOf(strategyAsHiveHoldsIt(edited)));
    final content = switch (await store.readStrategy('strategy-3')) {
      Found(:final value) => value,
      final other => throw StateError('$other'),
    };
    expect((content.strategy as ReadableStrategy).name, 'Renamed in the store');
    final check = await checkNow(store);
    expect(check.isExact, isFalse);
    expect(check.strategyProblems.map((p) => p.strategyId).toSet(),
        {'strategy-3'});
    await store.close();
  });

  test(
      'a strategy deleted from Hive is removed from the store with its record, and a folder gone from Hive goes too',
      () async {
    final storage = MemoryStorage();
    final store = await openOn(storage);
    await copyNow(store);
    await strategyBox.delete('strategy-1');
    await Hive.box<Folder>(HiveBoxNames.foldersBox).delete('folder-2');
    final again = await copyNow(store);
    expect(
        again.strategies
            .whereType<StrategyRemovedWithHive>()
            .map((s) => s.strategyId),
        ['strategy-1']);
    expect(
        again.folders.whereType<FolderRemovedWithHive>().map((f) => f.folderId),
        ['folder-2']);
    expect((await checkNow(store)).isExact, isTrue);
    expect(
        (store.library as LibraryOpen)
            .list
            .hiveRecords
            .containsKey('strategy-1'),
        isFalse);
    await store.close();
  });

  test(
      'a strategy the converter refuses is reported with its reason, left alone in Hive, and the check says it is missing',
      () async {
    final refused =
        strategyNumbered(9).copyWith(versionNumber: 1, id: 'strategy-old');
    await strategyBox.put(refused.id, refused);
    final before = await filesUnder(directory);
    final store = await openOn(MemoryStorage());
    final copy = await copyNow(store);
    final notCopied = copy.strategies.whereType<StrategyNotCopied>().single;
    expect(notCopied.strategyId, 'strategy-old');
    expect(
      notCopied.reason,
      isA<ConverterRefused>()
          .having((r) => r.problems.single, 'problem', isA<NotMigrated>()),
    );
    expect(copy.strategies.whereType<StrategyCopied>(),
        hasLength(strategies.length));
    final check = await checkNow(store);
    expect(check.isExact, isFalse);
    expect(
      check.strategyProblems
          .whereType<StrategyMissingFromStore>()
          .map((p) => p.strategyId),
      ['strategy-old'],
    );
    await store.close();
    expect(await filesUnder(directory), before);
  });

  test(
      'a strategy the store already holds without a Hive record is reported and left alone',
      () async {
    final storage = MemoryStorage();
    final store = await openOn(storage);
    final made = strategyToRows(strategyAsHiveHoldsIt(strategies[3]))
        as StrategyRowsMade;
    expect(
        await store.editLibrary([
          PutFolder(folderToRow(folderAsHiveHoldsIt(folders.first))),
          AddStrategy(made.rows),
        ]),
        isA<Saved<LibraryEdited, LibraryRefusal>>());
    final copy = await copyNow(store);
    final notCopied = copy.strategies.whereType<StrategyNotCopied>().single;
    expect(notCopied.strategyId, strategies[3].id);
    expect(notCopied.reason, isA<StoreHoldsItWithoutRecord>());
    await store.close();
  });

  test(
      'a record cached by Hive with sub-millisecond times digests as Hive stores it',
      () async {
    final live = strategyBox.get('strategy-0')!;
    expect(live.lastEdited.microsecond, isNonZero);
    final stored = strategyAsHiveHoldsIt(live);
    await Hive.close();
    await openScratchHive(directory);
    final reread = strategyBox.get('strategy-0')!;
    expect(hiveRecordDigestOf(strategyAsHiveHoldsIt(reread)),
        hiveRecordDigestOf(stored));
  });
}

final class _CutEngine implements StorageEngine {
  _CutEngine(this.inner, {required this.after});

  final StorageEngine inner;
  final int after;

  @override
  Future<Leasing> lease() async => switch (await inner.lease()) {
        Leased(:final lease) => Leased(_CutLease(lease, after)),
        final other => other,
      };
}

final class _CutLease implements StorageLease {
  _CutLease(this.inner, this.left);

  final StorageLease inner;
  int left;

  @override
  int get maxKeyLength => inner.maxKeyLength;

  @override
  LeaseStatus get status => inner.status;

  @override
  Future<KeyRead> read(String area, String key) => inner.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) =>
      inner.keys(area, prefix);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) =>
      inner.entries(area, prefix);

  @override
  Future<Stored<List<String>>> areas(String prefix) => inner.areas(prefix);

  @override
  Future<Committing> commit(List<Change> changes) async {
    if (left == 0)
      return const CommitRefused(DeviceFailure('the app was stopped'));
    left--;
    return inner.commit(changes);
  }

  @override
  Future<Releasing> release() => inner.release();
}
