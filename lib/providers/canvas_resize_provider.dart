import 'package:flutter_riverpod/flutter_riverpod.dart';

final canvasResizeProvider =
    NotifierProvider<CanvasResizeNotifier, int>(CanvasResizeNotifier.new);

class CanvasResizeNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}
