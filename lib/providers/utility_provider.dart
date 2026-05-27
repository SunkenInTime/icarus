import 'dart:convert';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

final utilityProvider =
    NotifierProvider<UtilityProvider, List<PlacedUtility>>(UtilityProvider.new);

class UtilityProviderSnapshot {
  final List<PlacedUtility> utilities;
  final List<PlacedUtility> poppedUtilities;

  const UtilityProviderSnapshot({
    required this.utilities,
    required this.poppedUtilities,
  });
}

class UtilityProvider extends Notifier<List<PlacedUtility>> {
  List<PlacedUtility> poppedUtilities = [];
  final Map<String, ActionObjectState> _pendingEditBefore = {};

  @override
  List<PlacedUtility> build() {
    return [];
  }

  void addUtility(PlacedUtility utility) {
    final action = UserAction(
      type: ActionType.addition,
      id: utility.id,
      group: ActionGroup.utility,
      objectDelta: ObjectHistoryDelta(
        after: ActionObjectState.utility(utility),
      ),
    );
    ref.read(actionProvider.notifier).addAction(action);

    state = [...state, utility];
  }

  void removeUtilityAsAction(String id) {
    final index = PlacedWidget.getIndexByID(id, state);
    if (index < 0) return;

    ref.read(actionProvider.notifier).addAction(
          UserAction(
            type: ActionType.deletion,
            id: id,
            group: ActionGroup.utility,
            objectDelta: ObjectHistoryDelta(
              before: ActionObjectState.utility(state[index]),
            ),
          ),
        );
    removeUtility(id);
  }

  void updatePosition(Offset position, String id) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;
    final before = ActionObjectState.utility(newState[index]);
    newState[index].updatePosition(position);
    final temp = newState.removeAt(index);

    final action = UserAction(
      type: ActionType.edit,
      id: id,
      group: ActionGroup.utility,
      objectDelta: ObjectHistoryDelta(
        before: before,
        after: ActionObjectState.utility(temp),
      ),
    );
    ref.read(actionProvider.notifier).addAction(action);

