import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/screenshot/capture_images.dart';

void main() {
  final fetched = Uint8List.fromList([1, 2, 3]);
  final pending = Uint8List.fromList([4, 5, 6]);

  test('cloud URLs are fetched; everything else paints as the editor would',
      () async {
    final requests = <(String, String)>[];
    final resolved = await resolveCaptureImageSources(
      {
        'remote': const RemoteImageUrl('https://media.example.com/remote.png'),
        'file': const LocalImageFile('/images/file.png'),
        'uploading': ImageBytes(pending),
        'failed': const ImageFailed(),
      },
      fetch: (imageId, url) async {
        requests.add((imageId, url));
        return fetched;
      },
    );

    expect(requests, [('remote', 'https://media.example.com/remote.png')]);
    expect((resolved['remote'] as ImageBytes).bytes, fetched);
    expect((resolved['file'] as LocalImageFile).path, '/images/file.png');
    expect((resolved['uploading'] as ImageBytes).bytes, pending);
    expect(resolved['failed'], isA<ImageFailed>());
  });

  test('an image still loading stops the capture', () async {
    await expectLater(
      resolveCaptureImageSources(
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
      resolveCaptureImageSources(
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
}
