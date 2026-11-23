import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/library_listing.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_start.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/widgets/library_entries.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'hive_scratch.dart';

Future<void> _still() async {}

final class _CountedHive extends HiveLibraryListing {
  final reads = <String>[];

  @override
  ValueListenable<Iterable<LocalStrategySummary>> get strategies =>
      _Counted(super.strategies, () => reads.add('strategies'));

  @override
  ValueListenable<Iterable<Folder>> get folders =>
      _Counted(super.folders, () => reads.add('folders'));

  @override
  LocalStrategySummary? strategy(String id) {
    reads.add('strategy $id');
    return super.strategy(id);
  }

  @override
  Folder? folder(String id) {
    reads.add('folder $id');
    return super.folder(id);
  }

  @override
  List<Folder> folderChildren(String id) {
    reads.add('children $id');
    return super.folderChildren(id);
  }

  @override
  bool get holdsAnything {
    reads.add('holds anything');
    return super.holdsAnything;
  }

  @override
  Iterable<LocalStrategySummary> strategiesAsStored() {
    reads.add('every strategy');
    return super.strategiesAsStored();
  }

  @override
  LocalStrategySummary? strategyAsStored(
    Object key, {
    required Set<String> notInStore,
  }) {
    reads.add('strategy $key');
    return super.strategyAsStored(key, notInStore: notInStore);
  }

  @override
  Iterable<Folder> foldersAsStored() {
    reads.add('every folder');
    return super.foldersAsStored();
  }

  @override
  bool holdsStrategy(String id) {
    reads.add('holds $id');
    return super.holdsStrategy(id);
  }

  @override
  Folder? folderAsStored(Object key) {
    reads.add('folder $key');
    return super.folderAsStored(key);
  }
}

final class _Counted<T> implements ValueListenable<T> {
  _Counted(this._source, this._read);

  final ValueListenable<T> _source;
  final VoidCallback _read;

  @override
  T get value {
    _read();
    return _source.value;
  }

  @override
  void addListener(VoidCallback listener) => _source.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _source.removeListener(listener);
}

String _tile(LocalStrategySummary strategy) => [
      strategy.id,
      strategy.name,
      strategy.mapData.name,
      strategy.folderId,
      strategy.createdAt.microsecondsSinceEpoch,
      strategy.lastEdited.microsecondsSinceEpoch,
      strategy.sides.name,
      strategy.opensOnAttack,
      strategy.agentTypes.map((agent) => agent.name).join(' '),
      if (strategy.notInStore) 'not in the store',
    ].join(' | ');

String _folder(Folder folder) => [
      folder.id,
      folder.name,
      folder.parentID,
      folder.dateCreated.microsecondsSinceEpoch,
      folder.iconId,
      folder.color.name,
      folder.customColor?.toARGB32(),
    ].join(' | ');

List<String> _tiles(LocalLibraryListing listing) =>
    [for (final strategy in listing.strategies.value) _tile(strategy)];

List<String> _folders(LocalLibraryListing listing) =>
    [for (final folder in listing.folders.value) _folder(folder)];

StrategyData _withoutDrawings(StrategyData strategy) => strategy.copyWith(
      pages: [
        for (final page in strategy.pages) page.copyWith(drawingData: const []),
      ],
    );

final _full = _withoutDrawings(generatedStrategy(Optionals.set));
final _bare = _withoutDrawings(generatedStrategy(Optionals.unset));

List<Folder> _folderTree() => [
      Folder(name: 'Retakes', id: 'f-retakes', dateCreated: DateTime.utc(2026)),
      Folder(
        name: 'B site',
        id: 'f-b',
        dateCreated: DateTime.utc(2026, 2),
        parentID: 'f-retakes',
        color: FolderColor.blue,
      ),
    ];

