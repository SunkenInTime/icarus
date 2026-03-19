import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';

class SectorCircleWidget extends ConsumerWidget {
  static const double handleTopInsetVirtual = 7.5;

  const SectorCircleWidget({
    super.key,
    required this.iconPath,
    required this.size,
    required this.outlineColor,
    required this.sweepAngleDegrees,
    required this.hasCenterDot,
    required this.hasPerimeter,
    this.opacity = 70,
    this.innerSize = 2,
    this.fillColor,
    required this.id,
    required this.isAlly,
    this.lineUpId,
    this.rotation,
  });

  final String? lineUpId;
  final bool isAlly;
  final String? id;
  final String iconPath;
  final double size;
  final Color outlineColor;
  final double sweepAngleDegrees;
  final bool hasCenterDot;
  final bool hasPerimeter;
  final int? opacity;
  final double? innerSize;
  final Color? fillColor;
  final double? rotation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final scaleSize = coordinateSystem.scale(size);
    final secondaryScaleSize = coordinateSystem.scale(innerSize ?? 0);
    final scaledTopInset = coordinateSystem.scale(handleTopInsetVirtual);
    final style = _SectorCircleStyle.fromValues(
      coordinateSystem: coordinateSystem,
      outlineColor: outlineColor,
      opacity: opacity,
      hasCenterDot: hasCenterDot,
      hasPerimeter: hasPerimeter,
    );

    return SizedBox(
      width: scaleSize,
      height: scaleSize + scaledTopInset,
      child: Stack(
        children: [
          Positioned(
            top: scaledTopInset,
            left: 0,
            child: SizedBox(
              width: scaleSize,
              height: scaleSize,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: SectorCirclePainter(
                          sweepAngleDegrees: sweepAngleDegrees,
                          fillColor: style.fillColor,
                          strokeColor: style.strokeColor,
                          strokeWidth: style.strokeWidth,
                        ),
                      ),
                    ),
                  ),
                  if (hasPerimeter)
                    _buildInnerCircle(coordinateSystem, secondaryScaleSize),
                  if (hasCenterDot)
                    _buildCenterIcon(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInnerCircle(
    CoordinateSystem coordinateSystem,
    double secondaryScaleSize,
  ) {
    assert(
        fillColor != null, 'fillColor is required when hasPerimeter is true');

    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.center,
          child: Container(
            width: secondaryScaleSize,
            height: secondaryScaleSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fillColor!.withAlpha(opacity ?? 70),
              border: Border.all(
                color: fillColor!,
                width: coordinateSystem.scale(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterIcon() {
    return Positioned.fill(
      child: Align(
        alignment: Alignment.center,
        child: Transform.rotate(
          angle: -(rotation ?? 0),
          alignment: Alignment.center,
          child: AbilityWidget(
            lineUpId: lineUpId,
            iconPath: iconPath,
            id: id,
            isAlly: isAlly,
          ),
        ),
      ),
    );
  }
}

class SectorCirclePainter extends CustomPainter {
  const SectorCirclePainter({
    required this.sweepAngleDegrees,
    required this.fillColor,
    required this.strokeColor,
    required this.strokeWidth,
  });

  final double sweepAngleDegrees;
  final Color? fillColor;
  final Color strokeColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || sweepAngleDegrees <= 0) {
      return;
    }

    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final sweepRadians = sweepAngleDegrees * (math.pi / 180);
    final startAngle = -math.pi / 2 - (sweepRadians / 2);

    final fillPath = _buildSectorPath(
      center: center,
      radius: radius,
      startAngle: startAngle,
      sweepRadians: sweepRadians,
    );

    if (fillColor != null) {
      final fillPaint = Paint()
        ..color = fillColor!
        ..style = PaintingStyle.fill;
      canvas.drawPath(fillPath, fillPaint);
    }

    final strokeRadius = math.max(0.0, radius - (strokeWidth / 2)).toDouble();
    final strokePath = _buildSectorPath(
      center: center,
      radius: strokeRadius,
      startAngle: startAngle,
      sweepRadians: sweepRadians,
    );
    final strokePaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawPath(strokePath, strokePaint);
  }

  Path _buildSectorPath({
    required Offset center,
    required double radius,
    required double startAngle,
    required double sweepRadians,
  }) {
    final rect = Rect.fromCircle(center: center, radius: radius);

    return Path()
      ..moveTo(center.dx, center.dy)
      ..lineTo(
        center.dx + (radius * math.cos(startAngle)),
        center.dy + (radius * math.sin(startAngle)),
      )
      ..arcTo(rect, startAngle, sweepRadians, false)
      ..close();
  }

  @override
  bool shouldRepaint(covariant SectorCirclePainter oldDelegate) {
    return oldDelegate.sweepAngleDegrees != sweepAngleDegrees ||
        oldDelegate.fillColor != fillColor ||
        oldDelegate.strokeColor != strokeColor ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

class _SectorCircleStyle {
  const _SectorCircleStyle({
    required this.fillColor,
    required this.strokeColor,
    required this.strokeWidth,
  });

  final Color? fillColor;
  final Color strokeColor;
  final double strokeWidth;

  factory _SectorCircleStyle.fromValues({
    required CoordinateSystem coordinateSystem,
    required Color outlineColor,
    required int? opacity,
    required bool hasCenterDot,
    required bool hasPerimeter,
  }) {
    if (!hasCenterDot) {
      return _SectorCircleStyle(
        fillColor: outlineColor.withAlpha(opacity ?? 70),
        strokeColor: outlineColor,
        strokeWidth: coordinateSystem.scale(5),
      );
    }

    if (hasPerimeter) {
      return _SectorCircleStyle(
        fillColor: null,
        strokeColor: outlineColor.withAlpha(100),
        strokeWidth: coordinateSystem.scale(2),
      );
    }

    return _SectorCircleStyle(
      fillColor: outlineColor.withAlpha(opacity ?? 70),
      strokeColor: outlineColor,
      strokeWidth: coordinateSystem.scale(2),
    );
  }
}
