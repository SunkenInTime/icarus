import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class ViewConeWidget extends ConsumerWidget {
  final String? id;
  final double angle;
  final double? rotation;
  final double? length;

  const ViewConeWidget({
    super.key,
    required this.id,
    required this.angle,
    this.rotation,
    this.length,
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

    // Container size: width = 2*length (cone can extend left/right), height = length (cone extends up)
    // The apex (anchor point) is at the bottom center
    final containerWidth = scaledLength * 2;
    final containerHeight = scaledLength;

    final totalHeight =
        (ViewConeUtility.maxLength + 7.5 + (Settings.utilityIconSize / 2)) *
            coord.scaleFactor;
    final totalWidth = (ViewConeUtility.maxLength * 2) * coord.scaleFactor;

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
            bottom: Settings.utilityIconSize / 2 * coord.scaleFactor,
            left: (totalWidth - containerWidth) / 2,
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
          Positioned(
            bottom: 0,
            left:
                (totalWidth - Settings.utilityIconSize * coord.scaleFactor) / 2,
            child: MouseWatch(
              onDeleteKeyPressed: () {
                if (id == null) return;
                final action = UserAction(
                  type: ActionType.deletion,
                  id: id!,
                  group: ActionGroup.utility,
                );
                ref.read(actionProvider.notifier).addAction(action);
                ref.read(utilityProvider.notifier).removeUtility(id!);
              },
              cursor: SystemMouseCursors.click,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: Settings.tacticalVioletTheme.border,
                  ),
                  color: Settings.tacticalVioletTheme.card,
                ),
                width: Settings.utilityIconSize * coord.scaleFactor,
                height: Settings.utilityIconSize * coord.scaleFactor,
                child: const Icon(LucideIcons.eye),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Get the anchor point (bottom center) for this view cone
  /// This is where the utility position should align
  static Offset getAnchorPoint(double scaledLength) {
    // Bottom center of the container
    return Offset(scaledLength, scaledLength);
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
    return oldDelegate.angle != angle || oldDelegate.length != length;
  }
}
