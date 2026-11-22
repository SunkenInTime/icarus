import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:flutter/foundation.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'tile_parity.dart';

final _agentPool = [
  AgentType.jett,
  AgentType.sova,
  AgentType.omen,
  AgentType.killjoy,
  AgentType.breach,
  AgentType.viper,
];

PlacedAbility _ability(String id, double x) => PlacedAbility(
      id: id,
      data: AgentData.agents[AgentType.sova]!.abilities.first,
      position: Offset(x, 300),
    );

LineUpGraph _lineups(Random random, String prefix) {
  final count = random.nextInt(4);
  return LineUpGraph(
    origins: [
      for (var n = 0; n < count; n++)
        LineUpOrigin(
          id: '$prefix-origin-$n',
          agent: PlacedAgent(
            id: '$prefix-origin-$n-agent',
            type: _agentPool[random.nextInt(_agentPool.length)],
            position: Offset(100.0 + n, 200),
          ),
        ),
    ],
    landings: [
      for (var n = 0; n < count; n++)
        LineUpLanding(
          id: '$prefix-landing-$n',
          ability: _ability('$prefix-landing-$n-ability', 300.0 + n),
        ),
    ],
    links: [
      for (var n = 0; n < count; n++)
        LineUpLink(
          id: '$prefix-link-$n',
          originId: '$prefix-origin-$n',
          landingId: '$prefix-landing-$n',
        ),
      if (count > 1)
        LineUpLink(
          id: '$prefix-link-across',
          originId: '$prefix-origin-${random.nextInt(count)}',
          landingId: '$prefix-landing-${random.nextInt(count)}',
        ),
    ],
  );
}

StrategyPage _page(Random random, String strategyId, int index) {
  final id = '$strategyId-page-$index';
  final lineups = _lineups(random, id);
  return StrategyPage(
    id: id,
    name: 'Page ${index + 1}',
    isAutoNamed: true,
    sortIndex: index,
    drawingData: const [],
    agentData: [
      for (var n = 0; n < random.nextInt(5); n++)
        PlacedAgent(
          id: '$id-agent-$n',
          type: _agentPool[random.nextInt(_agentPool.length)],
          position: Offset(10.0 * n, 20),
        ),
    ],
    abilityData: const [],
    textData: const [],
    imageData: const [],
    utilityData: const [],
    isAttack: random.nextBool(),
    settings: StrategySettings(),
    lineUpOrigins: lineups.origins,
    lineUpLandings: lineups.landings,
    lineUpLinks: lineups.links,
  );
}

StrategyData randomStrategy(int seed) {
  final random = Random(seed);
  final id = 'random-$seed';
  return StrategyData(
    id: id,
    name: 'Random $seed',
    mapData: MapValue.values[random.nextInt(MapValue.values.length)],
    versionNumber: Settings.versionNumber,
    lastEdited: DateTime.utc(2026, 1, 1).add(Duration(minutes: seed)),
    createdAt: DateTime.utc(2025, 1, 1).add(Duration(minutes: seed)),
    folderID: null,
    pages: [for (var n = 0; n < random.nextInt(5); n++) _page(random, id, n)],
  );
}

StrategyData edited(StrategyData strategy, int seed) {
  final random = Random(seed);
  final pages = [...strategy.pages];
  switch (random.nextInt(6)) {
    case 0 when pages.isNotEmpty:
      final at = random.nextInt(pages.length);
      pages[at] = pages[at].copyWith(
        agentData: [...pages[at].agentData.skip(1)],
      );
    case 1:
      pages.add(_page(random, '${strategy.id}-more-$seed', pages.length));
    case 2 when pages.isNotEmpty:
      final at = random.nextInt(pages.length);
      pages[at] = pages[at].copyWith(isAttack: !pages[at].isAttack);
    case 4 when pages.length > 1:
      pages.add(pages.removeAt(0));
    case 5 when pages.length > 1:
      pages[1] = pages[1].copyWith(sortIndex: pages[0].sortIndex);
    case _ when pages.length > 1:
      pages.removeAt(0);
      for (final (index, page) in pages.indexed) {
        pages[index] = page.copyWith(sortIndex: index);
      }
    case _:
      break;
  }
  return strategy.copyWith(pages: pages);
}

