import 'dart:convert';
import 'dart:developer';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/action_provider.dart';

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
        group: ActionGroup.agent);

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

  void updatePosition(Offset position, String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;
    newState[index].updatePosition(position);

    final temp = newState.removeAt(index);

    final action =
        UserAction(type: ActionType.edit, id: id, group: ActionGroup.agent);
    ref.read(actionProvider.notifier).addAction(action);

    state = [...newState, temp];
  }

  void undoAction(UserAction action) {
    // log("I got undone");
    switch (action.type) {
      case ActionType.addition:
        log("We are attmepting to remove");
        removeAgent(action.id);
      case ActionType.deletion:
      case ActionType.edit:
        undoPosition(action.id);
    }
  }

  void undoPosition(String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;

    newState[index].undoPosition();

    state = newState;
  }

  void redoAction(UserAction action) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(action.id, newState);
    switch (action.type) {
      case ActionType.addition:
        log("I tried adding back-adding");
        newState.add(poppedAgents.removeAt(index));

      case ActionType.deletion:
        poppedAgents.add(newState.removeAt(index));
        log("I tried adding back=del");
      case ActionType.edit:
        log("I tried adding back=del");
        newState[index].redoPosition();
    }
    state = newState;
  }

  String toJson() {
    final List<Map<String, dynamic>> jsonList =
        state.map((agent) => agent.toJson()).toList();
    return jsonEncode(jsonList);
  }

  void fromJson(String jsonString) {
    final List<dynamic> jsonList = jsonDecode(jsonString);
    state = jsonList
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
}
