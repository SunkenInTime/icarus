import 'dart:convert';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
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

    utility.updateCustomShapeGeometry(
      newPosition: position,
      newDiameter: diameterMeters,
      newWidth: widthMeters,
      newLength: lengthMeters,
    );

    final action =
        UserAction(type: ActionType.edit, id: id, group: ActionGroup.utility);
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
    final mapState = ref.read(mapProvider);
    final mapScale = Maps.mapScale[mapState.currentMap] ?? 1.0;
    final abilitySize = ref.read(strategySettingsProvider).abilitySize;
    for (final utility in newState) {
      utility.switchSides(mapScale: mapScale, abilitySize: abilitySize);
    }
    for (final utility in poppedUtilities) {
      utility.switchSides(mapScale: mapScale, abilitySize: abilitySize);
    }

    state = newState;
  }

  void undoAction(UserAction action) {
    switch (action.type) {
      case ActionType.addition:
        removeUtility(action.id);
        return;
      case ActionType.deletion:
        final index = PlacedWidget.getIndexByID(action.id, poppedUtilities);
        if (index < 0) {
          return;
        }

        final newState = [...state];

        final restoredUtility = poppedUtilities.removeAt(index);
        newState.add(restoredUtility);
        state = newState;
        return;
      case ActionType.edit:
        final newState = [...state];

        final index = PlacedWidget.getIndexByID(action.id, newState);
        if (index < 0) return;

        newState[index].undoAction();
        state = newState;
        return;
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
  }

  void redoAction(UserAction action) {
    final newState = [...state];

    try {
      switch (action.type) {
        case ActionType.addition:
          final index = PlacedWidget.getIndexByID(action.id, poppedUtilities);
          if (index < 0) return;
          final restoredUtility = poppedUtilities.removeAt(index);
          newState.add(restoredUtility);
          state = newState;
          return;

        case ActionType.deletion:
          final index = PlacedWidget.getIndexByID(action.id, newState);
          if (index < 0) return;
          poppedUtilities.add(newState.removeAt(index));
          state = newState;
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
    } catch (_) {}
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
    state = snapshot.utilities
        .map((utility) => utility.snapshotCopy<PlacedUtility>())
        .toList();
  }
}
