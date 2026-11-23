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
  const LineupsChanged(
    super.pageId,
    this.before,
    this.after, {
    required this.touching,
  });

  final LineUpGraph before;
  final LineUpGraph after;
  final Set<String> touching;
}

final class LineupPartChanged extends CanvasChange {
  const LineupPartChanged(super.pageId, this.partId, this.graph);

  final String partId;
  final LineUpGraph graph;
}

final class PageSettingsChanged extends CanvasChange {
  const PageSettingsChanged(super.pageId, this.settings);

  final StrategySettings settings;
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
  void onAction(UserAction action, {required ActionWay way});

  void onPagesChanged(List<CanvasChange> Function() changes, String label);
}

final class EditorNow {
  EditorNow({required LineUpGraph Function() lineups, required this.agent})
      : _lineups = lineups;

  final LineUpGraph Function() _lineups;
  late final LineUpGraph lineups = _lineups();
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
    var lineups = now.lineups;
    final changes = <List<CanvasChange>>[];
    for (final change in performed.reversed) {
      final atThisStep = lineups;
      changes.add(canvasChangesOf(
        change,
        pageId: pageId,
        reversed: reversed,
        now: EditorNow(lineups: () => atThisStep, agent: now.agent),
      ));
      lineups = lineupsBefore(change, reversed: reversed, after: lineups);
    }
    return [for (final step in changes.reversed) ...step];
  }
  switch (action) {
    case LineUpGraphAction(:final before, :final after):
      final (removed, added) = reversed ? (after, before) : (before, after);
      return [
        LineupsChanged(
          pageId,
          lineupsBefore(action, reversed: reversed, after: now.lineups),
          now.lineups,
          touching: {...lineupPartIds(removed), ...lineupPartIds(added)},
        ),
      ];
    case LineUpEditAction(:final targetId):
      return [LineupPartChanged(pageId, targetId, now.lineups)];
    case WeaponSelectionAction(:final id)
        when action.group == ActionGroup.lineUp:
      return [LineupPartChanged(pageId, id, now.lineups)];
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
      return [PageSettingsChanged(pageId, reversed ? before : after)];
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

LineUpGraph lineupsBefore(
  UserAction action, {
  required bool reversed,
  required LineUpGraph after,
}) {
  if (action.group == ActionGroup.bulk) {
    final performed =
        reversed ? action.changes.reversed.toList() : action.changes;
    var lineups = after;
    for (final change in performed.reversed) {
      lineups = lineupsBefore(change, reversed: reversed, after: lineups);
    }
    return lineups;
  }
  switch (action) {
    case LineUpEditAction(:final field, :final targetId, :final before):
      return lineupsWithField(
        after,
        field,
        targetId,
        reversed ? action.after : before,
      );
    case WeaponSelectionAction(:final id, :final before)
        when action.group == ActionGroup.lineUp:
      return lineupsWithWeapon(after, id, reversed ? action.after : before);
    case LineUpGraphAction(before: final graphBefore, after: final graphAfter):
      return reversed
          ? _withoutAdded(after, removed: graphAfter, added: graphBefore)
          : _withoutAdded(after, removed: graphBefore, added: graphAfter);
    default:
      return after;
  }
}

LineUpGraph _withoutAdded(
  LineUpGraph after, {
  required LineUpGraph removed,
  required LineUpGraph added,
}) {
  final addedLinks = {for (final link in added.links) link.id};
  final links = [
    for (final link in after.links)
      if (!addedLinks.contains(link.id)) link,
    for (final link in removed.links)
      if (!after.links.any((kept) => kept.id == link.id)) link,
  ];
  bool used(String id) =>
      links.any((link) => link.originId == id || link.landingId == id);
  final addedEnds = {
    for (final origin in added.origins) origin.id,
    for (final landing in added.landings) landing.id,
  };
  return LineUpGraph(
    origins: [
      for (final origin in after.origins)
        if (!addedEnds.contains(origin.id) || used(origin.id)) origin,
      for (final origin in removed.origins)
        if (!after.origins.any((kept) => kept.id == origin.id)) origin,
    ],
    landings: [
      for (final landing in after.landings)
        if (!addedEnds.contains(landing.id) || used(landing.id)) landing,
      for (final landing in removed.landings)
        if (!after.landings.any((kept) => kept.id == landing.id)) landing,
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
