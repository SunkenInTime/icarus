import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/canvas_units.dart' show cloneStrategy;
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_start.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/library_store/store_page_reads.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/canvas_shows.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/local_page_reads.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'gated_engine.dart';
import 'unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

final class _ReadGate {
  Completer<void>? _held;
  Completer<void>? _reached;
  var fail = false;

  Future<void> hold() {
    _held = Completer<void>();
    return (_reached = Completer<void>()).future;
  }

  void release() {
    _held?.complete();
    _held = null;
  }

  Future<void> pass() async {
    if (_reached case final reached? when !reached.isCompleted) {
      reached.complete();
    }
    if (_held case final held?) await held.future;
  }
}

final class _ReadGatedEngine implements StorageEngine {
  _ReadGatedEngine(this.inner, this.gate);

  final StorageEngine inner;
  final _ReadGate gate;

  @override
  Future<Leasing> lease() async => switch (await inner.lease()) {
        Leased(:final lease) => Leased(_ReadGatedLease(lease, gate)),
        final other => other,
      };
}

final class _ReadGatedLease implements StorageLease {
  _ReadGatedLease(this.inner, this.gate);

  final StorageLease inner;
  final _ReadGate gate;

  static const _failure = DeviceFailure('the disk could not be read');

  @override
  int get maxKeyLength => inner.maxKeyLength;

  @override
  LeaseStatus get status => inner.status;

  @override
  Future<KeyRead> read(String area, String key) async {
    await gate.pass();
    if (gate.fail) return const KeyNotRead(_failure);
    return inner.read(area, key);
  }

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async {
    await gate.pass();
    if (gate.fail) return const StorageFailed(_failure);
    return inner.keys(area, prefix);
  }

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async {
    await gate.pass();
    if (gate.fail) return const StorageFailed(_failure);
    return inner.entries(area, prefix);
  }

  @override
  Future<Stored<List<String>>> areas(String prefix) => inner.areas(prefix);

  @override
  Future<Committing> commit(List<Change> changes) => inner.commit(changes);

  @override
  Future<Releasing> release() => inner.release();
}

final class _Reading {
  _Reading(this.container, this.mirror, this.reads, this.store);

  final ProviderContainer container;
  final StoreMirror mirror;
  final StorePageReads reads;
  final LibraryStore store;

  StrategyProvider get editor => container.read(strategyProvider.notifier);

  List<String> get loads => [
        for (final load in reads.loads) '${load.kind.name} ${load.outcome}',
      ];

  String? captionOnCanvas() => container.read(agentProvider).first.caption;

  Future<void> settle() async {
    for (var turn = 0; turn < 6; turn++) {
      await Future<void>.delayed(Duration.zero);
      await mirror.drained();
    }
  }

  Future<void> plantInStoreOnly(StrategyData strategy, String caption) =>
      putInStoreOnly(cloneStrategy(strategy)
        ..pages.first.agentData.first.caption = caption);

