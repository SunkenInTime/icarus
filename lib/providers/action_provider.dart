import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:uuid/uuid.dart';

enum ActionGroup {
  agent,
  ability,
  drawing,
  text,
  image,
  utility,
  lineUp,
  strategySettings,
  bulk,
}

enum ActionType {
  addition,
  deletion,
  edit,
  bulkDeletion,
  transaction,
}

/// The history entries a bulk clear took out along with the objects: the
/// ones for the cleared groups. Undoing the clear puts them back.
class BulkActionSnapshot {
  final List<ActionGroup> targetGroups;
  final List<UserAction> actionStateBefore;

  const BulkActionSnapshot({
    required this.targetGroups,
    required this.actionStateBefore,
  });

  BulkActionSnapshot copy() {
    return BulkActionSnapshot(
      targetGroups: [...targetGroups],
      actionStateBefore:
          actionStateBefore.map((action) => action.copy()).toList(),
    );
  }
}

class UserAction {
  final ActionGroup group;
  final String id;
  final ActionType type;
  final ObjectHistoryDelta? objectDelta;
  final BulkActionSnapshot? bulkSnapshot;

  /// For a transaction or bulk clear (group [ActionGroup.bulk]): the change
  /// to each object, in the order they happened. Undo reverses them last to
  /// first and redo replays them, each against the page as it is now, so
  /// objects a teammate added or changed since are left alone.
  final List<UserAction> changes;

  UserAction({
    required this.type,
    required this.id,
    required this.group,
    this.objectDelta,
    this.bulkSnapshot,
    this.changes = const [],
  });

  UserAction copy() {
    return UserAction(
      type: type,
      id: id,
      group: group,
      objectDelta: objectDelta?.clone(),
      bulkSnapshot: bulkSnapshot?.copy(),
      changes: changes.map((change) => change.copy()).toList(),
    );
  }

  @override
  String toString() {
    return """
          Action Group: $group
          Item id: $id
          Action Type: $type
    """;
  }
}

final actionProvider =
    NotifierProvider<ActionProvider, List<UserAction>>(ActionProvider.new);

/// Records only the firearm, so undoing it never restores an older copy of an
/// agent's movement history or a lineup's graph. Shared by both agent groups.
class WeaponSelectionAction extends UserAction {
  WeaponSelectionAction({
    required super.id,
    required super.group,
    required this.before,
    required this.after,
  }) : super(type: ActionType.edit);

  final WeaponType before;
  final WeaponType after;

  // History stores copies, so the copy must stay a weapon action; a plain
  // edit would undo through the agent's movement history instead.
  @override
  WeaponSelectionAction copy() {
    return WeaponSelectionAction(
      id: id,
      group: group,
      before: before,
      after: after,
    );
  }
}

/// A change to the strategy settings. Undo and redo write only the settings
/// it changed, so a teammate's change to another setting is kept.
class StrategySettingsAction extends UserAction {
  StrategySettingsAction({
    required super.id,
    required this.before,
    required this.after,
  }) : super(type: ActionType.edit, group: ActionGroup.strategySettings);

  final StrategySettings before;
  final StrategySettings after;

  @override
  StrategySettingsAction copy() {
    return StrategySettingsAction(id: id, before: before, after: after);
  }
}

class ActionProvider extends Notifier<List<UserAction>> {
  static const List<ActionGroup> _clearableGroups = [
    ActionGroup.agent,
    ActionGroup.ability,
    ActionGroup.drawing,
    ActionGroup.text,
    ActionGroup.image,
    ActionGroup.utility,
    ActionGroup.lineUp,
  ];
  static const _uuid = Uuid();
  List<UserAction> poppedItems = [];

  /// While a transaction's mutation runs, the changes it records.
  List<UserAction>? _transactionChanges;

  @override
  List<UserAction> build() {
    return [];
  }