Future<LibraryStore> _store() async => switch (await LibraryStore.open(
      MemoryEngine(MemoryStorage()),
      canRead: appCanRead,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => fail('$problem'),
    };

Future<StrategySummary> _putAndList(
  LibraryStore store,
  StrategyData strategy,
) async {
  final rows = switch (strategyToRows(strategyAsHiveHoldsIt(strategy))) {
    StrategyRowsMade(:final rows) => rows,
    StrategyRowsRefused(:final problems) => fail('$problems'),
  };
  switch (await store.putStrategy(rows)) {
    case Saved() || NothingToSave():
      break;
    case Refused(:final reason):
      fail('${strategy.id}: $reason');
    case final other:
      fail('$other');
  }
  return switch (store.library) {
    LibraryOpen(:final list) =>
      list.strategies.singleWhere((s) => s.publicId == strategy.id),
    LibraryShut(:final failure) => fail('$failure'),
  };
}

void main() {
  test(
      'the store summary shows what main\'s tile shows, for generated strategies and after each edit',
      () async {
    final strategies = [
      generatedStrategy(Optionals.set),
      generatedStrategy(Optionals.unset),
      for (var seed = 0; seed < 150; seed++) randomStrategy(seed),
    ];
    final store = await _store();
    expect(
      await store.editLibrary([
        PutFolder(
          folderToRow(
            Folder(
                name: 'Retakes', id: 'folder-1', dateCreated: DateTime(2025)),
          ),
        ),
      ]),
      isA<Saved<LibraryEdited, LibraryRefusal>>(),
    );
    final differing = <String>[];
    var groupOrderOnly = 0;
    var pageOrderOnly = 0;
    var compared = 0;
    for (final strategy in strategies) {
      var current = strategy;
      for (var step = 0; step < 4; step++) {
        compared++;
        switch (tileParity(await _putAndList(store, current), current)) {
          case TileSame():
            break;
          case TileInGroupOrder():
            groupOrderOnly++;
          case TileInPageOrder():
            pageOrderOnly++;
          case final TileDiffers differs:
            differing.add('${current.id} step $step: $differs');
        }
        current = edited(current, step * 7919 + current.pages.length);
      }
    }
    await store.close();
    debugPrint('$compared summaries compared; $groupOrderOnly differ only '
        'because their lineup origins are not in group order, '
        '$pageOrderOnly only because their saved page list is out of sort '
        'order or has two pages at one sort index');
    expect(differing, isEmpty, reason: differing.take(3).join('\n'));
  });

  test(
      'with agents and lineup groups at shared places, the summary shows the order the store reads the page in',
      () async {
    final store = await _store();
    final differing = <String>[];
    var tied = 0;
    for (var seed = 0; seed < 150; seed++) {
      final random = Random(seed);
      final rows = switch (strategyToRows(
        strategyAsHiveHoldsIt(randomStrategy(seed)),
      )) {
        StrategyRowsMade(:final rows) => rows,
        StrategyRowsRefused(:final problems) => fail('$problems'),
      };
      final elements = [...rows.elements];
      final groups = [...rows.lineupGroups];
      if (elements.length > 1) {
        final from = random.nextInt(elements.length);
        final to = random.nextInt(elements.length);
        if (elements[from] case final LiveElement moved
            when elements[to].pagePublicId == moved.pagePublicId) {
          elements[from] = LiveElement(
            publicId: moved.publicId,
            pagePublicId: moved.pagePublicId,
            payload: moved.payload,
            sortIndex: (elements[to] as LiveElement).sortIndex,
            revision: moved.revision,
          );
          tied++;
        }
      }
      if (groups.length > 1) {
        final from = random.nextInt(groups.length);
        final to = random.nextInt(groups.length);
        if (groups[from] case final LiveLineupGroup moved
            when groups[to].pagePublicId == moved.pagePublicId) {
          groups[from] = LiveLineupGroup(
            strategyPublicId: moved.strategyPublicId,
            publicId: moved.publicId,
            pagePublicId: moved.pagePublicId,
            payload: moved.payload,
            sortIndex: (groups[to] as LiveLineupGroup).sortIndex,
            revision: moved.revision,
          );
          tied++;
        }
      }
      final perturbed = StrategyRowSet(
        strategy: rows.strategy,
        pages: rows.pages,
        settings: rows.settings,
        elements: elements,
        lineupGroups: groups,
      );
      final readBack = switch (strategyFromRows(perturbed)) {
        StrategyDataMade(:final strategy) => strategy,
        StrategyDataRefused(:final problems) => fail('$problems'),
      };
      switch (await store.putStrategy(perturbed)) {
        case Saved() || NothingToSave():
          break;
        case final other:
          fail('$other');
      }
      final summary = switch (store.library) {
        LibraryOpen(:final list) =>
          list.strategies.singleWhere((s) => s.publicId == readBack.id),
        LibraryShut(:final failure) => fail('$failure'),
      };
      if (tileParity(summary, readBack) case final TileDiffers differs) {
        differing.add('seed $seed: $differs');
      }
    }
    await store.close();
    debugPrint('150 strategies read back from rows with $tied rows moved to '
        'a place another row holds');
    expect(tied, greaterThan(50));
    expect(differing, isEmpty, reason: differing.take(3).join('\n'));
  });
}
