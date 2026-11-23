import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
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
  const LineupsChanged(super.pageId, this.before, this.after);

  final LineUpGraph before;
  final LineUpGraph after;
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
  const EditorNow({required this.lineups, required this.agent});

  final LineUpGraph lineups;
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

bool readsTheEditor(UserAction action) => switch (action) {
      LineUpEditAction() || WeaponSelectionAction() => true,
      _ when action.group == ActionGroup.bulk =>
        action.changes.any(readsTheEditor),
      _ => false,
    };

List<CanvasChange> canvasChangesOf(
  UserAction action, {
  required String pageId,
  required bool reversed,
  required EditorNow now,
}) {
  if (action.group == ActionGroup.bulk) {
    final changes = reversed ? action.changes.reversed : action.changes;
    return [
      for (final change in changes)
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
      return [
        reversed
            ? LineupsChanged(pageId, after, before)
            : LineupsChanged(pageId, before, after),
      ];
    case LineUpEditAction(:final targetId):
      return [LineupPartChanged(pageId, targetId, now.lineups)];
    case WeaponSelectionAction(:final id)
        when action.group == ActionGroup.lineUp:
      return [LineupPartChanged(pageId, id, now.lineups)];
    case WeaponSelectionAction(:final id):
      return switch (now.agent(id)) {
        final agent? => [
            ObjectChanged(
              pageId,
              ActionObjectState.agent(agent),
              ActionObjectState.agent(agent),
            ),
          ],
        null => const [],
      };
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
