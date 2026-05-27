abstract final class ImageScalePolicy {
  static const double minWidth = 90;
  static const double maxWidth = 460;
  static const double defaultWidth = 185;

  static double clamp(double value) {
    return value.clamp(minWidth, maxWidth).toDouble();
  }
}
