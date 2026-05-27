import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

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
  final bool showCenterMarker;

  const ViewConeWidget({
    super.key,
    required this.id,
    required this.angle,
    this.rotation,
    this.length,
    this.showCenterMarker = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coord = CoordinateSystem.instance;

    double currentLength = 50; // Default short length

    if (id != null) {
      try {
        final utility = ref
            .watch(utilityProvider)
            .firstWhere((element) => element.id == id);
        currentLength = utility.length > 0 ? utility.length : 50;
      } catch (_) {
        // Utility not found, use defaults
      }
    }

    // Override with passed values if available (for feedback/transitions)

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

    return SizedBox(
      width: totalWidth,
      height: totalHeight,
      child: Stack(
        children: [
          const Positioned.fill(
            child: IgnorePointer(
              child: SizedBox(),
            ),
          ),
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

  ViewConePainter({
    required this.angle,
    required this.length,
  });

  @override
  void paint(Canvas canvas, Size size) {
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

  @override
  bool shouldRepaint(covariant ViewConePainter oldDelegate) {
    return oldDelegate.length != length;
  }
}
