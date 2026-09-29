import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:icarus/services/video_export/mp4_muxer.dart';
import 'package:icarus/services/video_export/video_export_errors.dart';

/// Encodes rendered frames into an H.264 .mp4 in the browser, using WebCodecs
/// `VideoEncoder` and [Mp4H264Muxer]. The web counterpart of the desktop
/// ffmpeg pipeline, which browsers cannot run.
///
/// The output is constant frame rate: each [addFrame] is repeated at `fps`
/// for its duration. A repeat reuses the frame's pixels, so a held page costs
/// one RGBA upload however long it is shown.
class WebCodecsMp4Encoder {
  /// Keyframe spacing ceiling, so players can seek within long holds.
  static const _maxKeyFrameIntervalSeconds = 2;

  /// Encoder queue depth at which [addFrame] waits for the encoder to catch
  /// up, so a fast renderer cannot pile up frames in memory.
  static const _maxEncodeQueueSize = 8;

  /// Whether this browser can encode H.264 at this size, frame rate, and
  /// bitrate. False when WebCodecs is missing entirely.
  static Future<bool> isSupported({
    required int width,
    required int height,
    required int fps,
    int? bitrate,
  }) async =>
      await _supportedConfig(
        width: width,
        height: height,
        fps: fps,
        bitrate: bitrate,
      ) !=
      null;

  _VideoEncoder? _encoder;
  _OffscreenCanvas? _scaleCanvas;
  _Canvas2D? _scaleContext;
  late int _inputWidth;
  late int _inputHeight;
  late int _outputWidth;
  late int _outputHeight;
  late int _fps;

  /// Frames handed to the encoder so far; frame i is shown at i / fps.
  int _framesEncoded = 0;
  int _framesSinceKeyFrame = 0;

  /// Sum of every [addFrame] duration, so rounding never accumulates.
  int _plannedMicros = 0;

  final List<_EncodedSample> _samples = [];
  Uint8List? _avcDecoderConfig;
  Completer<void>? _dequeued;

  /// Why the encoder failed, reported by the next call.
  String? _failure;
  bool _cancelled = false;
  bool _finished = false;

  /// Configures the encoder. Frames arrive at [inputWidth] x [inputHeight]
  /// and are scaled to [outputWidth] x [outputHeight] when those differ.
  /// A null [bitrate] encodes at a high variable bitrate (see
  /// [_defaultBitrate]); otherwise the bitrate is held constant.
  Future<void> start({
    required int inputWidth,
    required int inputHeight,
    required int outputWidth,
    required int outputHeight,
    required int fps,
    int? bitrate,
  }) async {
    if (_encoder != null) throw StateError('The encoder is already started.');
    if (fps <= 0) throw ArgumentError.value(fps, 'fps', 'must be positive');
    _inputWidth = inputWidth;
    _inputHeight = inputHeight;
    _outputWidth = outputWidth;
    _outputHeight = outputHeight;
    _fps = fps;

    final config = await _supportedConfig(
      width: outputWidth,
      height: outputHeight,
      fps: fps,
      bitrate: bitrate,
    );
    if (_cancelled) throw VideoExportCancelled();
    if (config == null) {
      throw VideoExportException(
        'This browser cannot encode H.264 video at '
        '${outputWidth}x$outputHeight, $fps fps.',
      );
    }

    if (outputWidth != inputWidth || outputHeight != inputHeight) {
      final canvas = _OffscreenCanvas(outputWidth, outputHeight);
      final context = canvas.getContext('2d');
      if (context == null) {
        throw VideoExportException('This browser cannot scale video frames.');
      }
      context.imageSmoothingQuality = 'high';
      _scaleCanvas = canvas;
      _scaleContext = context;
    }

    final encoder = _VideoEncoder(
      _VideoEncoderInit(
        output: _onChunk.toJS,
        error: _onError.toJS,
      ),
    );
    encoder.ondequeue = ((JSAny? _) => _wakeWaiter()).toJS;
    _encoder = encoder;
    try {
      encoder.configure(config);
    } on Object catch (error) {
      _closeEncoder();
      throw VideoExportException('Could not start the video encoder: $error');
    }
  }

