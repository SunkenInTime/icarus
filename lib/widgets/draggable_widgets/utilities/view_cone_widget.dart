import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/map_doors_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/view_cone/page_occluders.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/adjacent_page_copy_menu.dart';
import 'package:icarus/widgets/draggable_widgets/caption_menu.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/sightline_report_menu.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_elevation_menu.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';

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

  /// Paint alpha for a drag preview. Applied inside the cone painter so the
  /// preview needs no offscreen opacity layer.
  final double opacity;

  const ViewConeWidget({
    super.key,
    required this.id,
    required this.angle,
    this.rotation,
    this.length,
    this.worldOrigin,
    this.visionElevation,
    this.showCenterMarker = true,
    this.opacity = 1,
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

    final scaledLength = currentLength * coord.scaleFactor;
    final scaledAnchor = anchorPointVirtual.scale(
      coord.scaleFactor,
      coord.scaleFactor,
    );
    final scaledIconSize = Settings.utilityIconSize * coord.scaleFactor;

    // Container size: width = 2*length (cone can extend left/right), height =
    // length (cone extends up). A full circle extends down as well, past the
    // box its position is saved by. The apex (anchor point) is one length
    // below the container's top, in the middle.
    final containerWidth = scaledLength * 2;
    final containerHeight = angle >= ViewConeUtility.fullCircleDegrees
        ? containerWidth
        : scaledLength;

    final totalHeight = totalHeightVirtual * coord.scaleFactor;
    final totalWidth = totalWidthVirtual * coord.scaleFactor;
    final resolvedWorldOrigin = worldOrigin ??
        (placedUtility == null
            ? null
            : placedUtility.position +
                coord.virtualOffsetToWorld(anchorPointVirtual));
    final resolvedElevation = visionElevation ?? placedUtility?.visionElevation;
    List<Offset>? visibilityPolygon;
    SvgHeightVisibility? svgHeightModel;
    Offset? svgHeightOrigin;
    ShadContextMenuItem? sightlineReportItem;
    Widget? heightCone;
    if (resolvedWorldOrigin != null) {
      final mapState = ref.watch(mapProvider);
      final sideWorldOrigin = coord.positionForSide(
        canonicalPosition: resolvedWorldOrigin,
        reflectionOffset: Offset.zero,
        isAttack: mapState.isAttack,
      );
      // Registered maps only paint results from their reviewed SVG semantic
      // assets. The icon remains available while loading or after a failure.
      visibilityPolygon = const [Offset.zero];
      final runtime = ref
          .watch(svgHeightRuntimeProvider(mapState.currentMap))
          .asData
          ?.value;
      if (runtime != null) {
        svgHeightModel = runtime.model(mapState.isAttack);
        svgHeightOrigin = SvgHeightMapTransform.forMap(mapState.currentMap)
            .sourceFromSideWorld(
          sideWorldOrigin,
          isAttack: mapState.isAttack,
        );
        final changedDoors = ref.watch(changedMapDoorsProvider);
        heightCone = Builder(builder: (context) {
          final carried = carriedBySelection(context);
          return SvgHeightViewCone(
            runtime: runtime,
            canonicalOrigin: resolvedWorldOrigin,
            rotation: rotation ??
                coord.rotationForSide(placedUtility?.rotation ?? 0,
                    isAttack: mapState.isAttack),
            range: coord.virtualLengthToWorld(currentLength),
            angle: angle * pi / 180,
            isAttack: mapState.isAttack,
            elevation: resolvedElevation,
            opacity: opacity,
            changedDoors: changedDoors,
            blockers: SightBlockersScope.of(context),
            carriedBy: carried == null
                ? Offset.zero
                : selectionDragInWorld(carried, isAttack: mapState.isAttack),
          );
        });
      }
      // Only a placed cone carries a context menu; a drag preview has none.
      if (placedUtility != null) {
        sightlineReportItem = buildSightlineReportMenuItem(
          l10n: context.l10n,
          map: mapState.currentMap,
          isAttack: mapState.isAttack,
          model: svgHeightModel,
          canonicalOrigin: resolvedWorldOrigin,
          rotation: rotation ??
              coord.rotationForSide(placedUtility.rotation,
                  isAttack: mapState.isAttack),
          coneAngleDegrees: angle,
          lengthVirtual: currentLength,
          visionElevationCm: resolvedElevation,
          blockers: SightBlockersScope.of(context),
        );
      }
    }

    final contextMenuItems = placedUtility == null
        ? null
        : [
            if (svgHeightModel != null && svgHeightOrigin != null)
              buildSvgHeightElevationMenuItem(
                l10n: context.l10n,
                model: svgHeightModel,
                origin: svgHeightOrigin,
                selectedElevationCm: placedUtility.visionElevation,
                onChanged: (elevation) => ref
                    .read(utilityProvider.notifier)
                    .updateViewConeElevation(placedUtility!.id, elevation),
              ),
            if (sightlineReportItem != null) sightlineReportItem,
            ...buildCaptionMenuItems(context, ref, placedUtility.id),
            ...buildAdjacentPageCopyMenuItems(ref, placedUtility.id),
          ];

    return SizedBox(
      width: totalWidth,
      height: totalHeight,
      child: Stack(
        // The center marker's outline reaches past the box the cone is
        // clipped to.
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Stack(
              // A full circle reaches past the bottom of the box.
              clipBehavior: Clip.none,
              children: [
                const Positioned.fill(child: IgnorePointer(child: SizedBox())),
                Positioned(
                  top: scaledAnchor.dy - scaledLength,
                  left: scaledAnchor.dx - (containerWidth / 2),
                  child: IgnorePointer(
                    child: SizedBox(
                      width: containerWidth,
                      height: containerHeight,
                      child: heightCone ??
                          _faded(
                              opacity,
                              CustomPaint(
                                size: Size(containerWidth, containerHeight),
                                painter: ViewConePainter(
                                  angle: angle,
                                  length: scaledLength,
                                  visibilityPolygon: visibilityPolygon,
                                ),
                              )),
                    ),
                  ),
                ),
              ],
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
                contextMenuItems: contextMenuItems,
                cursor: SystemMouseCursors.click,
                child: _faded(
                  opacity,
                  EditorItemOutline(
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

  ViewConePainter({
    required this.angle,
    required this.length,
    this.visibilityPolygon,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // A non-null result means map clipping was evaluated. If the apex is
    // outside the SVG floor (or the cone otherwise has no visible area), the
    // geometry returns a degenerate polygon and nothing should be painted.
    if (visibilityPolygon != null && visibilityPolygon!.length < 3) return;

    final angleRad = angle * (pi / 180);

    final startAngle = -pi / 2 - angleRad / 2;

    final apex = Offset(size.width / 2, length);

    canvas.save();
    // A full circle is the gradient's own circle, with no wedge to cut.
    if (angle < ViewConeUtility.fullCircleDegrees) {
      final clipPath = Path();
      clipPath.moveTo(apex.dx, apex.dy);
      clipPath.arcTo(
        Rect.fromCircle(center: apex, radius: length),
        startAngle,
        angleRad,
        false,
      );
      clipPath.close();
      canvas.clipPath(clipPath);
    }
    if (visibilityPolygon != null && visibilityPolygon!.length >= 3) {
      canvas.clipPath(Path()..addPolygon(visibilityPolygon!, true));
    }

    final gradientCenter = apex;
    final gradientRadius = length;

    final gradientPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 1.0,
        colors: [
          const Color.fromARGB(255, 147, 147, 147).withValues(alpha: 0.5),
          Colors.transparent,
        ],
        stops: const [0.0, 1.0],
      ).createShader(
          Rect.fromCircle(center: gradientCenter, radius: gradientRadius));

    canvas.drawCircle(gradientCenter, gradientRadius, gradientPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant ViewConePainter oldDelegate) {
    return oldDelegate.length != length ||
        oldDelegate.angle != angle ||
        !listEquals(oldDelegate.visibilityPolygon, visibilityPolygon);
  }
}

Widget _faded(double opacity, Widget child) =>
    opacity >= 1 ? child : Opacity(opacity: opacity, child: child);
