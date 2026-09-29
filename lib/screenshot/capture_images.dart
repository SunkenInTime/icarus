import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:icarus/providers/strategy_image_source.dart';

/// An image a capture would paint is not ready: its cloud copy is still
/// loading, or its bytes could not be fetched or decoded. The capture stops
/// rather than save a picture with the image missing.
class CaptureImagesUnavailable implements Exception {
  const CaptureImagesUnavailable.stillLoading() : cause = null;
  const CaptureImagesUnavailable.fetchFailed(this.cause);

  /// Why the image could not be loaded; null while it is still loading.
  final Object? cause;

  String get userMessage => cause == null
      ? 'Images on this page are still loading. Try again in a moment.'
      : "Couldn't load the images on this page. Check your connection and "
          'try again.';

  @override
  String toString() => cause == null
      ? 'CaptureImagesUnavailable: an image is still loading'
      : 'CaptureImagesUnavailable: $cause';
}

/// Fetches the bytes behind a cloud image's [url].
typedef CaptureImageFetcher = Future<Uint8List> Function(
  String imageId,
  String url,
);

/// What each image in a capture paints, by image id, decoded and held in
/// the image cache so the capture's first frame already has every picture.
/// Call [release] once the capture is done.
class CaptureImages {
  CaptureImages._(this.sources, this._holds);

  /// Feeds [captureImageSourcesProvider] in the capture's container.
  final Map<String, StrategyImageSource> sources;
  final List<_HeldImage> _holds;

  void release() {
    for (final hold in _holds) {
      hold.release();
    }
    _holds.clear();
  }
}

/// Turns where each image's bytes come from, by image id, into what an
/// offscreen capture can paint.
///
/// A capture has no network reads of its own, so cloud URLs are fetched here
/// and painted from memory. Files and bytes already in memory paint as they
/// are, and an image the editor shows as unavailable is captured that way
/// too. Every image that paints is decoded before this returns. Throws
/// [CaptureImagesUnavailable] while an image is still loading, or when a
/// fetch or a decode fails. [checkpoint] runs before each image; whatever it
/// throws stops the work and releases what was held.
Future<CaptureImages> resolveCaptureImages(
  Map<String, StrategyImageSource> sources, {
  required CaptureImageFetcher fetch,
  void Function()? checkpoint,
}) async {
  if (sources.values.any((source) => source is ImageLoading)) {
    throw const CaptureImagesUnavailable.stillLoading();
  }
  // Downloads run together, so a page's wait is its slowest image rather
  // than the sum of them. A download nobody awaits (the capture stopped
  // first) must not surface as an unhandled error.
  final downloads = {
    for (final MapEntry(key: imageId, value: source) in sources.entries)
      if (source case RemoteImageUrl(:final url))
        imageId: _guard(() => fetch(imageId, url))..ignore(),
  };
  final resolved = <String, StrategyImageSource>{};
  final holds = <_HeldImage>[];
  try {
    for (final MapEntry(key: imageId, value: source) in sources.entries) {
      checkpoint?.call();
      final download = downloads[imageId];
      final paintable = download == null ? source : ImageBytes(await download);
      final image = paintable.imageProvider;
      if (image != null) {
        holds.add(await _guard(() => _HeldImage.decode(image)));
      }
      resolved[imageId] = paintable;
    }
    checkpoint?.call();
  } catch (_) {
    for (final hold in holds) {
      hold.release();
    }
    rethrow;
  }
  return CaptureImages._(resolved, holds);
}

Future<T> _guard<T>(Future<T> Function() load) async {
  try {
    return await load();
  } catch (error) {
    throw CaptureImagesUnavailable.fetchFailed(error);
  }
}

/// A decoded image kept listened to, which keeps it among the image cache's
/// live images: a widget asking for the same image finds it decoded, however
/// full the cache gets, until [release].
class _HeldImage {
  _HeldImage._(this._stream);

  final ImageStream _stream;
  late final ImageStreamListener _listener;
  bool _attached = false;

  /// Completes once [image]'s first frame is decoded.
  static Future<_HeldImage> decode(ImageProvider image) {
    final hold = _HeldImage._(image.resolve(ImageConfiguration.empty));
    final decoded = Completer<_HeldImage>();
    hold._listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!decoded.isCompleted) decoded.complete(hold);
      },
      onError: (Object error, StackTrace? stackTrace) {
        hold.release();
        if (!decoded.isCompleted) decoded.completeError(error, stackTrace);
      },
    );
    hold._attached = true;
    hold._stream.addListener(hold._listener);
    return decoded.future;
  }

  /// Lets go of the image. Safe to call again: a later frame that fails to
  /// decode lets go first, and the stream may be gone by the second call.
  void release() {
    if (!_attached) return;
    _attached = false;
    _stream.removeListener(_listener);
  }
}
