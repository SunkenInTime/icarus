import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/action_ops.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/ops_verdict.dart';
import 'package:icarus/library_store/stored_strategy.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart' hide UserAction;

import '../library_rows/generated_strategies.dart';

LineUpGraph _interleaved(LineUpGraph graph) {
  final links = [...graph.links];
  if (links.length < 4) return graph;
  return LineUpGraph(
    origins: graph.origins,
    landings: graph.landings,
    links: [links[0], links[3], links[1], links[2], ...links.skip(4)],
  );
}

StrategyPage _page(String id, int sortIndex, Random random) => generatedPage(
      id: id,
      sortIndex: sortIndex,
      optionals: random.nextBool() ? Optionals.set : Optionals.unset,
      isAttack: random.nextBool(),
      lineups: random.nextBool()
          ? _interleaved(sharedSpotLineups(id))
          : sharedSpotLineups(id),
    ).copyWith();

StrategyData _strategy(int seed, Random random) {
  final pages = [
    for (var n = 0; n < 3; n++) _page('s$seed-p$n', n, random),
  ];
  return generatedStrategy(Optionals.unset).copyWith(
    id: 's$seed',
    pages: [pages[2], pages[0], pages[1]],
  );
}

List<StrategyPage> _inOrder(StrategyData strategy) =>
    [...strategy.pages]..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

List<StrategyPage> _reindexed(List<StrategyPage> pages) => [
      for (final (index, page) in pages.indexed)
        page.copyWith(sortIndex: index),
    ];

List<ActionObjectState> _objectsOf(StrategyPage page) => [
      for (final agent in page.agentData) ActionObjectState.agent(agent),
      for (final ability in page.abilityData)
        ActionObjectState.ability(ability),
      for (final drawing in page.drawingData)
        ActionObjectState.drawing(drawing),
      for (final text in page.textData) ActionObjectState.text(text),
      for (final image in page.imageData) ActionObjectState.image(image),
      for (final utility in page.utilityData)
        ActionObjectState.utility(utility),
    ];

ActionObjectState _withId(ActionObjectState object, String id) =>
    ActionObjectState.fromJson(object.kind, {...object.toJson(), 'id': id});

ActionObjectState _moved(ActionObjectState object) {
  final json = object.toJson();
  if (json['position'] case final Map<String, dynamic> position) {
    json['position'] = {
      ...position,
      'dx': ((position['dx'] as num?) ?? 0) + 7,
    };
  } else if (json['color'] case final int color) {
    json['color'] = color ^ 0x00FF00;
  } else if (json['text'] case final String text) {
    json['text'] = '$text!';
  } else {
    json['isDotted'] = !(json['isDotted'] as bool? ?? false);
  }
  return ActionObjectState.fromJson(object.kind, json);
}

StrategyPage _withObjects(StrategyPage page, List<ActionObjectState> objects) =>
    page.copyWith(
      agentData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.agent) o.agent!,
      ],
      abilityData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.ability) o.ability!,
      ],
      drawingData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.drawing) o.drawing!,
      ],
      textData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.text) o.text!,
      ],
      imageData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.image) o.image!,
      ],
      utilityData: [
        for (final o in objects)
          if (o.kind == ActionObjectKind.utility) o.utility!,
      ],
    );

LineUpGraph _withoutLink(LineUpGraph graph, LineUpLink gone) {
  final links = [
    for (final link in graph.links)
      if (link.id != gone.id) link,
  ];
  return LineUpGraph(
    origins: [
      for (final origin in graph.origins)
        if (links.any((link) => link.originId == origin.id)) origin,
    ],
    landings: [
      for (final landing in graph.landings)
        if (links.any((link) => link.landingId == landing.id)) landing,
    ],
    links: links,
  );
}

LineUpGraph _withNewLineup(LineUpGraph graph, String prefix, Random random) {
  final fresh = sharedSpotLineups(prefix);
  final link = fresh.links.first;
  final shareOrigin = graph.origins.isNotEmpty && random.nextBool();
  final originId = shareOrigin
      ? graph.origins[random.nextInt(graph.origins.length)].id
      : link.originId;
  return LineUpGraph(
    origins: [
      ...graph.origins,
      if (!shareOrigin)
        fresh.origins.firstWhere((origin) => origin.id == link.originId),
    ],
    landings: [
      ...graph.landings,
      fresh.landings.firstWhere((landing) => landing.id == link.landingId),
    ],
    links: [
      ...graph.links,
      LineUpLink(
        id: link.id,
        originId: originId,
        landingId: link.landingId,
        name: link.name,
        notes: link.notes,
      ),
    ],
  );
}

