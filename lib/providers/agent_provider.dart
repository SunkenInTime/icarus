import 'dart:convert';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/const/utilities.dart';
import 'package:uuid/uuid.dart';

import 'package:icarus/const/placed_classes.dart';

final agentProvider =
    NotifierProvider<AgentProvider, List<PlacedAgentNode>>(AgentProvider.new);

class AgentProviderSnapshot {
  final List<PlacedAgentNode> agents;
  final List<PlacedAgentNode> poppedAgents;

  const AgentProviderSnapshot({
    required this.agents,
    required this.poppedAgents,
  });
}

class AgentProvider extends Notifier<List<PlacedAgentNode>> {
  List<PlacedAgentNode> poppedAgents = [];
  static const _uuid = Uuid();

  @override
  List<PlacedAgentNode> build() {
    return [];
  }

  void addAgent(PlacedAgentNode placedAgent) {
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
    poppedAgents.add(newState.removeAt(index));

    state = newState;
  }

  void removeAgentAsAction(String id) {
    if (!state.any((agent) => agent.id == id)) return;

    ref.read(actionProvider.notifier).addAction(
          UserAction(
            type: ActionType.deletion,
            id: id,
            group: ActionGroup.agent,
          ),
        );
    removeAgent(id);
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

    final agentSize = ref.read(strategySettingsProvider).agentSize;

    final centerPosition =
        Offset(position.dx + agentSize / 2, position.dy + agentSize / 2);
    final coordinateSystem = CoordinateSystem.instance;

    if (coordinateSystem.isOutOfBounds(centerPosition)) {
      removeAgentAsAction(id);
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

  String? duplicateAgentAt({
    required String sourceId,
    required Offset position,
  }) {
    final agentSize = ref.read(strategySettingsProvider).agentSize;
    final centerPosition =
        Offset(position.dx + agentSize / 2, position.dy + agentSize / 2);
    final coordinateSystem = CoordinateSystem.instance;
    if (coordinateSystem.isOutOfBounds(centerPosition)) return null;

    final sourceIndex = PlacedWidget.getIndexByID(sourceId, state);
    if (sourceIndex < 0) return null;

    final sourceAgent = state[sourceIndex];
    final duplicatedAgent =
        _duplicateNode(sourceAgent, id: _uuid.v4(), position: position);
    addAgent(duplicatedAgent);
    return duplicatedAgent.id;
  }

  void updateViewConeHistory(String id) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;
    final node = newState[index];
    if (node is! PlacedViewConeAgent) return;
    node.updateGeometryHistory();
    state = newState;
  }

  void updateViewConeGeometry({
    required String id,
    required double rotation,
    required double length,
  }) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;
    final node = newState[index];
    if (node is! PlacedViewConeAgent) return;
    node.updateGeometry(newRotation: rotation, newLength: length);
    ref.read(actionProvider.notifier).addAction(
          UserAction(type: ActionType.edit, id: id, group: ActionGroup.agent),
        );
    state = newState;
  }

