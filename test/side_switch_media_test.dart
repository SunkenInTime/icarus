import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/image_scale_policy.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/placed_media_dimensions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('PlacedText side switch', () {
    test('double switch returns empty text to original position', () {
      final text = _placedText(text: '');

      _switchText(text);
      _switchText(text);

      _expectClose(text.position, const Offset(100, 120));
    });

    test('double switch returns single-line text to original position', () {
      final text = _placedText(text: 'one line');

      _switchText(text);
      _switchText(text);

      _expectClose(text.position, const Offset(100, 120));
    });

    test('double switch returns wrapped text to original position', () {
      final text = _placedText(
        text: 'this text is long enough to wrap across multiple lines',
        size: 90,
      );

      _switchText(text);
      _switchText(text);

      _expectClose(text.position, const Offset(100, 120));
    });
  });

  test(
      'PlacedImage double switch returns non-square image to original position',
      () {
    final image = PlacedImage(
      id: 'image-1',
      position: const Offset(200, 220),
      aspectRatio: 16 / 9,
      scale: ImageScalePolicy.defaultWidth,
      fileExtension: '.png',
      sizeVersion: worldSizedMediaVersion,
    );

    _switchImage(image);
    _switchImage(image);

    _expectClose(image.position, const Offset(200, 220));
  });
}

PlacedText _placedText({
  required String text,
  double size = 220,
}) {
  return PlacedText(
    id: 'text-1',
    position: const Offset(100, 120),
    size: size,
    fontSize: 16,
    sizeVersion: worldSizedMediaVersion,
  )..text = text;
}

void _switchText(PlacedText text) {
  final size = PlacedTextDimensions.screenSize(
    coordinateSystem: CoordinateSystem.instance,
    widthWorld: text.size,
    fontSizeWorld: text.fontSize,
    text: text.text,
  );

  text.switchSides(Offset(size.width, size.height));
}

void _switchImage(PlacedImage image) {
  final size = PlacedImageDimensions.screenSize(
    coordinateSystem: CoordinateSystem.instance,
    scale: image.scale,
    aspectRatio: image.aspectRatio,
  );

  image.switchSides(Offset(size.width, size.height));
}

void _expectClose(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 1e-9));
  expect(actual.dy, closeTo(expected.dy, 1e-9));
}
