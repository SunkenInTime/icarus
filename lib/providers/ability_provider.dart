import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

final abilityProvider =
    NotifierProvider<AbilityProvider, List<PlacedAbility>>(AbilityProvider.new);

class AbilityProviderSnapshot {
  final List<PlacedAbility> abilities;
  final List<PlacedAbility> poppedAbilities;

  const AbilityProviderSnapshot({
    required this.abilities,
    required this.poppedAbilities,
  });
}

class AbilitySnapshot {
  final String id;
  final List<PlacedAbility> snapshot;

  AbilitySnapshot({required this.id, required this.snapshot});
}

class AbilityProvider extends Notifier<List<PlacedAbility>> {
  List<PlacedAbility> poppedAbility = [];
  final Map<String, ActionObjectState> _pendingEditBefore = {};
  List<AbilitySnapshot> snapshots = [];
  @override
  List<PlacedAbility> build() {
    return [];
  }

  void addAbility(PlacedAbility placedAbility) {
    final action = UserAction(
        type: ActionType.addition,
        id: placedAbility.id,
        group: ActionGroup.ability,
        objectDelta: ObjectHistoryDelta(
          after: ActionObjectState.ability(placedAbility),
        ));
    ref.read(actionProvider.notifier).addAction(action);

    state = [...state, placedAbility];
  }

  void removeAbilityAsAction(String id) {
    final index = PlacedWidget.getIndexByID(id, state);
    if (index < 0) return;

    ref.read(actionProvider.notifier).addAction(
          UserAction(
            type: ActionType.deletion,
            id: id,
            group: ActionGroup.ability,
            objectDelta: ObjectHistoryDelta(
              before: ActionObjectState.ability(state[index]),
            ),
          ),
        );
    removeAbility(id);
  }

  void updatePosition(Offset position, String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;

    final ability = newState[index];
    final before = ActionObjectState.ability(ability);

    final coordinateSystem = CoordinateSystem.instance;
    final mapState = ref.read(mapProvider);
    final mapScale = Maps.mapScale[mapState.currentMap] ?? 1.0;

    final abilitySize = ref.read(strategySettingsProvider).abilitySize;

    final centerOffset = ability.data.abilityData!
        .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize);

    final centerPosition =
        Offset(position.dx + centerOffset.dx, position.dy + centerOffset.dy);

    if (coordinateSystem.isOutOfBounds(centerPosition)) {
      removeAbilityAsAction(id);
      return;
    }

    newState[index].updatePosition(position);

    final temp = newState.removeAt(index);

    final action = UserAction(
      type: ActionType.edit,
      id: id,
      group: ActionGroup.ability,
      objectDelta: ObjectHistoryDelta(
        before: before,
        after: ActionObjectState.ability(temp),
      ),
    );
    ref.read(actionProvider.notifier).addAction(action);

