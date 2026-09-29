@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/video_export_errors.dart';
import 'package:icarus/services/video_export/web_codecs_video_encoder.dart';

import '../mp4_box_test_support.dart';

// Run with: flutter test --platform chrome test/web/web_codecs_video_encoder_test.dart
// Needs a Chrome or Edge build with H.264 (Chromium builds lack it); point
// CHROME_EXECUTABLE at it when Chrome is not installed.

void main() {
  test('Chrome can encode H.264 at every export size', () async {
    for (final (width, height, fps) in [
      (1920, 1080, 60),
      (1920, 1080, 30),
      (1280, 720, 30),
      (640, 360, 30),
    ]) {
      expect(
        await WebCodecsMp4Encoder.isSupported(
          width: width,
          height: height,
          fps: fps,
        ),
        isTrue,
        reason: '${width}x$height@$fps',
      );
    }
    expect(
      await WebCodecsMp4Encoder.isSupported(
        width: 1920,
        height: 1080,
        fps: 30,
        bitrate: 2000000,
      ),
      isTrue,
    );
  });

  test('encodes held frames into an MP4 the browser plays back', () async {
    final encoder = WebCodecsMp4Encoder();
    await encoder.start(
      inputWidth: 640,
      inputHeight: 360,
      outputWidth: 640,
      outputHeight: 360,
      fps: 30,
    );
    await encoder.addFrame(
      _solid(640, 360, 255, 0, 0),
      duration: const Duration(seconds: 1),
    );
    await encoder.addFrame(
      _solid(640, 360, 0, 255, 0),
      duration: const Duration(milliseconds: 500),
    );
    await encoder.addFrame(
      _solid(640, 360, 0, 0, 255),
      duration: const Duration(seconds: 1),
    );
    final mp4 = await encoder.finish();

    final boxes = Mp4Boxes(mp4);
    expect(boxes.topLevelTypes, ['ftyp', 'moov', 'mdat']);
    expect(boxes.sampleSizes(), hasLength(75));
    expect(boxes.mediaTimescale(), 30000);
    expect(boxes.mediaDuration(), 75000);
    expect(boxes.sampleDurations().toSet(), {1000});
    // Each held page opens on a keyframe.
    expect(boxes.syncSamples() ?? [for (var i = 1; i <= 75; i++) i],
        containsAll([1, 31, 46]));
    expect(boxes.trackSize(), (640, 360));

    final video = await _loadVideo(mp4);
    expect(video.videoWidth, 640);
    expect(video.videoHeight, 360);
    expect(video.duration, closeTo(2.5, 0.05));
    expect(await _colourAt(video, 0.5), 'red');
    expect(await _colourAt(video, 1.25), 'green');
    expect(await _colourAt(video, 2.2), 'blue');
  });

  test('scales 1280x720 frames down to a 640x360 video', () async {
    final encoder = WebCodecsMp4Encoder();
    await encoder.start(
      inputWidth: 1280,
      inputHeight: 720,
      outputWidth: 640,
      outputHeight: 360,
      fps: 30,
      bitrate: 1000000,
    );
    await encoder.addFrame(
      _solid(1280, 720, 0, 255, 0),
      duration: const Duration(milliseconds: 500),
    );
    await encoder.addFrame(
      _solid(1280, 720, 0, 0, 255),
      duration: const Duration(milliseconds: 500),
    );
    final mp4 = await encoder.finish();

    final boxes = Mp4Boxes(mp4);
    expect(boxes.sampleSizes(), hasLength(30));
    expect(boxes.trackSize(), (640, 360));

    final video = await _loadVideo(mp4);
    expect(video.videoWidth, 640);
    expect(video.videoHeight, 360);
    expect(video.duration, closeTo(1.0, 0.05));
    expect(await _colourAt(video, 0.25), 'green');
    expect(await _colourAt(video, 0.75), 'blue');
  });

  test('carries fractional frame remainders forward', () async {
    final encoder = WebCodecsMp4Encoder();
    await encoder.start(
      inputWidth: 64,
      inputHeight: 64,
      outputWidth: 64,
      outputHeight: 64,
      fps: 30,
    );
    // 50 ms is 1.5 frames at 30 fps: the runs are 2, 1, 2 frames so the
    // total stays round(150 ms * 30) = 5 frames (rounded half up).
    for (var i = 0; i < 3; i++) {
      await encoder.addFrame(
        _solid(64, 64, 80 * i, 0, 0),
        duration: const Duration(milliseconds: 50),
      );
    }
    final boxes = Mp4Boxes(await encoder.finish());
    expect(boxes.sampleSizes(), hasLength(5));
    expect(boxes.mediaDuration(), 5000);
  });

  test('cancel is idempotent and later calls report the cancel', () async {
    final encoder = WebCodecsMp4Encoder();
    await encoder.start(
      inputWidth: 64,
      inputHeight: 64,
      outputWidth: 64,
      outputHeight: 64,
      fps: 30,
    );
    encoder
      ..cancel()
      ..cancel();
    await expectLater(
      encoder.addFrame(_solid(64, 64, 0, 0, 0), duration: Duration.zero),
      throwsA(isA<VideoExportCancelled>()),
    );
  });
}