  void addAction(UserAction action) {
    final transactionChanges = _transactionChanges;
    if (transactionChanges != null) {
      transactionChanges.add(action.copy());
      return;
    }
    ref.read(strategyProvider.notifier).setUnsaved();
    if (action.group != ActionGroup.ability) {
      ref
          .read(abilityBarProvider.notifier)
          .updateData(null); // Make the agent tab disappear after an action
    }
    poppedItems = [];
    state = [...state, action.copy()];
  }

  void redoAction() {
    if (poppedItems.isEmpty) return;

    final action = poppedItems.removeLast();
    final undo = _redo(action);
    if (undo == null) return;

    final cleared = undo.bulkSnapshot?.targetGroups;
    if (cleared == null) {
      state = [...state, undo];
    } else {
      // The clear sets aside the history it makes unreplayable, as it did
      // the first time.
      final historyBefore = state.map((item) => item.copy()).toList();
      state = [
        ..._filterActionsForGroups(historyBefore, cleared),
        _withChanges(
          undo,
          undo.changes,
          bulkSnapshot: BulkActionSnapshot(
            targetGroups: cleared,
            actionStateBefore: historyBefore,
          ),
        ),
      ];
    }
    if (action.group == ActionGroup.bulk) {
      ref.read(abilityBarProvider.notifier).updateData(null);
    }
  }

  void undoAction() {
    if (state.isEmpty) return;

    final action = state.last;
    final redo = _undo(action);
    if (redo != null) poppedItems.add(redo);

    final bulkSnapshot = action.bulkSnapshot;
    if (bulkSnapshot == null) {
      state = state.sublist(0, state.length - 1);
      return;
    }
    // The history the clear set aside comes back, less what hydration has
    // since made unreplayable.
    state = bulkSnapshot.actionStateBefore.map((item) => item.copy()).toList();
    reconcileHistory();
  }

  /// Undoes [action] against the page as it is now. Returns the entry that
  /// redoes exactly what this undo did, or null when it changed nothing.
  UserAction? _undo(UserAction action) => _replay(action, undo: true);

  /// Redoes [action] against the page as it is now. Returns the entry that
  /// undoes exactly what this redo did, or null when it changed nothing.
  UserAction? _redo(UserAction action) => _replay(action, undo: false);

  UserAction? _replay(UserAction action, {required bool undo}) {
    if (action.group == ActionGroup.bulk) {
      // Undo runs the changes last to first, redo first to last; only the
      // ones that changed something are kept, in their original order.
      final order = undo ? action.changes.reversed : action.changes;
      final replayed = [
        for (final change in order)
          if (_replay(change, undo: undo) case final done?) done,
      ];
      if (replayed.isEmpty) return null;
      return _withChanges(
        action,
        undo ? replayed.reversed.toList() : replayed,
      );
    }

    final delta = action.objectDelta;
    if (delta != null) {
      final current = _currentObjectState(
        delta.id,
        delta.after?.kind ?? delta.before?.kind,
      );
      switch (action.type) {
        case ActionType.addition:
        case ActionType.deletion:
          final removes = (action.type == ActionType.addition) == undo;
          if (removes) {
            if (current == null) return null;
            _apply(action, undo: undo);
            // The opposite step puts back the object as it was when taken
            // away, a teammate's edits included.
            return _holding(action, current);
          }
          // An object that is already there is left as it is.
          if (current != null) return null;
        case ActionType.edit:
          // An object a teammate deleted stays deleted.
          if (current == null) return null;
        case ActionType.bulkDeletion:
        case ActionType.transaction:
          break;
      }
    }
    _apply(action, undo: undo);
    return action;
  }

  /// [action], an addition or deletion, holding [object] as the copy to put
  /// back.
  static UserAction _holding(UserAction action, ActionObjectState object) {
    return UserAction(
      type: action.type,
      id: action.id,
      group: action.group,
      objectDelta: action.type == ActionType.addition
          ? ObjectHistoryDelta(after: object)
          : ObjectHistoryDelta(before: object),
    );
  }

  static UserAction _withChanges(
    UserAction action,
    List<UserAction> changes, {
    BulkActionSnapshot? bulkSnapshot,
  }) {
    return UserAction(
      type: action.type,
      id: action.id,
      group: action.group,
      bulkSnapshot: bulkSnapshot ?? action.bulkSnapshot,
      changes: changes,
    );
  }

