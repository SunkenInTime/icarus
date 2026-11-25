import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/canvas_units.dart' show cloneStrategy;
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/hive_reads.dart';
import 'package:icarus/library_store/strategy_image.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

import '../library_rows/generated_strategies.dart';
import 'unit_harness.dart';

StrategyData _strategy(String id) => generatedStrategy(Optionals.set).copyWith(
      id: id,
      pages: [
        for (final index in [0, 1])
          generatedPage(
            id: '$id-p$index',
            sortIndex: index,
            optionals: Optionals.set,
            isAttack: index.isEven,
            itemPrefix: '$id-p$index',
          ).copyWith(lineUpGraph: sharedSpotLineups('$id-p$index-l')),
      ],
    );

String _rowsText(StrategyToRows converted) => switch (converted) {
      StrategyRowsRefused() => 'refused',
      StrategyRowsMade(:final rows) => [
          for (final row in <Row>[
            rows.strategy,
            ...rows.pages,
            ...rows.settings,
            ...rows.elements,
            ...rows.lineupGroups,
          ])
            switch (encodeJson(row.toJsonView())) {
              Encoded(:final text) => text,
              NotEncoded(:final problem) => problem,
            },
        ].join('\n'),
    };

StrategyData _bothPagesEdited(StrategyData strategy) {
  final edited = cloneStrategy(strategy);
  for (final page in edited.pages) {
    page.agentData.first.position += const Offset(40, 0);
  }
  return edited;
}

final _pointReads = <String, int>{};

final class _CountedDrawing extends FreeDrawing {
  _CountedDrawing(String id, List<Offset> points)
      : super(
          id: id,
          listOfPoints: points,
          colorValue: 0xFF336699,
          isDotted: false,
          hasArrow: false,
        );

  @override
  List<Offset> get listOfPoints {
    _pointReads.update(id, (reads) => reads + 1, ifAbsent: () => 1);
    return super.listOfPoints;
  }
}

StrategyData _drawn(String id, int strokes) => _strategy(id).withDrawings([
      for (var stroke = 0; stroke < strokes; stroke++)
        _CountedDrawing('$id-stroke-$stroke', [
          for (var point = 0; point < 200; point++)
            Offset(point * 1.5, stroke * 10.0 + point % 7),
        ]),
    ]);

extension on StrategyData {
  StrategyData withDrawings(List<DrawingElement> drawings) {
    final first = pages[0];
    return copyWith(pages: [
      StrategyPage(
        id: first.id,
        name: first.name,
        isAutoNamed: first.isAutoNamed,
        drawingData: drawings,
        agentData: first.agentData,
        abilityData: first.abilityData,
        textData: first.textData,
        imageData: first.imageData,
        utilityData: first.utilityData,
        sortIndex: first.sortIndex,
        isAttack: first.isAttack,
        settings: first.settings,
        lineUpOrigins: first.lineUpOrigins,
        lineUpLandings: first.lineUpLandings,
        lineUpLinks: first.lineUpLinks,
      ),
      ...pages.skip(1),
    ]);
  }
}

final class _Steps {
  final touched = <Set<String>>[];
  var _readsBefore = <String, int>{};

  void endStep() {
    touched.add({
      for (final MapEntry(:key, :value) in _pointReads.entries)
        if (value != (_readsBefore[key] ?? 0)) key,
    });
    _readsBefore = {..._pointReads};
  }
}

final class _FieldRecorder implements BinaryWriter {
  final fields = <int>[];
  int? count;

  @override
  void writeByte(int byte) {
    if (count == null) {
      count = byte;
    } else {
      fields.add(byte);
    }
  }

