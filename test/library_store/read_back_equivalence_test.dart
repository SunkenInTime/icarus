import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/library_store/canvas_units.dart' show cloneStrategy;
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/strategy_image.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

import '../library_rows/generated_strategies.dart';
import '../library_rows/library_sources.dart';
import 'read_back_in_one_go.dart';

const corpusVariable = 'ICARUS_LIBRARY_CORPUS';

StrategyData _strategy(String id, {List<int> sortIndexes = const [0, 1]}) =>
    generatedStrategy(Optionals.set).copyWith(
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

StrategyData _withoutPictures(StrategyData strategy) => strategy.copyWith(
      pages: [
        for (final page in strategy.pages) page.copyWith(imageData: const []),
      ],
    );

LineUpGraph _linked(String prefix, List<int> order) {
  final graph = sharedSpotLineups(prefix);
  return LineUpGraph(
    origins: graph.origins,
    landings: graph.landings,
    links: [for (final index in order) graph.links[index]],
  );
}

StrategyData _onFirstPage(
  StrategyData strategy,
  void Function(StrategyData strategy) change,
) {
  final changed = cloneStrategy(strategy);
  change(changed);
  return changed;
}

final _shapes = <String, StrategyData Function(StrategyData)>{
  'as generated, pictures included': (s) => s,
  'without pictures': _withoutPictures,
  'lineups grouped by their shared spot': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(lineUpGraph: sharedSpotLineups('${s.id}-l')),
        s.pages[1],
      ]),
  'lineups saved with their spots reordered': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(lineUpGraph: _linked('${s.id}-l', [3, 0, 1, 2])),
        s.pages[1],
      ]),
  'lineups saved interleaved': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(lineUpGraph: _linked('${s.id}-l', [0, 3, 1, 2])),
        s.pages[1],
      ]),
  'two pages at the same position': (s) => s.copyWith(pages: [
        s.pages[0],
        s.pages[1].copyWith(sortIndex: s.pages[0].sortIndex),
      ]),
  'pages saved out of their position order': (s) =>
      s.copyWith(pages: [s.pages[1], s.pages[0]]),
  'a page with nothing on it': (s) => s.copyWith(pages: [
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
  'a lineup whose spot was deleted': (s) {
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
  'pages at positions with gaps between them': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(sortIndex: 0),
        s.pages[1].copyWith(sortIndex: 5),
      ]),
  'the same item id on two pages': (s) => s.copyWith(pages: [
        s.pages[0],
        s.pages[1].copyWith(agentData: [
          s.pages[0].agentData.first,
          ...s.pages[1].agentData.skip(1),
        ]),
      ]),
  'the same item id twice on one page': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(agentData: [
          s.pages[0].agentData.first,
          s.pages[0].agentData.first,
          ...s.pages[0].agentData.skip(1),
        ]),
        s.pages[1],
      ]),
};

StrategyData Function(StrategyData) _atPosition(Offset position) =>
    (s) => _onFirstPage(s, (changed) {
          changed.pages[0].agentData.first.position = position;
        });

StrategyData Function(StrategyData) _captioned(String? caption) =>
    (s) => _onFirstPage(s, (changed) {
          changed.pages[0].agentData.first.caption = caption;
        });

StrategyData Function(StrategyData) _texted(String text) =>
    (s) => _onFirstPage(s, (changed) {
          changed.pages[0].textData.first.text = text;
        });

const _odd = '🔥 👨‍👩‍👧 مرحبا עברית e\u0301 \u202Eabc\u202C';
const _lone = 'a\uD800b';

final _values = <String, StrategyData Function(StrategyData)>{
  'an agent at x = -0.0': _atPosition(const Offset(-0.0, 202.5)),
  'an agent at y = -0.0': _atPosition(const Offset(101.25, -0.0)),
  'an agent at x = NaN': _atPosition(const Offset(double.nan, 202.5)),
  'an agent at x = infinity': _atPosition(const Offset(double.infinity, 10)),
  'an agent at y = -infinity': _atPosition(
    const Offset(10, double.negativeInfinity),
  ),
  'an agent at whole-valued doubles (5.0, 7.0)':
      _atPosition(const Offset(5.0, 7.0)),
  'an agent at a very large double': _atPosition(const Offset(1e300, 2.5)),
  'a page at sortIndex 2^53': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(sortIndex: 9007199254740992),
        s.pages[1],
      ]),
  'a drawing whose colour is 2^53': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(drawingData: [
          for (final drawing in s.pages[0].drawingData)
            drawing is FreeDrawing
                ? drawing.copyWith(colorValue: 9007199254740992)
                : drawing,
        ]),
        s.pages[1],
      ]),
  'a page at sortIndex 2^53 + 1': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(sortIndex: 9007199254740993),
        s.pages[1],
      ]),
  'a page at sortIndex 2^62': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(sortIndex: 4611686018427387904),
        s.pages[1],
      ]),
  'a page at the largest int sortIndex': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(sortIndex: 9223372036854775807),
        s.pages[1],
      ]),
  'a drawing whose colour is the largest int': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(drawingData: [
          for (final drawing in s.pages[0].drawingData)
            drawing is FreeDrawing
                ? drawing.copyWith(colorValue: 9223372036854775807)
                : drawing,
        ]),
        s.pages[1],
      ]),
  'settings with whole-valued doubles (5.0)': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(
          settings: StrategySettings(
            agentSize: 5.0,
            abilitySize: 7.0,
            useNeutralTeamColors: false,
          ),
        ),
        s.pages[1],
      ]),
  'a caption of emoji, RTL, combining marks and bidi controls':
      _captioned(_odd),
  'a caption with a lone surrogate': _captioned(_lone),
  'a text of emoji, RTL, combining marks and bidi controls': _texted(_odd),
  'a text with a lone surrogate': _texted(_lone),
  'an empty caption': _captioned(''),
  'no caption': _captioned(null),
  'a page name of emoji and a lone surrogate': (s) => s.copyWith(pages: [
        s.pages[0].copyWith(name: '$_odd $_lone'),
        s.pages[1],
      ]),
};

