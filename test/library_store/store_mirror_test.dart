import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/library_box_writes.dart';
import 'package:icarus/library_store/shadow_copy.dart';
import 'package:icarus/library_store/store_check.dart';
import 'package:icarus/library_store/store_mirror.dart';
import 'package:icarus/migrations/hidden_folder_repair.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus_library/icarus_library.dart';

import 'hive_scratch.dart';

Future<void> _still() async {}

StrategyPage _page(String id, int index) => StrategyPage(
      id: id,
      name: 'Page ${index + 1}',
      isAutoNamed: true,
      drawingData: const [],
      agentData: [
        PlacedAgent(
          id: '$id-agent',
          type: AgentType.sova,
          position: Offset(10.0 * (index + 1), 20),
        ),
      ],
      abilityData: const [],
      textData: const [],
      imageData: const [],
      utilityData: const [],
      sortIndex: index,
      isAttack: true,
      settings: StrategySettings(),
    );

StrategyData _legacy(String id, {String? folderId}) => StrategyData(
      id: id,
      name: 'Legacy $id',
      mapData: MapValue.bind,
      versionNumber: 1,
      lastEdited: DateTime.utc(2025, 3, 4),
      createdAt: DateTime.utc(2025, 3, 1),
      folderID: folderId,
      pages: [_page('$id-p1', 0), _page('$id-p2', 1)],
    );

final class _Counted implements StorageEngine {
  _Counted(this.inner);

  final StorageEngine inner;
  var commits = 0;

  @override
  Future<Leasing> lease() async => switch (await inner.lease()) {
        Leased(:final lease) => Leased(_CountedLease(lease, this)),
        final other => other,
      };
}

final class _CountedLease implements StorageLease {
  _CountedLease(this.inner, this.engine);

  final StorageLease inner;
  final _Counted engine;

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
  Future<Committing> commit(List<Change> changes) {
    engine.commits++;
    return inner.commit(changes);
  }

  @override
  Future<Releasing> release() => inner.release();
}

Box<StrategyData> get _strategies =>
    Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

Box<Folder> get _folders => Hive.box<Folder>(HiveBoxNames.foldersBox);

final class _Boxes implements LibraryBoxes {
  var strategyReads = 0;
  var folderReads = 0;

  @override
  StrategyData? strategy(String id) {
    strategyReads++;
    return _strategies.get(id);
  }

  @override
  Folder? folder(String id) {
    folderReads++;
    return _folders.get(id);
  }

  @override
  Iterable<StrategyData> get strategies => _strategies.values;

  @override
  Iterable<Folder> get folders => _folders.values;
}

final class _Thrown implements LibraryBoxes {
  _Thrown({required this.wholeLibrary});

  final bool wholeLibrary;

  @override
  StrategyData? strategy(String id) => throw StateError('a read that fails');

  @override
  Folder? folder(String id) => throw StateError('a read that fails');

  @override
  Iterable<StrategyData> get strategies =>
      wholeLibrary ? throw HiveError('a read that fails') : _strategies.values;

  @override
  Iterable<Folder> get folders => _folders.values;
}

final class _Recorder extends LocalLibraryFollower {
  final told = <String>[];

  @override
  void onWriting(LibraryTouch touch) =>
      told.add('writing ${touch.strategies} ${touch.folders}');

  @override
  void onAnswered(LibraryTouch touch) =>
      told.add('answered ${touch.strategies} ${touch.folders}');

  @override
  void onFault(Object error, StackTrace stackTrace) => told.add('fault');
}

final class _Throwing extends LocalLibraryFollower {
  final faults = <Object>[];

  @override
  void onWriting(LibraryTouch touch) => throw StateError('follower broke');

  @override
  void onAnswered(LibraryTouch touch) => throw StateError('follower broke');

  @override
  void onFault(Object error, StackTrace stackTrace) => faults.add(error);
}

final class _ThrowingTwice extends LocalLibraryFollower {
  @override
  void onWriting(LibraryTouch touch) => throw StateError('follower broke');

  @override
  void onAnswered(LibraryTouch touch) => throw StateError('follower broke');

