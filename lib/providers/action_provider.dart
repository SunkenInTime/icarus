import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
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

enum ActionGroup {
  agent,
  ability,
  drawing,
  text,
  image,
  utility,
  lineUp,
}

enum ActionType {
  addition,
  deletion,
  edit,
  bulkDeletion,
}

class UserAction {
  final ActionGroup group;
  final String id;
  final ActionType type;

  UserAction({
    required this.type,
    required this.id,
    required this.group,
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

/// Stores data for a bulk deletion action to enable undo/redo
class BulkActionData {
  final List<dynamic> agents;
  final List<dynamic> abilities;
  final List<dynamic> drawings;
  final List<dynamic> texts;
  final List<dynamic> images;
  final List<dynamic> utilities;
  final List<dynamic> lineUps;
  final List<UserAction> actions;

  BulkActionData({
    this.agents = const [],
    this.abilities = const [],
    this.drawings = const [],
    this.texts = const [],
    this.images = const [],
    this.utilities = const [],
    this.lineUps = const [],
    this.actions = const [],
  });

  bool get isEmpty =>
      agents.isEmpty &&
      abilities.isEmpty &&
      drawings.isEmpty &&
      texts.isEmpty &&
      images.isEmpty &&
      utilities.isEmpty &&
      lineUps.isEmpty;
}

final actionProvider =
    NotifierProvider<ActionProvider, List<UserAction>>(ActionProvider.new);

class ActionProvider extends Notifier<List<UserAction>> {
  List<UserAction> poppedItems = [];

  /// Storage for bulk action data, keyed by action id
  final Map<String, BulkActionData> _bulkActionData = {};

  @override
  List<UserAction> build() {
    return [];
  }

  void addAction(UserAction action) {
    ref.read(strategyProvider.notifier).setUnsaved();
    if (action.group != ActionGroup.ability) {
      ref
          .read(abilityBarProvider.notifier)
          .updateData(null); // Make the agent tab disappear after an action
    }
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

    // Handle bulk deletion redo
    if (poppedAction.type == ActionType.bulkDeletion) {
      _redoBulkDeletion(poppedAction);
      return;
    }

    log(poppedItems.length.toString());
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
    }

    final newState = [...state];
    newState.add(poppedItems.removeLast());

    ref.read(strategyProvider.notifier).setUnsaved();

    state = newState;
    // log("\n Current state \n ${state.toString()}");
  }

  void _redoBulkDeletion(UserAction action) {
    final bulkData = _bulkActionData[action.id];
    if (bulkData == null) return;

    // Remove the restored actions from state
    final actionsToRemove = bulkData.actions.map((a) => a.id).toSet();
    final newState = state.where((a) => !actionsToRemove.contains(a.id)).toList();

    // Clear items from each provider again
    ref.read(agentProvider.notifier).removeItems(bulkData.agents);
    ref.read(abilityProvider.notifier).removeItems(bulkData.abilities);
    ref.read(drawingProvider.notifier).removeItems(bulkData.drawings);
    ref.read(textProvider.notifier).removeItems(bulkData.texts);
    ref.read(placedImageProvider.notifier).removeItems(bulkData.images);
    ref.read(utilityProvider.notifier).removeItems(bulkData.utilities);
    ref.read(lineUpProvider.notifier).removeItems(bulkData.lineUps);

    // Move the bulk action back to state
    newState.add(poppedItems.removeLast());
    state = newState;

    ref.read(strategyProvider.notifier).setUnsaved();
  }

  void undoAction() {
    // log("Undo action was triggered");

    if (state.isEmpty) return;
    final currentAction = state.last;

    // Handle bulk deletion undo
    if (currentAction.type == ActionType.bulkDeletion) {
      _undoBulkDeletion(currentAction);
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
    }
    // log("Undo action was called");
    final newState = [...state];
    poppedItems.add(newState.removeLast());

    ref.read(strategyProvider.notifier).setUnsaved();

    state = newState;
    // log("\n Current state \n ${state.toString()}");

    // log("\n Popped State \n ${poppedItems.toString()}");
  }

  void _undoBulkDeletion(UserAction action) {
    final bulkData = _bulkActionData[action.id];
    if (bulkData == null) return;

    // Restore items to each provider
    ref.read(agentProvider.notifier).restoreItems(bulkData.agents);
    ref.read(abilityProvider.notifier).restoreItems(bulkData.abilities);
    ref.read(drawingProvider.notifier).restoreItems(bulkData.drawings);
    ref.read(textProvider.notifier).restoreItems(bulkData.texts);
    ref.read(placedImageProvider.notifier).restoreItems(bulkData.images);
    ref.read(utilityProvider.notifier).restoreItems(bulkData.utilities);
    ref.read(lineUpProvider.notifier).restoreItems(bulkData.lineUps);

    // Move the bulk action to poppedItems
    final newState = [...state];
    poppedItems.add(newState.removeLast());

    // Restore the individual actions that were active before the bulk delete
    state = [...newState, ...bulkData.actions];

    ref.read(strategyProvider.notifier).setUnsaved();
  }

  /// Clears all actions with undo support (for user-initiated "Clear all" button)
  void clearAllActions() {
    // Get all items from each provider before clearing
    final agents = ref.read(agentProvider.notifier).getItemsAndClear();
    final abilities = ref.read(abilityProvider.notifier).getItemsAndClear();
    final drawings = ref.read(drawingProvider.notifier).getItemsAndClear();
    final texts = ref.read(textProvider.notifier).getItemsAndClear();
    final images = ref.read(placedImageProvider.notifier).getItemsAndClear();
    final utilities = ref.read(utilityProvider.notifier).getItemsAndClear();
    final lineUps = ref.read(lineUpProvider.notifier).getItemsAndClear();

    // Store bulk action data if there were any items
    final bulkData = BulkActionData(
      agents: agents,
      abilities: abilities,
      drawings: drawings,
      texts: texts,
      images: images,
      utilities: utilities,
      lineUps: lineUps,
      actions: List.from(state),
    );

    if (!bulkData.isEmpty) {
      final actionId = const Uuid().v4();
      _bulkActionData[actionId] = bulkData;

      // Create a bulk action - using agent as a placeholder group
      final bulkAction = UserAction(
        type: ActionType.bulkDeletion,
        id: actionId,
        group: ActionGroup.agent,
      );

      // Clear popped items since we're starting fresh
      poppedItems = [];
      state = [bulkAction];
    } else {
      poppedItems = [];
      state = [];
    }

    ref.read(imageWidgetSizeProvider.notifier).clearAll();
    ref.read(textWidgetHeightProvider.notifier).clearAll();
    ref.read(strategyProvider.notifier).setUnsaved();
  }

  /// Hard reset - clears all state without undo history.
  /// Use this when switching strategies or pages (not for user-initiated clears).
  void hardClearAll() {
    poppedItems = [];
    _bulkActionData.clear();
    ref.read(agentProvider.notifier).clearAll();
    ref.read(abilityProvider.notifier).clearAll();
    ref.read(drawingProvider.notifier).clearAll();
    ref.read(textProvider.notifier).clearAll();
    ref.read(placedImageProvider.notifier).clearAll();
    ref.read(utilityProvider.notifier).clearAll();
    ref.read(lineUpProvider.notifier).clearAll();

    ref.read(imageWidgetSizeProvider.notifier).clearAll();
    ref.read(textWidgetHeightProvider.notifier).clearAll();
    state = [];
  }

  void clearAction(ActionGroup group) {
    // Get the actions that will be removed
    final removedActions = state.where((action) => action.group == group).toList();

    // Get items from the specific provider before clearing
    List<dynamic> clearedItems = [];
    switch (group) {
      case ActionGroup.agent:
        clearedItems = ref.read(agentProvider.notifier).getItemsAndClear();
      case ActionGroup.ability:
        clearedItems = ref.read(abilityProvider.notifier).getItemsAndClear();
      case ActionGroup.drawing:
        clearedItems = ref.read(drawingProvider.notifier).getItemsAndClear();
      case ActionGroup.text:
        clearedItems = ref.read(textProvider.notifier).getItemsAndClear();
      case ActionGroup.image:
        clearedItems = ref.read(placedImageProvider.notifier).getItemsAndClear();
      case ActionGroup.utility:
        clearedItems = ref.read(utilityProvider.notifier).getItemsAndClear();
      case ActionGroup.lineUp:
        clearedItems = ref.read(lineUpProvider.notifier).getItemsAndClear();
    }

    // Only create bulk action if there were items to clear
    if (clearedItems.isNotEmpty) {
      final actionId = const Uuid().v4();

      // Create bulk data with only the relevant group populated
      final bulkData = BulkActionData(
        agents: group == ActionGroup.agent ? clearedItems : [],
        abilities: group == ActionGroup.ability ? clearedItems : [],
        drawings: group == ActionGroup.drawing ? clearedItems : [],
        texts: group == ActionGroup.text ? clearedItems : [],
        images: group == ActionGroup.image ? clearedItems : [],
        utilities: group == ActionGroup.utility ? clearedItems : [],
        lineUps: group == ActionGroup.lineUp ? clearedItems : [],
        actions: removedActions,
      );
      _bulkActionData[actionId] = bulkData;

      final bulkAction = UserAction(
        type: ActionType.bulkDeletion,
        id: actionId,
        group: group,
      );

      // Filter out actions of this group from state and poppedItems
      final newState = state.where((action) => action.group != group).toList();
      poppedItems = poppedItems.where((action) => action.group != group).toList();

      // Add the bulk action
      state = [...newState, bulkAction];
    }

    ref.read(strategyProvider.notifier).setUnsaved();
  }
}
