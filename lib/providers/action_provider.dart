import 'dart:developer';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/image_widget_size_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/text_widget_height_provider.dart';
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
  bulk,
}

enum ActionType {
  addition,
  deletion,
  edit,
  bulkDeletion,
  transaction,
}

class TransactionSnapshot {
  final List<ActionGroup> targetGroups;
  final BulkActionSnapshot before;
  final BulkActionSnapshot after;

  const TransactionSnapshot({
    required this.targetGroups,
    required this.before,
    required this.after,
  });
}

class BulkActionSnapshot {
  final List<ActionGroup> targetGroups;
  final List<UserAction> actionStateBefore;
  final List<UserAction> redoStateBefore;
  final AgentProviderSnapshot? agentSnapshot;
  final AbilityProviderSnapshot? abilitySnapshot;
  final DrawingProviderSnapshot? drawingSnapshot;
  final TextProviderSnapshot? textSnapshot;
  final PlacedImageProviderSnapshot? imageSnapshot;
  final UtilityProviderSnapshot? utilitySnapshot;
  final LineUpProviderSnapshot? lineUpSnapshot;
  final Map<String, Offset> imageSizeSnapshot;
  final Map<String, Offset> textHeightSnapshot;

  const BulkActionSnapshot({
    required this.targetGroups,
    required this.actionStateBefore,
    required this.redoStateBefore,
    this.agentSnapshot,
    this.abilitySnapshot,
    this.drawingSnapshot,
    this.textSnapshot,
    this.imageSnapshot,
    this.utilitySnapshot,
    this.lineUpSnapshot,
    this.imageSizeSnapshot = const {},
    this.textHeightSnapshot = const {},
  });
}

class UserAction {
  final ActionGroup group;
  final String id;
  final ActionType type;
  final BulkActionSnapshot? bulkSnapshot;
  final TransactionSnapshot? transactionSnapshot;

