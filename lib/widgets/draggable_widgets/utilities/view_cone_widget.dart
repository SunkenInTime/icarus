import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

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

    final totalHeight = (300 + 7.5 + 10) * coord.scaleFactor;
    final totalWidth = (300 * 2) * coord.scaleFactor;

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
            bottom: 10 * coord.scaleFactor,
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
                    color: Colors.blue.withValues(alpha: 0.3),
                    borderColor: Colors.blue,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: (totalWidth - 10 * coord.scaleFactor) / 2,
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
                color: Settings.tacticalVioletTheme.secondary,
                width: 10 * coord.scaleFactor,
                height: 10 * coord.scaleFactor,
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
  final Color color;
  final Color borderColor;

  ViewConePainter({
    required this.angle,
    required this.length,
    required this.color,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // Convert angle to radians
    final angleRad = angle * (pi / 180);

    // Center the cone so it's always pointing "up" (centered)
    // Start angle should be at "up" (-pi/2) minus half of the cone, so it centers
    final startAngle = -pi / 2 - angleRad / 2;

    // The apex (origin point) is at bottom center of the container
    // Container: width = 2*length, height = length
    // Apex position: (width/2, height) = (length, length)
    final apex = Offset(size.width / 2, size.height);

    final path = Path();
    path.moveTo(apex.dx, apex.dy);
    path.arcTo(
      Rect.fromCircle(center: apex, radius: length),
      startAngle,
      angleRad,
      false,
    );
    path.close();

    canvas.drawPath(path, paint);
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant ViewConePainter oldDelegate) {
    return oldDelegate.angle != angle ||
        oldDelegate.length != length ||
        oldDelegate.color != color ||
        oldDelegate.borderColor != borderColor;
  }
}
