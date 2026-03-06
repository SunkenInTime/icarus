// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';

// //Add this CustomPaint widget to the Widget Tree
// CustomPaint(
//     size = Size(558, 445),
//     painter = RPSCustomPainter(),
// )

// Color shadeColor(Color color, double amount) {
//   // amount < 0 => darken, amount > 0 => lighten, range -1.0 to 1.0
//   assert(amount >= -1.0 && amount <= 1.0);
//   if (amount == 0) return color;

//   final target = amount > 0 ? Colors.white : Colors.black;
//   final t = amount.abs();

//   int mix(int channel, int mixWith) =>
//       (channel + ((mixWith - channel) * t)).round().clamp(0, 255);

//   return Color.fromARGB(
//     color.alpha,
//     mix(color.red, target.red),
//     mix(color.green, target.green),
//     mix(color.blue, target.blue),
//   );
// }

//Copy this CustomPainter code to the Bottom of the File
class CustomFolderPainter extends CustomPainter {
  final Color strokeColor;
  final Color backgroundColor;
  CustomFolderPainter({
    super.repaint,
    required this.strokeColor,
    required this.backgroundColor,
  });
  @override
  void paint(Canvas canvas, Size size) {
    // Calculate scale factors based on original size (558x445)
    double scaleX = size.width / 558;
    double scaleY = size.height / 445;

    Path path_0 = Path();
    path_0.moveTo(223.2 * scaleX, 0);
    path_0.lineTo(55.8 * scaleX, 0);
    path_0.cubicTo(25.11 * scaleX, 0, 0.279 * scaleX, 25.0312 * scaleY,
        0.279 * scaleX, 55.625 * scaleY);
    path_0.lineTo(0, 389.375 * scaleY);
    path_0.cubicTo(0, 419.969 * scaleY, 25.11 * scaleX, 445 * scaleY,
        55.8 * scaleX, 445 * scaleY);
    path_0.lineTo(502.2 * scaleX, 445 * scaleY);
    path_0.cubicTo(532.89 * scaleX, 445 * scaleY, 558 * scaleX,
        419.969 * scaleY, 558 * scaleX, 389.375 * scaleY);
    path_0.lineTo(558 * scaleX, 111.25 * scaleY);
    path_0.cubicTo(558 * scaleX, 80.6562 * scaleY, 532.89 * scaleX,
        55.625 * scaleY, 502.2 * scaleX, 55.625 * scaleY);
    path_0.lineTo(279 * scaleX, 55.625 * scaleY);
    path_0.lineTo(223.2 * scaleX, 0);
    path_0.close();

    Paint paint0Fill = Paint()..style = PaintingStyle.fill;
    paint0Fill.color = backgroundColor;
    canvas.drawPath(path_0, paint0Fill);

    Path path_1 = Path();
    path_1.moveTo(55.7998 * scaleX, 1 * scaleY);
    path_1.lineTo(222.787 * scaleX, 1 * scaleY);
    path_1.lineTo(278.294 * scaleX, 56.333 * scaleY);
    path_1.lineTo(278.587 * scaleX, 56.625 * scaleY);
    path_1.lineTo(502.2 * scaleX, 56.625 * scaleY);
    path_1.cubicTo(532.341 * scaleX, 56.6251 * scaleY, 557 * scaleX,
        81.2116 * scaleY, 557 * scaleX, 111.25 * scaleY);
    path_1.lineTo(557 * scaleX, 389.375 * scaleY);
    path_1.cubicTo(557 * scaleX, 419.413 * scaleY, 532.341 * scaleX,
        444 * scaleY, 502.2 * scaleX, 444 * scaleY);
    path_1.lineTo(55.7998 * scaleX, 444 * scaleY);
    path_1.cubicTo(25.6595 * scaleX, 444 * scaleY, 1.00053 * scaleX,
        419.414 * scaleY, 1 * scaleX, 389.376 * scaleY);
    path_1.lineTo(1.2793 * scaleX, 55.626 * scaleY);
    path_1.lineTo(1.2793 * scaleX, 55.625 * scaleY);
    path_1.cubicTo(1.2793 * scaleX, 25.58 * scaleY, 25.6657 * scaleX,
        1.00011 * scaleY, 55.7998 * scaleX, 1 * scaleY);
    path_1.close();

    Paint paint1Stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.014584229
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    //Change this to purpleAccent when hovered
    paint1Stroke.color = strokeColor;
    canvas.drawPath(path_1, paint1Stroke);

    Paint paint1Fill = Paint()..style = PaintingStyle.fill;
    paint1Fill.color = backgroundColor;

    canvas.drawPath(path_1, paint1Fill);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}

