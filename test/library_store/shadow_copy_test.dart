import 'dart:convert';
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
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/library_store/hive_record.dart';
import 'package:icarus/library_store/rows_digest.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'hive_scratch.dart';

Future<void> _still() async {}

const fixedHandBuiltDigest =
    'f63b2476719628869567b1263c1532b8715b4063ed5e45fd942034b09528e306';
const fixedMovedAgentDigest =
    'e61648ec65648f3eb045b9ace1b22484e5583943f56ce62ef7371140d8398eb4';

StrategyData handBuilt(
        {Offset agentAt = const Offset(10, 20), bool agentAlly = true}) =>
    StrategyData(
      id: 'hand-1',
      name: 'B split',
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.utc(2026, 1, 2, 3, 4, 5),
      createdAt: DateTime.utc(2026, 1, 1),
      folderID: null,
      pages: [
        StrategyPage(
          id: 'p1',
          name: 'Page 1',
          drawingData: const [],
          agentData: [
            PlacedAgent(
                id: 'a1',
                type: AgentType.jett,
                position: agentAt,
                isAlly: agentAlly),
          ],
          abilityData: const [],
          textData: const [],
          imageData: const [],
          utilityData: const [],
          sortIndex: 0,
          isAttack: true,
          settings: StrategySettings(),
        ),
      ],
    );

String rowDigest(StrategyData strategy) => switch (strategyToRows(strategy)) {
      StrategyRowsMade(:final rows) => switch (rowsDigestOf(rows)) {
          RowsDigested(:final digest) => digest,
          final RowsNotDigested other => throw StateError('$other'),
        },
      StrategyRowsRefused(:final problems) => throw StateError('$problems'),
    };