LineUpGraph _withNotes(LineUpGraph graph, LineUpLink edited, String notes) =>
    LineUpGraph(
      origins: graph.origins,
      landings: graph.landings,
      links: [
        for (final link in graph.links)
          if (link.id == edited.id)
            LineUpLink(
              id: link.id,
              originId: link.originId,
              landingId: link.landingId,
              name: link.name,
              youtubeLink: link.youtubeLink,
              notes: notes,
              images: link.images,
            )
          else
            link,
      ],
    );

final class _Step {
  _Step(this.after, this.change, this.what);

  final StrategyData after;
  final CanvasChange change;
  final String what;
}

_Step? _step(StrategyData strategy, Random random, int step) {
  final pages = _inOrder(strategy);
  final page = pages[random.nextInt(pages.length)];
  StrategyData withPage(StrategyPage changed) => strategy.copyWith(
        pages: [
          for (final p in strategy.pages) p.id == changed.id ? changed : p,
        ],
      );
  final objects = _objectsOf(page);
  switch (random.nextInt(13)) {
    case 0 || 1:
      final template = _objectsOf(_page('x', 0, random));
      final added = _withId(
        template[random.nextInt(template.length)],
        '${strategy.id}-added-$step',
      );
      return _Step(
        withPage(_withObjects(page, [...objects, added])),
        ObjectAdded(page.id, added),
        'add ${added.kind.name}',
      );
    case 2 when objects.isNotEmpty:
      final gone = objects[random.nextInt(objects.length)];
      return _Step(
        withPage(_withObjects(page, [
          for (final o in objects)
            if (o.id != gone.id) o,
        ])),
        ObjectRemoved(page.id, gone),
        'remove ${gone.kind.name}',
      );
    case 3 || 4 when objects.isNotEmpty:
      final before = objects[random.nextInt(objects.length)];
      final after = _moved(before);
      return _Step(
        withPage(_withObjects(page, [
          for (final o in objects) o.id == before.id ? after : o,
        ])),
        ObjectChanged(page.id, before, after),
        'change ${before.kind.name}',
      );
    case 5:
      final before = page.lineUpGraph;
      final after = before.links.isNotEmpty && random.nextBool()
          ? _withoutLink(
              before, before.links[random.nextInt(before.links.length)])
          : _withNewLineup(before, '${strategy.id}-l$step', random);
      return _Step(
        withPage(page.copyWith(lineUpGraph: after)),
        LineupsChanged(
          page.id,
          before,
          after,
          touching: {
            for (final (from, to) in [(before, after), (after, before)])
              for (final link in from.links)
                if (!to.links.any((kept) => kept.id == link.id)) ...[
                  link.id,
                  link.originId,
                  link.landingId,
                ],
          },
        ),
        'lineups',
      );
    case 6 when page.lineUpLinks.isNotEmpty:
      final link = page.lineUpLinks[random.nextInt(page.lineUpLinks.length)];
      final graph = _withNotes(page.lineUpGraph, link, 'notes $step');
      return _Step(
        withPage(page.copyWith(lineUpGraph: graph)),
        LineupPartChanged(page.id, link.id, graph),
        'lineup notes',
      );
    case 7:
      final settings = StrategySettings(
        agentSize: 20.0 + random.nextInt(20),
        abilitySize: 10.0 + random.nextInt(20),
        useNeutralTeamColors: random.nextBool(),
      );
      return _Step(
        withPage(page.copyWith(settings: settings)),
        PageSettingsChanged(page.id, settings),
        'settings',
      );
    case 8:
      final index = random.nextInt(pages.length + 1);
      final added = _page('${strategy.id}-page$step', index, random);
      return _Step(
        strategy.copyWith(
          pages: _reindexed([...pages]..insert(index, added)),
        ),
        PageAdded(added, index: index),
        'page add',
      );
    case 9 when pages.length > 1:
      return _Step(
        strategy.copyWith(
          pages: _reindexed([
            for (final p in pages)
              if (p.id != page.id) p,
          ]),
        ),
        PageRemoved(page.id),
        'page remove',
      );
    case 10:
      final index = random.nextInt(pages.length);
      final ordered = [
        for (final p in pages)
          if (p.id != page.id) p,
      ]..insert(index, page);
      return _Step(
        strategy.copyWith(pages: _reindexed(ordered)),
        PageMoved(page.id, index),
        'page move',
      );
    case 11:
      final isAttack = !page.isAttack;
      return _Step(
        withPage(page.copyWith(isAttack: isAttack)),
        PageSideSet(page.id, isAttack: isAttack),
        'page side',
      );
    case 12:
      final name = 'Retake $step';
      return _Step(
        withPage(page.copyWith(name: name, isAutoNamed: false)),
        PageRenamed(page.id, name, isAutoNamed: false),
        'page rename',
      );
  }
  return null;
}

