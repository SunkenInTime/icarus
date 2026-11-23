import 'dart:ui';

import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

sealed class CanvasChange {
  const CanvasChange(this.pageId);

  final String pageId;
}

final class ObjectAdded extends CanvasChange {
  const ObjectAdded(super.pageId, this.object);

  final ActionObjectState object;
}

final class ObjectRemoved extends CanvasChange {
  const ObjectRemoved(super.pageId, this.object);

  final ActionObjectState object;
}

final class ObjectChanged extends CanvasChange {
  const ObjectChanged(super.pageId, this.before, this.after);

  final ActionObjectState before;
  final ActionObjectState after;
}

final class LineupsChanged extends CanvasChange {
  const LineupsChanged(super.pageId,
      {required this.removed, required this.added});

  final LineUpGraph removed;
  final LineUpGraph added;
}

final class LineupFieldChanged extends CanvasChange {
  const LineupFieldChanged(
    super.pageId, {
    required this.field,
    required this.targetId,
    required this.before,
    required this.after,
  });

  final LineUpEditField field;
  final String targetId;
  final Object before;
  final Object after;
}

final class LineupWeaponChanged extends CanvasChange {
  const LineupWeaponChanged(
    super.pageId, {
    required this.originId,
    required this.before,
    required this.after,
  });

  final String originId;
  final WeaponType before;
  final WeaponType after;
}

final class PageSettingsChanged extends CanvasChange {
  const PageSettingsChanged(super.pageId,
      {required this.before, required this.after});

  final StrategySettings before;
  final StrategySettings after;
}

final class PageAdded extends CanvasChange {
  PageAdded(this.page, {required this.index, this.copyOf}) : super(page.id);

  final StrategyPage page;
  final int index;
  final String? copyOf;
}

final class PageRenamed extends CanvasChange {
  const PageRenamed(super.pageId, this.name, {required this.isAutoNamed});

  final String name;
  final bool isAutoNamed;
}

List<CanvasChange> pagesRenamedBetween(
  Iterable<StrategyPage> before,
  Iterable<StrategyPage> after,
) {
  final named = {for (final page in before) page.id: page};
  return [
    for (final page in after)
      if (named[page.id] case final was?
          when was.name != page.name || was.isAutoNamed != page.isAutoNamed)
        PageRenamed(page.id, page.name, isAutoNamed: page.isAutoNamed ?? false),
  ];
}

final class PageRemoved extends CanvasChange {
  const PageRemoved(super.pageId);
}

final class PageMoved extends CanvasChange {
  const PageMoved(super.pageId, this.index);

  final int index;
}

final class PageSideSet extends CanvasChange {
  const PageSideSet(super.pageId, {required this.isAttack});

  final bool isAttack;
}

enum ActionWay { done, undone, redone }

abstract interface class EditFollower {
  void attach();

  void onAction(UserAction action, {required ActionWay way});

  void onPagesChanged(List<CanvasChange> Function() changes, String label);
}

final class EditorNow {
  const EditorNow({required this.agent});

  final PlacedAgentNode? Function(String id) agent;
}

ActionObjectState? objectOnPage(StrategyPage page, String id) {
  for (final agent in page.agentData) {
    if (agent.id == id) return ActionObjectState.agent(agent);
  }
  for (final ability in page.abilityData) {
    if (ability.id == id) return ActionObjectState.ability(ability);
  }
  for (final drawing in page.drawingData) {
    if (drawing.id == id) return ActionObjectState.drawing(drawing);
  }
  for (final text in page.textData) {
    if (text.id == id) return ActionObjectState.text(text);
  }
  for (final image in page.imageData) {
    if (image.id == id) return ActionObjectState.image(image);
  }
  for (final utility in page.utilityData) {
    if (utility.id == id) return ActionObjectState.utility(utility);
  }
  return null;
}

