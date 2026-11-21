import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_rows/round_trip.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:path/path.dart' as path;

import '../desktop_4_6_3_adapters_test_support.dart';
import 'generated_strategies.dart';
import 'library_sources.dart';

String describe(RoundTrip result) => switch (result) {
      RoundTripSame() => 'same',
      RoundTripDiffers(:final differences, :final back) =>
        'differs: ${differences.join(', ')}; '
            'unreadable ${back.unreadable.length}, '
            'not in strategy ${back.notInStrategy.length}',
      RoundTripRefusedToRows(:final refused) =>
        'refused to rows: ${refused.problems.map((p) => p.runtimeType)}',
      RoundTripRefusedFromRows(:final refused) =>
        'refused from rows: ${refused.problems.map((p) => p.runtimeType)}',
    };

List<String> boundingBoxesTheDecoderFills(StrategyData strategy) {
  final pages = [...strategy.pages]
    ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
  return [
    for (final (pageIndex, page) in pages.indexed)
      for (final (index, drawing) in page.drawingData.indexed)
        if (drawing is! FreeDrawing && drawing.boundingBox == null)
          'boundingBoxFilled pages[$pageIndex].drawingData[$index].boundingBox',
  ];
}

void expectSameAfterRoundTrip(StrategyData strategy, {String? reason}) {
  final result = roundTrip(strategy);
  final fills = boundingBoxesTheDecoderFills(strategy);
  switch (result) {
    case RoundTripDiffers(:final differences, :final back)
        when fills.isNotEmpty &&
            back.unreadable.isEmpty &&
            back.notInStrategy.isEmpty:
      expect(differences.map((d) => '$d'), fills, reason: reason);
    case _:
      expect(
        result,
        isA<RoundTripSame>(),
        reason: '$reason: ${describe(result)}',
      );
      expect(fills, isEmpty, reason: reason);
  }
}

StrategyData asTheDrawingDecoderGivesIt(StrategyData strategy) =>
    strategy.copyWith(
      pages: [
        for (final page in strategy.pages)
          StrategyPage(
            id: page.id,
            name: page.name,
            isAutoNamed: page.isAutoNamed,
            drawingData: [
              for (final drawing in page.drawingData)
                DrawingProvider.elementFromJson(
                  jsonDecode(
                    jsonEncode(DrawingProvider.elementToJson(drawing)),
                  ) as Map<String, dynamic>,
                ),
            ],
            agentData: page.agentData,
            abilityData: page.abilityData,
            textData: page.textData,
            imageData: page.imageData,
            utilityData: page.utilityData,
            sortIndex: page.sortIndex,
            isAttack: page.isAttack,
            settings: page.settings,
            lineUpOrigins: page.lineUpOrigins,
            lineUpLandings: page.lineUpLandings,
            lineUpLinks: page.lineUpLinks,
          ),
      ],
    );

StrategyRowsMade rowsOf(StrategyData strategy) =>
    switch (strategyToRows(strategy)) {
      StrategyRowsMade() && final made => made,
      StrategyRowsRefused(:final problems) =>
        throw TestFailure('refused: $problems'),
    };

StrategyDataMade dataOf(StrategyRowSet rows) =>
    switch (strategyFromRows(rows, times)) {
      StrategyDataMade() && final made => made,
      StrategyDataRefused(:final problems) =>
        throw TestFailure('refused: $problems'),
    };

List<RowsProblem> refusalsOf(StrategyData strategy) =>
    switch (strategyToRows(strategy)) {
      StrategyRowsMade() => throw TestFailure('converted'),
      StrategyRowsRefused(:final problems) => problems,
    };

final times = StrategyTimes(
  createdAt: DateTime.utc(2026, 1, 2),
  lastEdited: DateTime.utc(2026, 1, 3),
);

StrategyData strategyWith(List<StrategyPage> pages) => StrategyData(
      id: 'strategy-test',
      name: 'Test',
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.utc(2026, 1, 3),
      createdAt: DateTime.utc(2026, 1, 2),
      folderID: null,
      pages: pages,
    );