    state = [...newState, temp];
  }

  void switchSides() {
    if (state.isEmpty && poppedAbility.isEmpty) return;

    final newState = <PlacedAbility>[...state];
    final mapState = ref.read(mapProvider);
    final mapScale = Maps.mapScale[mapState.currentMap] ?? 1.0;
    final abilitySizeSetting = ref.read(strategySettingsProvider).abilitySize;

    for (final ability in state) {
      ability.switchSides(mapScale: mapScale, abilitySize: abilitySizeSetting);
    }

    for (final ability in poppedAbility) {
      ability.switchSides(mapScale: mapScale, abilitySize: abilitySizeSetting);
    }

    state = newState;
  }

  void updateRotation(int index, double rotation, double length) {
    updateGeometry(index, rotation: rotation, length: length);
  }

  void updateGeometry(
    int index, {
    double? rotation,
    double? length,
    List<double>? armLengthsMeters,
  }) {
    final newState = [...state];
    final before = _pendingEditBefore.remove(newState[index].id) ??
        ActionObjectState.ability(newState[index]);
    newState[index].updateGeometry(
      newRotation: rotation,
      newLength: length,
      newArmLengthsMeters: armLengthsMeters,
    );
    final action = UserAction(
      type: ActionType.edit,
      id: newState[index].id,
      group: ActionGroup.ability,
      objectDelta: ObjectHistoryDelta(
        before: before,
        after: ActionObjectState.ability(newState[index]),
      ),
    );
    ref.read(actionProvider.notifier).addAction(action);
    state = newState;
  }

  void updateArmLengths(int index, List<double> armLengthsMeters) {
    updateGeometry(index, armLengthsMeters: armLengthsMeters);
  }

  void updateVisualState(int index, AbilityVisualState visualState) {
    final newState = [...state];
    if (index < 0 || index >= newState.length) {
      return;
    }

    final before = ActionObjectState.ability(newState[index]);
    newState[index].updateVisualState(visualState);
    ref.read(actionProvider.notifier).addAction(
          UserAction(
            type: ActionType.edit,
            id: newState[index].id,
            group: ActionGroup.ability,
            objectDelta: ObjectHistoryDelta(
              before: before,
              after: ActionObjectState.ability(newState[index]),
            ),
          ),
        );
    state = newState;
  }

  // void updateLength(int index, double length) {
  //   final newState = [...state];
  //   updateLengthHistory(index);
  //   newState[index].updateLength(length);

  //   final action = UserAction(
  //       type: ActionType.edit,
  //       id: newState[index].id,
  //       group: ActionGroup.ability);
  //   ref.read(actionProvider.notifier).addAction(action);
  //   state = newState;
  // }

  void updateRotationHistory(int index) {
    updateGeometryHistory(index);
  }

  void updateGeometryHistory(int index) {
    if (index < 0 || index >= state.length) return;
    _pendingEditBefore[state[index].id] = ActionObjectState.ability(state[index]);
  }

  // void updateLengthHistory(int index) {
  //   final newState = [...state];

  //   newState[index].updateLengthHistory();

  //   state = newState;
  // }

  void undoAction(UserAction action) {
    final delta = action.objectDelta;
    if (delta == null) {
      switch (action.type) {
        case ActionType.addition:
          removeAbility(action.id);
          return;
        case ActionType.deletion:
          if (poppedAbility.isEmpty) return;
          final newState = [...state];
          newState.add(clonePlacedAbility(poppedAbility.removeLast()));
          state = newState;
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
        removeAbility(action.id);
        return;
      case ActionType.deletion:
        final before = delta.before?.ability;
        if (before == null) return;
        _upsertAbility(clonePlacedAbility(before));
        return;
      case ActionType.edit:
        final before = delta.before?.ability;
        if (before == null) return;
        _upsertAbility(clonePlacedAbility(before));
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
          if (poppedAbility.isEmpty) return;
          newState.add(clonePlacedAbility(poppedAbility.removeLast()));
          state = newState;
          return;
        case ActionType.deletion:
          final index = PlacedWidget.getIndexByID(action.id, newState);
          if (index < 0) return;
          poppedAbility.add(clonePlacedAbility(newState.removeAt(index)));
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
    }
    switch (action.type) {
      case ActionType.addition:
        final after = delta.after?.ability;
        if (after == null) return;
        _upsertAbility(clonePlacedAbility(after));
        return;
      case ActionType.deletion:
        removeAbility(action.id);
        return;
      case ActionType.edit:
        final after = delta.after?.ability;
        if (after == null) return;
        _upsertAbility(clonePlacedAbility(after));
        return;
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
  }

  void removeAbility(String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;
    final removedAbility = newState.removeAt(index);
    poppedAbility.removeWhere((item) => item.id == id);
    poppedAbility.add(clonePlacedAbility(removedAbility));

    state = newState;
  }

  void fromHive(List<PlacedAbility> hiveAbilities) {
    poppedAbility = [];
    _pendingEditBefore.clear();
    state = hiveAbilities;
  }

  void clearAll() {
    poppedAbility = [];
    _pendingEditBefore.clear();
    state = [];
  }

  AbilityProviderSnapshot takeSnapshot() {
    return AbilityProviderSnapshot(
      abilities: state.map((ability) => clonePlacedAbility(ability)).toList(),
      poppedAbilities:
          poppedAbility.map((ability) => clonePlacedAbility(ability)).toList(),
    );
  }

  void restoreSnapshot(AbilityProviderSnapshot snapshot) {
    poppedAbility =
        snapshot.poppedAbilities.map((ability) => clonePlacedAbility(ability)).toList();
    _pendingEditBefore.clear();
    state = snapshot.abilities.map((ability) => clonePlacedAbility(ability)).toList();
  }

  void _upsertAbility(PlacedAbility ability) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(ability.id, newState);
    if (index < 0) {
      newState.add(ability);
    } else {
      newState[index] = ability;
    }
    state = newState;
  }

  String toJson() {
    final List<Map<String, dynamic>> jsonList =
        state.map((ability) => ability.toJson()).toList();
    return jsonEncode(jsonList);
  }

  static String objectToJson(List<PlacedAbility> abilities) {
    final List<Map<String, dynamic>> jsonList =
        abilities.map((ability) => ability.toJson()).toList();
    return jsonEncode(jsonList);
  }

  static List<PlacedAbility> fromJson(String jsonString) {
    final List<dynamic> jsonList = jsonDecode(jsonString);
    return jsonList
        .map((json) => PlacedAbility.fromJson(json as Map<String, dynamic>))
        .toList();
  }
}
