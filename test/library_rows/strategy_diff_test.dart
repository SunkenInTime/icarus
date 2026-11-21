import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/strategy_diff_check.dart';

import 'library_corpus_test.dart' show corpusVariable;
import 'library_sources.dart';

StrategyRowSet rowsOf(StrategyData strategy) =>
    switch (strategyToRows(strategy)) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };

sealed class Step {
  const Step();
}

final class Reached extends Step {
  const Reached(this.rows, this.ops);

  final StrategyRowSet rows;
  final int ops;
}

final class Missed extends Step {
  const Missed(this.what);

  final String what;
}

Step diffAndApply(StrategyRowSet stored, StrategyRowSet target, String editId) {
  switch (diffStrategy(stored, target, editId: editId)) {
    case DiffRefused(:final refusal):
      return Missed('refused: $refusal');
    case DiffOps(:final ops):
      switch (checkDiff(stored, target, ops)) {
        case DiffMissed(:final what):
          return Missed(what);
        case DiffReached(:final rows):
          return switch (diffStrategy(rows, target, editId: '$editId/again')) {
            DiffOps(ops: []) => Reached(rows, ops.length),
            DiffOps(ops: final left) => Missed('${left.length} ops left'),
            DiffRefused(:final refusal) => Missed('then refused: $refusal'),
          };
      }
  }
}

PlacedAbility recon(String id, Offset at) => PlacedAbility(
      id: id,
      data: AgentData.agents[AgentType.sova]!.abilities.first,
      position: at,
    );

StrategyPage editPage(
  StrategyData strategy,
  String pageId,
  StrategyPage Function(StrategyPage page) edit,
) =>
    [
      for (final page in strategy.pages)
        if (page.id == pageId) edit(page),
    ].single;

StrategyData withPage(
  StrategyData strategy,
  String pageId,
  StrategyPage Function(StrategyPage page) edit,
) =>
    strategy.copyWith(
      pages: [
        for (final page in strategy.pages)
          page.id == pageId ? edit(page) : page,
      ],
    );

