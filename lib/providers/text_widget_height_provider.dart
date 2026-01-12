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

  void clearAll() {
    state = {};
  }
}
