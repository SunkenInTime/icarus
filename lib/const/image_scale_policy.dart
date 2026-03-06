abstract final class ImageScalePolicy {
  static const double minWidth = 100;
  static const double maxWidth = 500;
  static const double defaultWidth = 200;

  static double clamp(double value) {
    return value.clamp(minWidth, maxWidth).toDouble();
  }
}