  void _apply(UserAction action, {required bool undo}) {
    switch (action.group) {
      case ActionGroup.agent:
        final agents = ref.read(agentProvider.notifier);
        undo ? agents.undoAction(action) : agents.redoAction(action);
      case ActionGroup.ability:
        final abilities = ref.read(abilityProvider.notifier);
        undo ? abilities.undoAction(action) : abilities.redoAction(action);
      case ActionGroup.drawing:
        final drawings = ref.read(drawingProvider.notifier);
        undo ? drawings.undoAction(action) : drawings.redoAction(action);
      case ActionGroup.text:
        final texts = ref.read(textProvider.notifier);
        undo ? texts.undoAction(action) : texts.redoAction(action);
      case ActionGroup.image:
        final images = ref.read(placedImageProvider.notifier);
        undo ? images.undoAction(action) : images.redoAction(action);
      case ActionGroup.utility:
        final utilities = ref.read(utilityProvider.notifier);
        undo ? utilities.undoAction(action) : utilities.redoAction(action);
      case ActionGroup.lineUp:
        final lineUps = ref.read(lineUpProvider.notifier);
        undo ? lineUps.undoAction(action) : lineUps.redoAction(action);
      case ActionGroup.strategySettings:
        if (action is StrategySettingsAction) {
          undo
              ? _writeSettings(to: action.before, from: action.after)
              : _writeSettings(to: action.after, from: action.before);
        }
      case ActionGroup.bulk:
        break;
    }
  }

  void _writeSettings({
    required StrategySettings to,
    required StrategySettings from,
  }) {
    final written = writeChangedFields(
      to: to.toJson(),
      from: from.toJson(),
      onto: ref.read(strategySettingsProvider).toJson(),
    );
    ref
        .read(strategySettingsProvider.notifier)
        .fromHive(StrategySettings.fromJson(written));
  }

  // Hard reset used by strategy/page lifecycle flows. This is not undoable.
  void resetActionState() {
    poppedItems = [];
    ref.read(agentProvider.notifier).clearAll();
    ref.read(abilityProvider.notifier).clearAll();
    ref.read(drawingProvider.notifier).clearAll();
    ref.read(textProvider.notifier).clearAll();
    ref.read(placedImageProvider.notifier).clearAll();
    ref.read(utilityProvider.notifier).clearAll();
    ref.read(lineUpProvider.notifier).clearAll();

    state = [];
  }

  void clearActionHistory() {
    poppedItems = [];
    state = [];
  }

  void reconcileHistory() {
    // An edit stays while its target exists or a retained addition or
    // deletion, on either stack, can bring it back.
    final history = _andChanges([...state, ...poppedItems]).toList();
    final lineUpIds = ref.read(lineUpProvider.notifier).replayableIds(history);
    final objectIds = {
      for (final action in history)
        if (action.type != ActionType.edit && action.objectDelta != null)
          action.objectDelta!.id,
    };
    state = _reconcileActions(state, lineUpIds, objectIds);
    poppedItems = _reconcileActions(poppedItems, lineUpIds, objectIds);
  }

  static Iterable<UserAction> _andChanges(
    Iterable<UserAction> actions,
  ) sync* {
    for (final action in actions) {
      yield action;
      yield* _andChanges(action.changes);
    }
  }

  void clearAllAsAction() {
    _performBulkClear(_clearableGroups);
  }

  void clearGroupAsAction(ActionGroup group) {
    if (!_clearableGroups.contains(group)) return;
    _performBulkClear([group]);
  }

