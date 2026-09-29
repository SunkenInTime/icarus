import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:http/http.dart' as http;
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

/// Answers only when closed, which is what aborting looks like to a caller.
class _SlowClient extends http.BaseClient {
  final requested = <String>[];
  var closed = false;
  final _closing = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requested.add(request.url.toString());
    await _closing.future;
    throw http.ClientException('Client closed', request.url);
  }

  @override
  void close() {
    closed = true;
    if (!_closing.isCompleted) _closing.complete();
  }
}

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
    // Live, so no amount of cache pressure evicts them before the capture.
    cache.clear();
    for (final key in keys) {
      expect(cache.statusForKey(key).live, isTrue);
    }

    images.release();
    cache.clear();
    for (final key in keys) {
      expect(cache.statusForKey(key).untracked, isTrue);
    }
  });

  test('cloud images download together, not one after another', () async {
    final started = <String>[];
    final watch = Stopwatch()..start();
    final images = await resolveCaptureImages(
      {
        for (final id in ['a', 'b', 'c', 'd'])
          id: RemoteImageUrl('https://media.example.com/$id.png'),
      },
      fetch: (imageId, _) async {
        started.add(imageId);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return _png(imageId.codeUnitAt(0));
      },
    );
    addTearDown(images.release);

    expect(started, ['a', 'b', 'c', 'd']);
    // Four 200 ms downloads in series would take 800 ms.
    expect(watch.elapsedMilliseconds, lessThan(600));
    expect(images.sources.values, everyElement(isA<ImageBytes>()));
  });

  test('a capture that fails aborts the downloads it no longer needs',
      () async {
    final client = _SlowClient();
    await expectLater(
      http.runWithClient(
        () => resolveCaptureImages(
          {
            'broken': const RemoteImageUrl('https://media.example.com/x.png'),
            'slow': const RemoteImageUrl('https://media.example.com/s.png'),
          },
          fetch: (imageId, url) async {
            if (imageId == 'broken') throw Exception('offline');
            return (await http.get(Uri.parse(url))).bodyBytes;
          },
        ),
        () => client,
      ),
      throwsA(isA<CaptureImagesUnavailable>()),
    );
    expect(client.requested, ['https://media.example.com/s.png']);
    expect(client.closed, isTrue);
  });

  test('an image still loading stops the capture before any download',
      () async {
    final started = <String>[];
    await expectLater(
      resolveCaptureImages(
        {
          'remote': const RemoteImageUrl('https://media.example.com/r.png'),
          'loading': const ImageLoading(),
        },
        fetch: (imageId, _) async {
          started.add(imageId);
          return fetched;
        },
      ),
      throwsA(isA<CaptureImagesUnavailable>()),
    );
    expect(started, isEmpty);
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