  /// Adds one rendered frame (top-to-bottom RGBA, inputWidth * inputHeight * 4
  /// bytes) shown for [duration].
  ///
  /// The frame is repeated for round(duration * fps) ticks, at least one,
  /// measured against the running total so remainders carry forward and the
  /// video's length matches the sum of the durations.
  Future<void> addFrame(Uint8List rgba, {required Duration duration}) async {
    final encoder = _checkRunning();
    if (rgba.length != _inputWidth * _inputHeight * 4) {
      throw ArgumentError(
        'Expected ${_inputWidth * _inputHeight * 4} RGBA bytes, '
        'got ${rgba.length}.',
      );
    }
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    _plannedMicros += duration.inMicroseconds;
    final plannedFrames =
        (_plannedMicros * _fps / Duration.microsecondsPerSecond).round();
    final repeats = math.max(1, plannedFrames - _framesEncoded);

    final base = _baseFrame(rgba);
    try {
      for (var i = 0; i < repeats; i++) {
        while (encoder.encodeQueueSize > _maxEncodeQueueSize) {
          final dequeued = _dequeued ??= Completer<void>();
          await dequeued.future;
          _checkRunning();
        }
        final index = _framesEncoded;
        final timestamp = _timestampOf(index);
        final frame = _VideoFrame(
          base,
          _VideoFrameInit(
            timestamp: timestamp,
            duration: _timestampOf(index + 1) - timestamp,
          ),
        );
        // A held page (a run longer than one frame) opens on a keyframe so it
        // starts crisp and seeks cleanly. Single-frame runs are transition
        // frames; keying each of them would spend the bitrate on I-frames.
        final keyFrame = index == 0 ||
            (i == 0 && repeats > 1) ||
            _framesSinceKeyFrame >= _maxKeyFrameIntervalSeconds * _fps;
        try {
          encoder.encode(frame, _EncodeOptions(keyFrame: keyFrame));
        } on Object catch (error) {
          _failure ??= '$error';
          _checkRunning();
        } finally {
          frame.close();
        }
        _framesEncoded++;
        _framesSinceKeyFrame = keyFrame ? 1 : _framesSinceKeyFrame + 1;
      }
    } finally {
      base.close();
    }
    _checkRunning();
  }

  /// Flushes the encoder and returns the finished .mp4 bytes.
  Future<Uint8List> finish() async {
    final encoder = _checkRunning();
    try {
      await encoder.flush().toDart;
    } on Object catch (error) {
      _failure ??= '$error';
    }
    _checkRunning();
    _finished = true;
    _closeEncoder();

    final config = _avcDecoderConfig;
    if (_samples.isEmpty || config == null) {
      throw VideoExportException('The video encoder produced no video.');
    }
    final ticksPerFrame = _timescale ~/ _fps;
    final muxer = Mp4H264Muxer(
      width: _outputWidth,
      height: _outputHeight,
      timescale: _timescale,
    );
    for (var i = 0; i < _samples.length; i++) {
      final sample = _samples[i];
      final nextFrame =
          i + 1 < _samples.length ? _samples[i + 1].frame : _framesEncoded;
      // The MP4 has no composition offsets, so chunks must arrive in
      // presentation order. Encoders that reorder (B-frames) fail loudly
      // rather than produce a video that plays frames out of order.
      if (nextFrame <= sample.frame) {
        throw VideoExportException(
          'The video encoder returned frames out of order.',
        );
      }
      muxer.addSample(
        sample.bytes,
        duration: (nextFrame - sample.frame) * ticksPerFrame,
        isKeyFrame: sample.isKeyFrame,
      );
    }
    return muxer.finish(avcDecoderConfig: config);
  }

  /// Stops encoding and releases the encoder. Safe to call at any time and
  /// more than once; later [addFrame] and [finish] calls throw
  /// [VideoExportCancelled].
  void cancel() {
    _cancelled = true;
    _closeEncoder();
    _wakeWaiter();
  }

  /// Media ticks per second. 1000 ticks per frame keeps every frame duration
  /// an exact integer.
  int get _timescale => _fps * 1000;

  int _timestampOf(int frame) =>
      (frame * Duration.microsecondsPerSecond / _fps).round();

  _VideoFrame _baseFrame(Uint8List rgba) {
    final raw = _VideoFrame(
      rgba.toJS,
      _VideoFrameBufferInit(
        format: 'RGBA',
        codedWidth: _inputWidth,
        codedHeight: _inputHeight,
        timestamp: 0,
      ),
    );
    final context = _scaleContext;
    if (context == null) return raw;
    try {
      context.drawImage(raw, 0, 0, _outputWidth, _outputHeight);
    } finally {
      raw.close();
    }
    return _VideoFrame(_scaleCanvas!, _VideoFrameInit(timestamp: 0));
  }