List<CanvasChange> canvasChangesOf(
  UserAction action, {
  required String pageId,
  required bool reversed,
  required EditorNow now,
}) {
  if (action.group == ActionGroup.bulk) {
    final performed =
        reversed ? action.changes.reversed.toList() : action.changes;
    return [
      for (final change in performed)
        ...canvasChangesOf(
          change,
          pageId: pageId,
          reversed: reversed,
          now: now,
        ),
    ];
  }
  switch (action) {
    case LineUpGraphAction(:final before, :final after):
      final (removed, added) = reversed ? (after, before) : (before, after);
      return [
        LineupsChanged(
          pageId,
          removed: removed.deepCopy(),
          added: added.deepCopy(),
        ),
      ];
    case LineUpEditAction(:final targetId, :final field, :final before):
      final (from, to) =
          reversed ? (action.after, before) : (before, action.after);
      return [
        LineupFieldChanged(
          pageId,
          field: field,
          targetId: targetId,
          before: from,
          after: to,
        ),
      ];
    case WeaponSelectionAction(:final id, :final before, :final after)
        when action.group == ActionGroup.lineUp:
      final (from, to) = reversed ? (after, before) : (before, after);
      return [
        LineupWeaponChanged(pageId, originId: id, before: from, after: to),
      ];
    case WeaponSelectionAction(:final id, :final before, :final after):
      final agent = now.agent(id);
      if (agent == null) return const [];
      final (from, to) = reversed ? (after, before) : (before, after);
      final changedFrom = ActionObjectState.agent(agent);
      changedFrom.agent!.weapon = from;
      final changedTo = ActionObjectState.agent(agent);
      changedTo.agent!.weapon = to;
      return [ObjectChanged(pageId, changedFrom, changedTo)];
    case StrategySettingsAction(:final before, :final after):
      final (from, to) = reversed ? (after, before) : (before, after);
      return [PageSettingsChanged(pageId, before: from, after: to)];
  }
  final delta = action.objectDelta;
  if (delta == null) return const [];
  return switch ((action.type, delta.before, delta.after, reversed)) {
    (ActionType.addition, _, final after?, false) => [
        ObjectAdded(pageId, after),
      ],
    (ActionType.addition, _, final after?, true) => [
        ObjectRemoved(pageId, after),
      ],
    (ActionType.deletion, final before?, _, false) => [
        ObjectRemoved(pageId, before),
      ],
    (ActionType.deletion, final before?, _, true) => [
        ObjectAdded(pageId, before),
      ],
    (ActionType.edit, final before?, final after?, false) => [
        ObjectChanged(pageId, before, after),
      ],
    (ActionType.edit, final before?, final after?, true) => [
        ObjectChanged(pageId, after, before),
      ],
    _ => const [],
  };
}

Set<String> lineupPartIds(LineUpGraph graph) => {
      for (final origin in graph.origins) origin.id,
      for (final landing in graph.landings) landing.id,
      for (final link in graph.links) link.id,
    };

LineUpGraph lineupsWithParts(
  LineUpGraph graph, {
  required LineUpGraph removed,
  required LineUpGraph added,
}) {
  final gone = {for (final link in removed.links) link.id};
  final links = [
    for (final link in graph.links)
      if (!gone.contains(link.id)) link,
    for (final link in added.links)
      if (!graph.links.any((kept) => kept.id == link.id) ||
          gone.contains(link.id))
        link,
  ];
  bool used(String id) =>
      links.any((link) => link.originId == id || link.landingId == id);
  final removedEnds = {
    for (final origin in removed.origins) origin.id,
    for (final landing in removed.landings) landing.id,
  };
  final origins = [
    for (final origin in graph.origins)
      if (!removedEnds.contains(origin.id) || used(origin.id)) origin,
  ];
  final landings = [
    for (final landing in graph.landings)
      if (!removedEnds.contains(landing.id) || used(landing.id)) landing,
  ];
  return LineUpGraph(
    origins: [
      ...origins,
      for (final origin in added.origins)
        if (!origins.any((kept) => kept.id == origin.id)) origin,
    ],
    landings: [
      ...landings,
      for (final landing in added.landings)
        if (!landings.any((kept) => kept.id == landing.id)) landing,
    ],
    links: links,
  );
}

LineUpGraph lineupsWithField(
  LineUpGraph graph,
  LineUpEditField field,
  String targetId,
  Object value,
) =>
    switch (field) {
      LineUpEditField.originPosition => LineUpGraph(
          origins: [
            for (final origin in graph.origins)
              origin.id == targetId
                  ? origin.copyWith(
                      agent: origin.agent.copyWith(position: value as Offset)
                        ..isDeleted = origin.agent.isDeleted,
                    )
                  : origin,
          ],
          landings: graph.landings,
          links: graph.links,
        ),
      LineUpEditField.landingPosition ||
      LineUpEditField.landingVisibility =>
        LineUpGraph(
          origins: graph.origins,
          landings: [
            for (final landing in graph.landings)
              landing.id == targetId
                  ? landing.copyWith(
                      ability: (field == LineUpEditField.landingPosition
                          ? landing.ability.copyWith(position: value as Offset)
                          : landing.ability.copyWith(
                              visualState: (value as AbilityVisibilityChange)
                                  .writeTo(landing.ability.visualState),
                            ))
                        ..isDeleted = landing.ability.isDeleted,
                    )
                  : landing,
          ],
          links: graph.links,
        ),
      LineUpEditField.linkDetails => LineUpGraph(
          origins: graph.origins,
          landings: graph.landings,
          links: [
            for (final link in graph.links)
              link.id == targetId
                  ? (value as LineUpLinkChange).writeTo(link)
                  : link,
          ],
        ),
    };

LineUpGraph lineupsWithWeapon(
  LineUpGraph graph,
  String originId,
  WeaponType weapon,
) =>
    LineUpGraph(
      origins: [
        for (final origin in graph.origins)
          origin.id == originId
              ? origin.copyWith(agent: origin.agent.copyWith(weapon: weapon))
              : origin,
      ],
      landings: graph.landings,
      links: graph.links,
    );
