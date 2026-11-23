import 'dart:convert';
import 'dart:ui';

import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/canvas_changes.dart';
import 'package:icarus/library_store/hive_library.dart';
import 'package:icarus/library_store/ops_verdict.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

StrategySettings cloneSettings(StrategySettings settings) => StrategySettings(
      agentSize: settings.agentSize,
      abilitySize: settings.abilitySize,
      useNeutralTeamColors: settings.useNeutralTeamColors,
    );

StrategyPage pageOf({
  required String id,
  required String name,
  required bool? isAutoNamed,
  required int sortIndex,
  required bool isAttack,
  required StrategySettings settings,
  required List<ActionObjectState> objects,
  required LineUpGraph lineups,
}) {
  final graph = lineups.deepCopy();
  return StrategyPage(
    id: id,
    name: name,
    isAutoNamed: isAutoNamed,
    sortIndex: sortIndex,
    isAttack: isAttack,
    settings: cloneSettings(settings),
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
    lineUpOrigins: graph.origins,
    lineUpLandings: graph.landings,
    lineUpLinks: graph.links,
  );
}

List<ActionObjectState> objectsOnPage(StrategyPage page) => [
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

StrategyPage clonePage(StrategyPage page) => pageOf(
      id: page.id,
      name: page.name,
      isAutoNamed: page.isAutoNamed,
      sortIndex: page.sortIndex,
      isAttack: page.isAttack,
      settings: page.settings,
      objects: objectsOnPage(page),
      lineups: page.lineUpGraph,
    );

StrategyData cloneStrategy(StrategyData strategy) => strategy.copyWith(
      pages: [for (final page in strategy.pages) clonePage(page)],
    );

int itemsOn(StrategyPage page) =>
    page.agentData.length +
    page.abilityData.length +
    page.drawingData.length +
    page.textData.length +
    page.imageData.length +
    page.utilityData.length;

final class StaleBefore {
  const StaleBefore(
    this.what,
    this.id,
    this.field, {
    required this.declared,
    required this.held,
  });

  final String what;
  final String id;
  final String field;
  final Object? declared;
  final Object? held;

  static String _short(Object? value) {
    final text = '$value';
    return text.length <= 60 ? text : '${text.substring(0, 57)}...';
  }

  @override
  String toString() => '$what $id $field: the action\'s before is '
      '${_short(declared)}, the canvas held ${_short(held)}';
}

final class Replayed {
  const Replayed(this.strategy, this.stale);

  final StrategyData strategy;
  final List<StaleBefore> stale;
}

Map<String, Object?> _json(ActionObjectState object) =>
    jsonDecode(jsonEncode(object.toJson())) as Map<String, Object?>;

Replayed replayDeclared(StrategyData start, List<CanvasChange> changes) {
  final stale = <StaleBefore>[];
  final pages = {for (final page in start.pages) page.id: page};
  final objects = {
    for (final page in start.pages) page.id: objectsOnPage(page),
  };
  final graphs = {
    for (final page in start.pages) page.id: page.lineUpGraph,
  };
  final settings = {
    for (final page in start.pages) page.id: page.settings,
  };
  final names = {
    for (final page in start.pages)
      page.id: (name: page.name, isAutoNamed: page.isAutoNamed),
  };
  final sides = {for (final page in start.pages) page.id: page.isAttack};
  var name = start.name;
  var map = start.mapData;
  var themeProfileId = start.themeProfileId;
  var themeOverridePalette = start.themeOverridePalette;
  final order = [
    for (final page in [
      ...start.pages
    ]..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)))
      page.id,
  ];

  for (final change in changes) {
    final pageId = change.pageId;
    switch (change) {
      case ObjectAdded(:final object):
        final list = objects[pageId];
        if (list == null) continue;
        list
          ..removeWhere((o) => o.id == object.id)
          ..add(ActionObjectState.fromJson(object.kind, _json(object)));
      case ObjectRemoved(:final object):
        objects[pageId]?.removeWhere((o) => o.id == object.id);
      case ObjectChanged(:final before, :final after):
        final list = objects[pageId];
        if (list == null) continue;
        final index = list.indexWhere((o) => o.id == after.id);
        if (index < 0) continue;
        final from = _json(before);
        final to = _json(after);
        final current = _json(list[index]);
        for (final key in {...from.keys, ...to.keys}) {
          if (cloudJsonEquivalent(from[key], to[key])) continue;
          if (!cloudJsonEquivalent(current[key], from[key])) {
            stale.add(StaleBefore(after.kind.name, after.id, key,
                declared: from[key], held: current[key]));
          }
          if (to.containsKey(key)) {
            current[key] = to[key];
          } else {
            current.remove(key);
          }
        }
        list[index] = ActionObjectState.fromJson(after.kind, current);
      case LineupsChanged(:final removed, :final added):
        final graph = graphs[pageId];
        if (graph == null) continue;
        graphs[pageId] =
            lineupsWithParts(graph, removed: removed, added: added);
      case LineupFieldChanged(
          :final field,
          :final targetId,
          :final before,
          :final after,
        ):
        final graph = graphs[pageId];
        if (graph == null) continue;
        final current = switch (field) {
          LineUpEditField.originPosition => graph.origins
              .where((o) => o.id == targetId)
              .firstOrNull
              ?.agent
              .position,
          LineUpEditField.landingPosition => graph.landings
              .where((l) => l.id == targetId)
              .firstOrNull
              ?.ability
              .position,
          _ => null,
        };
        if (before is Offset && current != null && current != before) {
          stale.add(StaleBefore('lineup', targetId, field.name,
              declared: before, held: current));
        }
        graphs[pageId] = lineupsWithField(graph, field, targetId, after);
      case LineupWeaponChanged(:final originId, :final before, :final after):
        final graph = graphs[pageId];
        if (graph == null) continue;
        final current = graph.origins
            .where((o) => o.id == originId)
            .firstOrNull
            ?.agent
            .weapon;
        if (current != null && current != before) {
          stale.add(StaleBefore('lineup origin', originId, 'weapon',
              declared: before.name, held: current.name));
        }
        graphs[pageId] = lineupsWithWeapon(graph, originId, after);
      case PageSettingsChanged(:final before, :final after):
        final now = settings[pageId];
        if (now == null) continue;
        double pick(double was, double from, double to, String field) {
          if (from == to) return was;
          if (was != from)
            stale.add(StaleBefore('page settings', pageId, field,
                declared: from, held: was));
          return to;
        }
        var neutral = now.useNeutralTeamColors;
        if (before.useNeutralTeamColors != after.useNeutralTeamColors) {
          if (neutral != before.useNeutralTeamColors) {
            stale.add(StaleBefore(
                'page settings', pageId, 'useNeutralTeamColors',
                declared: before.useNeutralTeamColors, held: neutral));
          }
          neutral = after.useNeutralTeamColors;
        }
        settings[pageId] = StrategySettings(
          agentSize: pick(
              now.agentSize, before.agentSize, after.agentSize, 'agentSize'),
          abilitySize: pick(now.abilitySize, before.abilitySize,
              after.abilitySize, 'abilitySize'),
          useNeutralTeamColors: neutral,
        );
      case PageAdded(:final page, :final index):
        pages[page.id] = page;
        objects[page.id] = objectsOnPage(page);
        graphs[page.id] = page.lineUpGraph.deepCopy();
        settings[page.id] = cloneSettings(page.settings);
        names[page.id] = (name: page.name, isAutoNamed: page.isAutoNamed);
        sides[page.id] = page.isAttack;
        order
          ..remove(page.id)
          ..insert(index.clamp(0, order.length), page.id);
      case PageRenamed(:final name, :final isAutoNamed):
        if (names.containsKey(pageId)) {
          names[pageId] = (name: name, isAutoNamed: isAutoNamed);
        }
      case PageRemoved():
        order.remove(pageId);
      case PageMoved(:final index):
        if (order.remove(pageId)) {
          order.insert(index.clamp(0, order.length), pageId);
        }
      case PageSideSet(:final isAttack):
        if (sides.containsKey(pageId)) sides[pageId] = isAttack;
      case ObjectRaised(:final id):
        final list = objects[pageId];
        if (list == null) continue;
        final index = list.indexWhere((o) => o.id == id);
        if (index < 0) continue;
        list.add(list.removeAt(index));
      case StrategyFieldsChanged(
          name: final newName,
          map: final newMap,
          :final theme
        ):
        if (newName != null) name = newName;
        if (newMap != null) map = newMap;
        if (theme != null) {
          themeProfileId = theme.profileId;
          themeOverridePalette = theme.overridePalette;
        }
    }
  }

  return Replayed(
    start.copyWith(
      name: name,
      mapData: map,
      themeProfileId: themeProfileId,
      clearThemeProfileId: themeProfileId == null,
      themeOverridePalette: themeOverridePalette,
      clearThemeOverridePalette: themeOverridePalette == null,
      pages: [
        for (final (index, id) in order.indexed)
          pageOf(
            id: id,
            name: names[id]!.name,
            isAutoNamed: names[id]!.isAutoNamed,
            sortIndex: index,
            isAttack: sides[id]!,
            settings: settings[id]!,
            objects: objects[id]!,
            lineups: graphs[id]!,
          ),
      ],
    ),
    stale,
  );
}

