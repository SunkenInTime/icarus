import 'dart:ui';

import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/local_library.dart';

typedef _Copied = ({
  List<PlacedAgentNode> agents,
  List<PlacedAbility> abilities,
  List<PlacedUtility> utilities,
});

int _copied(StrategyPage page) =>
    page.agentData.length + page.abilityData.length + page.utilityData.length;

int _wallPoints(Iterable<PlacedAbility> abilities) =>
    abilities.fold(0, (sum, ability) => sum + (ability.wallPath?.length ?? 0));

String _ms(int micros) => (micros / 1000).toStringAsFixed(3);

_Copied _copy(
  List<PlacedAgentNode> agents,
  List<PlacedAbility> abilities,
  List<PlacedUtility> utilities,
) =>
    (
      agents: [for (final item in agents) item.deepCopy<PlacedAgentNode>()],
      abilities: [for (final item in abilities) item.deepCopy<PlacedAbility>()],
      utilities: [for (final item in utilities) item.deepCopy<PlacedUtility>()],
    );

String _timed(
  String label,
  int runs,
  List<PlacedAgentNode> agents,
  List<PlacedAbility> abilities,
  List<PlacedUtility> utilities,
) {
  final kept = <_Copied>[];
  for (var warm = 0; warm < 5; warm++) {
    kept.add(_copy(agents, abilities, utilities));
  }
  final times = [
    for (var run = 0; run < runs; run++)
      () {
        final clock = Stopwatch()..start();
        kept.add(_copy(agents, abilities, utilities));
        return clock.elapsedMicroseconds;
      }(),
  ]..sort();
  final last = kept.last;
  return 'COPY $label (${agents.length} agents, ${abilities.length} '
      'abilities with ${_wallPoints(abilities)} wall points, '
      '${utilities.length} utilities), $runs runs: median '
      '${_ms(times[runs ~/ 2])} ms, fastest ${_ms(times.first)} ms, slowest '
      '${_ms(times.last)} ms; ${kept.length} copies kept, the last holding '
      '${last.agents.length + last.abilities.length + last.utilities.length} '
      'items and ${_wallPoints(last.abilities)} wall points';
}

Future<List<String>> loadCopyCost(String pick, int runs) async {
  final strategies = [...const LocalLibrary().storedStrategies]..sort(
      (a, b) => a.pages
          .fold(0, (sum, page) => sum + _copied(page))
          .compareTo(b.pages.fold(0, (sum, page) => sum + _copied(page))),
    );
  if (strategies.isEmpty) throw StateError('no strategy to measure');
  final target = switch (pick) {
    'largest' => strategies.last,
    _ => strategies.firstWhere((strategy) => strategy.name == pick),
  };
  if (target.pages.isEmpty) throw StateError('$pick has no pages');
  final busiest =
      target.pages.reduce((a, b) => _copied(a) >= _copied(b) ? a : b);
  final walled = [
    for (final strategy in strategies) ...strategy.pages,
  ].reduce((a, b) =>
      _wallPoints(a.abilityData) >= _wallPoints(b.abilityData) ? a : b);
  final highTide = AgentData.agents[AgentType.harbor]!.abilities[1];
  final synthetic = [
    for (var wall = 0; wall < 100; wall++)
      PlacedAbility(
        id: 'synthetic-wall-$wall',
        data: highTide,
        position: Offset(wall * 7.25, wall * 3.5),
        wallPath: [
          for (var point = 0; point < 50; point++)
            Offset(point * 4.125, (point % 7) * 2.5),
        ],
      ),
  ];
  return [
    _timed('$pick, its page with the most agents, abilities and utilities',
        runs, busiest.agentData, busiest.abilityData, busiest.utilityData),
    _timed('the library page with the most wall points', runs, walled.agentData,
        walled.abilityData, walled.utilityData),
    _timed('a made-up page of 100 High Tides with 50-point walls', runs,
        const [], synthetic, const []),
  ];
}
