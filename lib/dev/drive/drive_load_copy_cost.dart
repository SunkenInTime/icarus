import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';

int _copied(StrategyPage page) =>
    page.agentData.length + page.abilityData.length + page.utilityData.length;

String _ms(int micros) => (micros / 1000).toStringAsFixed(3);

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
  final page = target.pages.reduce((a, b) => _copied(a) >= _copied(b) ? a : b);
  List<int> timed(int times) {
    void copy() {
      for (var round = 0; round < times; round++) {
        [for (final item in page.agentData) item.deepCopy<PlacedAgentNode>()];
        [for (final item in page.abilityData) item.deepCopy<PlacedAbility>()];
        [for (final item in page.utilityData) item.deepCopy<PlacedUtility>()];
      }
    }

    for (var warm = 0; warm < 5; warm++) {
      copy();
    }
    return [
      for (var run = 0; run < runs; run++)
        () {
          final clock = Stopwatch()..start();
          copy();
          return clock.elapsedMicroseconds;
        }(),
    ]..sort();
  }

  String spread(List<int> times) => 'median ${_ms(times[runs ~/ 2])} ms, '
      'fastest ${_ms(times.first)} ms, slowest ${_ms(times.last)} ms';
  return [
    'COPY $pick, its page with the most agents, abilities and utilities '
        '(${page.agentData.length} agents, ${page.abilityData.length} '
        'abilities, ${page.utilityData.length} utilities), copied as a load '
        'copies them, $runs runs: ${spread(timed(1))}',
    'COPY $pick, the same page\'s items ten times over '
        '(${_copied(page) * 10} items), $runs runs: ${spread(timed(10))}',
  ];
}