StrategyData _readable(StrategyData strategy) =>
    switch (strategyToRows(strategyAsHiveHoldsIt(strategy))) {
      StrategyRowsMade(:final rows) => switch (strategyFromRows(rows)) {
          StrategyDataMade(:final strategy) => strategy,
          StrategyDataRefused(:final problems) => fail('$problems'),
        },
      StrategyRowsRefused(:final problems) => fail('$problems'),
    };

Future<StrategyData> _readBack(LibraryStore store, String id) async {
  switch (await readStoredRows(store, id)) {
    case StoredRowsRead(:final rows):
      return switch (strategyFromRows(rows)) {
        StrategyDataMade(:final strategy) => strategy,
        StrategyDataRefused(:final problems) => fail('$problems'),
      };
    case StoredRowsNot(:final stored):
      fail('$stored');
  }
}

Future<LibraryStore> _storeWith(StrategyData strategy) async {
  final store = switch (await LibraryStore.open(
    MemoryEngine(MemoryStorage()),
    canRead: appCanRead,
  )) {
    StoreOpened(:final store) => store,
    StoreNotOpened(:final problem) => fail('$problem'),
  };
  final rows = switch (strategyToRows(strategyAsHiveHoldsIt(strategy))) {
    StrategyRowsMade(:final rows) => rows,
    StrategyRowsRefused(:final problems) => fail('$problems'),
  };
  final put = await store.putStrategy(rows);
  expect(put, isA<Saved<LibraryEdited, Object>>(),
      reason: switch (put) {
        Refused(:final reason) => "$reason",
        _ => "$put"
      });
  return store;
}

LineUpGraph _without(LineUpGraph graph, Set<String> linkIds) =>
    linkIds.fold(graph, (left, id) {
      final link = left.links.where((link) => link.id == id).firstOrNull;
      return link == null ? left : _withoutLink(left, link);
    });

LineUpGraph _part(LineUpGraph graph, String linkId) {
  final link = graph.links.singleWhere((link) => link.id == linkId);
  return LineUpGraph(
    origins: [graph.origins.singleWhere((o) => o.id == link.originId)],
    landings: [graph.landings.singleWhere((l) => l.id == link.landingId)],
    links: [link],
  );
}

LineUpGraphAction _lineupAdded(LineUpGraph graph, String linkId) =>
    LineUpGraphAction(
      type: ActionType.addition,
      id: linkId,
      after: _part(graph, linkId),
    );

LineUpGraphAction _lineupDeleted(LineUpGraph graph, String linkId) =>
    LineUpGraphAction(
      type: ActionType.deletion,
      id: linkId,
      before: _part(graph, linkId),
    );

