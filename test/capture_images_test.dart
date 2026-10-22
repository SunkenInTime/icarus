import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
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

/// Like a browser client: once closed it refuses every request. Answers
/// each URL with its status after its delay in milliseconds.
class _RefusingAfterCloseClient extends http.BaseClient {
  _RefusingAfterCloseClient(this.answers, this.body);

  final Map<String, (int, int)> answers;
  final Uint8List body;
  final requested = <String>[];
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) throw http.ClientException('Client is closed', request.url);
    requested.add(request.url.toString());
    final (status, delay) = answers[request.url.toString()]!;
    await Future<void>.delayed(Duration(milliseconds: delay));
    if (closed) throw http.ClientException('Request aborted', request.url);
    return http.StreamedResponse(Stream.value(body), status);
  }

  @override
  void close() => closed = true;
}

/// The box every image in these captures is drawn in.
const _box = Size(497, 280);

Map<String, CaptureImage> _sized(Map<String, StrategyImageSource> sources) =>
    sources.map(
      (id, source) => MapEntry(id, (source: source, drawnAtMost: _box)),
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
      _sized({
        'remote': const RemoteImageUrl('https://media.example.com/remote.png'),
        'file': LocalImageFile(filePath),
        'uploading': ImageBytes(pending),
        'failed': const ImageFailed(),
      }),
      fetch: (imageId, url, _) async {
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
      _sized({
        'remote': const RemoteImageUrl('https://media.example.com/remote.png'),
        'file': LocalImageFile(filePath),
      }),
      fetch: (_, __, ___) async => fetched,
    );

    // The capture's widgets ask for the same keys and find them decoded.
    final keys = [
      for (final source in images.sources.values)
        await source
            .imageProvider(drawnAtMost: _box)!
            .obtainKey(ImageConfiguration.empty),
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

  test('each image is decoded for the box the capture draws it in',
      () async {
    final big = Uint8List.fromList(
      img.encodePng(img.Image(width: 2000, height: 1000)),
    );
    final images = await resolveCaptureImages(
      {'big': (source: ImageBytes(big), drawnAtMost: const Size(500, 250))},
      fetch: (_, __, ___) async => fetched,
    );
    addTearDown(images.release);

    // The capture's widget asks for the same box and gets the held decode.
    final decoded = Completer<ImageInfo>();
    images.sources['big']!
        .imageProvider(drawnAtMost: const Size(500, 250))!
        .resolve(ImageConfiguration.empty)
        .addListener(ImageStreamListener((info, _) => decoded.complete(info)));
    final info = await decoded.future;
    addTearDown(info.dispose);
    expect((info.image.width, info.image.height), (1000, 500));
  });

  test(
      'holding the next pages lets go of the images left behind and keeps '
      'the ones they share', () async {
    final cache = PaintingBinding.instance.imageCache;
    final fetches = <String>[];
    final images = CaptureImages(
      fetch: (imageId, _, __) async {
        fetches.add(imageId);
        return _png(imageId.codeUnitAt(0));
      },
    );
    addTearDown(images.release);
    Map<String, CaptureImage> remote(List<String> ids) => _sized({
          for (final id in ids)
            id: RemoteImageUrl('https://media.example.com/$id.png'),
        });
    Future<Object> keyOf(String id) => images.sources[id]!
        .imageProvider(drawnAtMost: _box)!
        .obtainKey(ImageConfiguration.empty);

    await images.hold(remote(['a', 'b']));
    final a = await keyOf('a');
    final b = await keyOf('b');
    await images.hold(remote(['b', 'c']));
    final c = await keyOf('c');

    expect(images.sources.keys, unorderedEquals(['b', 'c']));
    // The shared image is neither downloaded nor decoded again.
    expect(fetches, ['a', 'b', 'c']);
    cache.clear();
    expect(cache.statusForKey(a).untracked, isTrue);
    expect(cache.statusForKey(b).live, isTrue);
    expect(cache.statusForKey(c).live, isTrue);
  });

  test('cloud images download together, not one after another', () async {
    final started = <String>[];
    final watch = Stopwatch()..start();
    final images = await resolveCaptureImages(
      _sized({
        for (final id in ['a', 'b', 'c', 'd'])
          id: RemoteImageUrl('https://media.example.com/$id.png'),
      }),
      fetch: (imageId, _, __) async {
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
          _sized({
            'broken': const RemoteImageUrl('https://media.example.com/x.png'),
            'slow': const RemoteImageUrl('https://media.example.com/s.png'),
          }),
          fetch: (imageId, url, client) async {
            if (imageId == 'broken') throw Exception('offline');
            return (await client.get(Uri.parse(url))).bodyBytes;
          },
        ),
        () => client,
      ),
      throwsA(isA<CaptureImagesUnavailable>()),
    );
    expect(client.requested, ['https://media.example.com/s.png']);
    expect(client.closed, isTrue);
  });

  test('downloads and URL refreshes share a client nothing closes early',
      () async {
    // A browser client refuses every request once closed, and aborts the
    // ones in flight. One download finishing must not close it for the
    // others, or for a refresh after an expired URL.
    final client = _RefusingAfterCloseClient({
      'https://media.example.com/fast.png': (200, 10),
      'https://media.example.com/slow.png': (200, 150),
      'https://media.example.com/expired.png': (403, 20),
      'https://media.example.com/fresh.png': (200, 20),
    }, _png(40));
    final images = await http.runWithClient(
      () => resolveCaptureImages(
        _sized({
          for (final id in ['fast', 'slow', 'expired'])
            id: RemoteImageUrl('https://media.example.com/$id.png'),
        }),
        fetch: (imageId, url, client) => downloadCloudImageBytes(
          url,
          client: client,
          freshUrl: () async => 'https://media.example.com/fresh.png',
        ),
      ),
      () => client,
    );
    addTearDown(images.release);

    expect(images.sources.values, everyElement(isA<ImageBytes>()));
    expect(client.requested, hasLength(4));
    expect(client.closed, isTrue);
  });

  test('an image still loading stops the capture before any download',
      () async {
    final started = <String>[];
    await expectLater(
      resolveCaptureImages(
        _sized({
          'remote': const RemoteImageUrl('https://media.example.com/r.png'),
          'loading': const ImageLoading(),
        }),
        fetch: (imageId, _, __) async {
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
        _sized({'loading': const ImageLoading()}),
        fetch: (_, __, ___) async => fetched,
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
        _sized({'remote': const RemoteImageUrl('https://media.example.com/r.png')}),
        fetch: (_, __, ___) async => throw failure,
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
        _sized({'remote': const RemoteImageUrl('https://media.example.com/r.png')}),
        fetch: (_, __, ___) async => Uint8List.fromList([1, 2, 3, 4]),
      ),
      throwsA(
        isA<CaptureImagesUnavailable>()
            .having((error) => error.cause, 'cause', isNotNull),
      ),
    );
  });
}
