import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/screenshot/persistent_offscreen_renderer.dart';
import 'package:icarus/services/video_export/video_export_errors.dart';
import 'package:icarus/widgets/asset_svg.dart';

// A 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);
const _svg = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
    '<rect width="10" height="10" fill="#fff"/></svg>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Reads of these assets stay in flight until the test answers them, the way
  // a request does on a slow connection.
  final inFlight = <String, Completer<ByteData?>>{};
  var heldBack = <String>{};

  ByteData bytesOf(String key) => ByteData.sublistView(
        key.endsWith('.svg') ? Uint8List.fromList(utf8.encode(_svg)) : _png,
      );
  void arrive(String key) => inFlight[key]!.complete(bytesOf(key));

  setUp(() {
    inFlight.clear();
    heldBack = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(Uint8List.sublistView(message!));
      if (key.contains('AssetManifest')) {
        return const StandardMessageCodec().encodeMessage(<String, Object?>{});
      }
      if (!heldBack.contains(key)) return bytesOf(key);
      return (inFlight[key] ??= Completer()).future;
    });
  });

  tearDown(() {
    for (final MapEntry(:key, value: read) in inFlight.entries) {
      if (!read.isCompleted) read.complete(bytesOf(key));
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    PaintingBinding.instance.imageCache.clear();
  });

  PersistentOffscreenRenderer renderer({
    Duration stallLimit = const Duration(seconds: 10),
    bool Function()? isCancelled,
  }) =>
      PersistentOffscreenRenderer(
        targetSize: const Size(8, 8),
        pictureStallLimit: stallLimit,
        isCancelled: isCancelled,
      );

  Widget image(String asset) =>
      Image.asset(asset, width: 8, height: 8, fit: BoxFit.fill);

  /// Takes a frame through [capture] with the fixed waits long over, as a
  /// page's are when its pictures are slower than them.
  Future<Uint8List> takenLate(
    PersistentOffscreenRenderer renderer,
    Widget frame,
    void Function() whileWaiting,
  ) async {
    await renderer.prepare(
      frame,
      settleDuration: const Duration(milliseconds: 20),
    );
    final capture = renderer.captureRawRgba(frame);
    var taken = false;
    unawaited(capture.whenComplete(() => taken = true));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(taken, isFalse, reason: 'took a frame with its picture missing');
    whileWaiting();
    return capture;
  }

  testWidgets('a video frame waits for an image still on its way', (
    tester,
  ) async {
    heldBack = {'slow_image.png'};
    await tester.runAsync(() async {
      final capture = renderer();
      final rgba = await takenLate(
        capture,
        image('slow_image.png'),
        () => arrive('slow_image.png'),
      );
      expect(rgba[3], greaterThan(0));
      await capture.dispose(waitForFrame: () async {});
    });
  });

  testWidgets('a video frame waits for an SVG still on its way', (
    tester,
  ) async {
    heldBack = {'slow_map.svg'};
    await tester.runAsync(() async {
      final capture = renderer();
      final rgba = await takenLate(
        capture,
        const AssetSvg('slow_map.svg', width: 8, height: 8, fit: BoxFit.fill),
        () => arrive('slow_map.svg'),
      );
      expect(rgba.sublist(0, 4), [255, 255, 255, 255]);
      await capture.dispose(waitForFrame: () async {});
    });
  });

  // No test here pumps a frame, like a minimized window, and a LayoutBuilder
  // leaves rebuilding what's under it to the next frame.
  testWidgets('a picture under a LayoutBuilder arrives with no app frames', (
    tester,
  ) async {
    heldBack = {'under_builder.svg'};
    await tester.runAsync(() async {
      final capture = renderer(
        stallLimit: const Duration(milliseconds: 500),
      );
      final rgba = await takenLate(
        capture,
        LayoutBuilder(
          builder: (context, constraints) => const AssetSvg(
            'under_builder.svg',
            width: 8,
            height: 8,
            fit: BoxFit.fill,
          ),
        ),
        () => arrive('under_builder.svg'),
      );
      expect(rgba.sublist(0, 4), [255, 255, 255, 255]);
      await capture.dispose(waitForFrame: () async {});
    });
  });

  testWidgets('a screenshot waits for an image still on its way', (
    tester,
  ) async {
    heldBack = {'slow_shot.png'};
    await tester.runAsync(() async {
      final capture = renderer();
      final frame = image('slow_shot.png');
      final png = capture.capture(frame);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      arrive('slow_shot.png');

      final codec = await ui.instantiateImageCodec(await png);
      final picture = (await codec.getNextFrame()).image;
      final rgba = await picture.toByteData();
      expect(rgba!.getUint8(3), greaterThan(0));
      picture.dispose();
      codec.dispose();
      await capture.dispose(waitForFrame: () async {});
    });
  });

  testWidgets('a capture says so when a picture stops coming', (tester) async {
    heldBack = {'stalled.png'};
    await tester.runAsync(() async {
      final capture = renderer(
        stallLimit: const Duration(milliseconds: 100),
      );
      await expectLater(
        capture.captureRawRgba(image('stalled.png')),
        throwsA(
          isA<CaptureImagesUnavailable>().having(
            (error) => error.userMessage,
            'message',
            contains('still loading'),
          ),
        ),
      );
      await capture.dispose(waitForFrame: () async {});
    });
  });

  testWidgets('pictures that keep arriving are never stopped', (tester) async {
    const stallLimit = Duration(seconds: 1);
    const gap = Duration(milliseconds: 700);
    heldBack = {'first.png', 'second.png'};
    await tester.runAsync(() async {
      final capture = renderer(stallLimit: stallLimit);
      final frame = Row(
        textDirection: TextDirection.ltr,
        children: [
          Image.asset('first.png', width: 4, height: 8),
          Image.asset('second.png', width: 4, height: 8),
        ],
      );
      final rgba = capture.captureRawRgba(frame);
      await Future<void>.delayed(gap);
      arrive('first.png');
      await Future<void>.delayed(gap);
      arrive('second.png');
      await rgba;
      await capture.dispose(waitForFrame: () async {});
    });
  });

  testWidgets('a read that fails during the wait stops the capture', (
    tester,
  ) async {
    heldBack = {'failing.png'};
    await tester.runAsync(() async {
      final capture = renderer();
      final rgba = capture.captureRawRgba(image('failing.png'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      inFlight['failing.png']!.complete(null);

      await expectLater(
        rgba,
        throwsA(
          isA<CaptureImagesUnavailable>().having(
            (error) => error.userMessage,
            'message',
            contains("Couldn't load"),
          ),
        ),
      );
      heldBack = {};
      await capture.dispose(waitForFrame: () async {});
    });
  });

  testWidgets('cancelling stops the wait', (tester) async {
    heldBack = {'cancelled.png'};
    await tester.runAsync(() async {
      var cancelled = false;
      final capture = renderer(isCancelled: () => cancelled);
      final rgba = capture.captureRawRgba(image('cancelled.png'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cancelled = true;

      await expectLater(rgba, throwsA(isA<VideoExportCancelled>()));
      await capture.dispose(waitForFrame: () async {});
    });
  });

  testWidgets('a picture on its way holds the box it will draw in', (
    tester,
  ) async {
    heldBack = {'loading_box.svg'};
    await tester.pumpWidget(
      const Center(child: AssetSvg('loading_box.svg', width: 10, height: 20)),
    );

    expect(find.byType(AssetSvgLoading), findsOneWidget);
    expect(tester.getSize(find.byType(AssetSvg)), const Size(10, 20));
  });
}