    state = [...newState, temp];
  }

  void updateRotation(int index, double rotation, double length) {
    final newState = [...state];
    final before = _pendingEditBefore.remove(newState[index].id) ??
        ActionObjectState.utility(newState[index]);
    newState[index].updateRotation(rotation, length);
    final action = UserAction(
      type: ActionType.edit,
      id: newState[index].id,
      group: ActionGroup.utility,
      objectDelta: ObjectHistoryDelta(
        before: before,
        after: ActionObjectState.utility(newState[index]),
      ),
    );
    ref.read(actionProvider.notifier).addAction(action);
    state = newState;
  }

  void updateCustomRectangleSize({
    required String id,
    required double widthMeters,
    required double lengthMeters,
  }) {
    updateCustomShapeGeometry(
      id: id,
      widthMeters: widthMeters,
      lengthMeters: lengthMeters,
    );
  }

  void updateCustomCircleDiameter({
    required String id,
    required double diameterMeters,
  }) {
    updateCustomShapeGeometry(id: id, diameterMeters: diameterMeters);
  }

  void updateCustomShapeGeometry({
    required String id,
    Offset? position,
    double? diameterMeters,
    double? widthMeters,
    double? lengthMeters,
  }) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;

    final utility = newState[index];
    final nextPosition = position ?? utility.position;
    final nextDiameter = diameterMeters ?? utility.customDiameter;
    final nextWidth = widthMeters ?? utility.customWidth;
    final nextLength = lengthMeters ?? utility.customLength;

    final hasGeometryChange = utility.position != nextPosition ||
        utility.customDiameter != nextDiameter ||
        utility.customWidth != nextWidth ||
        utility.customLength != nextLength;
    if (!hasGeometryChange) return;

    final before = ActionObjectState.utility(utility);
    utility.updateCustomShapeGeometry(
      newPosition: position,
      newDiameter: diameterMeters,
      newWidth: widthMeters,
      newLength: lengthMeters,
    );

    final action = UserAction(
      type: ActionType.edit,
      id: id,
      group: ActionGroup.utility,
      objectDelta: ObjectHistoryDelta(
        before: before,
        after: ActionObjectState.utility(utility),
      ),
    );
    ref.read(actionProvider.notifier).addAction(action);
    state = newState;
  }

  void updateRotationHistory(int index) {
    if (index < 0 || index >= state.length) return;
    _pendingEditBefore[state[index].id] = ActionObjectState.utility(state[index]);
  }

  void switchSides() {
    final newState = [...state];
    final mapState = ref.read(mapProvider);
    final mapScale = Maps.mapScale[mapState.currentMap] ?? 1.0;
    final agentSize = ref.read(strategySettingsProvider).agentSize;
    final abilitySize = ref.read(strategySettingsProvider).abilitySize;
    for (final utility in newState) {
      utility.switchSides(
        mapScale: mapScale,
        agentSize: agentSize,
        abilitySize: abilitySize,
      );
    }
    for (final utility in poppedUtilities) {
      utility.switchSides(
        mapScale: mapScale,
        agentSize: agentSize,
        abilitySize: abilitySize,
      );
    }

    state = newState;
  }

  void undoAction(UserAction action) {
    final delta = action.objectDelta;
    if (delta == null) {
      switch (action.type) {
        case ActionType.addition:
          removeUtility(action.id);
          return;
        case ActionType.deletion:
          if (poppedUtilities.isEmpty) return;
          _upsertUtility(clonePlacedUtility(poppedUtilities.removeLast()));
          return;
        case ActionType.edit:
          final index = PlacedWidget.getIndexByID(action.id, state);
          if (index < 0) return;
          final newState = [...state];
          newState[index].undoAction();
          state = newState;
          return;
        case ActionType.bulkDeletion:
        case ActionType.transaction:
          return;
      }
    }
    switch (action.type) {
      case ActionType.addition:
        removeUtility(action.id);
        return;
      case ActionType.deletion:
        final before = delta.before?.utility;
        if (before == null) {
          return;
        }
        _upsertUtility(clonePlacedUtility(before));
        return;
      case ActionType.edit:
        final before = delta.before?.utility;
        if (before == null) return;
        _upsertUtility(clonePlacedUtility(before));
        return;
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
  }

  void redoAction(UserAction action) {
    final delta = action.objectDelta;
    if (delta == null) {
      final newState = [...state];
      switch (action.type) {
        case ActionType.addition:
          if (poppedUtilities.isEmpty) return;
          _upsertUtility(clonePlacedUtility(poppedUtilities.removeLast()));
          return;
        case ActionType.deletion:
          removeUtility(action.id);
          return;
        case ActionType.edit:
          final index = PlacedWidget.getIndexByID(action.id, newState);
          if (index < 0) return;
          newState[index].redoAction();
          state = newState;
          return;
        case ActionType.bulkDeletion:
        case ActionType.transaction:
          return;
      }
    }
    switch (action.type) {
      case ActionType.addition:
        final after = delta.after?.utility;
        if (after == null) return;
        _upsertUtility(clonePlacedUtility(after));
        return;
      case ActionType.deletion:
        removeUtility(action.id);
        return;
      case ActionType.edit:
        final after = delta.after?.utility;
        if (after == null) return;
        _upsertUtility(clonePlacedUtility(after));
        return;
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
  }

  void removeUtility(String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;
    final removedUtility = newState.removeAt(index);
    poppedUtilities.removeWhere((utility) => utility.id == id);
    poppedUtilities.add(clonePlacedUtility(removedUtility));

    state = newState;
  }

  void fromHive(List<PlacedUtility> hiveUtilities) {
    poppedUtilities = [];
    _pendingEditBefore.clear();
    state = hiveUtilities;
  }

  void clearAll() {
    poppedUtilities = [];
    _pendingEditBefore.clear();
    state = [];
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

  UtilityProviderSnapshot takeSnapshot() {
    return UtilityProviderSnapshot(
      utilities: state
          .map((utility) => utility.snapshotCopy<PlacedUtility>())
          .toList(),
      poppedUtilities: poppedUtilities
          .map((utility) => utility.snapshotCopy<PlacedUtility>())
          .toList(),
    );
  }

  void restoreSnapshot(UtilityProviderSnapshot snapshot) {
    poppedUtilities = snapshot.poppedUtilities
        .map((utility) => utility.snapshotCopy<PlacedUtility>())
        .toList();
    _pendingEditBefore.clear();
    state = snapshot.utilities
        .map((utility) => utility.snapshotCopy<PlacedUtility>())
        .toList();
  }

  void _upsertUtility(PlacedUtility utility) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(utility.id, newState);
    if (index < 0) {
      newState.add(utility);
    } else {
      newState[index] = utility;
    }
    state = newState;
  }
}