List<StrategyData> _library() => [
      _full.copyWith(id: 'z-last', name: 'Same name', folderID: 'f-b'),
      _bare.copyWith(id: 'a-first', name: 'Same name'),
      _full.copyWith(
        id: 'm-middle',
        name: 'Mixed sides',
        folderID: 'f-retakes',
        pages: [
          for (final (index, page) in _full.pages.indexed)
            page.copyWith(isAttack: index.isEven),
        ],
      ),
      _bare.copyWith(id: 'empty', name: 'No pages', pages: const []),
    ];

Future<LibraryStore> _store([MemoryEngine? engine]) async =>
    switch (await LibraryStore.open(
      engine ?? MemoryEngine(MemoryStorage()),
      canRead: appCanRead,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => fail('$problem'),
    };

({StoreLibraryListing listing, StoreMirror mirror, _CountedHive hive}) _reading(
    {Future<void> Function() betweenAnimations = _still}) {
  final hive = _CountedHive();
  final listing = StoreLibraryListing(hive, clock: () => Duration.zero);
  final mirror = StoreMirror(
    reads: HiveReads(),
    betweenAnimations: betweenAnimations,
  );
  LocalLibrary.follower = mirror;
  listing.follow(mirror);
  return (listing: listing, mirror: mirror, hive: hive);
}

Future<void> _copy(StoreMirror mirror, LibraryStore store) async {
  final writes = LibraryBoxWrites();
  await mirror.copyThenFollow(store, writes: writes);
  await writes.stop();
}

List<String> _asStored() => [
      for (final strategy in HiveLibraryListing().strategiesAsStored())
        _tile(strategy),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-listing-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    await openScratchHive(
      directory,
      strategies: _library(),
      folders: _folderTree(),
    );
  });
  tearDown(() async {
    LocalLibrary.follower = null;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
      'the list is Hive\'s until the start-up copy has finished, then the store\'s, with the same tiles in the same order and one notice that the rows moved',
      () async {
    final (:listing, :mirror, hive: _) = _reading();
    final before = (strategies: _tiles(listing), folders: _folders(listing));
    expect(listing.source, isA<ListFromHive>());
    var strategyNotices = 0;
    var folderNotices = 0;
    listing.strategies.addListener(() => strategyNotices++);
    listing.folders.addListener(() => folderNotices++);

    await _copy(mirror, await _store());

    expect(listing.source, isA<ListFromStore>());
    expect(_tiles(listing), before.strategies);
    expect(_folders(listing), before.folders);
    expect(before.strategies.map((tile) => tile.split(' | ').first),
        ['a-first', 'empty', 'm-middle', 'z-last']);
    expect((strategyNotices, folderNotices), (1, 1));
    expect(listing.strategies.value.every(listing.drewFromStore), isTrue);
    expect(listing.folders.value.every(listing.drewFromStore), isTrue);
    for (final strategy in HiveLibraryListing().strategiesAsStored()) {
      expect(_tile(listing.strategy(strategy.id)!), _tile(strategy));
    }
    expect(listing.folderChildren('f-retakes').map((folder) => folder.id),
        ['f-b']);
    for (final id in ['a-first', 'empty', 'm-middle', 'z-last', 'missing']) {
      expect(
        listing.mixesSides(id).value,
        HiveLibraryListing().mixesSides(id).value,
        reason: id,
      );
    }
  });

  test(
      'once the list is the store\'s, drawing it reads nothing from Hive for strategies the store is known to hold as Hive does',
      () async {
    final (:listing, :mirror, :hive) = _reading();
    await _copy(mirror, await _store());
    hive.reads.clear();

    listing.strategies.value.toList();
    listing.folders.value.toList();
    listing.strategy('a-first');
    listing.strategy('missing');
    listing.folder('f-b');
    listing.folderChildren('f-retakes');
    listing.holdsAnything;
    listing.mixesSides('m-middle').value;

    expect(hive.reads, isEmpty);
  });

  test(
      'a strategy the converter refuses and one the store cannot read are listed from Hive with the mark, in Hive\'s order, and keep up with Hive',
      () async {
    final newer = _bare.copyWith(
      id: 'b-newer',
      name: 'From a newer build',
      versionNumber: Settings.versionNumber + 1,
    );
    final damaged = _bare.copyWith(
      id: 'c-damaged',
      name: 'Unreadable in the store',
      mapData: MapValue.bind,
    );
    await const LocalLibrary().addStrategy(newer);
    await const LocalLibrary().addStrategy(damaged);
    final engine = MemoryEngine(MemoryStorage());
    final seeding = await _store(engine);
    final rows = switch (strategyToRows(strategyAsHiveHoldsIt(damaged))) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };
    expect(
        await seeding.putStrategy(rows), isA<Saved<LibraryEdited, Object>>());
    await seeding.close();
    final lease = switch (await engine.lease()) {
      Leased(:final lease) => lease,
      final other => fail('$other'),
    };
    expect(
      await lease.commit([
        Put(strategyArea('c-damaged'), 'strategy', '{"publicId": "half'),
      ]),
      isA<CommitApplied>(),
    );
    await lease.release();

    final (:listing, :mirror, :hive) = _reading();
    final before = _tiles(listing);
    var notices = 0;
    listing.strategies.addListener(() => notices++);
    await _copy(mirror, await _store(engine));
    hive.reads.clear();

    expect(listing.source, isA<ListFromStore>());
    expect(listing.strategiesNotInStore, {'b-newer', 'c-damaged'});
    expect(notices, 1);
    expect(_tiles(listing), [
      for (final tile in before)
        tile.startsWith('b-newer') || tile.startsWith('c-damaged')
            ? '$tile | not in the store'
            : tile,
    ]);
    expect(hive.reads, ['strategy b-newer', 'strategy c-damaged']);

    await const LocalLibrary().addStrategy(
      newer.copyWith(name: 'Newer, renamed'),
    );
    await mirror.drained();
    expect(_nameOf(listing, 'b-newer'), 'Newer, renamed');
    expect(listing.strategiesNotInStore, {'b-newer', 'c-damaged'});
  });

  test(
      'a Hive strategy whose id the store holds as a cloud strategy is drawn from Hive with the mark even when the mirror never refused it, and a cloud strategy Hive does not hold adds no row and no mark',
      () async {
    final store = await _store();
    for (final (id, name) in [
      ('z-in-both', 'In the cloud'),
      ('y-cloud-only', 'Only in the cloud'),
    ]) {
      final rows = switch (strategyToRows(
          strategyAsHiveHoldsIt(_bare.copyWith(id: id, name: name)))) {
        StrategyRowsMade(:final rows) => rows,
        StrategyRowsRefused(:final problems) => fail('$problems'),
      };
      expect(
        await store.addCloudStrategy(
          Account('account-a'),
          HeaderRead(
            strategy: rows.strategy,
            pages: rows.pages.toList(),
            settings: rows.settings.toList(),
          ),
          const [],
        ),
        isA<Saved<StrategySummary, LibraryRefusal>>(),
      );
    }
    final (:listing, :mirror, hive: _) = _reading();
    await _copy(mirror, store);
    expect(listing.source, isA<ListFromStore>());
    expect(listing.strategiesNotInStore, isEmpty);

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
      'z-in-both',
      _bare.copyWith(id: 'z-in-both', name: 'Here too'),
    );

    expect(mirror.refusedStrategies, isNot(contains('z-in-both')));
    final row = _rowOf(listing, 'z-in-both');
    expect(row.name, 'Here too');
    expect(listing.drewFromStore(row), isFalse);
    expect(row.notInStore, isTrue);
    expect(listing.strategy('z-in-both')?.name, 'Here too');
    expect(listing.strategiesNotInStore, {'z-in-both'});
    expect(
      [for (final strategy in listing.strategies.value) strategy.id],
      [
        for (final strategy in HiveLibraryListing().strategiesAsStored())
          strategy.id,
      ],
    );
  });

  test(
      'a rename shows at once, drawn from Hive, and stays shown when the mirror catches up, with one notice as the row moves to the store',
      () async {
    final gap = Completer<void>();
    var copied = false;
    final (:listing, :mirror, hive: _) = _reading(
      betweenAnimations: () => copied ? gap.future : _still(),
    );
    await _copy(mirror, await _store());
    copied = true;
    var notices = 0;
    final heard = <String>[];
    listing.strategies.addListener(() {
      notices++;
      heard.add(_nameOf(listing, 'a-first'));
    });

    final renaming = const LocalLibrary().renameStrategy(
      const LocalLibrary().storedStrategy('a-first')!,
      'Renamed',
    );
    expect(_nameOf(listing, 'a-first'), 'Renamed');
    await renaming;
    for (var turn = 0; turn < 100 && notices == 0; turn++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(notices, 1);
    expect(heard, ['Renamed']);
    expect(_nameOf(listing, 'a-first'), 'Renamed');
    expect(mirror.strategiesNotKnownEqual, contains('a-first'));
    expect(listing.drewFromStore(_rowOf(listing, 'a-first')), isFalse);
    final afterSave = notices;

    gap.complete();
    await mirror.drained();

    expect(mirror.strategiesNotKnownEqual, isEmpty);
    expect(_nameOf(listing, 'a-first'), 'Renamed');
    expect(_tiles(listing), _asStored());
    expect(listing.drewFromStore(_rowOf(listing, 'a-first')), isTrue);
    expect(notices, afterSave + 1);
  });

  test(
      'a strategy started during the start-up copy is drawn from Hive at the handover, not from the copy taken before it',
      () async {
    Completer<void>? paused;
    final (:listing, :mirror, hive: _) = _reading(
      betweenAnimations: () =>
          paused?.future ?? Future<void>.delayed(Duration.zero),
    );
    for (var n = 0; n < 30; n++) {
      await const LocalLibrary()
          .addStrategy(_bare.copyWith(id: 'later-$n', name: 'Later $n'));
    }
    final fromTheStore = <String>[];
    final listening = mirror.updates.listen((_) {
      if (listing.source is ListFromStore) {
        fromTheStore.add(_nameOf(listing, 'a-first'));
      }
    });
    final store = await _store();
    final writes = LibraryBoxWrites();
    final copying = mirror.copyThenFollow(
      store,
      writes: writes,
      progress: (done, _) {
        if (done == 3) paused ??= Completer<void>();
      },
    );
    while (paused == null) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(listing.source, isA<ListFromHive>());
    await const LocalLibrary().renameStrategy(
      const LocalLibrary().storedStrategy('a-first')!,
      'Renamed mid-copy',
    );
    expect(fromTheStore, isEmpty);
    paused!.complete();
    paused = null;
    await copying;
    await writes.stop();
    await mirror.drained();
    await listening.cancel();

    expect(fromTheStore, isNotEmpty);
    expect(fromTheStore.first, 'Renamed mid-copy');
    expect(fromTheStore.toSet(), {'Renamed mid-copy'});
    expect(_tiles(listing), _asStored());
  });

  test(
      'two strategies saved in the same millisecond sort the same while drawn from Hive as once drawn from the store',
      () async {
    final gap = Completer<void>();
    var copied = false;
    final (:listing, :mirror, hive: _) = _reading(
      betweenAnimations: () => copied ? gap.future : _still(),
    );
    await _copy(mirror, await _store());
    copied = true;
    final saved = DateTime.fromMicrosecondsSinceEpoch(1795000000000123);
    await const LocalLibrary().addStrategy(
      _bare.copyWith(
        id: 'x-later',
        lastEdited: saved.add(const Duration(microseconds: 800)),
      ),
    );
    await const LocalLibrary()
        .addStrategy(_bare.copyWith(id: 'w-earlier', lastEdited: saved));
    List<String> byDate() => [
          for (final row in sortLibraryStrategies(
            [
              for (final strategy in listing.strategies.value)
                LibraryStrategyRow.local(strategy, showDeviceBadge: false),
            ],
            StrategyFilterState(
              sortBy: SortBy.dateUpdated,
              sortOrder: SortOrder.descending,
            ),
          ))
            row.id,
        ];
    expect(
        mirror.strategiesNotKnownEqual, containsAll(['x-later', 'w-earlier']));
    final whileFromHive = byDate();

    gap.complete();
    await mirror.drained();

    expect(mirror.strategiesNotKnownEqual, isEmpty);
    expect(byDate(), whileFromHive);
    expect(listing.strategy('x-later')!.lastEdited.microsecond, 0);
  });

  test(
      'a list held on Hive stays there until let go, then moves with one notice',
      () async {
    final (:listing, :mirror, hive: _) = _reading();
    listing.holdOnHive();
    final before = _tiles(listing);
    var notices = 0;
    listing.strategies.addListener(() => notices++);

    await _copy(mirror, await _store());
    expect(listing.source, isA<ListFromHive>());

    listing.letGo();

    expect(listing.source, isA<ListFromStore>());
    expect(_tiles(listing), before);
    expect(notices, 1);
    expect(listing.strategies.value.every(listing.drewFromStore), isTrue);
  });

  test('when the mirror is held, the list is drawn from Hive', () async {
    final (:listing, :mirror, hive: _) = _reading();
    await _copy(mirror, await _store());
    final before = _tiles(listing);

    mirror.hold();

    expect(listing.source, isA<ListFromHive>());
    expect(_tiles(listing), before);
  });

  test('when the store shuts, the list is drawn from Hive again', () async {
    final (:listing, :mirror, hive: _) = _reading();
    final store = await _store();
    await _copy(mirror, store);
    final before = _tiles(listing);

    await store.close();
    await pumpEventQueue();

    expect(listing.source, isA<ListFromHive>());
    expect(_tiles(listing), before);
  });

  test(
      'through start-up, off, shadow and mirror list Hive with main\'s listenables, and only read draws from the store',
      () {
    for (final choice in [
      const StoreSwitchOff(),
      const StoreSwitchShadow(),
      const StoreSwitchMirror(),
      const StoreSwitchRead(),
      const StoreSwitchOps(),
    ]) {
      final start = LibraryStoreStart.of(choice, clock: () => Duration.zero);
      final container = ProviderContainer(overrides: start.overrides);
      addTearDown(container.dispose);
      final view = container.read(localLibraryViewProvider);
      expect(container.read(libraryStoreSwitchProvider).runtimeType,
          choice.runtimeType);
      switch (choice) {
        case StoreSwitchOff():
          expect(start.mode, isNull);
        case StoreSwitchShadow():
          expect(start.mode, isA<ShadowOnly>());
        case StoreSwitchMirror() || StoreSwitchRead() || StoreSwitchOps():
          expect(start.mode, isA<Mirroring>());
      }
      expect(
        start.editFollower != null,
        choice is StoreSwitchOps,
        reason: '$choice',
      );
      final reads = choice is StoreSwitchRead;
      expect(start.listing != null, reads, reason: '$choice');
      expect(
        container.read(localLibraryListingProvider),
        reads ? same(start.listing) : isNull,
        reason: '$choice',
      );
      if (!reads) {
        expect(
          view.strategies.runtimeType,
          view.onDisk.strategies.runtimeType,
          reason: '$choice',
        );
        expect(
          [for (final s in view.strategies.value) s.lastEdited],
          [
            for (final s in _library()..sort((a, b) => a.id.compareTo(b.id)))
              s.lastEdited
          ],
          reason: '$choice keeps Hive\'s own dates',
        );
      }
      expect(view.strategies.value.map((s) => s.id),
          ['a-first', 'empty', 'm-middle', 'z-last'],
          reason: '$choice');
    }
  });
}

LocalStrategySummary _rowOf(LocalLibraryListing listing, String id) =>
    listing.strategies.value.singleWhere((strategy) => strategy.id == id);

String _nameOf(LocalLibraryListing listing, String id) =>
    listing.strategies.value.singleWhere((strategy) => strategy.id == id).name;
