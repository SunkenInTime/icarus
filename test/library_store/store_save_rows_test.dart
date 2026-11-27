import 'dart:math';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'gated_engine.dart';

const _itemsOnThePage = 75;

StrategyData _strategyOfOnePage() {
  final pages = [
    for (var index = 0; index < 8; index++)
      generatedPage(
        id: 'page-$index',
        sortIndex: index,
        optionals: Optionals.set,
        isAttack: true,
        itemPrefix: 'part-$index',
      ),
  ];
  final kinds = [
    [for (final page in pages) ...page.agentData],
    [for (final page in pages) ...page.abilityData],
    [for (final page in pages) ...page.drawingData],
    [for (final page in pages) ...page.textData],
    [for (final page in pages) ...page.imageData],
    [for (final page in pages) ...page.utilityData],
  ];
  while (kinds.fold(0, (sum, kind) => sum + kind.length) > _itemsOnThePage) {
    kinds.reduce((a, b) => a.length >= b.length ? a : b).removeLast();
  }
  final page = pages.first.copyWith(
    agentData: kinds[0].cast(),
    abilityData: kinds[1].cast(),
    drawingData: kinds[2].cast(),
    textData: kinds[3].cast(),
    imageData: kinds[4].cast(),
    utilityData: kinds[5].cast(),
  );
  return generatedStrategy(Optionals.set).copyWith(pages: [page])
    ..folderID = null;
}

int _items(StrategyPage page) =>
    page.agentData.length +
    page.abilityData.length +
    page.drawingData.length +
    page.textData.length +
    page.imageData.length +
    page.utilityData.length;

StrategyRowSet _rows(StrategyData strategy) =>
    switch (strategyToRows(strategy)) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };

Future<LibraryStore> _open(StorageEngine engine) async =>
    switch (await LibraryStore.open(engine, canRead: appCanRead)) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => fail('$problem'),
    };

void main() {
  late StrategyData strategy;
  late CommitGate gate;
  late MemoryStorage storage;
  late LibraryStore store;

  Future<int> rowsWrittenBySave() async {
    gate.puts.clear();
    expect(
      await store.putStrategy(
        _rows(strategy),
        writtenAt: Settings.versionNumber,
      ),
      isA<Saved<LibraryEdited, LibraryRefusal>>(),
    );
    return gate.puts.where((put) => put.$1 == strategyArea(strategy.id)).length;
  }

  setUp(() async {
    strategy = _strategyOfOnePage();
    expect(_items(strategy.pages.single), _itemsOnThePage);
    gate = CommitGate();
    storage = MemoryStorage();
    store = await _open(GatedEngine(MemoryEngine(storage), gate));
    await rowsWrittenBySave();
  });
  tearDown(() => store.close());

  test('adding one agent to the 75-item page writes its own row and no other',
      () async {
    strategy.pages.single.agentData.add(PlacedAgent(
      id: 'added-agent',
      type: AgentType.jett,
      position: const Offset(400, 400),
      isAlly: true,
    ));

    expect(await rowsWrittenBySave(), 1);
  });

  test('moving one item on the 75-item page writes its own row and no other',
      () async {
    final ability = strategy.pages.single.abilityData[1];
    ability.position = ability.position + const Offset(12, 0);

    expect(await rowsWrittenBySave(), 1);
  });

  test(
      'generated adds, removals and moves, each saved, read back after a '
      'reopen as the page the editor holds', () async {
    final random = Random(775);
    final page = strategy.pages.single;
    final placed = <List<PlacedWidget>>[
      page.agentData,
      page.abilityData,
      page.textData,
      page.imageData,
      page.utilityData,
    ];
    final kinds = <List<Object>>[...placed, page.drawingData];
    for (var step = 0; step < 60; step++) {
      List<T> anyFilled<T>(List<List<T>> lists) {
        final filled = [
          for (final list in lists)
            if (list.isNotEmpty) list,
        ];
        return filled[random.nextInt(filled.length)];
      }

      switch (random.nextInt(3)) {
        case 0:
          page.agentData.insert(
            random.nextInt(page.agentData.length + 1),
            PlacedAgent(
              id: 'generated-$step',
              type: AgentType.sova,
              position: Offset(100.0 + step, 200),
              isAlly: step.isEven,
            ),
          );
        case 1:
          final kind = anyFilled(kinds);
          kind.removeAt(random.nextInt(kind.length));
        case _:
          final kind = anyFilled(placed);
          final item = kind[random.nextInt(kind.length)];
          item.position = item.position + Offset(random.nextDouble() * 40, 3);
      }
      await rowsWrittenBySave();
    }
    await store.close();

    store = await _open(MemoryEngine(storage));
    final read = switch (await readStoredRows(store, strategy.id)) {
      StoredRowsRead(:final rows) => switch (strategyOfRows(rows)) {
          StoredAsData(:final strategy) => strategy,
          final other => fail('$other'),
        },
      StoredRowsNot(:final stored) => fail('$stored'),
    };
    expect(
      strategyDifferences(
        strategy.copyWith(
          createdAt: read.createdAt,
          lastEdited: read.lastEdited,
        ),
        read,
      ),
      isEmpty,
    );
  });
}
