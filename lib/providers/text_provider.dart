import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_widget_height_provider.dart';

final textProvider =
    NotifierProvider<TextProvider, List<PlacedText>>(TextProvider.new);

class TextProviderSnapshot {
  final List<PlacedText> texts;
  final List<PlacedText> poppedText;

  const TextProviderSnapshot({
    required this.texts,
    required this.poppedText,
  });
}

class TextProvider extends Notifier<List<PlacedText>> {
  static final double _legacyWidthToWorldFactor =
      (1000.0 * (16 / 9)) / CoordinateSystem.screenShotSize.width;
  static final double _legacyFontToWorldFactor =
      1000.0 / CoordinateSystem.screenShotSize.height;

  List<PlacedText> poppedText = [];

  static PlacedText _migrateLoadedText(PlacedText text) {
    final migrated = text.copyWith();
    if (!migrated.usesWorldSize) {
      migrated.size = migrated.size * _legacyWidthToWorldFactor;
      migrated.fontSize = migrated.fontSize * _legacyFontToWorldFactor;
      migrated.markSizeAsWorld();
    }
    return migrated;
  }

  @override
  List<PlacedText> build() {
    return [];
  }

  void addText(PlacedText text) {
    final action = UserAction(
      type: ActionType.addition,
      id: text.id,
      group: ActionGroup.text,
      objectDelta: ObjectHistoryDelta(
        after: ActionObjectState.text(text),
        afterTextHeights:
            ref.read(textWidgetHeightProvider.notifier).takeSnapshotForIds([text.id]),
      ),
    );

    ref.read(actionProvider.notifier).addAction(action);

    state = [...state, text];
  }

  void removeTextAsAction(String id) {
    final index = PlacedWidget.getIndexByID(id, state);
    if (index < 0) return;

    ref.read(actionProvider.notifier).addAction(
          UserAction(
            type: ActionType.deletion,
            id: id,
            group: ActionGroup.text,
            objectDelta: ObjectHistoryDelta(
              before: ActionObjectState.text(state[index]),
              beforeTextHeights: ref
                  .read(textWidgetHeightProvider.notifier)
                  .takeSnapshotForIds([id]),
            ),
          ),
        );
    removeText(id);
  }

  void updatePosition(Offset position, String id) {
    final newState = [...state];

    final index = PlacedWidget.getIndexByID(id, newState);

    if (index < 0) return;
    final before = ActionObjectState.text(newState[index]);

    newState[index].updatePosition(position);

    //Moving foward
    final temp = newState.removeAt(index);

    final action = UserAction(
      type: ActionType.edit,
      id: id,
      group: ActionGroup.text,
      objectDelta: ObjectHistoryDelta(
        before: before,
        after: ActionObjectState.text(temp),
        beforeTextHeights:
            ref.read(textWidgetHeightProvider.notifier).takeSnapshotForIds([id]),
        afterTextHeights:
            ref.read(textWidgetHeightProvider.notifier).takeSnapshotForIds([id]),
      ),
    );
    ref.read(actionProvider.notifier).addAction(action);

    state = [...newState, temp];
  }

  void switchSides() {
    final newState = [...state];
    for (final text in newState) {
      text.switchSides(
          ref.read(textWidgetHeightProvider.notifier).getOffset(text.id));
    }

    for (final text in poppedText) {
      text.switchSides(
          ref.read(textWidgetHeightProvider.notifier).getOffset(text.id));
    }

    state = newState;
  }

  void commitText(String id, String nextText) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;

    if (newState[index].text == nextText) return;

