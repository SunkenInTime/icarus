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
  CaptureImages._(this.sources, this._handles);

  /// Feeds [captureImageSourcesProvider] in the capture's container.
  final Map<String, StrategyImageSource> sources;
  final List<ImageStreamCompleterHandle> _handles;

  void release() {
    for (final handle in _handles) {
      handle.dispose();
    }
    _handles.clear();
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
/// fetch or a decode fails.
Future<CaptureImages> resolveCaptureImages(
  Map<String, StrategyImageSource> sources, {
  required CaptureImageFetcher fetch,
}) async {
  final resolved = <String, StrategyImageSource>{};
  final handles = <ImageStreamCompleterHandle>[];
  try {
    for (final MapEntry(key: imageId, value: source) in sources.entries) {
      final paintable = switch (source) {
        RemoteImageUrl(:final url) => ImageBytes(
            await _guard(() => fetch(imageId, url)),
          ),
        ImageLoading() => throw const CaptureImagesUnavailable.stillLoading(),
        LocalImageFile() || ImageBytes() || ImageFailed() => source,
      };
      final image = paintable.imageProvider;
      if (image != null) handles.add(await _guard(() => _decode(image)));
      resolved[imageId] = paintable;
    }
  } catch (_) {
    for (final handle in handles) {
      handle.dispose();
    }
    rethrow;
  }
  return CaptureImages._(resolved, handles);
}

Future<T> _guard<T>(Future<T> Function() load) async {
  try {
    return await load();
  } catch (error) {
    throw CaptureImagesUnavailable.fetchFailed(error);
  }
}

/// Decodes [image]'s first frame into the image cache and keeps it there
/// until the returned handle is disposed.
Future<ImageStreamCompleterHandle> _decode(ImageProvider image) {
  final decoded = Completer<ImageStreamCompleterHandle>();
  final stream = image.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      info.dispose();
      if (!decoded.isCompleted) {
        decoded.complete(stream.completer!.keepAlive());
      }
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stackTrace) {
      if (!decoded.isCompleted) decoded.completeError(error, stackTrace);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return decoded.future;
}
