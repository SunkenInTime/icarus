// One-off helper: extracts the largest frame of the Windows app icon into
// assets/logo.png so in-app UI (e.g. the update dialog) can show the logo.
// Run with: flutter pub run / dart run tool/extract_app_icon.dart
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final bytes = File('windows/runner/resources/app_icon.ico').readAsBytesSync();
  final ico = img.IcoDecoder()..startDecode(bytes);
  final frameCount = ico.numFrames();

  img.Image? largest;
  for (var i = 0; i < frameCount; i++) {
    final frame = ico.decodeFrame(i);
    if (frame == null) continue;
    if (largest == null || frame.width > largest.width) {
      largest = frame;
    }
  }

  if (largest == null) {
    stderr.writeln('No decodable frames found in app_icon.ico');
    exit(1);
  }

  File('assets/logo.png').writeAsBytesSync(img.encodePng(largest));
  stdout.writeln('Wrote assets/logo.png (${largest.width}x${largest.height})');

  // Also produce a white-mark-on-transparent version: the icon is a white
  // glyph on a black tile, so luminance maps directly to alpha.
  final mark = img.Image(
    width: largest.width,
    height: largest.height,
    numChannels: 4,
  );
  for (final pixel in largest) {
    final lum = img.getLuminanceRgb(pixel.r, pixel.g, pixel.b);
    mark.setPixelRgba(pixel.x, pixel.y, 255, 255, 255, lum.round());
  }
  File('assets/logo_mark.png').writeAsBytesSync(img.encodePng(mark));
  stdout.writeln('Wrote assets/logo_mark.png');
}
