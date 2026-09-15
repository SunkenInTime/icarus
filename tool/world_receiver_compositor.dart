import 'dart:ui';

import 'world_receiver_mask.dart';

/// Clips completed visibility to SVG destinations. Both callbacks use the
/// current canvas coordinates; callers apply their map transform beforehand.
/// World shadows must still include blockers in unpainted gaps.
void paintWorldReceiverVisibility({
  required Canvas canvas,
  required WorldReceiverMask receiver,
  required void Function(Canvas) paintVisibility,
}) {
  canvas.saveLayer(receiver.viewBox, Paint());
  try {
    paintVisibility(canvas);
    // A separate layer makes the union of receiver fills one destination-in
    // operation. Applying dstIn to each path would intersect disjoint islands.
    canvas.saveLayer(receiver.viewBox, Paint()..blendMode = BlendMode.dstIn);
    try {
      receiver.paint(canvas, Paint()..color = const Color(0xffffffff));
    } finally {
      canvas.restore();
    }
  } finally {
    canvas.restore();
  }
}
