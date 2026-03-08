import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final imageWidgetSizeProvider =
    NotifierProvider<ImageWidgetSizeProvider, Map<String, Offset>>(
  ImageWidgetSizeProvider.new,
);

class ImageWidgetSizeProvider extends Notifier<Map<String, Offset>> {
  @override
  Map<String, Offset> build() {
    return {};
  }

  void updateSize(String id, Offset size) {
    state = {...state, id: size};
  }

  Offset getSize(String id) {
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