String _verdict(ReadBack readBack) => switch (readBack) {
      ReadsBackEqual() => 'equal',
      ReadsBackDifferently(:final words) => 'differently: $words',
    };

var _notCopied = 0;

StrategyData? _firstPageRenamed(StrategyData strategy) {
  if (strategy.pages.isEmpty) return null;
  try {
    return strategy.copyWith(
      pages: [
        strategy.pages.first.copyWith(name: '${strategy.pages.first.name}*'),
        ...strategy.pages.skip(1),
      ],
    );
  } on Object {
    _notCopied += 1;
    return null;
  }
}

Future<List<String>> _differences(String label, StrategyData strategy) async {
  final stepped = StrategyImages();
  final inOneCall = StrategyImages();
  final checks = [
    ('first check', strategy),
    ('the same again, from the cache', strategy),
    if (_firstPageRenamed(strategy) case final renamed?)
      ('after the first page changed', renamed),
  ];
  final differences = <String>[];
  for (final (moment, checked) in checks) {
    final byFingerprint = _verdict(
      readBackInOneGo(checked, pageKey: fingerprintPageKey),
    );
    final byDirect = _verdict(readBackInOneGo(checked));
    if (byFingerprint != byDirect) {
      differences.add('$label, $moment: fingerprint key says '
          '"$byFingerprint", direct key says "$byDirect"');
    }
    final inOneGo = verdictKind(readBackInOneGo(checked));
    final bySteps =
        verdictKind((await stepped.between(checked, () async {})).readBack);
    final byStepsInOneCall = verdictKind(inOneCall.of(checked).readBack);
    if (bySteps != inOneGo || byStepsInOneCall != inOneGo) {
      differences.add('$label, $moment: in one go "$inOneGo", in steps '
          '"$bySteps", in steps in one call "$byStepsInOneCall"');
    }
  }
  return differences;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'the direct page key gives the fingerprint key\'s verdicts, and the '
      'check in steps gives the check in one go\'s, on shapes the real '
      'libraries do not have', () async {
    final differences = <String>[];
    final verdicts = <String, String>{};
    for (final MapEntry(key: name, value: shape) in _shapes.entries) {
      final s = strategyAsHiveHoldsIt(shape(_strategy('shape-$name')));
      verdicts[name] = _verdict(readBackInOneGo(s));
      differences.addAll(await _differences(name, s));
    }
    stdout
        .writeln('KEYS ${_shapes.length} shapes, ${differences.length} differ; '
            '${verdicts.values.where((v) => v == 'equal').length} read back '
            'equal');
    expect(differences, isEmpty);
  });

  test(
      'the direct page key gives the fingerprint key\'s verdicts, and the '
      'check in steps gives the check in one go\'s, on the values tried on '
      '#737', () async {
    final differences = <String>[];
    final verdicts = <String, String>{};
    for (final MapEntry(key: name, value: change) in _values.entries) {
      final s = strategyAsHiveHoldsIt(change(_strategy('value-$name')));
      verdicts[name] = _verdict(readBackInOneGo(s));
      differences.addAll(await _differences(name, s));
    }
    for (final MapEntry(:key, :value) in verdicts.entries) {
      stdout.writeln('KEYS $key: $value');
    }
    stdout.writeln('KEYS ${_values.length} values, ${differences.length} '
        'differ; $_notCopied could not be copied to change a page');
    expect(differences, isEmpty);
  });

  final corpus = Platform.environment[corpusVariable];

  test(
    'the direct page key gives the fingerprint key\'s verdicts, and the '
    'check in steps gives the check in one go\'s, on every strategy in the '
    'corpus',
    skip: corpus == null ? 'set $corpusVariable to a corpus folder' : false,
    () async {
      final differences = <String>[];
      var strategies = 0;
      var equal = 0;
      for (final store in hiveStoresUnder(Directory(corpus!))) {
        for (final strategy in (await loadHiveStore(store)).strategies) {
          final held = strategyAsHiveHoldsIt(strategy);
          strategies += 1;
          if (readBackInOneGo(held) is ReadsBackEqual) equal += 1;
          differences.addAll(
              await _differences('${strategy.id} "${strategy.name}"', held));
        }
      }
      stdout.writeln(
          'KEYS corpus: $strategies strategies, $equal read back equal, '
          '${differences.length} differ');
      expect(strategies, greaterThan(0));
      expect(differences, isEmpty);
    },
  );
}