List<StrategyData> scriptedSession() {
  final note = PlacedText(id: 'note', position: const Offset(40, 50))
    ..text = 'wait for flash'
    ..caption = 'call it';
  final first = StrategyPage(
    id: 'page-1',
    name: 'Page 1',
    isAutoNamed: true,
    sortIndex: 0,
    drawingData: const [],
    agentData: [
      PlacedAgent(
        id: 'jett',
        type: AgentType.jett,
        position: const Offset(1, 2),
      ),
    ],
    abilityData: [recon('recon', const Offset(300, 300))],
    textData: [note],
    imageData: const [],
    utilityData: const [],
    isAttack: true,
    settings: StrategySettings(),
    lineUpOrigins: [
      LineUpOrigin(
        id: 'origin',
        agent: PlacedAgent(
          id: 'origin-agent',
          type: AgentType.sova,
          position: const Offset(600, 400),
        ),
      ),
    ],
    lineUpLandings: [
      LineUpLanding(
        id: 'landing',
        ability: recon('landing-ability', const Offset(700, 200)),
      ),
    ],
    lineUpLinks: [
      LineUpLink(id: 'link', originId: 'origin', landingId: 'landing'),
    ],
  );
  final states = <StrategyData>[
    StrategyData(
      id: 'session',
      name: 'Retake B',
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.utc(2026, 11, 1),
      createdAt: DateTime.utc(2026, 11, 1),
      folderID: null,
      pages: [first],
    ),
  ];
  void step(StrategyData Function(StrategyData strategy) edit) =>
      states.add(edit(states.last));

  step(
    (s) => withPage(s, 'page-1', (page) {
      return page.copyWith(
        agentData: [
          PlacedAgent(
            id: 'jett',
            type: AgentType.jett,
            position: const Offset(220, 140),
          ),
        ],
      );
    }),
  );
  step(
    (s) => s.copyWith(
      pages: [
        ...s.pages,
        editPage(s, 'page-1', (page) {
          return page.copyWith(
            id: 'page-2',
            name: 'Page 2',
            isAutoNamed: true,
            sortIndex: 1,
          );
        }),
      ],
    ),
  );
  step(
    (s) => withPage(s, 'page-2', (page) {
      return page.copyWith(name: 'Execute', isAutoNamed: false);
    }),
  );
  step(
    (s) => withPage(s, 'page-1', (page) {
      return page.copyWith(
        textData: [
          PlacedText(id: 'note', position: const Offset(40, 50))
            ..text = 'wait for flash',
        ],
      );
    }),
  );
  step(
    (s) => withPage(s, 'page-2', (page) {
      return page.copyWith(abilityData: const []);
    }),
  );
  step(
    (s) => s.copyWith(
      pages: [for (final page in s.pages) page.copyWith(isAttack: false)],
    ),
  );
  step(
    (s) => s.copyWith(
      pages: [
        for (final page in s.pages)
          page.copyWith(
            settings: StrategySettings(agentSize: 40, abilitySize: 30),
          ),
      ],
    ),
  );
  step(
    (s) => s.copyWith(
      pages: [
        for (final page in s.pages)
          page.copyWith(
            sortIndex: page.id == 'page-2' ? 0 : 1,
            name: page.isAutoNamed == true ? 'Page 2' : page.name,
          ),
      ],
    ),
  );
  step(
    (s) => withPage(s, 'page-1', (page) {
      return page.copyWith(
        lineUpGraph: LineUpGraph(
          origins: page.lineUpOrigins,
          landings: page.lineUpLandings,
          links: [
            for (final link in page.lineUpLinks)
              link.copyWith(notes: 'jump throw'),
          ],
        ),
      );
    }),
  );
  step(
    (s) => withPage(s, 'page-2', (page) {
      return page.copyWith(
        agentData: [
          ...page.agentData,
          PlacedAgent(
            id: 'omen',
            type: AgentType.omen,
            position: const Offset(500, 500),
          ),
        ],
      );
    }),
  );
  step(
    (s) => s.copyWith(
      pages: [
        for (final page in s.pages)
          if (page.id != 'page-1') page.copyWith(sortIndex: 0),
      ],
    ),
  );
  step(
    (s) => s.copyWith(
      name: 'Retake B fast',
      themeOverridePalette: MapThemePalette(
        baseColorValue: 0xFF101820,
        detailColorValue: 0xFF2A3440,
        highlightColorValue: 0xFFE0A030,
      ),
    ),
  );
  return states;
}

final class Mutator {
  Mutator(this.rows, this.seed);

  final StrategyRowSet rows;
  final int seed;

  ElementPayload _moved(ElementPayload payload) {
    final data = payload.data.toJson();
    if (data['position'] case final Map<String, Object?> at) {
      data['position'] = {...at, 'dx': ((at['dx'] as num?) ?? 0) + 17};
    }
    data.remove('caption');
    return payload.withData(data);
  }