  @override
  void write<T>(T value, {bool withTypeId = true}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<String> _keysOf(StrategyData strategy, StrategyPage page) => [
      pagePartKey(strategy.mapData, page),
      for (final item in pageItemsOf(page)) itemKey(strategy.mapData, item),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('with Hive open', () {
    setUp(openUnitHive);
    tearDown(Hive.close);

    test(
        'a Hive write landing at any break between steps leaves the image of '
        'the version the check began with', () async {
      final first = strategyAsHiveHoldsIt(_strategy('written'));
      final second = _bothPagesEdited(first);
      final firstRows = _rowsText(strategyToRows(first));
      expect(_rowsText(strategyToRows(second)), isNot(firstRows));
      final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      var breaks = 0;
      await StrategyImages().between(first, () async => breaks += 1);
      expect(breaks, greaterThan(first.pages.length * 2));

      for (var at = 0; at < breaks; at++) {
        await box.put(first.id, first);
        final held = switch (HiveReads().strategy(first.id)) {
          InHive(value: final strategy) => strategy,
          final other => throw StateError('Hive holds $other'),
        };
        var breath = 0;
        final image = await StrategyImages().between(held, () async {
          if (breath++ == at) await box.put(second.id, second);
        });

        expect(_rowsText(image.rows), firstRows, reason: 'write at break $at');
        expect(image.readBack, isA<ReadsBackEqual>(),
            reason: 'write at break $at');
        final after = switch (HiveReads().strategy(first.id)) {
          InHive(value: final strategy) => strategy,
          final other => throw StateError('Hive holds $other'),
        };
        expect(
          _rowsText(StrategyImages().of(after).rows),
          _rowsText(strategyToRows(strategyAsHiveHoldsIt(second))),
          reason: 'write at break $at',
        );
      }
    });
  });

  test(
      'no step reads more than one drawing\'s points, each drawing\'s points '
      'are serialised twice, once for its row and once for its key, and only '
      'parts not already known equal are read back', () async {
    final readsPerSerialisation = () {
      final probe = _CountedDrawing('probe', const [Offset(1, 2)]);
      _pointReads.clear();
      DrawingProvider.elementToJson(probe);
      return _pointReads['probe']!;
    }();
    final strategy = strategyAsHiveHoldsIt(_drawn('counted', 6));
    final strokes = [
      for (final drawing in strategy.pages[0].drawingData) drawing.id,
    ];
    final parts = [
      for (final page in strategy.pages) 1 + pageItemsOf(page).length,
    ].reduce((a, b) => a + b);
    final images = StrategyImages();
    for (final (moment, readBack) in [
      ('first check', parts),
      ('again, every part from the cache', 0),
    ]) {
      _pointReads.clear();
      final steps = _Steps();
      final image = await images.between(strategy, () async => steps.endStep());
      steps.endStep();

      expect(image.readBack, isA<ReadsBackEqual>(), reason: moment);
      expect(image.partsReadBack, readBack, reason: moment);
      expect(
        [for (final touched in steps.touched) touched.length].reduce(
          (a, b) => a > b ? a : b,
        ),
        1,
        reason: moment,
      );
      expect(
        {
          for (final id in strokes)
            id: _pointReads[id]! ~/ readsPerSerialisation
        },
        {for (final id in strokes) id: 2},
        reason: moment,
      );
      expect(
        {
          for (final id in strokes) id: _pointReads[id]! % readsPerSerialisation
        },
        {for (final id in strokes) id: 0},
        reason: moment,
      );
    }
  });

  test(
      'changing any one field a page saves to Hive, each setting, or one '
      'field of one item in each list, changes what the check compares for '
      'that page', () {
    final strategy = _strategy('fields');
    final page = strategy.pages[0];
    final graph = page.lineUpGraph;
    StrategyPage withFirst(
      StrategyPage Function(StrategyPage copy) change,
    ) =>
        change(page.copyWith());
    StrategyPage settings({
      double? agentSize,
      double? abilitySize,
      bool? useNeutralTeamColors,
    }) =>
        page.copyWith(
          settings: StrategySettings(
            agentSize: agentSize ?? page.settings.agentSize,
            abilitySize: abilitySize ?? page.settings.abilitySize,
            useNeutralTeamColors:
                useNeutralTeamColors ?? page.settings.useNeutralTeamColors,
          ),
        );
    final changes = <int, List<StrategyPage Function()>>{
      0: [() => page.copyWith(id: '${page.id}*')],
      1: [() => page.copyWith(sortIndex: page.sortIndex + 1)],
      2: [() => page.copyWith(name: '${page.name}*')],
      3: [
        () => withFirst((copy) {
              (copy.drawingData.first as FreeDrawing)
                  .listOfPoints
                  .add(const Offset(77, 66));
              return copy;
            }),
      ],
      4: [
        () => withFirst((copy) {
              copy.agentData.first.position += const Offset(1, 0);
              return copy;
            }),
      ],
      5: [
        () => withFirst((copy) {
              copy.abilityData.first.position += const Offset(0, 1);
              return copy;
            }),
      ],
      6: [
        () => withFirst((copy) {
              copy.textData.first.text = '${copy.textData.first.text}*';
              return copy;
            }),
      ],
      7: [
        () => withFirst((copy) {
              copy.imageData.first.caption = 'another caption';
              return copy;
            }),
      ],
      8: [
        () => withFirst((copy) {
              copy.utilityData.first.rotation += 0.5;
              return copy;
            }),
      ],
      9: [() => page.copyWith(isAttack: !page.isAttack)],
      10: [
        () => settings(agentSize: page.settings.agentSize + 1),
        () => settings(abilitySize: page.settings.abilitySize + 1),
        () => settings(
              useNeutralTeamColors: !page.settings.useNeutralTeamColors,
            ),
      ],
      14: [() => page.copyWith(isAutoNamed: !(page.isAutoNamed ?? false))],
      15: [
        () => page.copyWith(
              lineUpGraph: LineUpGraph(origins: [
                ...graph.origins,
                graph.origins.first.copyWith(id: 'another origin'),
              ], landings: graph.landings, links: graph.links),
            ),
      ],
      16: [
        () => page.copyWith(
              lineUpGraph: LineUpGraph(
                  origins: graph.origins,
                  landings: [
                    ...graph.landings,
                    graph.landings.first.copyWith(id: 'another landing'),
                  ],
                  links: graph.links),
            ),
      ],
      17: [
        () => page.copyWith(
              lineUpGraph: LineUpGraph(
                origins: graph.origins,
                landings: graph.landings,
                links: graph.links.skip(1).toList(),
              ),
            ),
      ],
    };
    const projections = {
      11: 'lineUps, rebuilt from the lineup graph whenever a page is built',
      12: 'lineUpGroups, rebuilt from the lineup graph whenever a page is '
          'built',
    };
    final recorder = _FieldRecorder();
    StrategyPageAdapter().write(recorder, page);

    expect(recorder.fields, hasLength(recorder.count!));
    expect(
      {...changes.keys, ...projections.keys},
      recorder.fields.toSet(),
      reason: 'every field the adapter writes needs a change here, or a '
          'reason it cannot change on its own',
    );
    final before = _keysOf(strategy, page);
    for (final MapEntry(key: field, value: each) in changes.entries) {
      for (final (index, change) in each.indexed) {
        expect(_keysOf(strategy, change()), isNot(before),
            reason: 'field $field, change $index');
      }
    }
  });
}
