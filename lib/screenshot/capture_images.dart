import 'dart:typed_data';

import 'package:icarus/providers/strategy_image_source.dart';

/// An image a capture would paint is not ready: its cloud copy is still
/// loading, or its bytes could not be fetched. The capture stops rather than
/// save a picture with the image missing.
class CaptureImagesUnavailable implements Exception {
  const CaptureImagesUnavailable.stillLoading() : cause = null;
  const CaptureImagesUnavailable.fetchFailed(this.cause);

  /// Why the fetch failed; null while an image is still loading.
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

/// Turns where each image's bytes come from, by image id, into what an
/// offscreen capture can paint ([captureImageSourcesProvider]).
///
/// A capture has no network reads of its own, so cloud URLs are fetched here
/// and painted from memory. Files and bytes already in memory paint as they
/// are, and an image the editor shows as unavailable is captured that way
/// too. Throws [CaptureImagesUnavailable] while an image is still loading or
/// when a fetch fails.
Future<Map<String, StrategyImageSource>> resolveCaptureImageSources(
  Map<String, StrategyImageSource> sources, {
  required CaptureImageFetcher fetch,
}) async {
  final resolved = <String, StrategyImageSource>{};
  for (final MapEntry(key: imageId, value: source) in sources.entries) {
    switch (source) {
      case RemoteImageUrl(:final url):
        try {
          resolved[imageId] = ImageBytes(await fetch(imageId, url));
        } catch (error) {
          throw CaptureImagesUnavailable.fetchFailed(error);
        }
      case ImageLoading():
        throw const CaptureImagesUnavailable.stillLoading();
      case LocalImageFile() || ImageBytes() || ImageFailed():
        resolved[imageId] = source;
    }
  }
  return resolved;
}