  UserAction({
    required this.type,
    required this.id,
    required this.group,
    this.bulkSnapshot,
    this.transactionSnapshot,
  });

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

class ActionProvider extends Notifier<List<UserAction>> {
  static const List<ActionGroup> _undoableGroups = [
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
  bool _recordingDisabled = false;

  @override
  List<UserAction> build() {
    return [];
  }

  void addAction(UserAction action) {
    if (_recordingDisabled) {
      return;
    }
    ref.read(strategyProvider.notifier).setUnsaved();
    if (action.group != ActionGroup.ability) {
      ref
          .read(abilityBarProvider.notifier)
          .updateData(null); // Make the agent tab disappear after an action
    }
    poppedItems = [];
    state = [...state, action];

    // log("\n Current state \n ${state.toString()}");
  }

  void redoAction() {
    log(poppedItems.length.toString());
    if (poppedItems.isEmpty) {
      // log("Popped list is empty");
      return;
    }

    final poppedAction = poppedItems.last;
    log(poppedItems.length.toString());
    if (poppedAction.type == ActionType.bulkDeletion) {
      _redoBulkAction(poppedAction);
      return;
    }
    if (poppedAction.type == ActionType.transaction) {
      _redoTransaction(poppedAction);
      return;
    }

    switch (poppedAction.group) {
      case ActionGroup.agent:
        ref.read(agentProvider.notifier).redoAction(poppedAction);
      case ActionGroup.ability:
        ref.read(abilityProvider.notifier).redoAction(poppedAction);
      case ActionGroup.drawing:
        ref.read(drawingProvider.notifier).redoAction(poppedAction);
      case ActionGroup.text:
        ref.read(textProvider.notifier).redoAction(poppedAction);
      case ActionGroup.image:
        ref.read(placedImageProvider.notifier).redoAction(poppedAction);
      case ActionGroup.utility:
        ref.read(utilityProvider.notifier).redoAction(poppedAction);
      case ActionGroup.lineUp:
        ref.read(lineUpProvider.notifier).redoAction(poppedAction);
      case ActionGroup.bulk:
        return;
    }

    final newState = [...state];
    newState.add(poppedItems.removeLast());

    ref.read(strategyProvider.notifier).setUnsaved();

    state = newState;
    // log("\n Current state \n ${state.toString()}");
  }

  void undoAction() {
    // log("Undo action was triggered");

    if (state.isEmpty) return;
    final currentAction = state.last;
    if (currentAction.type == ActionType.bulkDeletion) {
      _undoBulkAction(currentAction);
      return;
    }
    if (currentAction.type == ActionType.transaction) {
      _undoTransaction(currentAction);
      return;
    }

    switch (currentAction.group) {
      case ActionGroup.agent:
        ref.read(agentProvider.notifier).undoAction(currentAction);
      case ActionGroup.ability:
        ref.read(abilityProvider.notifier).undoAction(currentAction);
      case ActionGroup.drawing:
        ref.read(drawingProvider.notifier).undoAction(currentAction);
      case ActionGroup.text:
        ref.read(textProvider.notifier).undoAction(currentAction);
      case ActionGroup.image:
        ref.read(placedImageProvider.notifier).undoAction(currentAction);
      case ActionGroup.utility:
        ref.read(utilityProvider.notifier).undoAction(currentAction);
      case ActionGroup.lineUp:
        ref.read(lineUpProvider.notifier).undoAction(currentAction);
      case ActionGroup.bulk:
        return;
    }
    // log("Undo action was called");
    final newState = [...state];
    poppedItems.add(newState.removeLast());

    ref.read(strategyProvider.notifier).setUnsaved();

    state = newState;
    // log("\n Current state \n ${state.toString()}");

    // log("\n Popped State \n ${poppedItems.toString()}");
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

    ref.read(imageWidgetSizeProvider.notifier).clearAll();
    ref.read(textWidgetHeightProvider.notifier).clearAll();
    ref.read(strategyProvider.notifier).setUnsaved();
    state = [];
  }

  void clearAllAsAction() {
    _performBulkClear(_undoableGroups);
  }

  void clearGroupAsAction(ActionGroup group) {
    if (group == ActionGroup.bulk) return;
    _performBulkClear([group]);
  }

  void performTransaction({
    required List<ActionGroup> groups,
    required void Function() mutation,
  }) {
    final targetGroups = <ActionGroup>[];
    for (final group in groups) {
      if (_undoableGroups.contains(group) && !targetGroups.contains(group)) {
        targetGroups.add(group);
      }
    }
    if (targetGroups.isEmpty) {
      mutation();
      return;
    }

    final before = _captureBulkSnapshot(targetGroups);
    final previousRecordingState = _recordingDisabled;
    _recordingDisabled = true;
    try {
      mutation();
    } finally {
      _recordingDisabled = previousRecordingState;
    }
    final after = _captureBulkSnapshot(targetGroups);

    addAction(
      UserAction(
        type: ActionType.transaction,
        id: _uuid.v4(),
        group: ActionGroup.bulk,
        transactionSnapshot: TransactionSnapshot(
          targetGroups: targetGroups,
          before: before,
          after: after,
        ),
      ),
    );
  }

  void _performBulkClear(List<ActionGroup> groups) {
    final targetGroups = <ActionGroup>[];
    for (final group in groups) {
      if (_undoableGroups.contains(group) && !targetGroups.contains(group)) {
        targetGroups.add(group);
      }
    }

    if (targetGroups.isEmpty || !_hasAnyItemsForGroups(targetGroups)) {
      return;
    }

    final snapshot = _captureBulkSnapshot(targetGroups);
    final filteredActions = _filterActionsForGroups(
      snapshot.actionStateBefore,
      targetGroups,
    );

    _clearProvidersForGroups(targetGroups);
    _clearAncillaryState(snapshot);

    state = filteredActions;
    addAction(
      UserAction(
        type: ActionType.bulkDeletion,
        id: _uuid.v4(),
        group: ActionGroup.bulk,
        bulkSnapshot: snapshot,
      ),
    );
  }

  bool _hasAnyItemsForGroups(List<ActionGroup> groups) {
    for (final group in groups) {
      switch (group) {
        case ActionGroup.agent:
          if (ref.read(agentProvider).isNotEmpty) return true;
        case ActionGroup.ability:
          if (ref.read(abilityProvider).isNotEmpty) return true;
        case ActionGroup.drawing:
          if (ref.read(drawingProvider).elements.isNotEmpty) return true;
        case ActionGroup.text:
          if (ref.read(textProvider).isNotEmpty) return true;
        case ActionGroup.image:
          if (ref.read(placedImageProvider).images.isNotEmpty) return true;
        case ActionGroup.utility:
          if (ref.read(utilityProvider).isNotEmpty) return true;
        case ActionGroup.lineUp:
          if (ref.read(lineUpProvider).lineUps.isNotEmpty) return true;
        case ActionGroup.bulk:
          break;
      }
    }
    return false;
  }

  BulkActionSnapshot _captureBulkSnapshot(List<ActionGroup> groups) {
    final imageIds = groups.contains(ActionGroup.image)
        ? ref.read(placedImageProvider).images.map((image) => image.id)
        : const <String>[];
    final textIds = groups.contains(ActionGroup.text)
        ? ref.read(textProvider).map((text) => text.id)
        : const <String>[];

    return BulkActionSnapshot(
      targetGroups: [...groups],
      actionStateBefore: [...state],
      redoStateBefore: [...poppedItems],
      agentSnapshot: groups.contains(ActionGroup.agent)
          ? ref.read(agentProvider.notifier).takeSnapshot()
          : null,
      abilitySnapshot: groups.contains(ActionGroup.ability)
          ? ref.read(abilityProvider.notifier).takeSnapshot()
          : null,
      drawingSnapshot: groups.contains(ActionGroup.drawing)
          ? ref.read(drawingProvider.notifier).takeSnapshot()
          : null,
      textSnapshot: groups.contains(ActionGroup.text)
          ? ref.read(textProvider.notifier).takeSnapshot()
          : null,
      imageSnapshot: groups.contains(ActionGroup.image)
          ? ref.read(placedImageProvider.notifier).takeSnapshot()
          : null,
      utilitySnapshot: groups.contains(ActionGroup.utility)
          ? ref.read(utilityProvider.notifier).takeSnapshot()
          : null,
      lineUpSnapshot: groups.contains(ActionGroup.lineUp)
          ? ref.read(lineUpProvider.notifier).takeSnapshot()
          : null,
      imageSizeSnapshot: ref
          .read(imageWidgetSizeProvider.notifier)
          .takeSnapshotForIds(imageIds),
      textHeightSnapshot: ref
          .read(textWidgetHeightProvider.notifier)
          .takeSnapshotForIds(textIds),
    );
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
    if (action.group == ActionGroup.bulk) {
      final bulkSnapshot = action.bulkSnapshot;
      if (bulkSnapshot != null) {
        return bulkSnapshot.targetGroups.any(targetGroups.contains);
      }
      final transactionSnapshot = action.transactionSnapshot;
      if (transactionSnapshot != null) {
        return transactionSnapshot.targetGroups.any(targetGroups.contains);
      }
      return false;
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
        case ActionGroup.bulk:
          break;
      }
    }
  }

