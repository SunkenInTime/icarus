import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
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
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
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
        for (final load in reads.loads) '${load.kind.name} ${load.served}',
      ];

  String? captionOnCanvas() => container.read(agentProvider).first.caption;

  Future<void> settle() async {
    for (var turn = 0; turn < 6; turn++) {
      await Future<void>.delayed(Duration.zero);
      await mirror.drained();
    }
  }

  Future<void> plantInStoreOnly(StrategyData strategy, String caption) async {
    final planted = cloneStrategy(strategy);
    planted.pages.first.agentData.first.caption = caption;
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
      'pages bar lists the store\'s pages', () async {
    final s = strategy();
    final h = await reading([s]);
    await h.plantInStoreOnly(s, 'only in the store');

    expect(await h.editor.loadFromHive(s.id), isTrue);

    expect(h.captionOnCanvas(), 'only in the store');
    expect(h.loads, ['open from the store']);
    expect(container.read(strategyPageSessionProvider).availablePageIds,
        [s.pages[0].id, s.pages[1].id]);
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

    expect(await h.editor.loadFromHive(s.id), isTrue);
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

  test(
      'a Hive write that begins while the store read is held sends the open '
      'to Hive: the canvas shows Hive\'s page, not the one planted in the '
      'store', () async {
    final s = strategy();
    final gate = _ReadGate();
    final h =
        await reading([s], engine: (memory) => _ReadGatedEngine(memory, gate));
    await h.plantInStoreOnly(s, 'only in the store');
    await h.store.unload(s.id);
    final held = gate.hold();

    final opening = h.editor.loadFromHive(s.id);
    await held;
    final stored = const LocalLibrary().storedStrategy(s.id)!;
    final renaming = const LocalLibrary().renameStrategy(stored, 'Renamed');
    gate.release();
    (await renaming).orThrow();

    expect(await opening, isTrue);
    expect(h.captionOnCanvas(), s.pages[0].agentData.first.caption);
    expect(h.loads,
        ['open from Hive: ${FromHiveBecause.hiveWriteDuringRead.words}']);
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
