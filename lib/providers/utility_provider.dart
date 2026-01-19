import 'dart:convert';
import 'dart:developer';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/map_provider.dart';

final utilityProvider =
    NotifierProvider<UtilityProvider, List<PlacedUtility>>(UtilityProvider.new);

class UtilityProvider extends Notifier<List<PlacedUtility>> {
  List<PlacedUtility> poppedUtilities = [];

  @override
  List<PlacedUtility> build() {
    return [];
  }

  void addUtility(PlacedUtility utility) {
    final action = UserAction(
      type: ActionType.addition,
      id: utility.id,
      group: ActionGroup.utility,
    );
    ref.read(actionProvider.notifier).addAction(action);

    state = [...state, utility];
  }

  void updatePosition(Offset position, String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;
    newState[index].updatePosition(position);

    final temp = newState.removeAt(index);

    final action =
        UserAction(type: ActionType.edit, id: id, group: ActionGroup.utility);
    ref.read(actionProvider.notifier).addAction(action);

    state = [...newState, temp];
  }

  void updateRotation(int index, double rotation, double length) {
    final newState = [...state];
    updateRotationHistory(index);
    newState[index].updateRotation(rotation, length);
    final action = UserAction(
        type: ActionType.edit,
        id: newState[index].id,
        group: ActionGroup.utility);
    ref.read(actionProvider.notifier).addAction(action);
    state = newState;
  }

  void updateRotationHistory(int index) {
    final newState = [...state];

    newState[index].updateRotationHistory();

    state = newState;
  }

  void switchSides() {
    final newState = [...state];

    for (final utility in newState) {
      utility.switchSides();
    }
    for (final utility in poppedUtilities) {
      utility.switchSides();
    }

    state = newState;
  }

  void undoAction(UserAction action) {
    switch (action.type) {
      case ActionType.addition:
        removeUtility(action.id);
      case ActionType.deletion:
        if (poppedUtilities.isEmpty) {
          return;
        }

        final newState = [...state];

        newState.add(poppedUtilities.removeLast());
        state = newState;
      case ActionType.edit:
        final newState = [...state];

        final index = PlacedWidget.getIndexByID(action.id, newState);

        // log("Previous rotation: ${newState[index].rotation} Previous length: ${newState[index].length}");
        newState[index].undoAction();

        // log("Current rotation: ${newState[index].rotation} Current length: ${newState[index].length}");
        state = newState;
      case ActionType.bulkDeletion:
        // Handled by ActionProvider
        break;
    }
  }

  void redoAction(UserAction action) {
    final newState = [...state];

    try {
      switch (action.type) {
        case ActionType.addition:
          final index = PlacedWidget.getIndexByID(action.id, poppedUtilities);
          newState.add(poppedUtilities.removeAt(index));

        case ActionType.deletion:
          final index = PlacedWidget.getIndexByID(action.id, poppedUtilities);

          poppedUtilities.add(newState.removeAt(index));
        case ActionType.edit:
          final index = PlacedWidget.getIndexByID(action.id, newState);
          newState[index].redoAction();
        case ActionType.bulkDeletion:
          // Handled by ActionProvider
          break;
      }
    } catch (_) {
      log("failed to find index");
    }
    state = newState;
  }

  void removeUtility(String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;
    final ability = newState.removeAt(index);
    poppedUtilities.add(ability);

    state = newState;
  }

  void fromHive(List<PlacedUtility> hiveUtilities) {
    poppedUtilities = [];
    state = hiveUtilities;
  }

  void clearAll() {
    poppedUtilities = [];
    state = [];
  }

  /// Returns all current items and clears the state (for bulk undo support)
  List<PlacedUtility> getItemsAndClear() {
    final items = List<PlacedUtility>.from(state);
    poppedUtilities = [];
    state = [];
    return items;
  }

  /// Restores items from a bulk undo operation
  void restoreItems(List<dynamic> items) {
    final utilities = items.cast<PlacedUtility>();
    state = [...state, ...utilities];
  }

  /// Removes items by matching objects (for bulk redo operation)
  void removeItems(List<dynamic> items) {
    final idsToRemove = items.cast<PlacedUtility>().map((u) => u.id).toSet();
    state = state.where((u) => !idsToRemove.contains(u.id)).toList();
  }

  String toJsonFromData(List<PlacedUtility> elements) {
    final List<Map<String, dynamic>> jsonList =
        elements.map((utility) => utility.toJson()).toList();
    return jsonEncode(jsonList);
  }

  String toJson() {
    final List<Map<String, dynamic>> jsonList =
        state.map((utility) => utility.toJson()).toList();
    return jsonEncode(jsonList);
  }

  static List<PlacedUtility> fromJson(String jsonString) {
    final List<dynamic> jsonList = jsonDecode(jsonString);
    return jsonList
        .map((json) => PlacedUtility.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  static String objectToJson(List<PlacedUtility> utilities) {
    final List<Map<String, dynamic>> jsonList =
        utilities.map((utility) => utility.toJson()).toList();
    return jsonEncode(jsonList);
  }
}