  _VideoEncoder _checkRunning() {
    if (_cancelled) throw VideoExportCancelled();
    final failure = _failure;
    if (failure != null) {
      _closeEncoder();
      throw VideoExportException('The video encoder failed: $failure');
    }
    final encoder = _encoder;
    if (encoder == null || _finished) {
      throw StateError(
        _finished ? 'The video is already finished.' : 'Call start() first.',
      );
    }
    return encoder;
  }

  void _onChunk(_EncodedVideoChunk chunk, _ChunkMetadata? metadata) {
    try {
      final description = metadata?.decoderConfig?.description;
      if (description != null) {
        final config = _copyBufferSource(description);
        final previous = _avcDecoderConfig;
        if (previous != null && !_sameBytes(previous, config)) {
          // The MP4 carries one avcC, which every sample must decode with.
          throw StateError('The encoder changed its H.264 parameter sets.');
        }
        _avcDecoderConfig = config;
      }
      final bytes = _Uint8Array(chunk.byteLength);
      chunk.copyTo(bytes);
      _samples.add(
        _EncodedSample(
          frame:
              (chunk.timestamp * _fps / Duration.microsecondsPerSecond).round(),
          bytes: bytes.toDart,
          isKeyFrame: chunk.type == 'key',
        ),
      );
    } on Object catch (error) {
      _failure ??= '$error';
      _closeEncoder();
      _wakeWaiter();
    }
  }

  void _onError(JSAny? error) {
    _failure ??= _jsString(error);
    _wakeWaiter();
  }

  void _wakeWaiter() {
    final waiter = _dequeued;
    _dequeued = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _closeEncoder() {
    final encoder = _encoder;
    if (encoder == null || encoder.state == 'closed') return;
    try {
      encoder.close();
    } on Object {
      // Already closed by an encoder error.
    }
  }

  /// Picks a bitrate for [bitrate] == null: 8 Mbps at 1080p30, the desktop
  /// Max preset's H.264 rate, scaled by pixel count. 60 fps gets 1.5x rather
  /// than 2x: consecutive frames differ less, and held pages cost almost
  /// nothing either way.
  static int _defaultBitrate(int width, int height, int fps) {
    final pixelScale = width * height / (1920 * 1080);
    final rateScale = fps > 30 ? 1.5 : 1.0;
    return math.max(1000000, (8000000 * pixelScale * rateScale).round());
  }

  /// The first H.264 profile this browser accepts at this size, or null.
  /// High needs a hardware encoder in Chrome; its software encoder (OpenH264)
  /// only does Constrained Baseline, so fall back through Main to that.
  static Future<_VideoEncoderConfig?> _supportedConfig({
    required int width,
    required int height,
    required int fps,
    int? bitrate,
  }) async {
    if (!globalContext.has('VideoEncoder')) return null;
    final targetBitrate = bitrate ?? _defaultBitrate(width, height, fps);
    final level = _h264Level(width, height, fps, targetBitrate);
    if (level == null) return null;
    for (final profile in _h264Profiles) {
      final config = _VideoEncoderConfig(
        codec: 'avc1.$profile${level.toRadixString(16).padLeft(2, '0')}',
        width: width,
        height: height,
        bitrate: targetBitrate,
        bitrateMode: bitrate != null ? 'constant' : 'variable',
        framerate: fps,
        avc: _AvcEncoderConfig(format: 'avc'),
        latencyMode: 'quality',
      );
      try {
        final support = await _VideoEncoder.isConfigSupported(config).toDart;
        if (support.supported ?? false) return config;
      } on Object {
        // A rejected (TypeError) config means this profile is not usable.
      }
    }
    return null;
  }

  /// profile_idc and constraint flags, in preference order: High, Main,
  /// Constrained Baseline.
  static const _h264Profiles = ['6400', '4d00', '42e0'];

  /// The lowest H.264 level whose frame size, macroblock rate, and bitrate
  /// limits hold this stream, or null when none does.
  static int? _h264Level(int width, int height, int fps, int bitrate) {
    final macroblocks = ((width + 15) ~/ 16) * ((height + 15) ~/ 16);
    final macroblocksPerSecond = macroblocks * fps;
    // (level_idc, MaxFS, MaxMBPS, MaxBR in kbit/s for Baseline/Main; High
    // allows 1.25x, so these limits hold for every profile above.)
    const levels = [
      (30, 1620, 40500, 10000),
      (31, 3600, 108000, 14000),
      (32, 5120, 216000, 20000),
      (40, 8192, 245760, 20000),
      (41, 8192, 245760, 50000),
      (42, 8704, 522240, 50000),
      (50, 22080, 589824, 135000),
      (51, 36864, 983040, 240000),
      (52, 36864, 2073600, 240000),
    ];
    for (final (idc, maxFs, maxMbps, maxBrKbps) in levels) {
      if (macroblocks <= maxFs &&
          macroblocksPerSecond <= maxMbps &&
          bitrate <= maxBrKbps * 1000) {
        return idc;
      }
    }
    return null;
  }
}

class _EncodedSample {
  _EncodedSample({
    required this.frame,
    required this.bytes,
    required this.isKeyFrame,
  });

