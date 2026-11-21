import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'hive_scratch.dart';

Future<void> _still() async {}

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
      expect(finished.strategies.whereType<StrategyNotMirrored>(), isEmpty);
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
      'a strategy changed in Hive is brought up to date in one commit, and a stop before it leaves the old copy whole',
      () async {
    final storage = MemoryStorage();
    final first = await openOn(storage);
    await copyNow(first);
    await first.close();
    final before = storage.contents;
    final edited = strategyBox
        .get('strategy-2')!
        .copyWith(name: 'Renamed in an older build');
    await strategyBox.put(edited.id, edited);
    final cut = switch (await LibraryStore.open(
      _CutEngine(MemoryEngine(storage), after: 0),
      canRead: appCanRead,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };
    expect(await copyNow(cut), isA<ShadowCopyStopped>());
    await cut.close();
    expect(storage.contents, before);
    final counted = _CutEngine(MemoryEngine(storage), after: 1000);
    final resumed =
        switch (await LibraryStore.open(counted, canRead: appCanRead)) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };
    final again = await copyNow(resumed);
    expect(kinds(again.strategies),
        {StrategyUnchanged: strategies.length - 1, StrategyTookHiveVersion: 1});
    expect(counted.commits, 1);
    expect((await checkNow(resumed)).isExact, isTrue);
    await resumed.close();
  });

  test(
      'a strategy changed in the store through an op is put back to what Hive holds',
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
    final again = await copyNow(store);
    expect(
        again.strategies
            .whereType<StrategyTookHiveVersion>()
            .map((s) => s.strategyId),
        ['strategy-3']);
    expect((await checkNow(store)).isExact, isTrue);
    await store.close();
  });

  test(
      'a strategy deleted from Hive is removed from the store, and a folder gone from Hive goes too',
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
    await store.close();
  });

  test(
      'strategies the converter refuses are not mirrored, with their reasons, left alone in Hive, and counted by the check',
      () async {
    final translucent = strategyNumbered(7).copyWith(
      id: 'strategy-translucent',
      themeOverridePalette: MapThemePalette(
        baseColorValue: 0x80101820,
        detailColorValue: 0xFFF2AA4C,
        highlightColorValue: 0xFFFFFFFF,
      ),
    );
    final page = handBuilt().pages.single;
    final repeated = handBuilt().copyWith(
        id: 'strategy-repeated', pages: [page, page.copyWith(sortIndex: 1)]);
    final old =
        strategyNumbered(9).copyWith(versionNumber: 1, id: 'strategy-old');
    for (final strategy in [translucent, repeated, old]) {
      await strategyBox.put(strategy.id, strategy);
    }
    final writes = await HiveWrites.watch(directory);
    final store = await openOn(MemoryStorage());
    final copy = await copyNow(store);
    final reasons = {
      for (final s in copy.strategies.whereType<StrategyNotMirrored>())
        s.strategyId: switch (s.reason) {
          ConverterRefused(:final problems) =>
            problems.map((p) => p.runtimeType).toSet(),
          final other => {other.runtimeType},
        },
    };
    expect(reasons, {
      'strategy-translucent': {PaletteHasTransparency},
      'strategy-repeated': {PageIdRepeated},
      'strategy-old': {NotMigrated},
    });
    expect(copy.strategies.whereType<StrategyCopied>(),
        hasLength(strategies.length));
    final check = await checkNow(store);
    expect(check.isExact, isFalse);
    expect(
        check.notMirrored.map((p) => (p.runtimeType, p.strategyId)).toSet(), {
      (StrategyNotConverted, 'strategy-translucent'),
      (StrategyNotConverted, 'strategy-repeated'),
      (StrategyNotConverted, 'strategy-old'),
    });
    await store.close();
    expect(await writes.stop(), isEmpty);
  });

  test(
      'a strategy that an update migrates without change is unchanged in the store, with nothing written',
      () async {
    await strategyBox.put('hand-1', handBuilt());
    final storage = MemoryStorage();
    final store = await openOn(storage);
    await copyNow(store);
    await store.close();
    final written = storage.contents;
    final older =
        handBuilt().copyWith(versionNumber: Settings.versionNumber - 1);
    final migrated = StrategyMigrator.migrateToCurrentVersion(older);
    expect(migrated.versionNumber, Settings.versionNumber);
    await strategyBox.put('hand-1', migrated);
    final again = await openOn(storage);
    final copy = await copyNow(again);
    expect(
        copy.strategies.whereType<StrategyUnchanged>().map((s) => s.strategyId),
        contains('hand-1'));
    expect(copy.strategies.whereType<StrategyTookHiveVersion>(), isEmpty);
    await again.close();
    expect(storage.contents, written);
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
    final notMirrored = copy.strategies.whereType<StrategyNotMirrored>().single;
    expect(notMirrored.strategyId, 'strategy-b');
    expect(notMirrored.reason, isA<StoreCouldNotEncode>());
    final check = await checkNow(store);
    expect(check.strategyProblems.map((p) => (p.runtimeType, p.strategyId)),
        [(StrategyRowsNotEncodable, 'strategy-b')]);
    expect(check.sameStrategies, 2);
    await store.close();
  });

  test(
      'what the store holds that this build cannot read is kept: a folder is rewritten around it, and a strategy holding it is not mirrored',
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
    final notMirrored =
        again.strategies.whereType<StrategyNotMirrored>().single;
    expect(notMirrored.strategyId, 'strategy-3');
    expect(
      notMirrored.reason,
      isA<StoreRefusedIt>().having(
        (r) => r.refusal,
        'refusal',
        isA<PutWouldDrop>()
            .having((d) => d.dropped, 'dropped', Dropped.unknownField),
      ),
    );
    final check = await checkNow(store);
    expect(check.notMirrored.map((c) => c.strategyId), ['strategy-3']);
    await store.close();
    final folder =
        jsonDecode(held.contents['library']!['folder/${digestOf('folder-1')}']!)
            as Map<String, Object?>;
    expect(folder['fromNewerBuild'], 1);
    expect(folder['name'], 'Retakes, renamed in an older build');
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
  var commits = 0;

  @override
  Future<Leasing> lease() async => switch (await inner.lease()) {
        Leased(:final lease) => Leased(_CutLease(lease, after, this)),
        final other => other,
      };
}

final class _CutLease implements StorageLease {
  _CutLease(this.inner, this.left, this.engine);

  final StorageLease inner;
  final _CutEngine engine;
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
    engine.commits++;
    return inner.commit(changes);
  }

  @override
  Future<Releasing> release() => inner.release();
}
