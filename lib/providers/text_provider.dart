import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';

final textProvider =
    NotifierProvider<TextProvider, List<PlacedText>>(TextProvider.new);

class TextProvider extends Notifier<List<PlacedText>> {
  List<PlacedText> poppedText = [];
  @override
  List<PlacedText> build() {
    return [];
  }

  void addText(PlacedText text) {
    final action = UserAction(
      type: ActionType.addition,
      id: text.id,
      group: ActionGroup.text,
    );

    ref.read(actionProvider.notifier).addAction(action);

    state = [...state, text];
  }

  void updatePosition(Offset position, String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;

    newState[index].updatePosition(position);

    //Moving foward
    final temp = newState.removeAt(index);

    final action =
        UserAction(type: ActionType.edit, id: id, group: ActionGroup.text);
    ref.read(actionProvider.notifier).addAction(action);

    state = [...newState, temp];
  }

  void editText(String text, String id) {
    final newState = [...state];

    newState
        .firstWhere(
          (element) => element.id == id,
        )
        .text = text;
    // newState[index].text = text;
    state = newState;
  }

  void undoAction(UserAction action) {
    switch (action.type) {
      case ActionType.addition:
        removeText(action.id);
      case ActionType.deletion:
        if (poppedText.isEmpty) return;

        final newState = [...state];

        newState.add(poppedText.removeLast());
        state = newState;

      case ActionType.edit:
        final newState = [...state];

        final index = PlacedWidget.getIndexByID(action.id, newState);

        newState[index].undoAction();

        state = newState;
    }
  }

  void redoAction(UserAction action) {
    final newState = [...state];

    try {
      switch (action.type) {
        case ActionType.addition:
          final index = PlacedWidget.getIndexByID(action.id, poppedText);
          newState.add(poppedText.removeAt(index));

        case ActionType.deletion:
          final index = PlacedWidget.getIndexByID(action.id, poppedText);

          poppedText.add(newState.removeAt(index));

        case ActionType.edit:
          final index = PlacedWidget.getIndexByID(action.id, newState);

          newState[index].redoAction();
      }
    } catch (_) {
      log("oops");
    }
    state = newState;
  }

  void updateSize(int index, double size) {
    final newState = [...state];
    if (index < 0 || index >= newState.length) return;

    newState[index].size = size;
    state = newState;
  }

  void removeText(String id) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;

    final text = newState.removeAt(index);
    poppedText.add(text);

    state = newState;
  }

  String toJson() {
    final List<Map<String, dynamic>> jsonList =
        state.map((text) => text.toJson()).toList();
    return jsonEncode(jsonList);
  }

  void fromHive(List<PlacedText> hiveText) {
    poppedText = [];
    state = hiveText;
  }

  static List<PlacedText> fromJson(String jsonString) {
    final List<dynamic> jsonList = jsonDecode(jsonString);
    return jsonList
        .map((json) => PlacedText.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  static String objectToJson(List<PlacedText> texts) {
    final List<Map<String, dynamic>> jsonList =
        texts.map((text) => text.toJson()).toList();
    return jsonEncode(jsonList);
  }

  void clearAll() {
    poppedText = [];
    state = [];
  }
}