  /// Index of the frame this chunk encodes, from its timestamp.
  final int frame;
  final Uint8List bytes;
  final bool isKeyFrame;
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Copies a WebCodecs BufferSource (an ArrayBuffer or a view of one).
Uint8List _copyBufferSource(JSObject source) {
  final bytes = source.isA<JSArrayBuffer>()
      ? _Uint8Array.view(source, 0, (source as _ArrayBuffer).byteLength)
      : _Uint8Array.view(
          (source as _ArrayBufferView).buffer,
          source.byteOffset,
          source.byteLength,
        );
  return Uint8List.fromList(bytes.toDart);
}

@JS('String')
external String _jsString(JSAny? value);

@JS('VideoEncoder')
extension type _VideoEncoder._(JSObject _) implements JSObject {
  external factory _VideoEncoder(_VideoEncoderInit init);

  external static JSPromise<_VideoEncoderSupport> isConfigSupported(
    _VideoEncoderConfig config,
  );

  external String get state;
  external int get encodeQueueSize;
  external set ondequeue(JSFunction? handler);

  external void configure(_VideoEncoderConfig config);
  external void encode(_VideoFrame frame, _EncodeOptions options);
  external JSPromise<JSAny?> flush();
  external void close();
}

extension type _VideoEncoderInit._(JSObject _) implements JSObject {
  external factory _VideoEncoderInit({JSFunction output, JSFunction error});
}

extension type _VideoEncoderConfig._(JSObject _) implements JSObject {
  external factory _VideoEncoderConfig({
    String codec,
    int width,
    int height,
    int bitrate,
    String bitrateMode,
    num framerate,
    _AvcEncoderConfig avc,
    String latencyMode,
  });
}

extension type _AvcEncoderConfig._(JSObject _) implements JSObject {
  external factory _AvcEncoderConfig({String format});
}

extension type _VideoEncoderSupport._(JSObject _) implements JSObject {
  external bool? get supported;
}

extension type _EncodeOptions._(JSObject _) implements JSObject {
  external factory _EncodeOptions({bool keyFrame});
}

@JS('VideoFrame')
extension type _VideoFrame._(JSObject _) implements JSObject {
  /// [source] is a BufferSource with a [_VideoFrameBufferInit], or an image
  /// source (VideoFrame, OffscreenCanvas) with a [_VideoFrameInit].
  external factory _VideoFrame(JSObject source, JSObject init);

  external void close();
}

extension type _VideoFrameBufferInit._(JSObject _) implements JSObject {
  external factory _VideoFrameBufferInit({
    String format,
    int codedWidth,
    int codedHeight,
    int timestamp,
  });
}

extension type _VideoFrameInit._(JSObject _) implements JSObject {
  external factory _VideoFrameInit({int timestamp, int duration});
}

extension type _EncodedVideoChunk._(JSObject _) implements JSObject {
  external String get type;
  external int get timestamp;
  external int get byteLength;
  external void copyTo(_Uint8Array destination);
}

extension type _ChunkMetadata._(JSObject _) implements JSObject {
  external _DecoderConfig? get decoderConfig;
}

extension type _DecoderConfig._(JSObject _) implements JSObject {
  external JSObject? get description;
}

@JS('OffscreenCanvas')
extension type _OffscreenCanvas._(JSObject _) implements JSObject {
  external factory _OffscreenCanvas(int width, int height);

  external _Canvas2D? getContext(String contextId);
}

extension type _Canvas2D._(JSObject _) implements JSObject {
  external set imageSmoothingQuality(String value);

  external void drawImage(
    JSObject image,
    num dx,
    num dy,
    num dWidth,
    num dHeight,
  );
}

extension type _ArrayBuffer._(JSObject _) implements JSObject {
  external int get byteLength;
}

extension type _ArrayBufferView._(JSObject _) implements JSObject {
  external JSObject get buffer;
  external int get byteOffset;
  external int get byteLength;
}

@JS('Uint8Array')
extension type _Uint8Array._(JSUint8Array _) implements JSUint8Array {
  external factory _Uint8Array(int length);
  external factory _Uint8Array.view(JSObject buffer, int offset, int length);
}
