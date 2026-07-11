import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/providers/view_cone_debug_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_elevation_menu.dart';

class ViewConeWidget extends ConsumerWidget {
  static const Offset anchorPointVirtual = Offset(
    ViewConeUtility.maxLength,
    ViewConeUtility.maxLength + ViewConeUtility.iconTopOffset,
  );
  static const double totalWidthVirtual = ViewConeUtility.maxLength * 2;
  static double get totalHeightVirtual =>
      anchorPointVirtual.dy + (Settings.utilityIconSize / 2);

  final String? id;
  final double angle;
  final double? rotation;
  final double? length;
  final Offset? worldOrigin;
  final double? visionElevation;
  final bool showCenterMarker;

  const ViewConeWidget({
    super.key,
    required this.id,
    required this.angle,
    this.rotation,
    this.length,
    this.worldOrigin,
    this.visionElevation,
    this.showCenterMarker = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coord = CoordinateSystem.instance;

    double currentLength = 50;
    PlacedUtility? placedUtility;

    if (id != null) {
      for (final utility in ref.watch(utilityProvider)) {
        if (utility.id == id) {
          placedUtility = utility;
          currentLength = utility.length > 0 ? utility.length : 50;
          break;
        }
      }
    }

    if (length != null && length! > 0) currentLength = length!;

    // Scale length to screen coordinates
    final scaledLength = currentLength * coord.scaleFactor;
    final scaledAnchor = anchorPointVirtual.scale(
      coord.scaleFactor,
      coord.scaleFactor,
    );
    final scaledIconSize = Settings.utilityIconSize * coord.scaleFactor;

    // Container size: width = 2*length (cone can extend left/right), height = length (cone extends up)
    // The apex (anchor point) is at the bottom center
    final containerWidth = scaledLength * 2;
    final containerHeight = scaledLength;

    final totalHeight = totalHeightVirtual * coord.scaleFactor;
    final totalWidth = totalWidthVirtual * coord.scaleFactor;
    final resolvedWorldOrigin = worldOrigin ??
        (placedUtility == null
            ? null
            : placedUtility.position +
                coord.virtualOffsetToWorld(anchorPointVirtual));
    final resolvedElevation = visionElevation ?? placedUtility?.visionElevation;
    final debugEnabled = ref.watch(viewConeDebugProvider);
    List<Offset>? visibilityPolygon;
    List<VisionSegment>? debugMatchedSegments;
    List<VisionSegment>? debugRiotSegments;
    List<VisionSegment>? debugRejectedSegments;
    List<VisionSegment>? debugBoundarySegments;
    String? debugLabel;
    VisionGeometryMap? geometry;
    if (resolvedWorldOrigin != null) {
      final mapState = ref.watch(mapProvider);
      geometry = ref
          .watch(viewConeGeometryProvider(mapState.currentMap))
          .asData
          ?.value;
      if (geometry != null) {
        final inferredHeight = geometry.inferredHeightAt(
          isAttack: mapState.isAttack,
          position: resolvedWorldOrigin,
        );
        final layer = geometry.layerForPosition(
          isAttack: mapState.isAttack,
          position: resolvedWorldOrigin,
          elevationOverride: resolvedElevation,
        );
        // Placed free cones normally pass their drag-preview rotation directly,
        // while this provider fallback keeps clipping correct for any caller
        // that only supplies the persisted utility id.
        final effectiveRotation = rotation ?? placedUtility?.rotation ?? 0;
        // MapProvider.switchSide mirrors every placed item before toggling the
        // side. The resolved origin is therefore already in the current map's
        // display frame and pairs with the correspondingly mirrored layer.
        final worldPolygon = VisionPolygon.compute(
          layer: layer,
          origin: resolvedWorldOrigin,
          facingAngle: effectiveRotation - pi / 2,
          coneAngle: angle * pi / 180,
          range: coord.virtualLengthToWorld(currentLength),
        );
        final inverseRotation = -effectiveRotation;
        final cosine = cos(inverseRotation);
        final sine = sin(inverseRotation);
        final apex = Offset(containerWidth / 2, containerHeight);
        Offset toLocal(Offset point) {
          final delta = point - resolvedWorldOrigin;
          final local = Offset(
            delta.dx * cosine - delta.dy * sine,
            delta.dx * sine + delta.dy * cosine,
          );
          return apex + coord.worldOffsetToScreen(local);
        }

        visibilityPolygon = [
          for (final point in worldPolygon) toLocal(point),
        ];
        if (debugEnabled) {
          debugMatchedSegments = [
            for (final segment in layer.matchedBoundarySegments)
              VisionSegment(toLocal(segment.start), toLocal(segment.end)),
          ];
          debugRiotSegments = [
            for (final segment in layer.riotSegments)
              VisionSegment(toLocal(segment.start), toLocal(segment.end)),
          ];
          debugRejectedSegments = [
            for (final segment in layer.rejectedSegments)
              VisionSegment(toLocal(segment.start), toLocal(segment.end)),
          ];
          debugBoundarySegments = [
            for (final segment
                in layer.boundary?.segments ?? const <VisionSegment>[])
              VisionSegment(toLocal(segment.start), toLocal(segment.end)),
          ];
          debugLabel = inferredHeight == null
              ? 'fallback ${formatVisionElevation(layer.elevation)}'
              : 'height ${formatVisionElevation(inferredHeight)}  '
                  'slice ${formatVisionElevation(layer.elevation)}  '
                  '${layer.matchedSourceSegments.length} matched / '
                  '${layer.riotSegments.length} retained / '
                  '${layer.rejectedSegments.length} rejected';
        }
      }
    }

    final elevationMenuItems = placedUtility != null && geometry != null
        ? [
            buildViewConeElevationMenuItem(
              geometry: geometry,
              selectedElevation: placedUtility.visionElevation,
              automaticElevation: geometry
                  .layerForPosition(
                    isAttack: ref.read(mapProvider).isAttack,
                    position: resolvedWorldOrigin!,
                  )
                  .elevation,
              onChanged: (elevation) {
                ref
                    .read(utilityProvider.notifier)
                    .updateViewConeElevation(placedUtility!.id, elevation);
              },
            ),
            buildViewConeDebugMenuItem(
              enabled: debugEnabled,
              onChanged: (enabled) =>
                  ref.read(viewConeDebugProvider.notifier).state = enabled,
            ),
          ]
        : null;

    return SizedBox(
      width: totalWidth,
      height: totalHeight,
      child: Stack(
        children: [
          const Positioned.fill(child: IgnorePointer(child: SizedBox())),
          Positioned(
            top: scaledAnchor.dy - containerHeight,
            left: scaledAnchor.dx - (containerWidth / 2),
            child: IgnorePointer(
              child: SizedBox(
                width: containerWidth,
                height: containerHeight,
                child: CustomPaint(
                  size: Size(containerWidth, containerHeight),
                  painter: ViewConePainter(
                    angle: angle,
                    length: scaledLength,
                    visibilityPolygon: visibilityPolygon,
                    debugMatchedSegments: debugMatchedSegments,
                    debugRiotSegments: debugRiotSegments,
                    debugRejectedSegments: debugRejectedSegments,
                    debugBoundarySegments: debugBoundarySegments,
                    debugLabel: debugLabel,
                  ),
                ),
              ),
            ),
          ),
          if (showCenterMarker)
            Positioned(
              top: scaledAnchor.dy - (scaledIconSize / 2),
              left: scaledAnchor.dx - (scaledIconSize / 2),
              child: MouseWatch(
                deleteTarget: (id?.isNotEmpty ?? false)
                    ? HoveredDeleteTarget.utility(id: id!, ownerToken: Object())
                    : null,
                contextMenuItems: elevationMenuItems,
                cursor: SystemMouseCursors.click,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: Settings.tacticalVioletTheme.border,
                    ),
                    color: Settings.tacticalVioletTheme.card,
                  ),
                  width: scaledIconSize,
                  height: scaledIconSize,
                  child: Image.asset('assets/eye.webp'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ViewConePainter extends CustomPainter {
  final double angle;
  final double length;
  final List<Offset>? visibilityPolygon;
  final List<VisionSegment>? debugMatchedSegments;
  final List<VisionSegment>? debugRiotSegments;
  final List<VisionSegment>? debugRejectedSegments;
  final List<VisionSegment>? debugBoundarySegments;
  final String? debugLabel;

  ViewConePainter({
    required this.angle,
    required this.length,
    this.visibilityPolygon,
    this.debugMatchedSegments,
    this.debugRiotSegments,
    this.debugRejectedSegments,
    this.debugBoundarySegments,
    this.debugLabel,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (debugMatchedSegments != null ||
        debugRiotSegments != null ||
        debugRejectedSegments != null ||
        debugBoundarySegments != null) {
      _paintDebugGeometry(canvas, size);
    }

    // A non-null result means map clipping was evaluated. If the apex is
    // outside the SVG floor (or the cone otherwise has no visible area), the
    // geometry returns a degenerate polygon and nothing should be painted.
    if (visibilityPolygon != null && visibilityPolygon!.length < 3) return;

    // Convert angle to radians
    final angleRad = angle * (pi / 180);

    // Center the cone so it's always pointing "up" (centered)
    // Start angle should be at "up" (-pi/2) minus half of the cone, so it centers
    final startAngle = -pi / 2 - angleRad / 2;

    // The apex (origin point) is at bottom center of the container
    // Container: width = 2*length, height = length
    // Apex position: (width/2, height) = (length, length)
    final apex = Offset(size.width / 2, size.height);

    // Create clipping path for the wedge
    final clipPath = Path();
    clipPath.moveTo(apex.dx, apex.dy);
    clipPath.arcTo(
      Rect.fromCircle(center: apex, radius: length),
      startAngle,
      angleRad,
      false,
    );
    clipPath.close();

    // Save canvas state and apply clip
    canvas.save();
    canvas.clipPath(clipPath);
    if (visibilityPolygon != null && visibilityPolygon!.length >= 3) {
      final visibilityPath = Path()
        ..moveTo(visibilityPolygon!.first.dx, visibilityPolygon!.first.dy);
      for (final point in visibilityPolygon!.skip(1)) {
        visibilityPath.lineTo(point.dx, point.dy);
      }
      visibilityPath.close();
      canvas.clipPath(visibilityPath);
    }

    // Draw radial gradient circle (will be clipped to wedge)
    final gradientPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.0,
        colors: [
          const Color.fromARGB(255, 147, 147, 147).withValues(alpha: 0.5),
          Colors.transparent,
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: apex, radius: length));

    canvas.drawCircle(apex, length, gradientPaint);

    // Restore canvas state
    canvas.restore();
  }

  void _paintDebugGeometry(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final matchedPaint = Paint()
      ..color = const Color(0xFF22D3EE).withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final riotPaint = Paint()
      ..color = const Color(0xFFA78BFA).withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;
    final boundaryPaint = Paint()
      ..color = const Color(0xFFF59E0B).withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;
    final rejectedPaint = Paint()
      ..color = const Color(0xFFFB7185).withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final segment in debugBoundarySegments ?? const <VisionSegment>[]) {
      canvas.drawLine(segment.start, segment.end, boundaryPaint);
    }
    for (final segment in debugMatchedSegments ?? const <VisionSegment>[]) {
      canvas.drawLine(segment.start, segment.end, matchedPaint);
    }
    for (final segment in debugRiotSegments ?? const <VisionSegment>[]) {
      canvas.drawLine(segment.start, segment.end, riotPaint);
    }
    for (final segment in debugRejectedSegments ?? const <VisionSegment>[]) {
      canvas.drawLine(segment.start, segment.end, rejectedPaint);
    }
    canvas.drawCircle(
      Offset(size.width / 2, size.height),
      3,
      Paint()..color = const Color(0xFF4ADE80),
    );

    final label = debugLabel;
    if (label != null) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            backgroundColor: Color(0xCC111827),
            fontSize: 10,
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: max(0.0, size.width - 12));
      textPainter.paint(
        canvas,
        Offset(6, max(4.0, size.height - textPainter.height - 8)),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ViewConePainter oldDelegate) {
    return oldDelegate.length != length ||
        oldDelegate.angle != angle ||
        !listEquals(oldDelegate.visibilityPolygon, visibilityPolygon) ||
        !listEquals(oldDelegate.debugMatchedSegments, debugMatchedSegments) ||
        !listEquals(oldDelegate.debugRiotSegments, debugRiotSegments) ||
        !listEquals(
          oldDelegate.debugRejectedSegments,
          debugRejectedSegments,
        ) ||
        !listEquals(
          oldDelegate.debugBoundarySegments,
          debugBoundarySegments,
        ) ||
        oldDelegate.debugLabel != debugLabel;
  }
}
