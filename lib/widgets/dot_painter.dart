// import 'package:flutter/material.dart';
// import 'package:icarus/const/coordinate_system.dart';

// class DotGrid extends StatelessWidget {
//   const DotGrid({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return CustomPaint(painter: DotPainter());
//   }
// }

// class DotPainter extends CustomPainter {
//   final playAreaSize = CoordinateSystem.instance.playAreaSize;
//   static const double dotSize = 3; // Size of each dot
//   static const double dotSpacing = 9.5;

//   @override
//   @override
//   void paint(Canvas canvas, Size size) {
//     final paint = Paint()
//       ..color = const Color.fromRGBO(210, 214, 219, 0.1)
//       ..style = PaintingStyle.fill;

//     // Use ceiling instead of floor to include partial spaces
//     int rows = (size.height / dotSpacing).ceil();
//     int columns = (size.width / dotSpacing).ceil();

//     for (int row = 0; row < rows; row++) {
//       for (int column = 0; column < columns; column++) {
//         double x = column * dotSpacing;
//         // Don't draw dots that would go beyond the size
//         if (x > size.width) continue;

//         double y = row * dotSpacing;
//         if (y > size.height) continue;

//         canvas.drawCircle(Offset(x, y), dotSize / 2, paint);
//       }
//     }
//   }

//   @override
//   bool shouldRepaint(DotPainter oldDelegate) {
//     if (oldDelegate.playAreaSize != playAreaSize) {
//       return true;
//     }
//     return false;
//   }
// }
import 'package:flutter/material.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';

class DotGrid extends StatelessWidget {
  const DotGrid({
    super.key,
    this.isScreenshot = false,
  });
  final bool isScreenshot;
  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: DotPainter(isScreenshot: isScreenshot));
  }
}

class DotPainter extends CustomPainter {
  DotPainter({required this.isScreenshot});

  final bool isScreenshot;

  Size playAreaSize = CoordinateSystem.instance.playAreaSize;
  static const double dotSize = 3; // Size of each dot
  static const double dotSpacing = 9.5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Settings.tacticalVioletTheme.border.withOpacity(0.7)
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
    if (oldDelegate.isScreenshot != isScreenshot) {
      playAreaSize = isScreenshot
          ? CoordinateSystem.screenShotSize
          : CoordinateSystem.instance.playAreaSize;
      return true;
    }
    // if (oldDelegate.playAreaSize != playAreaSize) {
    //   return true;
    // }
    return false;
  }
}
