import 'dart:convert';
import 'dart:developer';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

import '../const/placed_classes.dart';

final agentProvider =
    NotifierProvider<AgentProvider, List<PlacedAgent>>(AgentProvider.new);

class AgentProvider extends Notifier<List<PlacedAgent>> {
  List<PlacedAgent> poppedAgents = [];

  @override
  List<PlacedAgent> build() {
    return [];
  }

  void addAgent(PlacedAgent placedAgent) {
    final action = UserAction(
      type: ActionType.addition,
      id: placedAgent.id,
      group: ActionGroup.agent,
    );

    ref.read(actionProvider.notifier).addAction(action);
    state = [...state, placedAgent];
  }

  void removeAgent(String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;
    final agent = newState.removeAt(index);
    poppedAgents.add(agent);

    state = newState;
  }

  void toggleAgentState(String id) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;
    newState[index].state = newState[index].state == AgentState.dead
        ? AgentState.none
        : AgentState.dead;

    final action =
        UserAction(type: ActionType.edit, id: id, group: ActionGroup.agent);
    ref.read(actionProvider.notifier).addAction(action);

    state = newState;
  }

  void updatePosition(Offset position, String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);
    // ADD a check that if the position is not outt of the screen

    final abilitySize = ref.read(strategySettingsProvider).abilitySize;

    final centerPosition =
        Offset(position.dx + abilitySize / 2, position.dy + abilitySize / 2);
    final coordinateSystem = CoordinateSystem.instance;

    if (coordinateSystem.isOutOfBounds(centerPosition)) {
      removeAgent(id);
      return;
    }
    if (index < 0) return;
    newState[index].updatePosition(position);

    final temp = newState.removeAt(index);

    final action =
        UserAction(type: ActionType.edit, id: id, group: ActionGroup.agent);
    ref.read(actionProvider.notifier).addAction(action);

    state = [...newState, temp];
  }

  void undoAction(UserAction action) {
    log("I tried to remove a deleted item");

    switch (action.type) {
      case ActionType.addition:
        log("We are attmepting to remove");
        removeAgent(action.id);
      case ActionType.deletion:
        if (poppedAgents.isEmpty) {
          log("Popped agents is empty");
          return;
        }
        log("I tried to remove a deleted item");
        final newState = [...state];

        newState.add(poppedAgents.removeLast());
        state = newState;
      case ActionType.edit:
        undoPosition(action.id);
    }
  }

  void undoPosition(String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;

    newState[index].undoAction();

    state = newState;
  }

  void redoAction(UserAction action) {
    final newState = [...state];

    try {
      switch (action.type) {
        case ActionType.addition:
          final index = PlacedWidget.getIndexByID(action.id, poppedAgents);
          newState.add(poppedAgents.removeAt(index));

        case ActionType.deletion:
          final index = PlacedWidget.getIndexByID(action.id, poppedAgents);

          poppedAgents.add(newState.removeAt(index));
        case ActionType.edit:
          final index = PlacedWidget.getIndexByID(action.id, newState);
          newState[index].redoAction();
      }
    } catch (_) {
      log("failed to find index");
    }
    state = newState;
  }

  String toJson() {
    final List<Map<String, dynamic>> jsonList =
        state.map((agent) => agent.toJson()).toList();
    return jsonEncode(jsonList);
  }

  static String objectToJson(List<PlacedAgent> agents) {
    final List<Map<String, dynamic>> jsonList =
        agents.map((agent) => agent.toJson()).toList();
    return jsonEncode(jsonList);
  }

  void fromHive(List<PlacedAgent> hiveAgents) {
    poppedAgents = [];
    state = hiveAgents;
  }

  static List<PlacedAgent> fromJson(String jsonString) {
    final List<dynamic> jsonList = jsonDecode(jsonString);
    return jsonList
        .map((json) => PlacedAgent.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  @override
  String toString() {
    String output = "[";

    for (PlacedAgent agent in state) {
      output += "Name: ${agent.type}, Position: ${agent.position}, ";
    }

    output += "]";

    return output;
  }

  void switchSides() {
    if (state.isEmpty) return;

    final coordinateSystem = CoordinateSystem.instance;
    final agentSizeSetting = ref.read(strategySettingsProvider).agentSize;

    // Convert screen-pixel agent size into normalized coordinate units.
    // The agent widget is square in screen pixels, but the normalized space
    // has a different aspect ratio, so wNorm and hNorm may differ.
    final agentScreenPx = coordinateSystem.scale(agentSizeSetting);
    final wNorm = (agentScreenPx / coordinateSystem.effectiveSize.width) *
        coordinateSystem.normalizedWidth;
    final hNorm = (agentScreenPx / coordinateSystem.effectiveSize.height) *
        coordinateSystem.normalizedHeight;

    final newState = <PlacedAgent>[];

    for (final agent in state) {
      // Flip over both axes, accounting for top-left positioning:
      // x' = normalizedWidth  - x - wNorm
      // y' = normalizedHeight - y - hNorm
      final flippedX =
          coordinateSystem.normalizedWidth - agent.position.dx - wNorm;
      final flippedY =
          coordinateSystem.normalizedHeight - agent.position.dy - hNorm;

      agent.position = Offset(flippedX, flippedY);
      newState.add(agent);
    }

    state = newState;
  }

  void clearAll() {
    poppedAgents = [];
    state = [];
  }
}
