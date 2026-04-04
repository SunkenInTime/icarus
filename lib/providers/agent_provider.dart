import 'dart:convert';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
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
  final Map<String, ActionObjectState> _pendingEditBefore = {};
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
      objectDelta: ObjectHistoryDelta(
        after: ActionObjectState.agent(placedAgent),
      ),
    );

    ref.read(actionProvider.notifier).addAction(action);
    state = [...state, placedAgent];
  }

  void removeAgent(String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;
    final removedAgent = newState.removeAt(index);
    poppedAgents.removeWhere((agent) => agent.id == id);
    poppedAgents.add(clonePlacedAgentNode(removedAgent));

    state = newState;
  }

  void removeAgentAsAction(String id) {
    final index = PlacedWidget.getIndexByID(id, state);
    if (index < 0) return;

    ref.read(actionProvider.notifier).addAction(
          UserAction(
            type: ActionType.deletion,
            id: id,
            group: ActionGroup.agent,
            objectDelta: ObjectHistoryDelta(
              before: ActionObjectState.agent(state[index]),
            ),
          ),
        );
    removeAgent(id);
  }

  void toggleAgentState(String id) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;
    final before = ActionObjectState.agent(newState[index]);
    newState[index].state = newState[index].state == AgentState.dead
        ? AgentState.none
        : AgentState.dead;

    final action =
        UserAction(
          type: ActionType.edit,
          id: id,
          group: ActionGroup.agent,
          objectDelta: ObjectHistoryDelta(
            before: before,
            after: ActionObjectState.agent(newState[index]),
          ),
        );
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
    final before = ActionObjectState.agent(newState[index]);
    newState[index].updatePosition(position);

    final temp = newState.removeAt(index);

    final action = UserAction(
      type: ActionType.edit,
      id: id,
      group: ActionGroup.agent,
      objectDelta: ObjectHistoryDelta(
        before: before,
        after: ActionObjectState.agent(temp),
      ),
    );
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
    final index = PlacedWidget.getIndexByID(id, state);
    if (index < 0) return;
    final node = state[index];
    if (node is! PlacedViewConeAgent) return;
    _pendingEditBefore[id] = ActionObjectState.agent(node);
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
    final before = _pendingEditBefore.remove(id) ?? ActionObjectState.agent(node);
    node.updateGeometry(newRotation: rotation, newLength: length);
    ref.read(actionProvider.notifier).addAction(
          UserAction(
            type: ActionType.edit,
            id: id,
            group: ActionGroup.agent,
            objectDelta: ObjectHistoryDelta(
              before: before,
              after: ActionObjectState.agent(node),
            ),
          ),
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
    final before = ActionObjectState.agent(node);
    final hasChange = node.diameterMeters != diameterMeters ||
        node.colorValue != colorValue ||
        node.opacityPercent != opacityPercent;
    if (!hasChange) return;
    node.updateGeometry(
      newDiameterMeters: diameterMeters,
      newColorValue: colorValue,
      newOpacityPercent: opacityPercent,
    );
    ref.read(actionProvider.notifier).addAction(
          UserAction(
            type: ActionType.edit,
            id: id,
            group: ActionGroup.agent,
            objectDelta: ObjectHistoryDelta(
              before: before,
              after: ActionObjectState.agent(node),
            ),
          ),
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
    final before = ActionObjectState.agent(node);

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
          UserAction(
            type: ActionType.edit,
            id: id,
            group: ActionGroup.agent,
            objectDelta: ObjectHistoryDelta(
              before: before,
              after: ActionObjectState.agent(newState[index]),
            ),
          ),
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
    final before = ActionObjectState.agent(node);

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
          UserAction(
            type: ActionType.edit,
            id: id,
            group: ActionGroup.agent,
            objectDelta: ObjectHistoryDelta(
              before: before,
              after: ActionObjectState.agent(newState[index]),
            ),
          ),
        );
    state = newState;
    return true;
  }

  void undoAction(UserAction action) {
    final delta = action.objectDelta;
    if (delta == null) {
      switch (action.type) {
        case ActionType.addition:
          removeAgent(action.id);
          return;
        case ActionType.deletion:
          if (poppedAgents.isEmpty) return;
          _upsertAgent(clonePlacedAgentNode(poppedAgents.removeLast()));
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
        removeAgent(action.id);
        return;
      case ActionType.deletion:
        final before = delta.before?.agent;
        if (before == null) {
          return;
        }
        _upsertAgent(clonePlacedAgentNode(before));
        return;
      case ActionType.edit:
        final before = delta.before?.agent;
        if (before == null) return;
        _upsertAgent(clonePlacedAgentNode(before));
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
          if (poppedAgents.isEmpty) return;
          _upsertAgent(clonePlacedAgentNode(poppedAgents.removeLast()));
          return;
        case ActionType.deletion:
          removeAgent(action.id);
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
        final after = delta.after?.agent;
        if (after == null) return;
        _upsertAgent(clonePlacedAgentNode(after));
        return;
      case ActionType.deletion:
        removeAgent(action.id);
        return;
      case ActionType.edit:
        final after = delta.after?.agent;
        if (after == null) return;
        _upsertAgent(clonePlacedAgentNode(after));
        return;
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
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
    _pendingEditBefore.clear();
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
    _pendingEditBefore.clear();
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
    _pendingEditBefore.clear();
    state = snapshot.agents
        .map((agent) => agent.snapshotCopy<PlacedAgentNode>())
        .toList();
  }

  void _upsertAgent(PlacedAgentNode agent) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(agent.id, newState);
    if (index < 0) {
      newState.add(agent);
    } else {
      newState[index] = agent;
    }
    state = newState;
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