Uint8List _solid(int width, int height, int r, int g, int b) {
  final bytes = Uint8List(width * height * 4);
  for (var i = 0; i < bytes.length; i += 4) {
    bytes[i] = r;
    bytes[i + 1] = g;
    bytes[i + 2] = b;
    bytes[i + 3] = 255;
  }
  return bytes;
}

Future<_VideoElement> _loadVideo(Uint8List mp4) async {
  final url = _Url.createObjectURL(
    _Blob([mp4.toJS].toJS, _BlobOptions(type: 'video/mp4')),
  );
  addTearDown(() => _Url.revokeObjectURL(url));
  final video = _document.createElement('video') as _VideoElement
    ..muted = true
    ..preload = 'auto';
  final loaded = _nextEvent(video, 'loadeddata');
  video.src = url;
  await loaded;
  return video;
}

/// Seeks [video] to [seconds] and names the dominant colour at its centre.
Future<String> _colourAt(_VideoElement video, double seconds) async {
  final seeked = _nextEvent(video, 'seeked');
  video.currentTime = seconds;
  await seeked;
  final canvas = _document.createElement('canvas') as _Canvas
    ..width = video.videoWidth
    ..height = video.videoHeight;
  final context = canvas.getContext('2d');
  context.drawImage(video, 0, 0);
  final pixel = context
      .getImageData(video.videoWidth ~/ 2, video.videoHeight ~/ 2, 1, 1)
      .data
      .toDart;
  final (r, g, b) = (pixel[0], pixel[1], pixel[2]);
  if (r > 180 && g < 80 && b < 80) return 'red';
  if (g > 180 && r < 80 && b < 80) return 'green';
  if (b > 180 && r < 80 && g < 80) return 'blue';
  return 'rgb($r, $g, $b)';
}

/// Completes on [video]'s next [type] event, or fails on its error event.
Future<void> _nextEvent(_VideoElement video, String type) {
  final done = Completer<void>();
  late JSFunction onEvent;
  late JSFunction onError;
  void detach() {
    video
      ..removeEventListener(type, onEvent)
      ..removeEventListener('error', onError);
  }

  onEvent = ((JSAny? _) {
    detach();
    if (!done.isCompleted) done.complete();
  }).toJS;
  onError = ((JSAny? _) {
    detach();
    if (!done.isCompleted) {
      done.completeError(
        StateError('The video element failed: code ${video.error?.code}'),
      );
    }
  }).toJS;
  video
    ..addEventListener(type, onEvent)
    ..addEventListener('error', onError);
  return done.future.timeout(const Duration(seconds: 20));
}

@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external JSObject createElement(String tag);
}

extension type _VideoElement._(JSObject _) implements JSObject {
  external set src(String value);
  external set muted(bool value);
  external set preload(String value);
  external set currentTime(num value);
  external int get videoWidth;
  external int get videoHeight;
  external double get duration;
  external _MediaError? get error;
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

extension type _MediaError._(JSObject _) implements JSObject {
  external int get code;
}

extension type _Canvas._(JSObject _) implements JSObject {
  external set width(int value);
  external set height(int value);
  external _Context2D getContext(String contextId);
}

extension type _Context2D._(JSObject _) implements JSObject {
  external void drawImage(JSObject image, num dx, num dy);
  external _ImageData getImageData(int x, int y, int width, int height);
}

extension type _ImageData._(JSObject _) implements JSObject {
  external JSUint8ClampedArray get data;
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts, _BlobOptions options);
}

extension type _BlobOptions._(JSObject _) implements JSObject {
  external factory _BlobOptions({String type});
}

@JS('URL')
extension type _Url._(JSObject _) implements JSObject {
  external static String createObjectURL(_Blob blob);
  external static void revokeObjectURL(String url);
}
