import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';

/// The ids of the placed items on the page on screen that hold a caption, and
/// the round ones among them, whose marker sits on their edge.
final captionedItemsProvider =
    Provider.autoDispose<({Set<String> all, Set<String> round})>((ref) {
  bool holds(PlacedWidget item) => item.caption?.isNotEmpty ?? false;
  final map = ref.watch(mapProvider).currentMap;
  final utilities = ref.watch(utilityProvider).where(
        (item) => holds(item) && mapDoorOfRow(item, map) == null,
      );
  return (
    all: {
      for (final item in ref.watch(agentProvider))
        if (holds(item)) item.id,
      for (final item in ref.watch(abilityProvider))
        if (holds(item)) item.id,
      for (final item in ref.watch(textProvider))
        if (holds(item)) item.id,
      for (final item in ref.watch(placedImageProvider).images)
        if (holds(item)) item.id,
      for (final item in utilities) item.id,
    },
    round: {
      for (final item in utilities)
        if (item.type == UtilityType.customCircle) item.id,
    },
  );
});

/// The note marker's bubble, in the 15 by 14 box it is drawn in. Its tail
/// starts on the item's corner, so it points at the item it belongs to.
final Path captionMarkerPath = Path()
  ..moveTo(4, 2)
  ..lineTo(11, 2)
  ..arcToPoint(const Offset(13, 4), radius: const Radius.circular(2))
  ..lineTo(13, 8)
  ..arcToPoint(const Offset(11, 10), radius: const Radius.circular(2))
  ..lineTo(5.5, 10)
  ..lineTo(2, 12.5)
  ..lineTo(2, 4)
  ..arcToPoint(const Offset(4, 2), radius: const Radius.circular(2))
  ..close();

/// How far the marker's box sits from the point it hangs on.
const _markerOffset = Offset(-3, -11);

/// Where a marker hangs on an item outlined by [corners], in screen
/// coordinates: the corner furthest up and right, whichever way the item is
/// turned, or that point on the edge of a round item.
Offset captionMarkerAnchor(List<Offset> corners, {required bool round}) {
  if (!round) {
    return corners.reduce(
      (best, corner) =>
          corner.dx - corner.dy > best.dx - best.dy ? corner : best,
    );
  }
  final center = (corners[0] + corners[2]) / 2;
  final radius = (corners[1] - corners[0]).distance / 2;
  return center + Offset(radius, -radius) * (math.sqrt2 / 2);
}

/// The top-left of a marker hung on [anchor], on whole device pixels: its
/// edges go soft between them, at any zoom.
Offset captionMarkerOrigin(Offset anchor, double devicePixelRatio) {
  final at = anchor + _markerOffset;
  return Offset(
    (at.dx * devicePixelRatio).roundToDouble() / devicePixelRatio,
    (at.dy * devicePixelRatio).roundToDouble() / devicePixelRatio,
  );
}

/// The markers on the items that hold a caption. It paints in the canvas above
/// the items, the same size at every zoom, takes no pointer and changes no
/// item's box, so it can't move what's saved.
class CaptionMarkers extends ConsumerStatefulWidget {
  const CaptionMarkers({required this.transformation, super.key});

  /// The canvas's zoom and pan, which move every marker.
  final TransformationController transformation;

  @override
  ConsumerState<CaptionMarkers> createState() => _CaptionMarkersState();
}

class _CaptionMarkersState extends ConsumerState<CaptionMarkers> {
  final _items = ValueNotifier(0);

  void _repaint() => _items.value++;

  /// Items follow a held pointer without any provider changing.
  void _onPointer(PointerEvent event) {
    if (event.down) _repaint();
  }

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    _items.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(captionedItemsProvider);
    // Items are laid out by the time this paints, in this frame or the next.
    ref.listen(agentProvider, (_, __) => _repaint());
    ref.listen(abilityProvider, (_, __) => _repaint());
    ref.listen(textProvider, (_, __) => _repaint());
    ref.listen(placedImageProvider, (_, __) => _repaint());
    ref.listen(utilityProvider, (_, __) => _repaint());
    if (items.all.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _CaptionMarkerPainter(
          items: items,
          registry: CanvasItemRegistryScope.maybeOf(context),
          stack: context.findAncestorRenderObjectOfType<RenderStack>(),
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
          repaint: Listenable.merge([widget.transformation, _items]),
        ),
      ),
    );
  }
}

class _CaptionMarkerPainter extends CustomPainter {
  _CaptionMarkerPainter({
    required this.items,
    required this.registry,
    required this.stack,
    required this.devicePixelRatio,
    required super.repaint,
  });

  final ({Set<String> all, Set<String> round}) items;
  final CanvasItemRegistry? registry;
  final RenderStack? stack;
  final double devicePixelRatio;

  static final _edge = Paint()
    ..color = Settings.tacticalVioletTheme.background
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5
    ..strokeJoin = StrokeJoin.round;
  static final _fill = Paint()..color = Settings.tacticalVioletTheme.foreground;

  @override
  void paint(Canvas canvas, Size size) {
    final registry = this.registry;
    final stack = this.stack;
    if (registry == null || stack == null || !stack.attached) return;
    // Drawn in screen coordinates, so a marker ignores the canvas's zoom and
    // lands on whole device pixels.
    final toScreen = stack.getTransformTo(null);
    final toCanvas = Matrix4.tryInvert(toScreen);
    if (toCanvas == null) return;
    canvas.save();
    canvas.transform(toCanvas.storage);
    for (final (:item, :corners) in registry.itemsIn(stack)) {
      if (!items.all.contains(item.id)) continue;
      final anchor = captionMarkerAnchor(
        [for (final c in corners) MatrixUtils.transformPoint(toScreen, c)],
        round: items.round.contains(item.id),
      );
      canvas.save();
      final origin = captionMarkerOrigin(anchor, devicePixelRatio);
      canvas.translate(origin.dx, origin.dy);
      canvas.drawPath(captionMarkerPath, _edge);
      canvas.drawPath(captionMarkerPath, _fill);
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CaptionMarkerPainter oldDelegate) =>
      items != oldDelegate.items ||
      stack != oldDelegate.stack ||
      devicePixelRatio != oldDelegate.devicePixelRatio;
}