  Future<void> putInStoreOnly(StrategyData planted) async {
    final rows = (strategyToRows(planted) as StrategyRowsMade).rows;
    final put = await store.putStrategy(rows);
    expect(put, isA<Saved>(),
        reason: switch (put) {
          Refused(:final reason) => '$reason',
          _ => '$put',
        });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late StorePageReads reads;
  StoreMirror? mirror;

  setUpAll(() {
    container = ProviderContainer(overrides: [
      authProvider.overrideWith(_SignedOut.new),
      localPageReadsProvider.overrideWith((ref) => reads),
    ]);
    appProviderContainer = container;
  });
  setUp(() async {
    await openUnitHive();
    mirror = StoreMirror(
      reads: HiveReads(),
      betweenAnimations: () => Future<void>.value(),
    );
    reads = StorePageReads(mirror!);
    container.invalidate(localPageReadsProvider);
  });
  tearDown(() async {
    LocalLibrary.follower = null;
    await Hive.close();
  });

  var made = 0;
  StrategyData strategy({List<int> sortIndexes = const [0, 1]}) {
    made += 1;
    final id = 'reads-$made';
    return generatedStrategy(Optionals.set).copyWith(
      id: id,
      pages: [
        for (final (index, sortIndex) in sortIndexes.indexed)
          generatedPage(
            id: '$id-p$index',
            sortIndex: sortIndex,
            optionals: Optionals.set,
            isAttack: index.isEven,
            itemPrefix: '$id-p$index',
          ),
      ],
    );
  }

  Future<_Reading> reading(
    List<StrategyData> strategies, {
    bool follow = true,
    bool allCopied = true,
    StorageEngine Function(StorageEngine memory)? engine,
  }) async {
    await Hive.box<Folder>(HiveBoxNames.foldersBox).put(
      'folder-1',
      Folder(name: 'Retakes', id: 'folder-1', dateCreated: DateTime.utc(2026)),
    );
    for (final strategy in strategies) {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(strategy.id, strategy);
    }
    LocalLibrary.follower = mirror;
    final store = switch (await LibraryStore.open(
      (engine ?? (memory) => memory)(MemoryEngine(MemoryStorage())),
      canRead: appCanRead,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => fail('$problem'),
    };
    addTearDown(store.close);
    if (follow) {
      final writes = LibraryBoxWrites();
      await mirror!.copyThenFollow(store, writes: writes);
      await writes.stop();
    }
    final harness = _Reading(container, mirror!, reads, store);
    await harness.settle();
    if (allCopied) expect(mirror!.refusedStrategies, isEmpty);
    return harness;
  }

  test(
      'an open comes from the store when it is known equal to Hive: a '
      'caption planted only in the store is what the canvas shows, and the '
      'pages bar lists the store\'s pages in the store\'s order', () async {
    final s = strategy();
    final h = await reading([s]);
    final planted = cloneStrategy(s);
    planted.pages.first.agentData.first.caption = 'only in the store';
    await h.putInStoreOnly(planted.copyWith(pages: [
      planted.pages[0].copyWith(sortIndex: 1),
      planted.pages[1].copyWith(sortIndex: 0),
    ]));

    expect(await h.editor.loadFromHive(s.id), isTrue);

    expect(h.captionOnCanvas(), 'only in the store');
    expect(h.loads, ['open from the store']);
    expect(container.read(strategyPageSessionProvider).availablePageIds,
        [s.pages[1].id, s.pages[0].id]);
  });

  test(
      'a page switch, with or without an edit, comes from Hive: it first '
      'writes the page it leaves to Hive, so the mirror has that write still '
      'to copy when the next page is read', () async {
    final s = strategy();
    final h = await reading([s]);
    expect(await h.editor.loadFromHive(s.id), isTrue);

    await h.editor.setActivePage(s.pages[1].id);
    await h.settle();
    final agent = container.read(agentProvider).first;
    container.read(agentProvider.notifier).setCaption(agent.id, 'edited');
    await h.editor.setActivePage(s.pages[0].id);
    await h.settle();
    await h.editor.setActivePage(s.pages[1].id);

    expect(h.captionOnCanvas(), 'edited');
    final mayDiffer =
        'pageSwitch from Hive: ${FromHiveBecause.mayDiffer.words}';
    expect(h.loads, ['open from the store', mayDiffer, mayDiffer, mayDiffer]);
  });

  test('an open that migrated the Hive record comes from Hive', () async {
    final s = strategy().copyWith(versionNumber: Settings.versionNumber - 1);
    final h = await reading([s], allCopied: false);

    expect(await h.editor.loadFromHive(s.id), isTrue);

    expect(h.loads, ['open from Hive: ${FromHiveBecause.migrationRan.words}']);
  });

  test('an open before the mirror follows comes from Hive', () async {
    final s = strategy();
    final h = await reading([s], follow: false);

    expect(await h.editor.loadFromHive(s.id), isTrue);

    expect(h.loads,
        ['open from Hive: ${FromHiveBecause.mirrorNotFollowing.words}']);
  });

  test(
      'an open while the mirror still has a Hive write to copy comes from '
      'Hive', () async {
    final s = strategy();
    final gate = CommitGate();
    final h = await reading([s], engine: (memory) => GatedEngine(memory, gate));
    gate.hold();
    final stored = const LocalLibrary().storedStrategy(s.id)!;
    (await const LocalLibrary().renameStrategy(stored, 'Renamed')).orThrow();
    await Future<void>.delayed(Duration.zero);

    expect(
      await h.editor.loadFromHive(s.id).timeout(
            const Duration(seconds: 10),
            onTimeout: () => fail(
                'the open waited for the held mirror write instead of reading '
                'Hive'),
          ),
      isTrue,
    );
    gate.release();
    await h.settle();

    expect(h.loads, ['open from Hive: ${FromHiveBecause.mayDiffer.words}']);
  });

  test('two pages sharing a position send the open to Hive', () async {
    final s = strategy(sortIndexes: [0, 0]);
    final h = await reading([s]);

    expect(await h.editor.loadFromHive(s.id), isTrue);

    expect(h.loads, ['open from Hive: ${FromHiveBecause.tiedPositions.words}']);
  });

  test('a strategy the store does not hold opens from Hive', () async {
    final s = strategy();
    final h = await reading([s]);
    expect(
      await h.store.editLibrary([RemoveStrategy(s.id)]),
      isA<Saved>(),
    );

    expect(await h.editor.loadFromHive(s.id), isTrue);

    expect(h.loads, ['open from Hive: ${FromHiveBecause.notInStore.words}']);
  });

  test('a page whose settings row is missing opens from Hive', () async {
    final s = strategy();
    final h = await reading([s]);
    final rows = (strategyToRows(s) as StrategyRowsMade).rows;
    final without = StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings.where((row) => row.pagePublicId != s.pages[0].id),
      elements: rows.elements,
      lineupGroups: rows.lineupGroups,
    );
    expect(await h.store.putStrategy(without), isA<Saved>());

    expect(await h.editor.loadFromHive(s.id), isTrue);

    expect(h.loads, [
      'open from Hive: ${FromHiveBecause.damagedRows.words} (no settings row)',
    ]);
  });

  test('a store read that fails sends the open to Hive', () async {
    final s = strategy();
    final gate = _ReadGate();
    final h =
        await reading([s], engine: (memory) => _ReadGatedEngine(memory, gate));
    await h.store.unload(s.id);
    gate.fail = true;

    expect(await h.editor.loadFromHive(s.id), isTrue);

    expect(h.loads.single,
        startsWith('open from Hive: ${FromHiveBecause.readFailed.words}'));
  });

  String? savedCaption(String strategyId, String pageId) => const LocalLibrary()
      .storedStrategy(strategyId)!
      .pages
      .firstWhere((page) => page.id == pageId)
      .agentData
      .first
      .caption;

  Future<void> saveCaption(String strategyId, String caption) async {
    final newer =
        cloneStrategy(const LocalLibrary().storedStrategy(strategyId)!);
    newer.pages
        .firstWhere((page) => page.sortIndex == 0)
        .agentData
        .first
        .caption = caption;
    (await const LocalLibrary().savePageOnScreen(newer)).orThrow();
  }

  test(
      'an open whose store read a Hive save overtakes draws Hive as it is '
      'once the store answers: the newer caption is on the canvas and a page '
      'switch keeps it', () async {
    final s = strategy();
    final gate = _ReadGate();
    final h =
        await reading([s], engine: (memory) => _ReadGatedEngine(memory, gate));
    await h.plantInStoreOnly(s, 'only in the store');
    await h.store.unload(s.id);
    final held = gate.hold();

    final opening = h.editor.loadFromHive(s.id);
    await held;
    await saveCaption(s.id, 'newer');
    gate.release();

    expect(await opening, isTrue);
    expect(h.captionOnCanvas(), 'newer');
    expect(h.loads,
        ['open from Hive: ${FromHiveBecause.hiveWriteDuringRead.words}']);
    await h.editor.setActivePage(s.pages[1].id);
    await h.settle();
    expect(savedCaption(s.id, s.pages[0].id), 'newer');
  });

  test(
      'a Hive save the mirror has copied before the held store read ends '
      'still sends the open to Hive', () async {
    final s = strategy();
    final gate = _ReadGate();
    final h =
        await reading([s], engine: (memory) => _ReadGatedEngine(memory, gate));
    await h.plantInStoreOnly(s, 'only in the store');
    await h.store.unload(s.id);
    final held = gate.hold();

    final opening = h.editor.loadFromHive(s.id);
    await held;
    await saveCaption(s.id, 'newer');
    for (var turn = 0; turn < 20; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
    gate.release();

    expect(await opening, isTrue);
    await h.settle();
    expect(h.mirror.strategiesNotKnownEqual, isNot(contains(s.id)));
    expect(h.loads,
        ['open from Hive: ${FromHiveBecause.hiveWriteDuringRead.words}']);
    expect(h.captionOnCanvas(), 'newer');
  });

  test('a page the store does not hold opens from Hive', () async {
    final s = strategy();
    final h = await reading([s]);
    await h.putInStoreOnly(
      cloneStrategy(s).copyWith(pages: [cloneStrategy(s).pages[0]]),
    );

    expect(await h.editor.loadFromHive(s.id, pageId: s.pages[1].id), isTrue);

    expect(container.read(strategyPageSessionProvider).activePageId,
        s.pages[1].id);
    expect(
        h.loads, ['open from Hive: ${FromHiveBecause.pageNotInStore.words}']);
  });

  test(
      'an open overtaken by another open while its store read is held is '
      'recorded as never shown, and the open that took its place as served',
      () async {
    final a = strategy();
    final b = strategy().copyWith(versionNumber: Settings.versionNumber - 1);
    final gate = _ReadGate();
    final h = await reading(
      [a, b],
      allCopied: false,
      engine: (memory) => _ReadGatedEngine(memory, gate),
    );
    await h.store.unload(a.id);
    final held = gate.hold();

    final openingA = h.editor.loadFromHive(a.id);
    await held;
    expect(await h.editor.loadFromHive(b.id), isTrue);
    gate.release();

    expect(await openingA, isFalse);
    expect(container.read(strategyProvider).strategyId, b.id);
    expect(h.loads, [
      'open from Hive: ${FromHiveBecause.migrationRan.words}',
      'open ${const GaveWay()}',
    ]);
  });

  test('a strategy with no pages records that there was no page to show',
      () async {
    final s = strategy().copyWith(pages: const []);
    final h = await reading([s], allCopied: false);

    expect(await h.editor.loadFromHive(s.id), isTrue);

    expect(h.loads, ['open ${const NoPageToShow()}']);
  });

  group(
      'while an open waits on its store read, the strategy it opens is '
      'already the open one and the canvas holds nothing', () {
    late StrategyData a;
    late StrategyData b;
    late _Reading h;
    late _ReadGate gate;
    late Future<bool> opening;

    setUp(() async {
      a = strategy();
      b = strategy();
      gate = _ReadGate();
      h = await reading([a, b],
          engine: (memory) => _ReadGatedEngine(memory, gate));
      expect(await h.editor.loadFromHive(a.id), isTrue);
      await h.store.unload(b.id);
      final held = gate.hold();
      opening = h.editor.loadFromHive(b.id);
      await held;
      expect(container.read(strategyProvider).strategyId, b.id);
      expect(container.read(canvasShowsProvider), isA<ShowsNothing>());
      expect(container.read(agentProvider), isEmpty);
    });

    List<String> agentsSaved(StrategyData strategy, int page) => [
          for (final agent in const LocalLibrary()
              .storedStrategy(strategy.id)!
              .pages
              .firstWhere((stored) => stored.id == strategy.pages[page].id)
              .agentData)
            agent.id,
        ];

    Future<void> openEnds() async {
      gate.release();
      expect(await opening, isTrue);
      await h.settle();
    }

    test(
        'the editor is closed to input for the whole read: the open is '
        'running, naming the strategy it opens, until its page is applied',
        () async {
      expect(container.read(strategyOpeningProvider)?.strategyId, b.id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(strategyOpeningProvider)?.strategyId, b.id);
      await openEnds();
      expect(container.read(strategyOpeningProvider), isNull);
      expect(container.read(canvasShowsProvider), isA<ShowsPage>());
    });

    test('a Save writes nothing and says the work was not saved', () async {
      h.editor.setUnsaved();
      await expectLater(h.editor.saveToHive(b.id), throwsStateError);
      await openEnds();
      expect(agentsSaved(b, 0),
          [for (final agent in b.pages[0].agentData) agent.id]);
    });

    test('the autosave writes nothing and leaves the work unsaved', () async {
      h.editor.setUnsaved();
      final saved = await h.editor
          .flushPendingAutosaveBeforeExit()
          .then((left) => left, onError: (Object _) => false);
      expect(saved, isFalse);
      await openEnds();
      expect(agentsSaved(b, 0),
          [for (final agent in b.pages[0].agentData) agent.id]);
    });

    test('a page click is ignored and the open ends on its first page',
        () async {
      await h.editor.selectPage(b.pages[1].id);
      await openEnds();
      expect(container.read(strategyPageSessionProvider).activePageId,
          b.pages[0].id);
      expect(agentsSaved(b, 0),
          [for (final agent in b.pages[0].agentData) agent.id]);
      expect(agentsSaved(b, 1),
          [for (final agent in b.pages[1].agentData) agent.id]);
    });
  });

  List<int> hiveBytes(String strategyId) {
    final writer = BinaryWriterImpl(Hive)
      ..write(const LocalLibrary()
          .storedStrategy(strategyId)!
          .copyWith(lastEdited: DateTime.utc(2000)));
    return writer.toBytes();
  }

  test(
      'a strategy whose rows read back differently from Hive, lineups saved '
      'interleaved, opens from Hive with that reason, and a Save with no edits '
      'writes Hive back byte for byte, its save time aside', () async {
    final s = strategy();
    final graph = sharedSpotLineups('${s.id}-lineups');
    final interleaved = s.copyWith(pages: [
      s.pages[0].copyWith(
        lineUpGraph: LineUpGraph(
          origins: graph.origins,
          landings: graph.landings,
          links: [graph.links[3], ...graph.links.take(3)],
        ),
        imageData: const [],
      ),
      s.pages[1].copyWith(imageData: const []),
    ]);
    final h = await reading([interleaved]);
    final before = hiveBytes(s.id);

    expect(h.mirror.strategiesReadingBackDifferently, contains(s.id));
    expect(await h.editor.loadFromHive(s.id), isTrue);
    await h.editor.saveToHive(s.id);
    await h.settle();

    expect(
        h.loads.single,
        startsWith(
            'open from Hive: ${FromHiveBecause.readsBackDifferently.words}'));
    expect(hiveBytes(s.id), before);
  });

  test('a strategy whose rows read back equal is not on that list', () async {
    final s = strategy();
    final h = await reading([s]);

    expect(h.mirror.strategiesReadingBackDifferently, isEmpty);
    expect(await h.editor.loadFromHive(s.id), isTrue);
    expect(h.loads, ['open from the store']);
  });

  group(
      'a Hive save that lands as the page is applied, after the store read '
      'was checked', () {
    Future<void> landAtApply(
      StrategyData Function(StrategyData stored) change,
    ) async {
      var landed = false;
      final listening = container.listen(
        strategyPageSessionProvider.select((state) => state.isApplyingPage),
        (_, applying) {
          if (!applying || landed) return;
          landed = true;
          final stored = const LocalLibrary().storedStrategy(
            container.read(strategyProvider).strategyId!,
          )!;
          unawaited(const LocalLibrary().savePageOnScreen(change(stored)));
        },
      );
      addTearDown(listening.close);
    }

    test('is the caption the canvas shows and the Save keeps', () async {
      final s = strategy();
      final h = await reading([s]);
      await h.plantInStoreOnly(s, 'only in the store');
      await landAtApply((stored) => cloneStrategy(stored)
        ..pages
            .firstWhere((page) => page.sortIndex == 0)
            .agentData
            .first
            .caption = 'newer');

      expect(await h.editor.loadFromHive(s.id), isTrue);
      await h.settle();

      expect(h.captionOnCanvas(), 'newer');
      expect(h.loads, [
        'open from Hive: ${FromHiveBecause.hiveWriteBeforeApply.words}',
      ]);
      await h.editor.saveToHive(s.id);
      await h.settle();
      expect(savedCaption(s.id, s.pages[0].id), 'newer');
    });

    test('is the map, theme and palette the editor shows and the Save keeps',
        () async {
      final s = strategy();
      final h = await reading([s]);
      final newerMap = MapValue.values.firstWhere((map) => map != s.mapData);
      final newerPalette = MapThemePalette(
        baseColorValue: 0xFF102030,
        detailColorValue: 0xFF405060,
        highlightColorValue: 0xFF708090,
      );
      await landAtApply((stored) => cloneStrategy(stored).copyWith(
            mapData: newerMap,
            themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
            themeOverridePalette: newerPalette,
          ));

      expect(await h.editor.loadFromHive(s.id), isTrue);
      await h.settle();

      expect(container.read(mapProvider).currentMap, newerMap);
      expect(
          container.read(strategyThemeProvider).overridePalette?.baseColorValue,
          newerPalette.baseColorValue);
      await h.editor.saveToHive(s.id);
      await h.settle();
      final saved = const LocalLibrary().storedStrategy(s.id)!;
      expect(saved.mapData, newerMap);
      expect(saved.themeOverridePalette?.baseColorValue,
          newerPalette.baseColorValue);
    });
  });

  test(
      'the outcome of an open is recorded when its page is applied, not when '
      'its read returns', () async {
    final s = strategy();
    final h = await reading([s]);
    final atApply = <int>[];
    final listening = container.listen(canvasShowsProvider, (_, shows) {
      if (shows is ShowsPage) atApply.add(h.reads.loads.length);
    });
    addTearDown(listening.close);

    expect(await h.editor.loadFromHive(s.id), isTrue);

    expect(atApply, [0]);
    expect(h.loads, ['open from the store']);
  });

  test('an open closed while its store read is held is recorded as never shown',
      () async {
    final s = strategy();
    final gate = _ReadGate();
    final h =
        await reading([s], engine: (memory) => _ReadGatedEngine(memory, gate));
    await h.store.unload(s.id);
    final held = gate.hold();

    final opening = h.editor.loadFromHive(s.id);
    await held;
    await h.editor.clearCurrentStrategy();
    gate.release();

    expect(await opening, isFalse);
    expect(h.loads, ['open ${const GaveWay()}']);
  });

  group(
      'shapes the real libraries do not have, through the mirror, a read-mode '
      'open and a Save with no edits', () {
    StrategyData withoutPictures(StrategyData strategy) => strategy.copyWith(
          pages: [
            for (final page in strategy.pages)
              page.copyWith(imageData: const []),
          ],
        );

    LineUpGraph interleaved(String prefix) {
      final graph = sharedSpotLineups(prefix);
      return LineUpGraph(
        origins: graph.origins,
        landings: graph.landings,
        links: [graph.links[3], ...graph.links.take(3)],
      );
    }

    final shapes = <String, (StrategyData Function(StrategyData), String)>{
      'lineups grouped by their shared spot': (
        (s) => s.copyWith(pages: [
              s.pages[0].copyWith(lineUpGraph: sharedSpotLineups('${s.id}-l')),
              s.pages[1],
            ]),
        'open from the store',
      ),
      'lineups saved interleaved': (
        (s) => s.copyWith(pages: [
              s.pages[0].copyWith(lineUpGraph: interleaved('${s.id}-l')),
              s.pages[1],
            ]),
        'open from Hive: ${FromHiveBecause.readsBackDifferently.words}',
      ),
      'two pages at the same position': (
        (s) => s.copyWith(pages: [
              s.pages[0],
              s.pages[1].copyWith(sortIndex: s.pages[0].sortIndex),
            ]),
        'open from Hive: ${FromHiveBecause.tiedPositions.words}',
      ),
      'pages saved out of their position order': (
        (s) => s.copyWith(pages: [s.pages[1], s.pages[0]]),
        'open from Hive: ${FromHiveBecause.readsBackDifferently.words}',
      ),
      'a page with nothing on it': (
        (s) => s.copyWith(pages: [
              s.pages[0].copyWith(
                agentData: const [],
                abilityData: const [],
                drawingData: const [],
                textData: const [],
                utilityData: const [],
                lineUpGraph: LineUpGraph.empty,
              ),
              s.pages[1],
            ]),
        'open from the store',
      ),
      'a lineup whose spot was deleted': (
        (s) {
          final graph = sharedSpotLineups('${s.id}-l');
          return s.copyWith(pages: [
            s.pages[0].copyWith(
              lineUpGraph: LineUpGraph(
                origins: graph.origins.skip(1).toList(),
                landings: graph.landings,
                links: graph.links,
              ),
            ),
            s.pages[1],
          ]);
        },
        'open from Hive: ${FromHiveBecause.mayDiffer.words}',
      ),
      'pages at positions with gaps between them': (
        (s) => s.copyWith(pages: [
              s.pages[0].copyWith(sortIndex: 0),
              s.pages[1].copyWith(sortIndex: 5),
            ]),
        'open from the store',
      ),
      'the same item id on two pages': (
        (s) => s.copyWith(pages: [
              s.pages[0],
              s.pages[1].copyWith(agentData: [
                s.pages[0].agentData.first,
                ...s.pages[1].agentData.skip(1),
              ]),
            ]),
        'open from the store',
      ),
      'the same item id twice on one page': (
        (s) => s.copyWith(pages: [
              s.pages[0].copyWith(agentData: [
                s.pages[0].agentData.first,
                s.pages[0].agentData.first,
                ...s.pages[0].agentData.skip(1),
              ]),
              s.pages[1],
            ]),
        'open from the store',
      ),
    };

    for (final MapEntry(key: name, value: (shape, served)) in shapes.entries) {
      test('$name: $served', () async {
        final s = withoutPictures(shape(strategy()));
        final h = await reading([s], allCopied: false);
        final before = hiveBytes(s.id);

        expect(await h.editor.loadFromHive(s.id), isTrue);
        await h.editor.saveToHive(s.id);
        await h.settle();

        expect(h.loads.single, startsWith(served));
        if (name == 'the same item id twice on one page') {
          final duplicated = s.pages[0].agentData.first.id;
          expect(
            container
                .read(agentProvider)
                .where((agent) => agent.id == duplicated),
            hasLength(2),
          );
        }
        expect(hiveBytes(s.id), before, reason: h.loads.single);
      });
    }
  });

  test('only the read mode reads pages from the store', () {
    for (final choice in [
      const StoreSwitchOff(),
      const StoreSwitchShadow(),
      const StoreSwitchMirror(),
      const StoreSwitchRead(),
      const StoreSwitchOps(),
    ]) {
      final start = LibraryStoreStart.of(choice, clock: () => Duration.zero);
      final scoped = ProviderContainer(overrides: start.overrides);
      addTearDown(scoped.dispose);
      expect(
        scoped.read(localPageReadsProvider),
        choice is StoreSwitchRead ? isA<StorePageReads>() : isNull,
        reason: '$choice',
      );
    }
  });
}