MemoryStorage edited(
  MemoryStorage storage,
  void Function(Map<String, Map<String, String>> contents) change,
) {
  final contents = {
    for (final MapEntry(:key, :value) in storage.contents.entries)
      key: {...value},
  };
  change(contents);
  return MemoryStorage(contents);
}

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
    final writes = await HiveWrites.watch(directory);
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
    expect(await writes.stop(), isEmpty);
  });

  test('the store remembers the digest of each Hive record it copied',
      () async {
    final store = await openOn(MemoryStorage());
    await copyNow(store);
    final list = (store.library as LibraryOpen).list;
    expect(list.hiveRecords.keys.toSet(), {for (final s in strategies) s.id});
    for (final strategy in hiveLibraryNow().strategies) {
      expect(list.hiveRecords[strategy.id]!.digest, rowDigest(strategy));
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
    expect(both.hiveNow, rowDigest(strategyAsHiveHoldsIt(edited)));
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
    final writes = await HiveWrites.watch(directory);
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
          .whereType<StrategyNotConverted>()
          .map((p) => p.strategyId),
      ['strategy-old'],
    );
    await store.close();
    expect(await writes.stop(), isEmpty);
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

  test('the digest of a hand-built strategy is a fixed value', () {
    expect(rowDigest(handBuilt()), fixedHandBuiltDigest);
    expect(rowDigest(handBuilt(agentAt: const Offset(11, 20))),
        fixedMovedAgentDigest);
  });

  test(
      'every change to what a strategy holds changes its digest, and a revision does not',
      () {
    final base = handBuilt();
    StrategyPage page(StrategyPage Function(StrategyPage page) change) =>
        change(base.pages.single);
    final changed = <String, StrategyData>{
      'name': base.copyWith(name: 'A split'),
      'map': base.copyWith(mapData: MapValue.bind),
      'folder': base.copyWith(folderID: 'folder-1'),
      'theme': base.copyWith(themeProfileId: 'profile-2'),
      'last edited': base.copyWith(lastEdited: DateTime.utc(2026, 1, 3)),
      'page name':
          base.copyWith(pages: [page((p) => p.copyWith(name: 'Retake'))]),
      'page place':
          base.copyWith(pages: [page((p) => p.copyWith(sortIndex: 1))]),
      'page side':
          base.copyWith(pages: [page((p) => p.copyWith(isAttack: false))]),
      'page settings': base.copyWith(
        pages: [
          page((p) => p.copyWith(settings: StrategySettings(agentSize: 40)))
        ],
      ),
      'agent place': handBuilt(agentAt: const Offset(10, 21)),
      'agent side': handBuilt(agentAlly: false),
    };
    final digests = {
      for (final MapEntry(:key, :value) in changed.entries)
        key: rowDigest(value),
    };
    expect(digests.values.toSet(), hasLength(changed.length));
    expect(digests.values, isNot(contains(rowDigest(base))));

    final rows = (strategyToRows(base) as StrategyRowsMade).rows;
    final revised = StrategyRowSet(
      strategy: rows.strategy.rewritten(revision: 7),
      pages: rows.pages,
      settings: rows.settings,
      elements: rows.elements,
      lineupGroups: rows.lineupGroups,
    );
    expect((rowsDigestOf(revised) as RowsDigested).digest, rowDigest(base));
  });

  test(
      'a strategy saved by an older version that migrates without change digests as it does in this one',
      () {
    final older =
        handBuilt().copyWith(versionNumber: Settings.versionNumber - 1);
    final migrated = StrategyMigrator.migrateToCurrentVersion(older);
    expect(migrated.versionNumber, Settings.versionNumber);
    expect(rowDigest(migrated), rowDigest(handBuilt()));
  });

  test(
      'the check fails when a page settings row the converter writes is missing from the store, even one holding defaults',
      () async {
    await strategyBox.put('hand-1', handBuilt());
    final storage = MemoryStorage();
    final store = await openOn(storage);
    await copyNow(store);
    await store.close();
    final damaged = edited(storage, (contents) {
      contents[strategyArea('hand-1')]!.remove('settings/${digestOf('p1')}');
    });
    final reopened = await openOn(damaged);
    final check = await checkNow(reopened);
    expect(check.isExact, isFalse);
    final differs = check.strategyProblems.whereType<StrategyDiffers>().single;
    expect(differs.strategyId, 'hand-1');
    expect(
        differs.rows.map((r) => r.kind), [RowDifferenceKind.missingFromStore]);
    expect(differs.fields, isEmpty);
    await reopened.close();
  });

  test(
      'the check fails on a strategy area the library listing does not account for',
      () async {
    final storage = MemoryStorage();
    final store = await openOn(storage);
    await copyNow(store);
    final ghost =
        (strategyToRows(handBuilt().copyWith(id: 'ghost')) as StrategyRowsMade)
            .rows;
    expect(await store.editLibrary([AddStrategy(ghost)]),
        isA<Saved<LibraryEdited, LibraryRefusal>>());
    await store.close();
    final unlisted = edited(storage, (contents) {
      contents['library']!.remove('summary/${digestOf('ghost')}');
    });
    final reopened = await openOn(unlisted);
    final check = await checkNow(reopened);
    expect(check.isExact, isFalse);
    expect(
        check.strategyProblems
            .whereType<StrategyNotListed>()
            .map((p) => p.strategyId),
        ['ghost']);
    await reopened.close();
  });

  test(
      'a strategy that cannot be written as JSON is reported between two that are copied, and the run finishes',
      () async {
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();
    final broken = handBuilt().copyWith(
      id: 'strategy-b',
      pages: [
        handBuilt()
            .pages
            .single
            .copyWith(settings: StrategySettings(agentSize: double.nan))
      ],
    );
    for (final strategy in [
      handBuilt().copyWith(id: 'strategy-a'),
      broken,
      handBuilt().copyWith(id: 'strategy-c')
    ]) {
      await strategyBox.put(strategy.id, strategy);
    }
    final store = await openOn(MemoryStorage());
    final copy = await copyNow(store);
    expect(copy, isA<ShadowCopyFinished>());
    expect(copy.strategies.whereType<StrategyCopied>().map((s) => s.strategyId),
        ['strategy-a', 'strategy-c']);
    final notCopied = copy.strategies.whereType<StrategyNotCopied>().single;
    expect(notCopied.strategyId, 'strategy-b');
    expect(notCopied.reason, isA<RowsNotEncodable>());
    final check = await checkNow(store);
    expect(check.strategyProblems.map((p) => (p.runtimeType, p.strategyId)),
        [(StrategyRowsNotEncodable, 'strategy-b')]);
    expect(check.sameStrategies, 2);
    await store.close();
  });

  test(
      'taking Hive\'s version keeps what the store holds that this build cannot read: on a folder, a record and a strategy row',
      () async {
    final storage = MemoryStorage();
    final first = await openOn(storage);
    await copyNow(first);
    await first.close();
    final held = edited(storage, (contents) {
      String withField(String text, String key, Object value) =>
          jsonEncode({...jsonDecode(text) as Map<String, Object?>, key: value});
      final library = contents['library']!;
      final folderName = 'folder/${digestOf('folder-1')}';
      library[folderName] =
          withField(library[folderName]!, 'fromNewerBuild', 1);
      final recordName = 'hive/${digestOf('strategy-2')}';
      library[recordName] =
          withField(library[recordName]!, 'copiedBy', 'a newer build');
      final area = contents[strategyArea('strategy-3')]!;
      area['strategy'] = withField(area['strategy']!, 'newerField', true);
    });
    final folderBox = Hive.box<Folder>(HiveBoxNames.foldersBox);
    folderBox.get('folder-1')!.name = 'Retakes, renamed in an older build';
    await folderBox.put('folder-1', folderBox.get('folder-1')!);
    for (final id in ['strategy-2', 'strategy-3']) {
      await strategyBox.put(
          id, strategyBox.get(id)!.copyWith(name: 'Renamed in an older build'));
    }
    final store = await openOn(held);
    final again = await copyNow(store);
    expect(again.folders.whereType<FolderCopied>().map((f) => f.folderId),
        ['folder-1']);
    expect(
        again.strategies
            .whereType<StrategyTookHiveVersion>()
            .map((s) => s.strategyId),
        ['strategy-2']);
    expect(
        again.strategies
            .whereType<StrategyChangedOnBothSides>()
            .map((s) => s.strategyId),
        ['strategy-3']);
    await store.close();
    final library = held.contents['library']!;
    final folder = jsonDecode(library['folder/${digestOf('folder-1')}']!)
        as Map<String, Object?>;
    expect(folder['fromNewerBuild'], 1);
    expect(folder['name'], 'Retakes, renamed in an older build');
    final record = jsonDecode(library['hive/${digestOf('strategy-2')}']!)
        as Map<String, Object?>;
    expect(record['copiedBy'], 'a newer build');
    expect(record['digest'],
        rowDigest(strategyAsHiveHoldsIt(strategyBox.get('strategy-2')!)));
    final kept =
        jsonDecode(held.contents[strategyArea('strategy-3')]!['strategy']!)
            as Map<String, Object?>;
    expect(kept['newerField'], true);
    expect(kept['name'], 'Strategy 3');
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