  StrategyRowSet mutated() {
    final pages = rows.pages.whereType<LivePage>().toList()
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final copied = '${pages.first.publicId}-copy-$seed';
    final dropped = pages.length > 1 ? pages.last.publicId : null;
    final elements = <ElementRow>[];
    for (final (index, row) in rows.elements.indexed) {
      if (row case LiveElement(:final pagePublicId, :final payload)) {
        if (pagePublicId == dropped) continue;
        if (index % 5 == 2) continue;
        elements.add(
          index.isEven
              ? row.rewritten(deleted: false, payload: _moved(payload))
              : row,
        );
        if (pagePublicId == pages.first.publicId) {
          elements.add(
            LiveElement(
              publicId: '${row.publicId}-copy-$seed',
              pagePublicId: copied,
              payload: payload.withData({
                ...payload.data.toMap(),
                'id': '${row.publicId}-copy-$seed',
              }),
              sortIndex: row.sortIndex,
              revision: 1,
            ),
          );
        }
      }
    }
    return StrategyRowSet(
      strategy: rows.strategy.rewritten(name: '${rows.strategy.name} (edited)'),
      pages: [
        for (final (index, page) in pages.reversed.indexed)
          if (page.publicId != dropped)
            page.placed(
              name: index == 0 ? 'Renamed $seed' : page.name,
              sortIndex: index,
            ),
        LivePage(
          publicId: copied,
          strategyPublicId: rows.strategy.publicId,
          name: 'Copy',
          isAutoNamed: false,
          sortIndex: pages.length,
          isAttack: !pages.first.isAttack,
          revision: 1,
        ),
      ],
      settings: [
        for (final row in rows.settings)
          if (row.pagePublicId != dropped)
            switch (row) {
              ReadablePageSettings(:final pagePublicId, :final revision) =>
                ReadablePageSettings(
                  pagePublicId: pagePublicId,
                  settings: const PageSettings(
                    agentSize: 33,
                    abilitySize: 31,
                    useNeutralTeamColors: true,
                  ),
                  revision: revision,
                ),
              _ => row,
            },
        ReadablePageSettings(
          pagePublicId: copied,
          settings: const PageSettings(
            agentSize: 30,
            abilitySize: 30,
            useNeutralTeamColors: false,
          ),
          revision: 1,
        ),
      ],
      elements: elements,
      lineupGroups: [
        for (final (index, group) in rows.lineupGroups.indexed)
          if (group.pagePublicId != dropped && index.isEven) group,
      ],
    );
  }
}

Duration fastest(int runs, void Function() run) {
  var best = const Duration(days: 1);
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    run();
    watch.stop();
    if (watch.elapsed < best) best = watch.elapsed;
  }
  return best;
}

StrategyRowSet strategyRowsFor(int items) => StrategyRowSet(
      strategy: ReadableStrategy(
        publicId: 'big',
        name: 'Big',
        mapData: 'ascent',
        revision: 1,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
      pages: [
        LivePage(
          publicId: 'page',
          strategyPublicId: 'big',
          name: 'Page 1',
          sortIndex: 0,
          isAttack: true,
          revision: 1,
        ),
      ],
      settings: [
        ReadablePageSettings(
          pagePublicId: 'page',
          settings: const PageSettings(
            agentSize: 30,
            abilitySize: 30,
            useNeutralTeamColors: false,
          ),
          revision: 1,
        ),
      ],
      elements: [
        for (var i = 0; i < items; i++)
          LiveElement(
            publicId: 'item-$i',
            pagePublicId: 'page',
            payload: ElementPayload(
              kind: i.isEven ? ElementKind.drawing : ElementKind.agent,
              payloadVersion: 1,
              data: {
                'id': 'item-$i',
                'elementType': i.isEven ? 'drawing' : 'agent',
                if (i.isEven)
                  'listOfPoints': [
                    for (var p = 0; p < 1000; p++) {'dx': p * 0.5, 'dy': p},
                  ]
                else
                  'position': {'dx': i, 'dy': i},
              },
            ),
            sortIndex: i,
            revision: 1,
          ),
      ],
    );

StrategyRowSet freshCopy(StrategyRowSet rows) => StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: [
        for (final row in rows.elements)
          if (row case LiveElement(:final payload))
            row.rewritten(
              deleted: false,
              payload: ElementPayload(
                kind: payload.kind,
                payloadVersion: payload.payloadVersion,
                data: payload.data.toJson(),
              ),
            )
          else
            row,
      ],
      lineupGroups: [
        for (final row in rows.lineupGroups)
          if (row case LiveLineupGroup(:final payload))
            LiveLineupGroup(
              publicId: row.publicId,
              strategyPublicId: row.strategyPublicId,
              pagePublicId: row.pagePublicId,
              payload: LineupGroupPayload(
                payloadVersion: payload.payloadVersion,
                data: payload.data.toJson(),
              ),
              sortIndex: row.sortIndex,
              revision: row.revision,
            )
          else
            row,
      ],
    );

