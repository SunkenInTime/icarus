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

    test('a picture twice its box or more is halved until it just fits', () {
      // An 8K screenshot in a 16:9 box half its width.
      final size = target(7680, 4320, 3840, 2160);
      expect((size.width, size.height), (3840, 2160));
      // A quarter of it is still more than the box needs, an eighth is not.
      final halved = target(7680, 4320, 1000, 563);
      expect((halved.width, halved.height), (1920, 1080));
    });

    test('a picture less than twice its box keeps every pixel', () {
      // Shrunk to anything but a half, it would draw softer.
      final size = target(7680, 4320, 3976, 2236);
      expect((size.width, size.height), (null, null));
    });

    test(
        'the side that needs more pixels sets the scale, so the picture '
        'still covers a box of another shape', () {
      // A wide picture in a square thumbnail: its height must fill the box,
      // so its width overflows it.
      final size = target(4000, 1000, 200, 200);
      expect((size.width, size.height), (1000, 250));
    });

    test('a picture smaller than its box keeps every pixel', () {
      final size = target(1920, 1080, 3974, 2236);
      expect((size.width, size.height), (null, null));
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

  testWidgets('a big picture decodes at the size of its box', (tester) async {
    final png = _png(2000, 500);

    expect(
      await _decodedSize(
        tester,
        ResizeToCover(MemoryImage(png), box: const Size(400, 100)),
      ),
      const Size(500, 125),
    );
    expect(
      await _decodedSize(
        tester,
        ResizeToCover(MemoryImage(png), box: const Size(4000, 1000)),
      ),
      const Size(2000, 500),
    );
  });

  testWidgets('the same picture in the same box shares one decode',
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

  testWidgets('a picture added to a page gets its aspect ratio from its size',
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