StrategyPage pageWith(String id, {LineUpGraph lineups = LineUpGraph.empty}) =>
    generatedPage(
      id: id,
      sortIndex: 0,
      optionals: Optionals.unset,
      isAttack: true,
    ).copyWith(lineUpGraph: lineups);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  test('the .ica fixtures of versions 43, 44 and 97 come back the same',
      () async {
    final files = icaFilesUnder(
      Directory(path.join('test', 'fixtures', 'strategy_integrity')),
    );
    expect(files.map((file) => path.basename(file.path)), [
      'base-test-v43.ica',
      'base-test.ica',
      'canvas-compatibility-v97.ica',
    ]);
    final strategies = await importIcaFiles(files);
    for (final (index, strategy) in strategies.indexed) {
      expect(strategy.pages, isNotEmpty);
      expectSameAfterRoundTrip(
        strategy,
        reason: path.basename(files[index].path),
      );
    }
  });

  test('the pages desktop 4.6.3 saves come back the same', () {
    final current = currentRegistry();
    final desktop463 = desktop463Registry();
    final pages = [
      desktop463RichPage(),
      desktop463RosterPage([
        for (final type in AgentType.values)
          if (type != AgentType.hush) type,
      ]),
    ];
    for (final page in pages) {
      final saved = across(desktop463, current, page);
      expectSameAfterRoundTrip(
        strategyWith([saved]),
        reason: 'page ${page.id}',
      );
    }
  });

  for (final optionals in Optionals.values) {
    test(
        'a strategy with every optional field ${optionals.name} comes back '
        'the same', () {
      expectSameAfterRoundTrip(generatedStrategy(optionals));
    });

    test(
        'with every optional field ${optionals.name}, this build writes '
        'the same Hive bytes back', () {
      final current = currentRegistry();
      final strategy = generatedStrategy(optionals);
      final back = dataOf(rowsOf(strategy).rows).strategy;
      final restamped = back.copyWith(
        createdAt: strategy.createdAt,
        lastEdited: strategy.lastEdited,
      );
      expect(
        writeRecord(current, restamped),
        writeRecord(current, asTheDrawingDecoderGivesIt(strategy)),
      );
    });
  }

  test('the generated strategies hold every item kind and both sides', () {
    final made = rowsOf(generatedStrategy(Optionals.set));
    final kinds = {
      for (final element in made.rows.elements)
        (element as LiveElement).payload.kind,
    };
    expect(kinds, ElementKind.values.toSet());
    expect(
      made.rows.pages.map((page) => (page as ReadablePageRow).isAttack).toSet(),
      {true, false},
    );
    expect(made.summary.lineupCount, 12);
    expect(made.rows.lineupGroups, hasLength(6));
    final versions = {
      for (final element in made.rows.elements)
        (element as LiveElement).payload.payloadVersion,
    };
    expect(versions, {1, 2, 3});
  });

  test('an item repeated on another page keeps its id inside its row', () {
    final strategy = generatedStrategy(Optionals.set);
    final made = rowsOf(strategy);
    final rowIds = made.rows.elements.map((row) => row.publicId).toList();
    expect(rowIds.toSet(), hasLength(rowIds.length));
    final first = made.rows.elementsOn('page-attack').cast<LiveElement>();
    final copy = made.rows.elementsOn('page-defense').cast<LiveElement>();
    expect(
      copy.map((row) => row.payload.data['id']),
      first.map((row) => row.payload.data['id']),
    );
    expect(first.map((row) => row.publicId),
        first.map((row) => row.payload.data['id']));
    expect(
      copy.map((row) => row.publicId).toSet().intersection(
            first.map((row) => row.publicId).toSet(),
          ),
      isEmpty,
    );
    expect(rowsOf(strategy).rows, made.rows);
  });

  test('a duplicated page repeats lineup ids, and its groups take others', () {
    final made = rowsOf(generatedStrategy(Optionals.set));
    final groupIds = made.rows.lineupGroups.map((row) => row.publicId).toList();
    expect(groupIds.toSet(), hasLength(groupIds.length));
    for (final row in made.rows.lineupGroups.cast<ReadableLineupGroupRow>()) {
      expect(row.payload.data['id'], row.publicId);
    }
  });

  test('lineups whose groups interleave come back in group order', () {
    final graph = sharedSpotLineups('page');
    final interleaved = LineUpGraph(
      origins: graph.origins,
      landings: graph.landings,
      links: [graph.links[3], ...graph.links.take(3)],
    );
    final strategy = strategyWith([pageWith('page', lineups: interleaved)]);
    final result = roundTrip(strategy);
    expect(result, isA<RoundTripDiffers>());
    expect(
      (result as RoundTripDiffers).differences.map((d) => '$d'),
      [
        'lineupOrder pages[0].lineUpOrigins',
        'lineupOrder pages[0].lineUpLandings',
      ],
    );
  });

  test('pages saved out of order come back in order of their sort index', () {
    final first = pageWith('page-a').copyWith(sortIndex: 1);
    final second = pageWith('page-b').copyWith(sortIndex: 0);
    final result = roundTrip(strategyWith([first, second]));
    expect(
      (result as RoundTripDiffers).differences.map((d) => '$d'),
      ['pageOrder pages'],
    );
  });

  test('the comparison sees a change to one field anywhere', () {
    final strategy = generatedStrategy(Optionals.set);
    final captioned = generatedStrategy(Optionals.set);
    captioned.pages[1].utilityData.last.caption = 'changed';
    expect(strategyDifferences(strategy, captioned).map((d) => '$d'), [
      'value pages[1].utilityData[${captioned.pages[1].utilityData.length - 1}]'
          '.caption',
    ]);

    final pictureless = generatedStrategy(Optionals.set);
    pictureless.pages[2].lineUpLinks.first.images.removeLast();
    expect(
      strategyDifferences(strategy, pictureless).map((d) => '$d'),
      containsAll([
        'value pages[2].lineUpLinks[0].images.length',
        'value pictureFiles.length',
      ]),
    );

    final renamed = generatedStrategy(Optionals.set).copyWith(name: 'Other');
    expect(
      strategyDifferences(strategy, renamed).map((d) => '$d'),
      ['value name'],
    );
  });

  test('a lineup group never takes the id a later group keeps', () {
    LineUpGraph oneLineup(String linkId, String spot) {
      final graph = sharedSpotLineups(spot);
      return LineUpGraph(
        origins: [graph.origins.first],
        landings: [graph.landings.first],
        links: [
          LineUpLink(
            id: linkId,
            originId: graph.origins.first.id,
            landingId: graph.landings.first.id,
          ),
        ],
      );
    }

    LineUpGraph joined(LineUpGraph a, LineUpGraph b) => LineUpGraph(
          origins: [...a.origins, ...b.origins],
          landings: [...a.landings, ...b.landings],
          links: [...a.links, ...b.links],
        );

    final strategy = strategyWith([
      pageWith('page-1', lineups: oneLineup('L', 'first')),
      pageWith(
        'page-2',
        lineups: joined(
          oneLineup('L', 'second'),
          oneLineup('92cce1d0-6436-520a-9831-717fb7e04f79', 'third'),
        ),
      ).copyWith(sortIndex: 1),
    ]);
    final made = rowsOf(strategy);
    expect(made.summary.lineupCount, 3);
    expect(made.rows.lineupGroups, hasLength(3));
    expectSameAfterRoundTrip(strategy);
  });

  group('what cannot become rows is refused, by name and place', () {
    test('a strategy not yet migrated, or written by a newer build', () {
      final older = generatedStrategy(Optionals.unset)
          .copyWith(versionNumber: Settings.versionNumber - 1);
      final newer = generatedStrategy(Optionals.unset)
          .copyWith(versionNumber: Settings.versionNumber + 1);
      expect(refusalsOf(older).single, isA<NotMigrated>());
      expect(refusalsOf(newer).single, isA<WrittenByNewerBuild>());
    });

    test('content still outside pages', () {
      final strategy = StrategyData(
        id: 'legacy',
        name: 'Legacy',
        mapData: MapValue.bind,
        versionNumber: Settings.versionNumber,
        lastEdited: DateTime.utc(2026),
        folderID: null,
        // ignore: deprecated_member_use_from_same_package
        textData: generatedPage(
          id: 'p',
          sortIndex: 0,
          optionals: Optionals.unset,
          isAttack: true,
        ).textData,
      );
      expect(
        (refusalsOf(strategy).single as ContentOutsidePages).items,
        1,
      );
    });

    test('a theme colour with transparency, which the row cannot hold', () {
      final strategy = generatedStrategy(Optionals.set).copyWith(
        themeOverridePalette: MapThemePalette(
          baseColorValue: 0x80101820,
          detailColorValue: 0xFFF2AA4C,
          highlightColorValue: 0xFFFFFFFF,
        ),
      );
      expect(refusalsOf(strategy).single, isA<PaletteHasTransparency>());
    });

    test('two pages with one id', () {
      final strategy = strategyWith([pageWith('same'), pageWith('same')]);
      expect((refusalsOf(strategy).single as PageIdRepeated).pageId, 'same');
    });

    test('an item whose numbers are not JSON', () {
      final page = pageWith('page');
      page.agentData.first.position = const Offset(double.nan, 1);
      final problem = refusalsOf(strategyWith([page])).single as ItemNotJson;
      expect(
        (problem.pageId, problem.kind, problem.itemId),
        ('page', ElementKind.agent, page.agentData.first.id),
      );
    });

    test('a lineup whose numbers are not JSON', () {
      final graph = sharedSpotLineups('page');
      graph.origins.first.agent.position = const Offset(double.infinity, 100);
      final problem = refusalsOf(strategyWith([
        pageWith('page', lineups: graph),
      ])).single;
      expect((problem as LineupNotJson).pageId, 'page');
    });

    test('a lineup missing an end, a spot nothing aims at, a repeated id', () {
      final graph = sharedSpotLineups('page');
      final broken = LineUpGraph(
        origins: [...graph.origins, graph.origins.first],
        landings: [
          ...graph.landings,
          LineUpLanding(id: 'unaimed', ability: graph.landings.first.ability),
        ],
        links: [
          ...graph.links,
          LineUpLink(id: 'dangling', originId: 'gone', landingId: 'gone'),
        ],
      );
      final problems = refusalsOf(strategyWith([
        pageWith('page', lineups: broken),
      ]));
      expect(
        problems.map(
          (problem) => switch (problem) {
            LineupIdRepeated(:final part, :final id) => 'repeated $part $id',
            LineupMissingEnd(:final linkId) => 'missing end $linkId',
            LineupSpotUnaimed(:final part, :final spotId) =>
              'unaimed $part $spotId',
            _ => '$problem',
          },
        ),
        unorderedEquals([
          'repeated LineupPart.origin page-origin-1',
          'missing end dangling',
          'unaimed LineupPart.landing unaimed',
        ]),
      );
    });
  });

  group('a row this build cannot read', () {
    UnreadableElement unreadableOn(String pageId) => UnreadableElement(
          publicId: 'from-a-newer-build',
          pagePublicId: pageId,
          problem: 'a kind from a newer build',
          reason: const FromNewerBuild(),
          stored: {
            'publicId': 'from-a-newer-build',
            'pagePublicId': pageId,
            'payload': {
              'kind': 'hologram',
              'payloadVersion': 9,
              'data': {'beam': 3},
            },
            'sortIndex': 0,
            'revision': 4,
            'deleted': false,
          },
        );

    test('is carried to the rows and back out, its JSON intact', () {
      final strategy = strategyWith([pageWith('page')]);
      final carried = unreadableOn('page');
      final made = switch (strategyToRows(strategy, carried: [carried])) {
        StrategyRowsMade() && final made => made,
        StrategyRowsRefused() => throw TestFailure('refused'),
      };
      expect(made.rows.element(carried.publicId), carried);
      final back = dataOf(made.rows);
      expect(back.unreadable.single.toJson(), carried.toJson());
      expect(strategyDifferences(strategy, back.strategy), isEmpty);
    });

    test('is refused when its page is not in the strategy', () {
      final problem = switch (strategyToRows(
        strategyWith([pageWith('page')]),
        carried: [unreadableOn('elsewhere')],
      )) {
        StrategyRowsRefused(:final problems) => problems.single,
        StrategyRowsMade() => throw TestFailure('converted'),
      };
      expect(problem, isA<CarriedRowOffPage>());
    });

    for (final (name, kind, data) in [
      (
        'an agent this build has never heard of',
        ElementKind.agent,
        {
          'id': 'future',
          'type': 'futureAgent',
          'position': {'dx': 1, 'dy': 2}
        },
      ),
      (
        'an agent of a kind this build has never heard of',
        ElementKind.agent,
        {
          'id': 'future',
          'kind': 'futureCone',
          'type': 'jett',
          'length': 40,
          'position': {'dx': 1, 'dy': 2},
        },
      ),
      (
        'a drawing of a type this build has never heard of',
        ElementKind.drawing,
        {'id': 'future', 'type': 'futureDrawing', 'colorValue': 1},
      ),
    ]) {
      test('is carried when it is $name', () {
        final made = rowsOf(strategyWith([pageWith('page')]));
        final future = LiveElement(
          publicId: 'future',
          pagePublicId: 'page',
          payload: ElementPayload(kind: kind, payloadVersion: 1, data: data),
          sortIndex: 99,
          revision: 1,
        );
        expect(canReadElementPayload(future.payload, MapValue.ascent), isFalse);
        final back = dataOf(made.rows.withRows([future]));
        expect(back.unreadable.single.toJson(), future.toJson());
      });
    }

    test('is carried when a live row does not decode as its kind', () {
      final made = rowsOf(strategyWith([pageWith('page')]));
      final broken = LiveElement(
        publicId: 'broken',
        pagePublicId: 'page',
        payload: ElementPayload(
          kind: ElementKind.ability,
          payloadVersion: 1,
          data: {
            'id': 'broken',
            'data': {'type': 'jett', 'index': 9},
          },
        ),
        sortIndex: 99,
        revision: 1,
      );
      final back = dataOf(made.rows.withRows([broken]));
      expect(back.unreadable.single.toJson(), broken.toJson());
      expect(
        back.strategy.pages.single.abilityData.map((a) => a.id),
        isNot(contains('broken')),
      );
    });
  });
}