  @override
  void onFault(Object error, StackTrace stackTrace) =>
      throw StateError('its fault handler broke too');
}

Future<StoreCheck> _checkThrough(
  LibraryStore store,
  StoreMirror mirror, {
  Future<void> Function()? during,
}) =>
    mirror.check((hive) async {
      final check = await checkStoreAgainstHive(
        hive,
        store,
        foreignNames: const [],
        breathe: _still,
        strategiesRefused: mirror.refusedStrategies,
        foldersRefused: mirror.refusedFolders,
      );
      if (during != null) await during();
      return check;
    });

Future<StoreChecked> _exact(LibraryStore store, StoreMirror mirror) async =>
    switch (await _checkThrough(store, mirror)) {
      final StoreChecked checked => checked,
      final other => throw StateError('$other'),
    };

Future<StoreMirror> _mirroring(
  LibraryStore store, {
  LibraryBoxes? boxes,
  Future<void> Function() betweenAnimations = _still,
}) async {
  final mirror = StoreMirror(
    reads: HiveReads.over(boxes ?? _Boxes()),
    betweenAnimations: betweenAnimations,
  );
  LocalLibrary.follower = mirror;
  final writes = LibraryBoxWrites();
  await mirror.copyThenFollow(store, writes: writes);
  await writes.stop();
  return mirror;
}

Future<String> _storedName(LibraryStore store, String id) async =>
    switch (await store.readStrategy(id)) {
      Found(:final value) => (value.strategy as ReadableStrategy).name,
      final other => throw StateError('$other'),
    };