  /// Runs [mutation] as one undo step made of the per-object changes it
  /// records. Changing strategy settings records nothing, so when [groups]
  /// names them they are compared before and after instead.
  void performTransaction({
    required List<ActionGroup> groups,
    required void Function() mutation,
  }) {
    final settingsBefore = groups.contains(ActionGroup.strategySettings)
        ? ref.read(strategySettingsProvider)
        : null;

    final outerChanges = _transactionChanges;
    final changes = _transactionChanges = <UserAction>[];
    try {
      mutation();
    } finally {
      _transactionChanges = outerChanges;
    }

    if (settingsBefore != null) {
      final settingsAfter = ref.read(strategySettingsProvider);
      if (!cloudJsonEquivalent(
          settingsBefore.toJson(), settingsAfter.toJson())) {
        changes.add(StrategySettingsAction(
          id: _uuid.v4(),
          before: settingsBefore,
          after: settingsAfter,
        ));
      }
    }
    if (changes.isEmpty) return;

    addAction(
      UserAction(
        type: ActionType.transaction,
        id: _uuid.v4(),
        group: ActionGroup.bulk,
        changes: changes,
      ),
    );
  }

  void _performBulkClear(List<ActionGroup> groups) {
    final targetGroups = <ActionGroup>[];
    for (final group in groups) {
      if (_clearableGroups.contains(group) && !targetGroups.contains(group)) {
        targetGroups.add(group);
      }
    }

    final changes = [
      for (final group in targetGroups) ..._clearChanges(group),
    ];
    if (changes.isEmpty) return;

    final historyBefore = state.map((action) => action.copy()).toList();
    _clearProvidersForGroups(targetGroups);

    state = _filterActionsForGroups(historyBefore, targetGroups);
    addAction(
      UserAction(
        type: ActionType.bulkDeletion,
        id: _uuid.v4(),
        group: ActionGroup.bulk,
        bulkSnapshot: BulkActionSnapshot(
          targetGroups: targetGroups,
          actionStateBefore: historyBefore,
        ),
        changes: changes,
      ),
    );
  }

  /// The deletions that clear [group]: one per object, topmost first, so
  /// undo (last to first) puts them back in their order. Lineups are
  /// removed as one graph change.
  List<UserAction> _clearChanges(ActionGroup group) {
    if (group == ActionGroup.lineUp) {
      final graph = ref.read(lineUpProvider).graph;
      return [
        if (graph.links.isNotEmpty)
          LineUpGraphAction(
            type: ActionType.deletion,
            id: _uuid.v4(),
            before: graph.deepCopy(),
          ),
      ];
    }

    final Iterable<ActionObjectState> objects = switch (group) {
      ActionGroup.agent => ref.read(agentProvider).map(ActionObjectState.agent),
      ActionGroup.ability =>
        ref.read(abilityProvider).map(ActionObjectState.ability),
      ActionGroup.drawing =>
        ref.read(drawingProvider).elements.map(ActionObjectState.drawing),
      ActionGroup.text => ref.read(textProvider).map(ActionObjectState.text),
      ActionGroup.image =>
        ref.read(placedImageProvider).images.map(ActionObjectState.image),
      ActionGroup.utility =>
        ref.read(utilityProvider).map(ActionObjectState.utility),
      ActionGroup.lineUp ||
      ActionGroup.strategySettings ||
      ActionGroup.bulk =>
        const [],
    };
    return [
      for (final object in objects.toList().reversed)
        UserAction(
          type: ActionType.deletion,
          id: object.id,
          group: group,
          objectDelta: ObjectHistoryDelta(before: object),
        ),
    ];
  }

  List<UserAction> _filterActionsForGroups(
    List<UserAction> actions,
    List<ActionGroup> targetGroups,
  ) {
    final groupSet = targetGroups.toSet();

    return actions
        .where((action) => !_actionIntersectsGroups(action, groupSet))
        .toList();
  }

  bool _actionIntersectsGroups(
      UserAction action, Set<ActionGroup> targetGroups) {
    final bulkSnapshot = action.bulkSnapshot;
    if (bulkSnapshot != null) {
      return bulkSnapshot.targetGroups.any(targetGroups.contains);
    }
    if (action.group == ActionGroup.bulk) {
      return action.changes
          .any((change) => _actionIntersectsGroups(change, targetGroups));
    }
    return targetGroups.contains(action.group);
  }