  void _clearAncillaryState(BulkActionSnapshot snapshot) {
    if (snapshot.imageSizeSnapshot.isNotEmpty) {
      ref
          .read(imageWidgetSizeProvider.notifier)
          .clearEntries(snapshot.imageSizeSnapshot.keys);
    }
    if (snapshot.textHeightSnapshot.isNotEmpty) {
      ref
          .read(textWidgetHeightProvider.notifier)
          .clearEntries(snapshot.textHeightSnapshot.keys);
    }
  }

  void _restoreBulkSnapshot(BulkActionSnapshot snapshot) {
    if (snapshot.agentSnapshot != null) {
      ref.read(agentProvider.notifier).restoreSnapshot(snapshot.agentSnapshot!);
    }
    if (snapshot.abilitySnapshot != null) {
      ref
          .read(abilityProvider.notifier)
          .restoreSnapshot(snapshot.abilitySnapshot!);
    }
    if (snapshot.drawingSnapshot != null) {
      ref
          .read(drawingProvider.notifier)
          .restoreSnapshot(snapshot.drawingSnapshot!);
    }
    if (snapshot.textSnapshot != null) {
      ref.read(textProvider.notifier).restoreSnapshot(snapshot.textSnapshot!);
    }
    if (snapshot.imageSnapshot != null) {
      ref
          .read(placedImageProvider.notifier)
          .restoreSnapshot(snapshot.imageSnapshot!);
    }
    if (snapshot.utilitySnapshot != null) {
      ref
          .read(utilityProvider.notifier)
          .restoreSnapshot(snapshot.utilitySnapshot!);
    }
    if (snapshot.lineUpSnapshot != null) {
      ref
          .read(lineUpProvider.notifier)
          .restoreSnapshot(snapshot.lineUpSnapshot!);
    }

    if (snapshot.imageSizeSnapshot.isNotEmpty) {
      ref
          .read(imageWidgetSizeProvider.notifier)
          .restoreSnapshot(snapshot.imageSizeSnapshot);
    }
    if (snapshot.textHeightSnapshot.isNotEmpty) {
      ref
          .read(textWidgetHeightProvider.notifier)
          .restoreSnapshot(snapshot.textHeightSnapshot);
    }
  }

  void _undoBulkAction(UserAction action) {
    final snapshot = action.bulkSnapshot;
    if (snapshot == null) return;

    _restoreBulkSnapshot(snapshot);
    poppedItems.add(action);
    ref.read(strategyProvider.notifier).setUnsaved();
    state = [...snapshot.actionStateBefore];
  }

  void _redoBulkAction(UserAction action) {
    final snapshot = action.bulkSnapshot;
    if (snapshot == null) return;

    _clearProvidersForGroups(snapshot.targetGroups);
    _clearAncillaryState(snapshot);

    final newState = _filterActionsForGroups(state, snapshot.targetGroups)
      ..add(poppedItems.removeLast());

    ref.read(strategyProvider.notifier).setUnsaved();
    ref.read(abilityBarProvider.notifier).updateData(null);
    state = newState;
  }

  void _undoTransaction(UserAction action) {
    final snapshot = action.transactionSnapshot;
    if (snapshot == null) return;

    _restoreBulkSnapshot(snapshot.before);
    final newState = [...state];
    poppedItems.add(newState.removeLast());
    ref.read(strategyProvider.notifier).setUnsaved();
    state = newState;
  }

  void _redoTransaction(UserAction action) {
    final snapshot = action.transactionSnapshot;
    if (snapshot == null) return;

    _restoreBulkSnapshot(snapshot.after);
    final newState = [...state];
    newState.add(poppedItems.removeLast());
    ref.read(strategyProvider.notifier).setUnsaved();
    ref.read(abilityBarProvider.notifier).updateData(null);
    state = newState;
  }
}