StrategyData _current(String id) =>
    StrategyMigrator.migrateToCurrentVersion(_legacy(id));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    directory = await Directory.systemTemp.createTemp('icarus-mirror-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => directory.path,
    );
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    await Hive.openBox<int>(HiveBoxNames.pinnedItemsBox);
  });
  tearDown(() async {
    LocalLibrary.follower = null;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
      'an editing session through the providers leaves the store exact after every step',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    final container = ProviderContainer();
    appProviderContainer = container;
    addTearDown(container.dispose);
    final notifier = container.read(strategyProvider.notifier);
    final library = container.read(folderProvider.notifier);
    await container
        .read(appPreferencesProvider.notifier)
        .setAutosaveEnabled(false);

    await const LocalLibrary().addStrategy(_legacy('library-legacy'));
    await StrategyMigrator.migrateAllStrategies();
    final mirror = await _mirroring(store);
    final steps = <String>[];
    Future<void> step(String name) async {
      steps.add(name);
      final check = await _exact(store, mirror);
      expect(
        check.isExact,
        isTrue,
        reason: '$name: ${check.strategyProblems} ${check.folderProblems}',
      );
      expect(check.sameStrategies, _strategies.length, reason: name);
      expect(check.sameFolders, _folders.length, reason: name);
    }

    await step('migrate the library at startup, then copy it');
    final plans = await library.createFolder(
        name: 'Plans', iconId: 1, color: FolderColor.blue);
    await step('create a folder');
    final created = await notifier.createNewStrategy(
        map: MapValue.ascent, name: 'Session', local: true);
    await step('create a strategy');
    await notifier.moveToFolder(strategyID: created.id, parentID: plans.id);
    await step('move the strategy into the folder');
    await notifier.loadFromHive(created.id);
    await step('open the strategy');
    container.read(agentProvider.notifier).addAgent(
          PlacedAgent(
              id: 'jett-1',
              type: AgentType.jett,
              position: const Offset(300, 200)),
        );
    container
        .read(textProvider.notifier)
        .addText(PlacedText(id: 'note-1', position: const Offset(50, 60)));
    container.read(strategySaveStateProvider.notifier).markDirty();
    await notifier.forceSaveNow(created.id);
    await step('save edits on the first page');
    await notifier.addPage();
    await step('add a page');
    final secondPageId =
        container.read(strategyPageSessionProvider).activePageId!;
    await notifier.renamePage(secondPageId, 'Retake');
    await step('rename the page');
    container.read(agentProvider.notifier).addAgent(
          PlacedAgent(
              id: 'omen-1',
              type: AgentType.omen,
              position: const Offset(500, 400)),
        );
    await notifier.copyPlacedWidgetToAdjacentPage(
      widgetId: 'omen-1',
      direction: PageTransitionDirection.backward,
    );
    await step('copy an agent to the page before');
    await notifier.reorderPage(1, 0);
    await step('reorder the pages');
    await notifier.switchSide(allPages: true);
    await step('switch side on every page');
    await notifier.applyMarkerSizesToAllPages();
    await step('apply marker sizes to every page');
    await notifier.addPage('Exec');
    final thirdPageId =
        container.read(strategyPageSessionProvider).activePageId!;
    await notifier.deletePage(thirdPageId);
    await step('add and delete a page');
    await notifier.renameStrategy(created.id, 'Session renamed');
    await step('rename the strategy');
    await notifier.duplicateStrategy(created.id);
    final copy = _strategies.values
        .firstWhere((strategy) => strategy.name == 'Session renamed (Copy)');
    await step('duplicate the strategy');
    await notifier.deleteStrategy(copy.id);
    await step('delete the copy');
    await library.editFolder(
      folder: _folders.get(plans.id)!,
      newName: 'Plans A',
      newIconId: 2,
      newColor: FolderColor.custom,
      newCustomColor: const Color(0xFF336699),
    );
    await step('restyle the folder');
    final archive = await library.createFolder(
        name: 'Archive', iconId: 3, color: FolderColor.green);
    await library.moveToFolder(folderID: plans.id, parentID: archive.id);
    await step('move the folder into another');
    await const LocalLibrary().addFolder(
      Folder(
          name: 'Orphan',
          id: 'orphan-folder',
          dateCreated: DateTime(2025, 5, 6),
          parentID: 'gone-folder'),
    );
    await const LocalLibrary()
        .addStrategy(_legacy('orphan-strategy', folderId: 'gone-folder'));
    await StrategyMigrator.migrateAllStrategies();
    await moveOrphansToTopLevel(_folders, _strategies);
    await step('move orphans to the top level');
    await const LocalLibrary().addStrategy(_legacy('opened-legacy'));
    await notifier.loadFromHive('opened-legacy');
    await step('open a strategy saved by an older build');
    await library.deleteFolder(archive.id);
    await step('delete a folder with a strategy inside');
    expect(steps, hasLength(21));
    expect(mirror.batches, greaterThan(0));
    await store.close();
  });

  test(
      'saves that arrive faster than the store writes them leave only the newest image to write',
      () async {
    final storage = MemoryStorage();
    final counted = _Counted(MemoryEngine(storage));
    final store = await openStoreOn(counted);
    final strategy = _legacy('fast');
    await _strategies.put(
        strategy.id, StrategyMigrator.migrateToCurrentVersion(strategy));
    final mirror = await _mirroring(store);
    await mirror.drained();
    final before = counted.commits;
    final hold = storage.holdNextWrite();
    final stored = _strategies.get('fast')!;
    await const LocalLibrary().renameStrategy(stored, 'rename 0');
    await hold.reached;
    for (var n = 1; n <= 30; n++) {
      expect(
        await const LocalLibrary().renameStrategy(stored, 'rename $n'),
        isA<LibraryWritten>(),
      );
    }
    hold.letGo();
    final check = await _exact(store, mirror);
    expect(check.isExact, isTrue, reason: '${check.strategyProblems}');
    expect(counted.commits - before, lessThanOrEqualTo(2));
    expect(mirror.batches, lessThanOrEqualTo(2));
    final content = switch (await store.readStrategy('fast')) {
      Found(:final value) => value,
      final other => throw StateError('$other'),
    };
    expect((content.strategy as ReadableStrategy).name, 'rename 30');
    await store.close();
  });

  test(
      'a store write that is refused leaves the save as it was and is listed, with the store\'s reason, as not mirrored',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    await _strategies.put(
        'filed', StrategyMigrator.migrateToCurrentVersion(_legacy('filed')));
    final mirror = await _mirroring(store);
    await _folders.put(
      'outside',
      Folder(
          name: 'Written outside LocalLibrary',
          id: 'outside',
          dateCreated: DateTime(2025)),
    );
    final saved = await const LocalLibrary()
        .moveStrategy(_strategies.get('filed')!, 'outside');
    expect(saved, isA<LibraryWritten>());
    expect(_strategies.get('filed')!.folderID, 'outside');
    final check = await _exact(store, mirror);
    expect(check.isExact, isFalse);
    expect(
      mirror.refusedStrategies['filed'],
      isA<StoreRefusedIt>()
          .having((r) => r.refusal, 'refusal', isA<NoSuchFolder>()),
    );
    expect(
      check.notMirrored
          .whereType<StrategyWriteRefused>()
          .map((c) => c.strategyId),
      ['filed'],
    );
    await store.close();
  });

  test(
      'a strategy the converter refuses on save is listed as not mirrored with the converter\'s reason',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    final mirror = await _mirroring(store);
    final translucent =
        StrategyMigrator.migrateToCurrentVersion(_legacy('translucent'))
            .copyWith(
      themeOverridePalette: MapThemePalette(
        baseColorValue: 0x80101820,
        detailColorValue: 0xFFF2AA4C,
        highlightColorValue: 0xFFFFFFFF,
      ),
    );
    expect(await const LocalLibrary().addStrategy(translucent),
        isA<LibraryWritten>());
    final check = await _exact(store, mirror);
    expect(mirror.refusedStrategies['translucent'], isA<ConverterRefused>());
    expect(check.notMirrored.map((c) => c.runtimeType).toSet(),
        containsAll([StrategyNotConverted, StrategyWriteRefused]));
    await store.close();
  });

  test(
      'stopped between the Hive write and the store write, the next start makes the store exact',
      () async {
    final storage = MemoryStorage();
    final first = await openStoreOn(MemoryEngine(storage));
    await _strategies.put(
        'kept', StrategyMigrator.migrateToCurrentVersion(_legacy('kept')));
    final mirror = await _mirroring(first);
    await mirror.drained();
    mirror.hold();
    expect(
      await const LocalLibrary()
          .renameStrategy(_strategies.get('kept')!, 'renamed before the stop'),
      isA<LibraryWritten>(),
    );
    expect(
      await const LocalLibrary().addStrategy(
          StrategyMigrator.migrateToCurrentVersion(_legacy('added'))),
      isA<LibraryWritten>(),
    );
    expect(mirror.pending, 2);
    final behind = await _exact(first, mirror);
    expect(behind.isExact, isFalse);
    await first.close();
    LocalLibrary.follower = null;

    final second = await openStoreOn(MemoryEngine(storage));
    final restarted = await _mirroring(second);
    final check = await _exact(second, restarted);
    expect(check.isExact, isTrue, reason: '${check.strategyProblems}');
    await second.close();
  });

  test(
      'with the follower detached a save writes Hive and the mirror neither hears of it nor writes the store',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    final mirror = await _mirroring(store);
    await const LocalLibrary().addStrategy(_current('told'));
    await mirror.drained();
    expect(await _storedName(store, 'told'), 'Legacy told');
    final batches = mirror.batches;
    LocalLibrary.follower = null;
    expect(await const LocalLibrary().addStrategy(_current('alone')),
        isA<LibraryWritten>());
    expect(_strategies.containsKey('alone'), isTrue);
    await mirror.drained();
    expect(mirror.pending, 0);
    expect(mirror.batches, batches);
    expect(await store.readStrategy('alone'), isA<NotFound<StrategyContent>>());
    await store.close();
  });

  test('a follower records what each save touched, before and after the write',
      () async {
    final recorder = _Recorder();
    LocalLibrary.follower = recorder;
    await const LocalLibrary().addStrategy(_current('told'));
    expect(recorder.told, ['writing [told] []', 'answered [told] []']);
  });

  test('a follower that throws cannot change the answer of a save', () async {
    final throwing = _Throwing();
    LocalLibrary.follower = throwing;
    expect(await const LocalLibrary().addStrategy(_current('kept')),
        isA<LibraryWritten>());
    expect(_strategies.containsKey('kept'), isTrue);
    expect(throwing.faults, hasLength(2));
  });

  test(
      'a strategy whose second write is in flight is not read until it answers, and a failed write leaves the store where it was',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    var gate = Completer<void>()..complete();
    final mirror =
        await _mirroring(store, betweenAnimations: () => gate.future);
    await const LocalLibrary().addStrategy(_current('held'));
    await mirror.drained();
    gate = Completer<void>();
    await const LocalLibrary()
        .renameStrategy(_strategies.get('held')!, 'second save');
    final answered = _strategies.get('held')!;
    const touch = LibraryTouch(strategies: ['held'], folders: []);
    mirror.onWriting(touch);
    await _strategies.put('held', answered.copyWith(name: 'in flight'));
    gate.complete();
    await mirror.drained();
    expect(await _storedName(store, 'held'), 'Legacy held');
    await _strategies.put('held', answered.copyWith());
    mirror.onAnswered(touch);
    final check = await _exact(store, mirror);
    expect(check.isExact, isTrue, reason: '${check.strategyProblems}');
    expect(await _storedName(store, 'held'), 'second save');
    await store.close();
  });

  test(
      'a strategy saved into a folder whose write is in flight is tried again when the folder lands',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    final mirror = await _mirroring(store);
    const folderTouch = LibraryTouch(strategies: [], folders: ['late']);
    mirror.onWriting(folderTouch);
    await _folders.put(
        'late', Folder(name: 'Late', id: 'late', dateCreated: DateTime(2025)));
    await const LocalLibrary()
        .addStrategy(_current('filed').copyWith(folderID: 'late'));
    await mirror.drained();
    expect(
        mirror.refusedStrategies['filed'],
        isA<StoreRefusedIt>()
            .having((r) => r.refusal, 'refusal', isA<NoSuchFolder>()));
    mirror.onAnswered(folderTouch);
    final check = await _exact(store, mirror);
    expect(check.isExact, isTrue,
        reason: '${check.strategyProblems} ${check.folderProblems}');
    expect(mirror.refusedStrategies, isEmpty);
    await store.close();
  });

  test(
      'a bulk delete whose folder part fails still tells the follower the strategy it deleted',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    await const LocalLibrary().addFolder(
        Folder(name: 'Plans', id: 'plans', dateCreated: DateTime(2025)));
    await const LocalLibrary()
        .addStrategy(_current('inside').copyWith(folderID: 'plans'));
    final wait = Completer<void>()..complete();
    var gate = wait;
    final mirror =
        await _mirroring(store, betweenAnimations: () => gate.future);
    await mirror.drained();
    gate = Completer<void>();
    await _folders.close();
    final deleted = await const LocalLibrary().deleteFoldersWithStrategies(
        folderIds: ['plans'], strategyIds: ['inside']);
    expect(deleted, isA<LibraryWriteFailed>());
    expect(_strategies.containsKey('inside'), isFalse);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    gate.complete();
    final check = await _exact(store, mirror);
    expect(check.isExact, isTrue,
        reason: '${check.strategyProblems} ${check.folderProblems}');
    await store.close();
  });

  test(
      'a folder the store refused and Hive then deleted has its not-mirrored record cleared',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    final mirror = await _mirroring(store);
    await const LocalLibrary().addFolder(Folder(
        name: 'Lost',
        id: 'lost',
        dateCreated: DateTime(2025),
        parentID: 'gone'));
    await mirror.drained();
    expect(mirror.refusedFolders.keys, ['lost']);
    await const LocalLibrary().deleteFolder('lost');
    final check = await _exact(store, mirror);
    expect(mirror.refusedFolders, isEmpty);
    expect(check.isExact, isTrue, reason: '${check.folderProblems}');
    await store.close();
  });

  test(
      'a save noticed while the check compares makes its answer "changed during the check", never exact',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    await _strategies.put('watched', _current('watched'));
    final mirror = await _mirroring(store);
    final check = await _checkThrough(
      store,
      mirror,
      during: () async {
        await const LocalLibrary().renameStrategy(
            _strategies.get('watched')!, 'renamed during the check');
      },
    );
    expect(check, isA<StoreChangedDuringCheck>());
    expect(await _exact(store, mirror),
        isA<StoreChecked>().having((c) => c.isExact, 'exact', isTrue));
    await store.close();
  });

  test(
      'an error inside a batch stops the mirror with its reason, and waiting for it answers at once',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    final mirror = await _mirroring(store, boxes: _Thrown(wholeLibrary: false));
    await const LocalLibrary().addStrategy(_current('broken'));
    await mirror.drained().timeout(const Duration(seconds: 2));
    expect(
      mirror.phase,
      isA<MirrorStopped>().having((p) => p.stop, 'stop', isA<MirrorFaulted>()),
    );
    expect(_strategies.containsKey('broken'), isTrue);
    await store.close();
  });

  test(
      'a hold that arrives while a batch waits for its moment stops that batch from writing',
      () async {
    final storage = MemoryStorage();
    final counted = _Counted(MemoryEngine(storage));
    final store = await openStoreOn(counted);
    var gate = Completer<void>()..complete();
    var waiting = Completer<void>();
    final mirror = await _mirroring(store, betweenAnimations: () {
      if (!waiting.isCompleted) waiting.complete();
      return gate.future;
    });
    await mirror.drained();
    final before = counted.commits;
    gate = Completer<void>();
    waiting = Completer<void>();
    await const LocalLibrary().addStrategy(_current('held back'));
    await waiting.future;
    mirror.hold();
    gate.complete();
    await mirror.drained();
    expect(counted.commits, before);
    expect(mirror.batches, 0);
    await store.close();
  });

  test(
      'one save costs the same reads whether the library holds 10 strategies or 700',
      () async {
    Future<({int strategies, int folders, int commits, Duration took})> oneSave(
        int size) async {
      await _strategies.clear();
      for (var n = 0; n < size; n++) {
        await _strategies.put('s$n', _current('s$n'));
      }
      final counted = _Counted(MemoryEngine(MemoryStorage()));
      final store = await openStoreOn(counted);
      final boxes = _Boxes();
      final mirror = await _mirroring(store, boxes: boxes);
      await mirror.drained();
      boxes
        ..strategyReads = 0
        ..folderReads = 0;
      final commits = counted.commits;
      final clock = Stopwatch()..start();
      await const LocalLibrary()
          .renameStrategy(_strategies.get('s0')!, 'edited');
      await mirror.drained();
      final took = clock.elapsed;
      await store.close();
      return (
        strategies: boxes.strategyReads,
        folders: boxes.folderReads,
        commits: counted.commits - commits,
        took: took
      );
    }

    final small = await oneSave(10);
    final large = await oneSave(700);
    debugPrint('one save, 10 strategies: $small; 700 strategies: $large');
    expect((large.strategies, large.folders, large.commits),
        (small.strategies, small.folders, small.commits));
    expect(large.strategies, 1);
    expect(large.commits, 1);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test(
      'a write that starts while the batch commits an earlier strategy is not read by that batch',
      () async {
    final storage = MemoryStorage();
    final store = await openStoreOn(MemoryEngine(storage));
    await _strategies.put('first', _current('first'));
    await _strategies.put('second', _current('second'));
    var gate = Completer<void>()..complete();
    final mirror =
        await _mirroring(store, betweenAnimations: () => gate.future);
    await mirror.drained();
    gate = Completer<void>();
    await const LocalLibrary()
        .renameStrategy(_strategies.get('first')!, 'first renamed');
    await const LocalLibrary()
        .renameStrategy(_strategies.get('second')!, 'second renamed');
    final answered = _strategies.get('second')!;
    final hold = storage.holdNextWrite();
    gate.complete();
    await hold.reached;
    const touch = LibraryTouch(strategies: ['second'], folders: []);
    mirror.onWriting(touch);
    await _strategies.put('second', answered.copyWith(name: 'provisional'));
    hold.letGo();
    await mirror.drained();
    expect(await _storedName(store, 'first'), 'first renamed');
    expect(await _storedName(store, 'second'), 'Legacy second');
    await _strategies.put('second', answered.copyWith());
    mirror.onAnswered(touch);
    final check = await _exact(store, mirror);
    expect(check.isExact, isTrue, reason: '${check.strategyProblems}');
    expect(await _storedName(store, 'second'), 'second renamed');
    await store.close();
  });

  test('the start-up copy does not read a strategy whose write is in flight',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    await _strategies.put('open', _current('open'));
    final committed = _strategies.get('open')!;
    final mirror = StoreMirror(
      reads: HiveReads.over(_Boxes()),
      betweenAnimations: _still,
    );
    LocalLibrary.follower = mirror;
    const touch = LibraryTouch(strategies: ['open'], folders: []);
    mirror.onWriting(touch);
    await _strategies.put('open', committed.copyWith(name: 'provisional'));
    final writes = LibraryBoxWrites();
    await mirror.copyThenFollow(store, writes: writes);
    await writes.stop();
    expect(await store.readStrategy('open'), isA<NotFound<StrategyContent>>());
    await _strategies.put('open', committed.copyWith());
    mirror.onAnswered(touch);
    final check = await _exact(store, mirror);
    expect(check.isExact, isTrue, reason: '${check.strategyProblems}');
    expect(await _storedName(store, 'open'), 'Legacy open');
    await store.close();
  });

  test(
      'a write in flight when the check begins makes its answer "changed during the check"',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    await _strategies.put('checked', _current('checked'));
    final mirror = await _mirroring(store);
    await mirror.drained();
    final before = _strategies.get('checked')!.copyWith();
    mirror.hold();
    await const LocalLibrary()
        .renameStrategy(_strategies.get('checked')!, 'committed');
    final committed = _strategies.get('checked')!.copyWith();
    const touch = LibraryTouch(strategies: ['checked'], folders: []);
    mirror.onWriting(touch);
    await _strategies.put('checked', before);
    final check = await _checkThrough(store, mirror);
    await _strategies.put('checked', committed);
    mirror.onAnswered(touch);
    expect(check, isA<StoreChangedDuringCheck>());
    await store.close();
  });

  test('each half of a bulk delete is answered when its own Hive write settles',
      () async {
    await const LocalLibrary().addFolder(
        Folder(name: 'Plans', id: 'plans', dateCreated: DateTime(2025)));
    await const LocalLibrary()
        .addStrategy(_current('inside').copyWith(folderID: 'plans'));
    final recorder = _Recorder();
    LocalLibrary.follower = recorder;
    await _folders.close();
    final deleted = await const LocalLibrary().deleteFoldersWithStrategies(
        folderIds: ['plans'], strategyIds: ['inside']);
    expect(deleted, isA<LibraryWriteFailed>());
    expect(recorder.told, [
      'writing [inside] []',
      'writing [] [plans]',
      'answered [] [plans]',
    ]);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await _strategies.flush();
    await pumpEventQueue();
    expect(recorder.told.last, 'answered [inside] []');
  });

  test(
      'a follower whose fault handler also throws cannot stop a save reaching Hive',
      () async {
    LocalLibrary.follower = _ThrowingTwice();
    expect(await const LocalLibrary().addStrategy(_current('kept')),
        isA<LibraryWritten>());
    expect(_strategies.containsKey('kept'), isTrue);
  });

  test(
      'a Hive read that fails during the start-up copy stops the mirror with its reason',
      () async {
    final store = await openStoreOn(MemoryEngine(MemoryStorage()));
    final mirror = StoreMirror(
      reads: HiveReads.over(_Thrown(wholeLibrary: true)),
      betweenAnimations: _still,
    );
    LocalLibrary.follower = mirror;
    final writes = LibraryBoxWrites();
    try {
      await mirror.copyThenFollow(store, writes: writes);
    } on Object {
      fail('the copy let its error out');
    } finally {
      await writes.stop();
    }
    await mirror.drained().timeout(const Duration(seconds: 2));
    expect(
      mirror.phase,
      isA<MirrorStopped>().having((p) => p.stop, 'stop', isA<MirrorFaulted>()),
    );
    await store.close();
  });
}
