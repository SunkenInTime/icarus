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

  group('PlacedText side projection', () {
    test('empty text projection is reversible without mutating storage', () {
      final text = _placedText(text: '');

      _expectTextProjectionRoundTrip(text);
    });

    test('single-line projection is reversible without mutating storage', () {
      final text = _placedText(text: 'one line');

      _expectTextProjectionRoundTrip(text);
    });

    test('wrapped projection is reversible without mutating storage', () {
      final text = _placedText(
        text: 'this text is long enough to wrap across multiple lines',
        size: 90,
      );

      _expectTextProjectionRoundTrip(text);
    });
  });

  test('PlacedImage projection is reversible without mutating storage', () {
    final image = PlacedImage(
      id: 'image-1',
      position: const Offset(200, 220),
      aspectRatio: 16 / 9,
      scale: ImageScalePolicy.defaultWidth,
      fileExtension: '.png',
      sizeVersion: worldSizedMediaVersion,
    );

    final coordinateSystem = CoordinateSystem.instance;
    final canonicalScreen = coordinateSystem.coordinateToScreen(image.position);
    final size = PlacedImageDimensions.screenSize(
      coordinateSystem: coordinateSystem,
      scale: image.scale,
      aspectRatio: image.aspectRatio,
    );
    final defense = coordinateSystem.screenPositionForSide(
      attackScreenPosition: canonicalScreen,
      reflectionOffset: Offset(size.width, size.height),
      isAttack: false,
    );
    final recovered = coordinateSystem.screenPositionFromSide(
      sideScreenPosition: defense,
      reflectionOffset: Offset(size.width, size.height),
      isAttack: false,
    );

    _expectClose(recovered, canonicalScreen);
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

void _expectTextProjectionRoundTrip(PlacedText text) {
  final coordinateSystem = CoordinateSystem.instance;
  final canonicalScreen = coordinateSystem.coordinateToScreen(text.position);
  final size = PlacedTextDimensions.screenSize(
    coordinateSystem: coordinateSystem,
    widthWorld: text.size,
    fontSizeWorld: text.fontSize,
    text: text.text,
  );
  final defense = coordinateSystem.screenPositionForSide(
    attackScreenPosition: canonicalScreen,
    reflectionOffset: Offset(size.width, size.height),
    isAttack: false,
  );
  final recovered = coordinateSystem.screenPositionFromSide(
    sideScreenPosition: defense,
    reflectionOffset: Offset(size.width, size.height),
    isAttack: false,
  );

  _expectClose(recovered, canonicalScreen);
  _expectClose(text.position, const Offset(100, 120));
}

void _expectClose(Offset actual, Offset expected) {
  expect(actual.dx, closeTo(expected.dx, 1e-9));
  expect(actual.dy, closeTo(expected.dy, 1e-9));
}
