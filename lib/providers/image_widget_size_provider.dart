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

  void clearAll() {
    state = {};
  }
}