Set<String> pagesNamedBy(List<CanvasChange> changes) => {
      for (final change in changes)
        if (change is! StrategyFieldsChanged) change.pageId,
    };

StrategyData? inRowTerms(StrategyData strategy) =>
    switch (strategyToRows(strategyAsHiveHoldsIt(strategy))) {
      StrategyRowsMade(:final rows) => switch (strategyFromRows(rows)) {
          StrategyDataMade(:final strategy) => strategy,
          StrategyDataRefused() => null,
        },
      StrategyRowsRefused() => null,
    };

StrategyData _withPages(StrategyData strategy, Set<String> pages) =>
    strategy.copyWith(pages: [
      for (final page in strategy.pages)
        if (pages.contains(page.id)) page,
    ]);

final class ComparedOn {
  ComparedOn(this.strategy, Set<String> pages)
      : rows = inRowTerms(_withPages(strategy, pages));

  final StrategyData strategy;
  final StrategyData? rows;
}

List<ReadBackDifference>? differencesOn(
  StrategyData expected,
  StrategyData actual,
  Set<String> pages,
) =>
    differencesBetween(ComparedOn(expected, pages), ComparedOn(actual, pages));

List<ReadBackDifference>? differencesBetween(
  ComparedOn expectedOn,
  ComparedOn actualOn,
) {
  final expected = expectedOn.strategy;
  final actual = actualOn.strategy;
  final left = expectedOn.rows;
  final right = actualOn.rows;
  if (left == null || right == null) return null;
  final differences = readBackDifferences(left, right);
  final listed = {for (final d in differences) '$d'};
  List<({String id, String name, bool? auto, bool side})> pageList(
    StrategyData strategy,
  ) =>
      [
        for (final page in [
          ...strategy.pages
        ]..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)))
          (
            id: page.id,
            name: page.name,
            auto: page.isAutoNamed,
            side: page.isAttack,
          ),
      ];
  final expectedList = pageList(expected);
  final actualList = pageList(actual);
  final actualById = {for (final p in actualList) p.id: p};
  final expectedIds = [for (final p in expectedList) p.id];
  final actualIds = [for (final p in actualList) p.id];
  void add(ReadBackDifference difference) {
    if (listed.add('$difference')) differences.add(difference);
  }

  for (final id in expectedIds.where((id) => !actualIds.contains(id))) {
    add(ReadBackDifference('page', id, 'missing'));
  }
  for (final id in actualIds.where((id) => !expectedIds.contains(id))) {
    add(ReadBackDifference('page', id, 'extra'));
  }
  final common = [
    for (final id in expectedIds)
      if (actualIds.contains(id)) id,
  ];
  final commonActual = [
    for (final id in actualIds)
      if (expectedIds.contains(id)) id,
  ];
  if (common.join('\u0000') != commonActual.join('\u0000')) {
    add(ReadBackDifference('pages', expected.id, 'order'));
  }
  for (final page in expectedList) {
    final other = actualById[page.id];
    if (other == null) continue;
    if (page.name != other.name)
      add(ReadBackDifference('page', page.id, 'name'));
    if (page.auto != other.auto) {
      add(ReadBackDifference('page', page.id, 'isAutoNamed'));
    }
    if (page.side != other.side) {
      add(ReadBackDifference('page', page.id, 'isAttack'));
    }
  }
  return differences;
}