void main() {
  test(
      'before rows plus the ops built for each change, read back, equal the after state, for every kind of object, lineups sharing spots in interleaved order, and a page list out of sort order',
      () async {
    final counts = <String, int>{};
    for (var seed = 0; seed < 60; seed++) {
      final random = Random(seed);
      var strategy = _strategy(seed, random);
      final store = await _storeWith(strategy);
      for (var step = 0; step < 40; step++) {
        final next = _step(strategy, random, step);
        if (next == null) continue;
        final builder = (await OpsBuilder.read(store, strategy.id))!;
        final built = await builder.build([next.change]);
        expect(built.gaps, isEmpty,
            reason: 'seed $seed step $step ${next.what}');
        if (built.ops.isNotEmpty) {
          final result = await store.commitAll(strategy.id, built.ops);
          expect(
            result,
            anyOf(
              isA<Saved<List<Committed>, CommitRefusal>>(),
              isA<NothingToSave<List<Committed>, CommitRefusal>>(),
            ),
            reason: 'seed $seed step $step ${next.what}: ${switch (result) {
              Refused(:final reason) => '$reason',
              _ => '$result'
            }}',
          );
        }
        strategy = next.after;
        expect(
          readBackDifferences(
            _readable(strategy),
            await _readBack(store, strategy.id),
          ),
          isEmpty,
          reason: 'seed $seed step $step ${next.what}',
        );
        counts.update(next.what, (n) => n + 1, ifAbsent: () => 1);
      }
      await store.close();
    }
    for (final kind in ActionObjectKind.values) {
      if (kind == ActionObjectKind.lineUp) continue;
      expect(counts['add ${kind.name}'], greaterThan(5), reason: kind.name);
      expect(counts['change ${kind.name}'], greaterThan(5), reason: kind.name);
    }
    for (final what in [
      'lineups',
      'lineup notes',
      'settings',
      'page add',
      'page remove',
      'page move',
      'page side',
      'page rename',
    ]) {
      expect(counts[what], greaterThan(5), reason: what);
    }
  });

  test(
      'a lineup action holds only the lineup it added or removed; with the page graph on screen it builds the ops that leave the store equal to the page, for an add at a shared spot, its undo and redo, a delete, and a transaction of two deletes and its undo',
      () async {
    final whole = sharedSpotLineups('pl');
    final pageId = 'lineup-page';
    final page = generatedPage(
      id: pageId,
      sortIndex: 0,
      optionals: Optionals.unset,
      isAttack: true,
      lineups: _without(whole, {'pl-link-b'}),
    ).copyWith();
    var strategy = generatedStrategy(Optionals.unset).copyWith(
      id: 'lineups',
      pages: [page],
    );
    final store = await _storeWith(strategy);
    final shapes = <String>[];

    Future<void> act(
      String what,
      UserAction action, {
      required LineUpGraph now,
      bool reversed = false,
    }) async {
      final builder = (await OpsBuilder.read(store, strategy.id))!;
      final built = await builder.build(canvasChangesOf(
        action,
        pageId: pageId,
        reversed: reversed,
        now: EditorNow(lineups: now, agent: (_) => null),
      ));
      expect(built.gaps, isEmpty, reason: what);
      final result = await store.commitAll(strategy.id, built.ops);
      expect(result, isA<Saved<List<Committed>, CommitRefusal>>(),
          reason: '$what: $result');
      shapes.addAll([
        for (final shape in built.lineupShapes)
          '$what ${shape is LineupsInsideGroups ? 'inside' : 'groups'}',
      ]);
      strategy = strategy.copyWith(pages: [
        strategy.pages.single.copyWith(lineUpGraph: now),
      ]);
      expect(
        readBackDifferences(
          _readable(strategy),
          await _readBack(store, strategy.id),
        ),
        isEmpty,
        reason: what,
      );
    }

    final added = _lineupAdded(whole, 'pl-link-b');
    await act('add at a shared spot', added, now: whole);
    await act('undo the add', added,
        now: _without(whole, {'pl-link-b'}), reversed: true);
    await act('redo the add', added, now: whole);
    final withoutD = _without(whole, {'pl-link-d'});
    await act('delete', _lineupDeleted(whole, 'pl-link-d'), now: withoutD);
    final both = UserAction(
      type: ActionType.transaction,
      id: 'both',
      group: ActionGroup.bulk,
      changes: [
        _lineupDeleted(withoutD, 'pl-link-a'),
        _lineupDeleted(withoutD, 'pl-link-c'),
      ],
    );
    await act('two deletes', both,
        now: _without(withoutD, {'pl-link-a', 'pl-link-c'}));
    await act('undo two deletes', both, now: withoutD, reversed: true);
    expect(shapes, [
      'add at a shared spot groups',
      'undo the add groups',
      'redo the add groups',
      'delete groups',
      'two deletes groups',
      'two deletes inside',
      'undo two deletes inside',
      'undo two deletes groups',
    ]);
    await store.close();
  });
}
