import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;

Uint8List _png(int red) => Uint8List.fromList(
      img.encodePng(
        img.fill(
          img.Image(width: 4, height: 4),
          color: img.ColorRgb8(red, 0, 0),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fetched = _png(10);
  final pending = _png(20);
  late Directory dir;
  late String filePath;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('icarus_capture_images');
    filePath = path.join(dir.path, 'file.png');
    await File(filePath).writeAsBytes(_png(30));
  });

  tearDownAll(() => dir.delete(recursive: true));

  test('cloud URLs are fetched; everything else paints as the editor would',
      () async {
    final requests = <(String, String)>[];
    final images = await resolveCaptureImages(
      {
        'remote': const RemoteImageUrl('https://media.example.com/remote.png'),
        'file': LocalImageFile(filePath),
        'uploading': ImageBytes(pending),
        'failed': const ImageFailed(),
      },
      fetch: (imageId, url) async {
        requests.add((imageId, url));
        return fetched;
      },
    );
    addTearDown(images.release);

    expect(requests, [('remote', 'https://media.example.com/remote.png')]);
    final sources = images.sources;
    expect((sources['remote'] as ImageBytes).bytes, fetched);
    expect((sources['file'] as LocalImageFile).path, filePath);
    expect((sources['uploading'] as ImageBytes).bytes, pending);
    expect(sources['failed'], isA<ImageFailed>());
  });

  test('every image that paints is decoded and held until released', () async {
    final cache = PaintingBinding.instance.imageCache;
    final images = await resolveCaptureImages(
      {
        'remote': const RemoteImageUrl('https://media.example.com/remote.png'),
        'file': LocalImageFile(filePath),
      },
      fetch: (_, __) async => fetched,
    );

    // The capture's widgets ask for the same keys and find them decoded.
    final keys = [
      for (final source in images.sources.values)
        await source.imageProvider!.obtainKey(ImageConfiguration.empty),
    ];
    for (final key in keys) {
      expect(cache.statusForKey(key).keepAlive, isTrue);
    }

    images.release();
    cache.clear();
    for (final key in keys) {
      expect(cache.statusForKey(key).untracked, isTrue);
    }
  });

  test('an image still loading stops the capture', () async {
    await expectLater(
      resolveCaptureImages(
        {'loading': const ImageLoading()},
        fetch: (_, __) async => fetched,
      ),
      throwsA(
        isA<CaptureImagesUnavailable>()
            .having((error) => error.cause, 'cause', isNull)
            .having(
              (error) => error.userMessage,
              'userMessage',
              contains('still loading'),
            ),
      ),
    );
  });

  test('a failed fetch stops the capture and keeps its cause', () async {
    final failure = Exception('offline');
    await expectLater(
      resolveCaptureImages(
        {'remote': const RemoteImageUrl('https://media.example.com/r.png')},
        fetch: (_, __) async => throw failure,
      ),
      throwsA(
        isA<CaptureImagesUnavailable>()
            .having((error) => error.cause, 'cause', same(failure))
            .having(
              (error) => error.userMessage,
              'userMessage',
              contains('connection'),
            ),
      ),
    );
  });

  test('bytes that do not decode stop the capture', () async {
    await expectLater(
      resolveCaptureImages(
        {'remote': const RemoteImageUrl('https://media.example.com/r.png')},
        fetch: (_, __) async => Uint8List.fromList([1, 2, 3, 4]),
      ),
      throwsA(
        isA<CaptureImagesUnavailable>()
            .having((error) => error.cause, 'cause', isNotNull),
      ),
    );
  });
}
