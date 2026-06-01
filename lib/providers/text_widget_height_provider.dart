import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final textWidgetHeightProvider =
    NotifierProvider<TextWidgetHeightProvider, Map<String, Offset>>(
  TextWidgetHeightProvider.new,
);

class TextWidgetHeightProvider extends Notifier<Map<String, Offset>> {
  @override
  Map<String, Offset> build() {
    return {};
  }

  void updateHeight(String id, Offset offset) {
    state = {...state, id: offset};
  }

  Offset getOffset(String id) {
    return state[id] ?? Offset.zero;
  }

  Map<String, Offset> takeSnapshotForIds(Iterable<String> ids) {
    return {
      for (final id in ids)
        if (state.containsKey(id)) id: state[id]!,
    };
  }

  void clearEntries(Iterable<String> ids) {
    final newState = {...state};
    for (final id in ids) {
      newState.remove(id);
    }
    state = newState;
  }

  void restoreSnapshot(Map<String, Offset> snapshot) {
    state = {
      ...state,
      ...snapshot,
    };
  }

  void clearAll() {
    state = {};
  }
}
