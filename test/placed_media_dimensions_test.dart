import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/image_scale_policy.dart';
import 'package:icarus/const/placed_media_dimensions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  test('image helper returns expected width and height', () {
    final size = PlacedImageDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      scale: ImageScalePolicy.defaultWidth,
      aspectRatio: 2.0,
    );

    final expectedWidth = CoordinateSystem.instance
        .worldWidthToScreen(ImageScalePolicy.defaultWidth);
    final cardWidth = expectedWidth -
        PlacedImageDimensions.tagWidth -
        PlacedImageDimensions.tagGap;
    final contentWidth = cardWidth - (PlacedImageDimensions.imagePadding * 2);
    final expectedHeight =
        (contentWidth / 2.0) + (PlacedImageDimensions.imagePadding * 2);

    expect(size.width, expectedWidth);
    expect(size.height, expectedHeight);
  });

  test('image helper clamps scale', () {
    final size = PlacedImageDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      scale: ImageScalePolicy.maxWidth * 10,
      aspectRatio: 1.0,
    );

    expect(
      size.width,
      CoordinateSystem.instance.worldWidthToScreen(ImageScalePolicy.maxWidth),
    );
  });

  test('image helper falls back to square aspect ratio', () {
    final zeroAspect = PlacedImageDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      scale: ImageScalePolicy.defaultWidth,
      aspectRatio: 0,
    );
    final squareAspect = PlacedImageDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      scale: ImageScalePolicy.defaultWidth,
      aspectRatio: 1,
    );

    expect(zeroAspect, squareAspect);
  });

  test('text helper returns deterministic screen width', () {
    final size = PlacedTextDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      widthWorld: 220,
      fontSizeWorld: 16,
      text: 'one line',
    );

    expect(size.width, CoordinateSystem.instance.worldWidthToScreen(220));
  });

  test('text helper uses one-line height for empty text', () {
    final empty = PlacedTextDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      widthWorld: 220,
      fontSizeWorld: 16,
      text: '',
    );
    final singleLine = PlacedTextDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      widthWorld: 220,
      fontSizeWorld: 16,
      text: 'one line',
    );

    expect(empty.height, singleLine.height);
    expect(empty.height, lessThan(64));
  });

  test('text helper height increases for wrapped text', () {
    final singleLine = PlacedTextDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      widthWorld: 220,
      fontSizeWorld: 16,
      text: 'short text',
    );
    final wrapped = PlacedTextDimensions.screenSize(
      coordinateSystem: CoordinateSystem.instance,
      widthWorld: 80,
      fontSizeWorld: 16,
      text: 'this is a long annotation that should wrap across several lines',
    );

    expect(wrapped.height, greaterThan(singleLine.height));
  });
}
