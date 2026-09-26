import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

final imageWidgetSizeProvider =
    NotifierProvider<ImageWidgetSizeProvider, Map<String, Offset>>(
  ImageWidgetSizeProvider.new,
);

class ImageWidgetSizeProvider extends Notifier<Map<String, Offset>> {
  @override
  Map<String, Offset> build() => {};

  void updateSize(String id, Offset size) {
    state = {...state, id: size};
  }

  Offset getSize(String id) => state[id] ?? Offset.zero;

  void clearEntries(Iterable<String> ids) {
    final newState = {...state};
    for (final id in ids) {
      newState.remove(id);
    }
    state = newState;
  }

  void clearAll() {
    state = {};
  }
}
