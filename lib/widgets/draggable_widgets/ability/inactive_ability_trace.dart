import 'dart:math' as math;

import 'package:flutter/material.dart';

const abilityStateTransitionDuration = Duration(milliseconds: 180);

Color abilityWallDisplayColor(Color color) => color.withAlpha(100);

class InactiveCircleAbilityTrace extends StatelessWidget {
  const InactiveCircleAbilityTrace({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      key: const ValueKey('inactive-circle-trace'),
      painter: InactiveCircleAbilityTracePainter(
        color: abilityWallDisplayColor(color),
      ),
    );
  }
}

class InactiveWallAbilityTrace extends StatelessWidget {
  const InactiveWallAbilityTrace({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      key: const ValueKey('inactive-wall-trace'),
      painter: InactiveWallAbilityTracePainter(
        color: abilityWallDisplayColor(color),
      ),
    );
  }
}

class InactiveCircleAbilityTracePainter extends CustomPainter {
  const InactiveCircleAbilityTracePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 2.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    const inset = strokeWidth / 2;
    final boundary = Path()
      ..addOval(
        Rect.fromLTWH(
          inset,
          inset,
          math.max(0, size.width - strokeWidth),
          math.max(0, size.height - strokeWidth),
        ),
      );

    _drawDashedPath(canvas, boundary, paint);

    canvas.drawCircle(
      size.center(Offset.zero),
      3,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(InactiveCircleAbilityTracePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class InactiveWallAbilityTracePainter extends CustomPainter {
  const InactiveWallAbilityTracePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 2.0;
    const inset = strokeWidth / 2;
    final start = Offset(size.width / 2, inset);
    final end = Offset(size.width / 2, size.height - inset);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..lineTo(end.dx, end.dy);
    final tracePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    _drawDashedPath(canvas, path, tracePaint);
  }

  @override
  bool shouldRepaint(InactiveWallAbilityTracePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

void _drawDashedPath(
  Canvas canvas,
  Path path,
  Paint paint, {
  double dashLength = 8,
  double gapLength = 5,
}) {
  for (final metric in path.computeMetrics()) {
    double distance = 0;
    while (distance < metric.length) {
      final end = math.min(distance + dashLength, metric.length);
      canvas.drawPath(metric.extractPath(distance, end), paint);
      distance = end + gapLength;
    }
  }
}
