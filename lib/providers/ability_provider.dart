import 'dart:convert';
import 'dart:developer' show log;
import 'dart:ui' show Offset;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

final abilityProvider =
    NotifierProvider<AbilityProvider, List<PlacedAbility>>(AbilityProvider.new);

class AbilitySnapshot {
  final String id;
  final List<PlacedAbility> snapshot;

  AbilitySnapshot({required this.id, required this.snapshot});
}

class AbilityProvider extends Notifier<List<PlacedAbility>> {
  List<PlacedAbility> poppedAbility = [];
  List<AbilitySnapshot> snapshots = [];
  @override
  List<PlacedAbility> build() {
    return [];
  }

  void addAbility(PlacedAbility placedAbility) {
    final action = UserAction(
        type: ActionType.addition,
        id: placedAbility.id,
        group: ActionGroup.ability);
    ref.read(actionProvider.notifier).addAction(action);

    state = [...state, placedAbility];
  }

  void updatePosition(Offset position, String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;

    final ability = newState[index];

    final coordinateSystem = CoordinateSystem.instance;
    final mapScale = ref.read(mapProvider.notifier).mapScale;

    final abilitySize = ref.read(strategySettingsProvider).abilitySize;

    final centerOffset = ability.data.abilityData!
        .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize);

    final centerPosition =
        Offset(position.dx + centerOffset.dx, position.dy + centerOffset.dy);

    if (coordinateSystem.isOutOfBounds(centerPosition)) {
      removeAbility(id);
      return;
    }

    log("Updating position of ability $id to $position, center at $centerPosition");
    newState[index].updatePosition(position);

    final temp = newState.removeAt(index);

    final action =
        UserAction(type: ActionType.edit, id: id, group: ActionGroup.ability);
    ref.read(actionProvider.notifier).addAction(action);

    state = [...newState, temp];
  }

  void switchSides() {
    // final newState = [...state];

    // for (PlacedAbility ability in newState) {
    //   final Offset abilitySize = ability.data.abilityData!.getAnchorPoint() +
    //       ability.data.abilityData!.getAnchorPoint();
    //   log(abilitySize.toString());
    //   // ability.position =
    //   //     Offset(1240 - abilitySize.dx - 6, 1000 - abilitySize.dy - 6) -
    //   //         ability.position;
    //   log("Previous position ${ability.position}");
    //   // ability.position = const Offset(1240, 1000) -
    //   //     ability.position -
    //   //     const Offset(6, 6) - //I still have no idea what minusing this 6 works
    //   //     abilitySize;
    // }

    // state = newState;
  }

  void updateRotation(int index, double rotation, double length) {
    final newState = [...state];
    updateRotationHistory(index);
    newState[index].updateRotation(rotation, length);
    final action = UserAction(
        type: ActionType.edit,
        id: newState[index].id,
        group: ActionGroup.ability);
    ref.read(actionProvider.notifier).addAction(action);
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
    final newState = [...state];

    newState[index].updateRotationHistory();

    state = newState;
  }

  // void updateLengthHistory(int index) {
  //   final newState = [...state];

  //   newState[index].updateLengthHistory();

  //   state = newState;
  // }

  void undoAction(UserAction action) {
    switch (action.type) {
      case ActionType.addition:
        log("We are attmepting to remove");
        removeAbility(action.id);
      case ActionType.deletion:
        if (poppedAbility.isEmpty) {
          log("Popped agents is empty");
          return;
        }

        final newState = [...state];

        newState.add(poppedAbility.removeLast());
        state = newState;
      case ActionType.edit:
        final newState = [...state];

        final index = PlacedWidget.getIndexByID(action.id, newState);

        log("Previous rotation: ${newState[index].rotation} Previous length: ${newState[index].length}");
        newState[index].undoAction();

        log("Current rotation: ${newState[index].rotation} Current length: ${newState[index].length}");
        state = newState;
    }
  }

  void redoAction(UserAction action) {
    final newState = [...state];

    try {
      switch (action.type) {
        case ActionType.addition:
          final index = PlacedWidget.getIndexByID(action.id, poppedAbility);
          newState.add(poppedAbility.removeAt(index));

        case ActionType.deletion:
          final index = PlacedWidget.getIndexByID(action.id, poppedAbility);

          poppedAbility.add(newState.removeAt(index));
        case ActionType.edit:
          final index = PlacedWidget.getIndexByID(action.id, newState);
          newState[index].redoAction();
      }
    } catch (_) {
      log("failed to find index");
    }
    state = newState;
  }

  void removeAbility(String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;
    final ability = newState.removeAt(index);
    poppedAbility.add(ability);

    state = newState;
  }

  void fromHive(List<PlacedAbility> hiveAbilities) {
    poppedAbility = [];
    state = hiveAbilities;
  }

  void clearAll() {
    poppedAbility = [];
    state = [];
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
