import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/services/resize_to_cover.dart';
import 'package:image/image.dart' as img;

/// A real PNG [width] × [height].
Uint8List _png(int width, int height) =>
    img.encodePng(img.Image(width: width, height: height));

/// The size [image] decodes to.
Future<Size> _decodedSize(WidgetTester tester, ImageProvider image) async {
  final size = await tester.runAsync(() {
    final decoded = Completer<Size>();
    final stream = image.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        decoded.complete(
          Size(info.image.width.toDouble(), info.image.height.toDouble()),
        );
        info.dispose();
        stream.removeListener(listener);
      },
      onError: (error, stackTrace) => decoded.completeError(error, stackTrace!),
    );
    stream.addListener(listener);
    return decoded.future;
  });
  return size!;
}

void main() {
  tearDown(() => PaintingBinding.instance.imageCache.clear());

  group('ResizeToCover.targetSize', () {
    ui.TargetImageSize target(int w, int h, int boxW, int boxH) =>
        ResizeToCover.targetSize(
          intrinsicWidth: w,
          intrinsicHeight: h,
          width: boxW,
          height: boxH,
        );

    test('a picture twice its box or more is halved, and only once', () {
      // An 8K screenshot in a 16:9 box half its width.
      final size = target(7680, 4320, 3840, 2160);
      expect((size.width, size.height), (3840, 2160));
      // A box an eighth its width still gets the half: smaller, the
      // decoder would sample fine detail rather than average it.
      final small = target(7680, 4320, 960, 540);
      expect((small.width, small.height), (3840, 2160));
    });

    test('a picture less than twice its box keeps every pixel', () {
      final size = target(7680, 4320, 3976, 2236);
      expect((size.width, size.height), (null, null));
    });

    test(
        'the side that needs more pixels sets the scale, so the picture '
        'still covers a box of another shape', () {
      // A wide picture in a square thumbnail: its height must fill the box,
      // so its width overflows it.
      final size = target(4000, 1000, 200, 600);
      expect((size.width, size.height), (null, null));
      final halved = target(4000, 1000, 200, 500);
      expect((halved.width, halved.height), (2000, 500));
    });

    test('a picture smaller than its box keeps every pixel', () {
      final size = target(1920, 1080, 3974, 2236);
      expect((size.width, size.height), (null, null));
    });

    test(
        'a halving that would change the picture\'s shape by half a pixel '
        'at its box is not taken', () {
      // An 8000x101 strip in a 497 px wide box: a half would be 4000x51,
      // a 1% wider strip, 5 px at the box's width.
      final strip = target(8000, 101, 497, 7);
      expect((strip.width, strip.height), (null, null));
      // A shape that halves evenly still does.
      final even = target(8000, 100, 497, 7);
      expect((even.width, even.height), (4000, 50));
    });

    test('a box with no finite size keeps every pixel', () {
      final box = ResizeToCover(
        MemoryImage(Uint8List(0)),
        box: const Size(double.infinity, double.infinity),
      );
      final size = target(1920, 1080, box.width, box.height);
      expect((size.width, size.height), (null, null));
    });
  });

  testWidgets('a picture at least twice its box decodes at half size',
      (tester) async {
    final png = _png(2000, 500);

    expect(
      await _decodedSize(
        tester,
        ResizeToCover(MemoryImage(png), box: const Size(400, 100)),
      ),
      const Size(1000, 250),
    );
    expect(
      await _decodedSize(
        tester,
        ResizeToCover(MemoryImage(png), box: const Size(4000, 1000)),
      ),
      const Size(2000, 500),
    );
  });

  testWidgets(
      'the half averages each 2x2 block, like the first mipmap level, '
      'so one-pixel detail turns grey rather than vanishing', (tester) async {
    // Columns black, white, white, black: every pair of columns averages to
    // grey. Sampling one column of each pair would keep black and white.
    final stripes = img.Image(width: 64, height: 8);
    for (final pixel in stripes) {
      final white = (pixel.x % 4 == 1 || pixel.x % 4 == 2);
      pixel.setRgb(white ? 255 : 0, white ? 255 : 0, white ? 255 : 0);
    }
    final provider = ResizeToCover(
      MemoryImage(img.encodePng(stripes)),
      box: const Size(32, 4),
    );

    final rgba = await tester.runAsync(() async {
      final decoded = Completer<ui.Image>();
      provider.resolve(ImageConfiguration.empty).addListener(
            ImageStreamListener((info, _) => decoded.complete(info.image)),
          );
      final image = await decoded.future;
      expect((image.width, image.height), (32, 4));
      return image.toByteData();
    });
    for (var i = 0; i < rgba!.lengthInBytes; i += 4) {
      expect(rgba.getUint8(i), inInclusiveRange(120, 135));
    }
  });

  testWidgets('the same picture in boxes the same whole size shares one key',
      (tester) async {
    final image = MemoryImage(_png(64, 64));
    final a = ResizeToCover(image, box: const Size(10.2, 10.2));
    final b = ResizeToCover(image, box: const Size(10.9, 10.9));
    final c = ResizeToCover(image, box: const Size(20, 20));

    expect(a, b);
    expect(
      await a.obtainKey(ImageConfiguration.empty),
      await b.obtainKey(ImageConfiguration.empty),
    );
    expect(a, isNot(c));
  });

  testWidgets('a picture added to a page still gets its aspect ratio',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final ratio = await tester.runAsync(
      () => container
          .read(placedImageProvider.notifier)
          .getImageAspectRatio(_png(300, 120)),
    );
    expect(ratio, 2.5);
  });
}