    final before = ActionObjectState.text(newState[index]);
    newState[index].commitText(nextText);
    ref.read(actionProvider.notifier).addAction(
          UserAction(
            type: ActionType.edit,
            id: id,
            group: ActionGroup.text,
            objectDelta: ObjectHistoryDelta(
              before: before,
              after: ActionObjectState.text(newState[index]),
              beforeTextHeights: ref
                  .read(textWidgetHeightProvider.notifier)
                  .takeSnapshotForIds([id]),
              afterTextHeights: ref
                  .read(textWidgetHeightProvider.notifier)
                  .takeSnapshotForIds([id]),
            ),
          ),
        );
    state = newState;
  }

  void updateTagColor(String id, int? colorValue) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(id, newState);
    if (index < 0) return;

    newState[index].tagColorValue = colorValue;
    state = newState;
  }

  void undoAction(UserAction action) {
    final delta = action.objectDelta;
    if (delta == null) {
      switch (action.type) {
        case ActionType.addition:
          removeText(action.id);
          return;
        case ActionType.deletion:
          if (poppedText.isEmpty) return;
          _upsertText(clonePlacedText(poppedText.removeLast()));
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
        _clearTextHeights(delta.afterTextHeights.keys);
        removeText(action.id);
        return;
      case ActionType.deletion:
        final before = delta.before?.text;
        if (before == null) return;
        _upsertText(clonePlacedText(before));
        _restoreTextHeights(delta.beforeTextHeights);
        return;

      case ActionType.edit:
        final before = delta.before?.text;
        if (before == null) return;
        _upsertText(clonePlacedText(before));
        _restoreTextHeights(delta.beforeTextHeights);
        return;
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
  }

  void redoAction(UserAction action) {
    final delta = action.objectDelta;
    if (delta == null) {
      switch (action.type) {
        case ActionType.addition:
          if (poppedText.isEmpty) return;
          _upsertText(clonePlacedText(poppedText.removeLast()));
          return;
        case ActionType.deletion:
          removeText(action.id);
          return;
        case ActionType.edit:
          final index = PlacedWidget.getIndexByID(action.id, state);
          if (index < 0) return;
          final newState = [...state];
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
        final after = delta.after?.text;
        if (after == null) return;
        _upsertText(clonePlacedText(after));
        _restoreTextHeights(delta.afterTextHeights);
        return;
      case ActionType.deletion:
        _clearTextHeights(delta.beforeTextHeights.keys);
        removeText(action.id);
        return;
      case ActionType.edit:
        final after = delta.after?.text;
        if (after == null) return;
        _upsertText(clonePlacedText(after));
        _restoreTextHeights(delta.afterTextHeights);
        return;
      case ActionType.bulkDeletion:
      case ActionType.transaction:
        return;
    }
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
    final draft = ref.read(textDraftProvider.notifier).draftFor(id);
    if (draft != null) {
      text.text = draft;
      ref.read(textDraftProvider.notifier).clearDraft(id);
    }
    poppedText.removeWhere((item) => item.id == id);
    poppedText.add(clonePlacedText(text));
    state = newState;
  }

  String toJson() {
    final List<Map<String, dynamic>> jsonList =
        state.map((text) => text.toJson()).toList();
    return jsonEncode(jsonList);
  }

  String toJsonFromData(List<PlacedText> elements) {
    final List<Map<String, dynamic>> jsonList =
        elements.map((text) => text.toJson()).toList();
    return jsonEncode(jsonList);
  }

  List<PlacedText> snapshotForPersistence() {
    final drafts = ref.read(textDraftProvider);
    return state
        .map(
          (text) => text.copyWith(
            text: drafts[text.id] ?? text.text,
          ),
        )
        .toList(growable: false);
  }

  void fromHive(List<PlacedText> hiveText) {
    ref.read(textDraftProvider.notifier).clearAllDrafts();
    poppedText = [];
    state = hiveText.map(_migrateLoadedText).toList();
  }

  static List<PlacedText> fromJson(String jsonString) {
    final List<dynamic> jsonList = jsonDecode(jsonString);
    return jsonList
        .map((json) => PlacedText.fromJson(json as Map<String, dynamic>))
        .map(_migrateLoadedText)
        .toList();
  }

  static String objectToJson(List<PlacedText> texts) {
    final List<Map<String, dynamic>> jsonList =
        texts.map((text) => text.toJson()).toList();
    return jsonEncode(jsonList);
  }

  void clearAll() {
    ref.read(textDraftProvider.notifier).clearAllDrafts();
    poppedText = [];
    state = [];
  }

  TextProviderSnapshot takeSnapshot() {
    return TextProviderSnapshot(
      texts: state.map((text) => clonePlacedText(text)).toList(),
      poppedText: poppedText.map((text) => clonePlacedText(text)).toList(),
    );
  }

  void restoreSnapshot(TextProviderSnapshot snapshot) {
    ref.read(textDraftProvider.notifier).clearAllDrafts();
    poppedText = snapshot.poppedText.map((text) => clonePlacedText(text)).toList();
    state = snapshot.texts.map((text) => clonePlacedText(text)).toList();
  }

  void _upsertText(PlacedText text) {
    final newState = [...state];
    final index = PlacedWidget.getIndexByID(text.id, newState);
    if (index < 0) {
      newState.add(text);
    } else {
      newState[index] = text;
    }
    state = newState;
  }

  void _restoreTextHeights(Map<String, Offset> snapshot) {
    if (snapshot.isEmpty) return;
    ref.read(textWidgetHeightProvider.notifier).restoreSnapshot(snapshot);
  }

  void _clearTextHeights(Iterable<String> ids) {
    if (ids.isEmpty) return;
    ref.read(textWidgetHeightProvider.notifier).clearEntries(ids);
  }
}