StrategyRowSet withOneMoved(StrategyRowSet rows, String id) => StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
      elements: [
        for (final row in rows.elements)
          if (row
              case LiveElement(
                publicId: final rowId,
                :final payload,
              ) when rowId == id)
            row.rewritten(
              deleted: false,
              payload: payload.withData({
                ...payload.data.toMap(),
                'position': {'dx': 999, 'dy': 1},
              }),
            )
          else
            row,
      ],
      lineupGroups: rows.lineupGroups,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  test('every step of an editing session reaches the next', () {
    final states = scriptedSession();
    var stored = rowsOf(states.first);
    final opsPerStep = <int>[];
    for (final (index, state) in states.indexed.skip(1)) {
      switch (diffAndApply(stored, rowsOf(state), 'step-$index')) {
        case Missed(:final what):
          fail('step $index: $what');
        case Reached(:final rows, :final ops):
          opsPerStep.add(ops);
          stored = rows;
      }
    }
    expect(opsPerStep, everyElement(greaterThan(0)));
    expect(
      opsPerStep.length,
      states.length - 1,
      reason: 'every step of the session was diffed',
    );
  });

  test('moving one item on a 300-item page is one op', () {
    final rows = strategyRowsFor(300);
    final shared = withOneMoved(rows, 'item-151');
    final fresh = withOneMoved(freshCopy(rows), 'item-151');
    for (final target in [shared, fresh]) {
      final ops = switch (diffStrategy(rows, target, editId: 'move')) {
        DiffOps(:final ops) => ops,
        DiffRefused(:final refusal) => fail('$refusal'),
      };
      expect(ops.single, isA<ElementPatchOp>());
    }
    final sharedTook = fastest(25, () {
      diffStrategy(rows, shared, editId: 'move');
    });
    final freshTook = fastest(25, () {
      diffStrategy(rows, fresh, editId: 'move');
    });
    stdout.writeln(
      '300-item page, one moved, fastest of 25: '
      '${sharedTook.inMicroseconds} us with unchanged items shared, '
      '${freshTook.inMicroseconds} us with every payload built again',
    );
    expect(sharedTook, lessThan(const Duration(milliseconds: 5)));
    expect(freshTook, lessThan(const Duration(milliseconds: 80)));
  });

  final corpus = Platform.environment[corpusVariable];
  test(
    'every strategy in the corpus is reached from empty and from itself',
    skip: corpus == null ? '$corpusVariable is not set' : false,
    () async {
      var strategies = 0;
      var fromEmptyOps = 0;
      var mutatedOps = 0;
      StrategyRowSet? largest;
      final misses = <String>[];
      final watch = Stopwatch()..start();
      for (final store in hiveStoresUnder(Directory(corpus!))) {
        final library = await loadHiveStore(store);
        for (final strategy in library.strategies) {
          final rows = rowsOf(strategy);
          final ordinal = strategies++;
          final empty = StrategyRowSet(strategy: rows.strategy);
          switch (diffAndApply(empty, rows, 'empty-$ordinal')) {
            case Missed(:final what):
              misses.add('strategy $ordinal from empty: $what');
            case Reached(:final ops):
              fromEmptyOps += ops;
          }
          if (rows.pages.isNotEmpty) {
            final mutated = Mutator(rows, ordinal).mutated();
            switch (diffAndApply(rows, mutated, 'mutated-$ordinal')) {
              case Missed(:final what):
                misses.add('strategy $ordinal mutated: $what');
              case Reached(:final ops):
                mutatedOps += ops;
            }
          }
          if (rows.elements.length > (largest?.elements.length ?? -1)) {
            largest = rows;
          }
        }
      }
      watch.stop();
      final big = largest!;
      final bigId = big.elements.whereType<LiveElement>().first.publicId;
      final bigMoved = withOneMoved(freshCopy(big), bigId);
      final bigTook = fastest(25, () {
        diffStrategy(big, bigMoved, editId: 'move');
      });
      stdout.writeln(
        'strategies: $strategies, ops from empty: $fromEmptyOps, '
        'ops to a mutated copy: $mutatedOps, misses: ${misses.length}, '
        'took ${watch.elapsed.inSeconds} s; largest strategy: '
        '${big.elements.length} elements on ${big.pages.length} pages, one item '
        'moved: fastest of 25 ${bigTook.inMicroseconds} us',
      );
      expect(misses, isEmpty);
      expect(strategies, greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
