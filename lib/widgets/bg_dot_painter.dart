import 'package:flutter/material.dart';
import 'package:icarus/const/settings.dart';

class BGDotGrid extends StatelessWidget {
  final Size size;

  const BGDotGrid({
    super.key,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            size: size,
            painter: DotPainter(size: size),
          ),
        ),
      ],
    );
  }
}

class DotPainter extends CustomPainter {
  final Size size;

  static const double dotSize = 3; // Size of each dot
  static const double dotSpacing = 9.5;

  DotPainter({required this.size});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Settings.tacticalVioletTheme.border.withOpacity(0.2)
      ..style = PaintingStyle.fill;

    // Calculate how many dots we need in each direction
    int rows = (size.height / dotSpacing).ceil() + 1;
    int columns = (size.width / dotSpacing).ceil() + 1;

    // Calculate the starting positions to ensure dots at edges
    double startX = 0;
    double startY = 0;

    // If we have more than one column/row, adjust spacing to ensure dots at edges
    double adjustedHorizontalSpacing =
        columns > 1 ? size.width / (columns - 1) : 0;
    double adjustedVerticalSpacing = rows > 1 ? size.height / (rows - 1) : 0;

    for (int row = 0; row < rows; row++) {
      for (int column = 0; column < columns; column++) {
        // Calculate position using adjusted spacing to ensure dots at edges
        double x = startX + column * adjustedHorizontalSpacing;
        double y = startY + row * adjustedVerticalSpacing;

        // Skip dots that would be outside the visible area
        if (x > size.width || y > size.height) continue;

        canvas.drawCircle(Offset(x, y), dotSize / 2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(DotPainter oldDelegate) {
    return oldDelegate.size != size;
  }
}
