import 'package:flutter/material.dart';

class CursorCircle extends StatelessWidget {
  const CursorCircle({
    super.key,
    required this.size,
    required this.ringThickness,
    required this.gap,
    required this.ringColor,
    required this.fillColor,
  });

  final double size;
  final double ringThickness;
  final double gap;
  final Color ringColor;
  final Color fillColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CursorCirclePainter(
          ringThickness: ringThickness,
          gap: gap,
          ringColor: ringColor,
          fillColor: fillColor,
        ),
      ),
    );
  }
}

class _CursorCirclePainter extends CustomPainter {
  _CursorCirclePainter({
    required this.ringThickness,
    required this.gap,
    required this.ringColor,
    required this.fillColor,
  });

  final double ringThickness;
  final double gap;
  final Color ringColor;
  final Color fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final outerRadius = size.shortestSide / 2;
    final ringRadius = outerRadius - (ringThickness / 2);
    final innerRadius = outerRadius - ringThickness - gap;

    // Outer ring
    final ringPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringThickness;
    canvas.drawCircle(center, ringRadius, ringPaint);

    // Inner filled circle
    if (innerRadius > 0) {
      final fillPaint = Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, innerRadius, fillPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CursorCirclePainter oldDelegate) {
    return oldDelegate.ringThickness != ringThickness ||
        oldDelegate.gap != gap ||
        oldDelegate.ringColor != ringColor ||
        oldDelegate.fillColor != fillColor;
  }
}
