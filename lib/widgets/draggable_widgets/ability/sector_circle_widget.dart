import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SectorCircleWidget extends ConsumerWidget {
  static const double handleTopInsetVirtual = 7.5;

  const SectorCircleWidget({
    super.key,
    required this.iconPath,
    required this.size,
    required this.rangeOutlineColor,
    required this.sweepAngleDegrees,
    required this.hasCenterDot,
    this.opacity = 70,
    this.rangeFillColor,
    this.innerRangeColor,
    this.innerRangeSize,
    required this.id,
    required this.isAlly,
    this.lineUpId,
    this.rotation,
    this.visualState,
    this.watchMouse = true,
    this.contextMenuItems,
  });

  final String? lineUpId;
  final bool isAlly;
  final String? id;
  final String iconPath;
  final double size;
  final Color rangeOutlineColor;
  final double sweepAngleDegrees;
  final bool hasCenterDot;
  final int? opacity;
  final Color? rangeFillColor;
  final Color? innerRangeColor;
  final double? innerRangeSize;
  final double? rotation;
  final AbilityVisualState? visualState;
  final bool watchMouse;
  final List<ShadContextMenuItem>? contextMenuItems;

  bool get hasInnerRange => innerRangeSize != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final scaleSize = coordinateSystem.scale(size);
    final scaledInnerRangeSize = coordinateSystem.scale(innerRangeSize ?? 0);
    final scaledTopInset = coordinateSystem.scale(handleTopInsetVirtual);
    final resolvedVisualState = visualState ?? const AbilityVisualState();
    final style = _SectorCircleStyle.fromValues(
      coordinateSystem: coordinateSystem,
      rangeOutlineColor: rangeOutlineColor,
      rangeFillColor: rangeFillColor,
      opacity: opacity,
      hasCenterDot: hasCenterDot,
      hasInnerRange: hasInnerRange,
      showRangeOutline: resolvedVisualState.showRangeOutline,
      showRangeFill: resolvedVisualState.showRangeFill,
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
                        key: const ValueKey('sector-range-layer'),
                        painter: SectorCirclePainter(
                          sweepAngleDegrees: sweepAngleDegrees,
                          fillColor: style.fillColor,
                          strokeColor: style.strokeColor,
                          strokeWidth: style.strokeWidth,
                        ),
                      ),
                    ),
                  ),
                  if (hasInnerRange) ...[
                    _buildInnerRangeFill(
                      scaledInnerRangeSize,
                      resolvedVisualState.showInnerFill,
                    ),
                    _buildInnerRangeOutline(
                      coordinateSystem,
                      scaledInnerRangeSize,
                      resolvedVisualState.showInnerOutline,
                    ),
                  ],
                  if (hasCenterDot) _buildCenterIcon(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInnerRangeFill(
    double scaledInnerRangeSize,
    bool showInnerFill,
  ) {
    assert(
      innerRangeColor != null,
      'innerRangeColor is required when innerRangeSize is set',
    );

    return Positioned.fill(
      child: Opacity(
        key: const ValueKey('sector-inner-fill-layer'),
        opacity: showInnerFill ? 1 : 0,
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.center,
            child: Container(
              width: scaledInnerRangeSize,
              height: scaledInnerRangeSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: innerRangeColor!.withAlpha(opacity ?? 70),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInnerRangeOutline(
    CoordinateSystem coordinateSystem,
    double scaledInnerRangeSize,
    bool showInnerOutline,
  ) {
    assert(
      innerRangeColor != null,
      'innerRangeColor is required when innerRangeSize is set',
    );

    return Positioned.fill(
      child: Opacity(
        key: const ValueKey('sector-inner-outline-layer'),
        opacity: showInnerOutline ? 1 : 0,
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.center,
            child: Container(
              width: scaledInnerRangeSize,
              height: scaledInnerRangeSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: innerRangeColor!,
                  width: coordinateSystem.scale(2),
                ),
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
            watchMouse: watchMouse,
            contextMenuItems: contextMenuItems,
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

    if (strokeWidth > 0 && strokeColor.a > 0) {
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
    required Color rangeOutlineColor,
    required Color? rangeFillColor,
    required int? opacity,
    required bool hasCenterDot,
    required bool hasInnerRange,
    required bool showRangeOutline,
    required bool showRangeFill,
  }) {
    final baseStyle = _baseStyle(
      coordinateSystem: coordinateSystem,
      rangeOutlineColor: rangeOutlineColor,
      rangeFillColor: rangeFillColor,
      opacity: opacity,
      hasCenterDot: hasCenterDot,
      hasInnerRange: hasInnerRange,
    );

    return _SectorCircleStyle(
      fillColor: showRangeFill ? baseStyle.fillColor : null,
      strokeColor: showRangeOutline ? baseStyle.strokeColor : Colors.transparent,
      strokeWidth: showRangeOutline ? baseStyle.strokeWidth : 0,
    );
  }

  static _SectorCircleStyle _baseStyle({
    required CoordinateSystem coordinateSystem,
    required Color rangeOutlineColor,
    required Color? rangeFillColor,
    required int? opacity,
    required bool hasCenterDot,
    required bool hasInnerRange,
  }) {
    if (hasInnerRange) {
      return _SectorCircleStyle(
        fillColor: null,
        strokeColor: rangeOutlineColor.withAlpha(100),
        strokeWidth: coordinateSystem.scale(2),
      );
    }

    return _SectorCircleStyle(
      fillColor:
          rangeFillColor ?? rangeOutlineColor.withAlpha(opacity ?? 70),
      strokeColor: rangeOutlineColor,
      strokeWidth: coordinateSystem.scale(hasCenterDot ? 2 : 5),
    );
  }
}
