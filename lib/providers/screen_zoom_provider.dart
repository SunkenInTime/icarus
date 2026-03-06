import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final screenZoomProvider =
    NotifierProvider<ScreenZoomProvider, double>(ScreenZoomProvider.new);

class ScreenZoomProvider extends Notifier<double> {
  @override
  double build() {
    return 1.0;
  }

  void updateZoom(double zoom) {
    state = zoom;
  }

  Offset zoomDragAnchorStrategy(
      Draggable<Object> draggable, BuildContext context, Offset position) {
    final double scale = state;
    final RenderBox renderObject = context.findRenderObject()! as RenderBox;
    return renderObject.globalToLocal(position).scale(scale, scale);
  }

  Offset zoomOffset(Offset offset) {
    return Offset(offset.dx * state, offset.dy * state);
  }
}