  void _clearProvidersForGroups(List<ActionGroup> groups) {
    for (final group in groups) {
      switch (group) {
        case ActionGroup.agent:
          ref.read(agentProvider.notifier).clearAll();
        case ActionGroup.ability:
          ref.read(abilityProvider.notifier).clearAll();
        case ActionGroup.drawing:
          ref.read(drawingProvider.notifier).clearAll();
        case ActionGroup.text:
          ref.read(textProvider.notifier).clearAll();
        case ActionGroup.image:
          ref.read(placedImageProvider.notifier).clearAll();
        case ActionGroup.utility:
          ref.read(utilityProvider.notifier).clearAll();
        case ActionGroup.lineUp:
          ref.read(lineUpProvider.notifier).clearAll();
        case ActionGroup.strategySettings:
          break;
        case ActionGroup.bulk:
          break;
      }
    }
  }

  List<UserAction> _reconcileActions(
    List<UserAction> actions,
    Set<String> lineUpIds,
    Set<String> objectIds,
  ) {
    return [
      for (final action in actions)
        if (_reconciled(action, lineUpIds, objectIds) case final kept?) kept,
    ];
  }

  /// [action] as far as it can still be replayed, or null when it cannot.
  /// A transaction or clear keeps the changes that stay and goes with the
  /// last of them.
  UserAction? _reconciled(
    UserAction action,
    Set<String> lineUpIds,
    Set<String> objectIds,
  ) {
    if (action.group == ActionGroup.bulk) {
      final changes = _reconcileActions(action.changes, lineUpIds, objectIds);
      return changes.isEmpty ? null : _withChanges(action, changes);
    }
    final delta = action.objectDelta;
    if (action.type == ActionType.edit &&
        delta != null &&
        !objectIds.contains(delta.id) &&
        !_canKeepEditAction(delta)) {
      return null;
    }
    if (action is LineUpEditAction && !lineUpIds.contains(action.targetId)) {
      return null;
    }
    return action.copy();
  }

  bool _canKeepEditAction(ObjectHistoryDelta delta) {
    final current =
        _currentObjectState(delta.id, delta.before?.kind ?? delta.after?.kind);
    if (current == null) {
      return false;
    }
    final expectedKind = delta.after?.kind ?? delta.before?.kind;
    return current.kind == expectedKind;
  }

  ActionObjectState? _currentObjectState(String id, ActionObjectKind? kind) {
    if (kind == null) {
      return null;
    }
    switch (kind) {
      case ActionObjectKind.agent:
        final index = PlacedWidget.getIndexByID(id, ref.read(agentProvider));
        if (index < 0) return null;
        return ActionObjectState.agent(ref.read(agentProvider)[index]);
      case ActionObjectKind.ability:
        final index = PlacedWidget.getIndexByID(id, ref.read(abilityProvider));
        if (index < 0) return null;
        return ActionObjectState.ability(ref.read(abilityProvider)[index]);
      case ActionObjectKind.drawing:
        final index =
            DrawingElement.getIndexByID(id, ref.read(drawingProvider).elements);
        if (index < 0) return null;
        return ActionObjectState.drawing(
            ref.read(drawingProvider).elements[index]);
      case ActionObjectKind.text:
        final index = PlacedWidget.getIndexByID(id, ref.read(textProvider));
        if (index < 0) return null;
        return ActionObjectState.text(ref.read(textProvider)[index]);
      case ActionObjectKind.image:
        final images = ref.read(placedImageProvider).images;
        final index = PlacedWidget.getIndexByID(id, images);
        if (index < 0) return null;
        return ActionObjectState.image(images[index]);
      case ActionObjectKind.utility:
        final index = PlacedWidget.getIndexByID(id, ref.read(utilityProvider));
        if (index < 0) return null;
        return ActionObjectState.utility(ref.read(utilityProvider)[index]);
      case ActionObjectKind.lineUp:
        // Lineup history is graph snapshots keyed by action id; the lineup
        // graph never records per-object deltas, so there is nothing to keep.
        return null;
    }
  }
}