  void updateCircleGeometry({
    required String id,
    required double diameterMeters,
    required int colorValue,
    required int opacityPercent,
  }) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;
    final node = newState[index];
    if (node is! PlacedCircleAgent) return;
    final hasChange = node.diameterMeters != diameterMeters ||
        node.colorValue != colorValue ||
        node.opacityPercent != opacityPercent;
    if (!hasChange) return;
    node.updateGeometryHistory();
    node.updateGeometry(
      newDiameterMeters: diameterMeters,
      newColorValue: colorValue,
      newOpacityPercent: opacityPercent,
    );
    ref.read(actionProvider.notifier).addAction(
          UserAction(type: ActionType.edit, id: id, group: ActionGroup.agent),
        );
    state = newState;
  }

  bool convertPlainAgentToViewCone({
    required String id,
    required UtilityType presetType,
    required double rotation,
    required double length,
  }) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return false;
    final node = newState[index];
    if (node is! PlacedAgent) return false;

    newState[index] = PlacedViewConeAgent(
      id: node.id,
      position: node.position,
      type: node.type,
      isAlly: node.isAlly,
      state: node.state,
      presetType: presetType,
      rotation: rotation,
      length: length,
    )..isDeleted = node.isDeleted;

    ref.read(actionProvider.notifier).addAction(
          UserAction(type: ActionType.edit, id: id, group: ActionGroup.agent),
        );
    state = newState;
    return true;
  }

  bool convertPlainAgentToCircle({
    required String id,
    required double diameterMeters,
    required int colorValue,
    required int opacityPercent,
  }) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return false;
    final node = newState[index];
    if (node is! PlacedAgent) return false;

    newState[index] = PlacedCircleAgent(
      id: node.id,
      position: node.position,
      type: node.type,
      isAlly: node.isAlly,
      state: node.state,
      diameterMeters: diameterMeters,
      colorValue: colorValue,
      opacityPercent: opacityPercent,
    )..isDeleted = node.isDeleted;

    ref.read(actionProvider.notifier).addAction(
          UserAction(type: ActionType.edit, id: id, group: ActionGroup.agent),
        );
    state = newState;
    return true;
  }

  void undoAction(UserAction action) {
    switch (action.type) {
      case ActionType.addition:
        removeAgent(action.id);
        return;
      case ActionType.deletion:
        final index = PlacedWidget.getIndexByID(action.id, poppedAgents);
        if (index < 0) {
          return;
        }
        final newState = [...state];

        final restoredAgent = poppedAgents.removeAt(index);
        newState.add(restoredAgent);
        state = newState;
        return;
      case ActionType.edit:
        undoPosition(action.id);
        return;
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
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
          if (index < 0) return;
          final restoredAgent = poppedAgents.removeAt(index);
          newState.add(restoredAgent);
          state = newState;
          return;

        case ActionType.deletion:
          final index = PlacedWidget.getIndexByID(action.id, newState);
          if (index < 0) return;
          final removedAgent = newState.removeAt(index);
          poppedAgents.add(removedAgent);
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

  String toJson() {
    final List<Map<String, dynamic>> jsonList =
        state.map((agent) => agent.toJson()).toList();
    return jsonEncode(jsonList);
  }

  static String objectToJson(List<PlacedAgentNode> agents) {
    final List<Map<String, dynamic>> jsonList =
        agents.map((agent) => agent.toJson()).toList();
    return jsonEncode(jsonList);
  }

  void fromHive(List<PlacedAgentNode> hiveAgents) {
    poppedAgents = [];
    state = hiveAgents;
  }

  static List<PlacedAgentNode> fromJson(String jsonString) {
    final List<dynamic> jsonList = jsonDecode(jsonString);
    return jsonList
        .map((json) => PlacedAgentNode.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  @override
  String toString() {
    String output = "[";

    for (final agent in state) {
      output += "Name: ${agent.type}, Position: ${agent.position}, ";
    }

    output += "]";

    return output;
  }

  void switchSides() {
    if (state.isEmpty) return;

    final newState = [...state];
    for (final agent in newState) {
      // Flip over both axes, accounting for top-left positioning:
      // x' = normalizedWidth  - x - wNorm
      // y' = normalizedHeight - y - hNorm
      agent.switchSides(ref.read(strategySettingsProvider).agentSize);
    }

    for (final agent in poppedAgents) {
      agent.switchSides(ref.read(strategySettingsProvider).agentSize);
    }

    state = newState;
  }

  void clearAll() {
    poppedAgents = [];
    state = [];
  }

  AgentProviderSnapshot takeSnapshot() {
    return AgentProviderSnapshot(
      agents:
          state.map((agent) => agent.snapshotCopy<PlacedAgentNode>()).toList(),
      poppedAgents: poppedAgents
          .map((agent) => agent.snapshotCopy<PlacedAgentNode>())
          .toList(),
    );
  }

  void restoreSnapshot(AgentProviderSnapshot snapshot) {
    poppedAgents = snapshot.poppedAgents
        .map((agent) => agent.snapshotCopy<PlacedAgentNode>())
        .toList();
    state = snapshot.agents
        .map((agent) => agent.snapshotCopy<PlacedAgentNode>())
        .toList();
  }

  PlacedAgentNode _duplicateNode(
    PlacedAgentNode source, {
    required String id,
    required Offset position,
  }) {
    return switch (source) {
      PlacedAgent() => source.copyWith(id: id, position: position),
      PlacedViewConeAgent() => source.copyWith(id: id, position: position),
      PlacedCircleAgent() => source.copyWith(id: id, position: position),
    };
  }
}
