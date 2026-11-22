import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus/strategy/strategy_models.dart';

import 'library_rows/generated_strategies.dart';

String mainsSideLabel(StrategyData strategy) {
  final pages = strategy.pages;
  if (pages.isEmpty) return 'Unknown';
  final first = pages.first.isAttack;
  if (pages.any((page) => page.isAttack != first)) return 'Mixed';
  return first ? 'Attack' : 'Defend';
}

List<AgentType> mainsTileAgents(StrategyData strategy) {
  final result = <AgentType>{};
  for (final page in strategy.pages) {
    for (final agent in page.agentData) {
      result.add(agent.type);
    }
    for (final origin in page.lineUpOrigins) {
      result.add(origin.agent.type);
    }
  }
  return result.toList();
}

String sideLabel(LocalSides sides) => switch (sides) {
      LocalSides.attack => 'Attack',
      LocalSides.defend => 'Defend',
      LocalSides.mixed => 'Mixed',
      LocalSides.unknown => 'Unknown',
    };

List<StrategyData> varied() {
  final full = generatedStrategy(Optionals.set);
  final bare = generatedStrategy(Optionals.unset);
  return [
    full,
    bare.copyWith(id: 'bare'),
    full.copyWith(id: 'no-pages', pages: const []),
    full.copyWith(
      id: 'attack-only',
      pages: [for (final page in full.pages) page.copyWith(isAttack: true)],
    ),
    full.copyWith(
      id: 'defend-only',
      pages: [for (final page in full.pages) page.copyWith(isAttack: false)],
    ),
    full.copyWith(
      id: 'mixed',
      pages: [
        for (final (index, page) in full.pages.indexed)
          page.copyWith(isAttack: index.isEven),
      ],
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-view-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('a summary shows what main derived from the strategy for each screen',
      () {
    final strategies = varied();
    expect(strategies.map(mainsSideLabel).toSet(),
        {'Attack', 'Defend', 'Mixed', 'Unknown'});
    for (final strategy in strategies) {
      final summary = LocalStrategySummary.fromHive(strategy);
      expect(summary.id, strategy.id);
      expect(summary.name, strategy.name);
      expect(summary.mapData, strategy.mapData);
      expect(summary.folderId, strategy.folderID);
      expect(summary.createdAt, strategy.createdAt);
      expect(summary.lastEdited, strategy.lastEdited);
      expect(sideLabel(summary.sides), mainsSideLabel(strategy),
          reason: strategy.id);
      expect(summary.opensOnAttack,
          strategy.pages.isEmpty || strategy.pages.first.isAttack,
          reason: strategy.id);
      expect(summary.agentTypes, mainsTileAgents(strategy),
          reason: strategy.id);
    }
  });

  test(
      'each listenable fires on exactly the box events the box listenable it replaces fired on',
      () async {
    final view = LocalLibraryView();
    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final folderBox = Hive.box<Folder>(HiveBoxNames.foldersBox);
    final heard = <String, int>{};
    void count(String what) =>
        heard.update(what, (n) => n + 1, ifAbsent: () => 1);
    final pairs = <(String, Listenable)>[
      ('view strategies', view.strategies),
      ('box strategies', strategyBox.listenable()),
      ('view folders', view.folders),
      ('box folders', folderBox.listenable()),
      ('view one', view.strategyImageChanges('one')),
      ('box one', strategyBox.listenable(keys: ['one'])),
      ('view none', view.strategyImageChanges(null)),
      ('box none', strategyBox.listenable(keys: [null])),
    ];
    final listeners = [
      for (final (what, listenable) in pairs) (listenable, () => count(what)),
    ];
    for (final (listenable, listener) in listeners) {
      listenable.addListener(listener);
    }
    final strategy = generatedStrategy(Optionals.set);
    const library = LocalLibrary();
    await library.addStrategy(strategy.copyWith(id: 'one'));
    await library.addStrategy(strategy.copyWith(id: 'two'));
    await library.renameStrategy(library.storedStrategy('one')!, 'renamed');
    await library.addFolder(
        Folder(name: 'Plans', id: 'plans', dateCreated: DateTime(2025)));
    await library.deleteFoldersWithStrategies(
        folderIds: ['plans'], strategyIds: ['two']);
    await library.deleteStrategy('one');
    await pumpEventQueue();
    for (final (listenable, listener) in listeners) {
      listenable.removeListener(listener);
    }
    for (final name in ['strategies', 'folders', 'one', 'none']) {
      expect(heard['view $name'], heard['box $name'], reason: name);
    }
    expect(heard['view strategies'], greaterThan(0));
    expect(heard['view folders'], greaterThan(0));
    expect(heard['view one'], greaterThan(0));
  });

  test(
      'the list values read the boxes when they are iterated, as box.values did',
      () async {
    final view = LocalLibraryView();
    final strategies = view.strategies.value;
    final folders = view.folders.value;
    expect(strategies, isEmpty);
    await const LocalLibrary()
        .addStrategy(generatedStrategy(Optionals.set).copyWith(id: 'late'));
    await const LocalLibrary().addFolder(
        Folder(name: 'Late', id: 'late-folder', dateCreated: DateTime(2025)));
    expect(strategies.map((s) => s.id), ['late']);
    expect(folders.map((f) => f.id), ['late-folder']);
    expect(view.strategy('late')!.name, generatedStrategy(Optionals.set).name);
    expect(view.holdsAnything, isTrue);
  });

  test(
      'the open strategy is read when the builder reads it, as the box was, so a delete after the notice reads as gone',
      () async {
    const library = LocalLibrary();
    await library
        .addStrategy(generatedStrategy(Optionals.set).copyWith(id: 'open'));
    final view = LocalLibraryView();
    final image = view.strategyImageChanges('open').value;
    expect(image.current?.id, 'open');
    await library.renameStrategy(library.storedStrategy('open')!, 'renamed');
    expect(image.current?.name, 'renamed');
    expect(view.strategyImageChanges(null).value.current, isNull);
    await library.deleteStrategy('open');
    expect(image.current, isNull);
  });

  test('reading a whole strategy answers without giving up the turn', () async {
    await const LocalLibrary()
        .addStrategy(generatedStrategy(Optionals.set).copyWith(id: 'read'));
    final view = LocalLibraryView();
    final order = <String>[];
    Future<void> reader() async {
      final strategy = await view.readStrategy('read');
      order.add('read ${strategy?.id}');
    }

    scheduleMicrotask(() => order.add('microtask'));
    final reading = reader();
    order.add('after the call');
    await reading;
    expect(order, ['read read', 'after the call', 'microtask']);
    expect(await view.readStrategy('missing'), isNull);
  });
}
