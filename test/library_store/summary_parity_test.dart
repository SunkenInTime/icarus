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
  switch (random.nextInt(4)) {
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
          case final TileDiffers differs:
            differing.add('${current.id} step $step: $differs');
        }
        current = edited(current, step * 7919 + current.pages.length);
      }
    }
    await store.close();
    debugPrint('$compared summaries compared; $groupOrderOnly differ only '
        'because their lineup origins are not in group order');
    expect(differing, isEmpty, reason: differing.take(3).join('\n'));
  });
}
