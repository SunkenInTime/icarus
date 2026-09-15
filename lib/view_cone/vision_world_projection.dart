import 'dart:ui';

/// The artwork can scale its two axes differently. Sight angles and distances
/// are measured in physical meters, then transformed into that same artwork.
class VisionWorldProjection {
  VisionWorldProjection({
    required this.origin,
    required this.axisU,
    required this.axisV,
  }) {
    final determinant = axisU.dx * axisV.dy - axisU.dy * axisV.dx;
    if (!determinant.isFinite || determinant.abs() < 1e-12) {
      throw const FormatException('Invalid world-to-canvas projection.');
    }
    _determinant = determinant;
  }

  final Offset origin;
  final Offset axisU;
  final Offset axisV;
  late final double _determinant;

  Offset vectorToMeters(Offset vector) => Offset(
        (vector.dx * axisV.dy - vector.dy * axisV.dx) / _determinant,
        (axisU.dx * vector.dy - axisU.dy * vector.dx) / _determinant,
      );

  Offset toMeters(Offset point) => vectorToMeters(point - origin);

  Offset toCanvas(Offset point) => origin + axisU * point.dx + axisV * point.dy;

  VisionWorldProjection get defense => VisionWorldProjection(
        origin: Offset(1000 * (16 / 9) - origin.dx, 1000 - origin.dy),
        axisU: -axisU,
        axisV: -axisV,
      );
}
