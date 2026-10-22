import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/painting.dart';

/// [image] decoded at half its size when it is never drawn larger than
/// that, and at full size otherwise: a quarter of the memory for a picture
/// whose half still fills a box [width] × [height] physical pixels, the
/// largest it is drawn.
///
/// Exactly half, and no smaller, because that is the one reduction the GPU
/// makes the same way. To draw a picture smaller the GPU averages it down
/// by halves (mipmaps), and the decoder's exact half averages each 2×2
/// block as the GPU's first half does. A side with an odd number of pixels
/// has no exact half, so that picture keeps every pixel. Shrunk further in
/// the decoder's single step, fine detail such as thin text is sampled
/// rather than averaged; shrunk straight to the box, text drew visibly
/// softer at the canvas's full zoom.
///
/// Whichever side needs more pixels to fill the box decides, which is
/// enough for both [BoxFit.contain] and [BoxFit.cover].
class HalvedImage extends ImageProvider<HalvedImageKey> {
  HalvedImage(this.image, {required Size box})
      : width = _pixels(box.width),
        height = _pixels(box.height);

  final ImageProvider image;
  final int width;
  final int height;

  static int _pixels(double extent) =>
      extent.isFinite ? math.max(1, extent.ceil()) : 0;

  /// The size to decode a picture [intrinsicWidth] × [intrinsicHeight] at
  /// for a box [width] × [height]: its exact half, or every pixel. A box
  /// with no finite size decodes every pixel.
  static ui.TargetImageSize targetSize({
    required int intrinsicWidth,
    required int intrinsicHeight,
    required int width,
    required int height,
  }) {
    final halfWidth = intrinsicWidth ~/ 2;
    final halfHeight = intrinsicHeight ~/ 2;
    if (width <= 0 ||
        height <= 0 ||
        intrinsicWidth.isOdd ||
        intrinsicHeight.isOdd ||
        halfWidth < width ||
        halfHeight < height) {
      return const ui.TargetImageSize();
    }
    return ui.TargetImageSize(width: halfWidth, height: halfHeight);
  }

  @override
  Future<HalvedImageKey> obtainKey(ImageConfiguration configuration) {
    // Answers synchronously when [image] does, as ResizeImage does, so a
    // picture already decoded paints on the first frame.
    Completer<HalvedImageKey>? completer;
    SynchronousFuture<HalvedImageKey>? result;
    image.obtainKey(configuration).then((Object key) {
      final resized = HalvedImageKey._(key, width, height);
      if (completer == null) {
        result = SynchronousFuture<HalvedImageKey>(resized);
      } else {
        completer.complete(resized);
      }
    });
    if (result != null) return result!;
    completer = Completer<HalvedImageKey>();
    return completer.future;
  }

  @override
  ImageStreamCompleter loadImage(
    HalvedImageKey key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> decodeToCover(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) {
      assert(getTargetSize == null, 'HalvedImage wraps a plain provider.');
      return decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) => targetSize(
          intrinsicWidth: intrinsicWidth,
          intrinsicHeight: intrinsicHeight,
          width: key._width,
          height: key._height,
        ),
      );
    }

    final completer = image.loadImage(key._image, decodeToCover);
    completer.addEphemeralErrorListener((_, __) {
      // As in ResizeImage: the cache may not hold the key yet when the
      // error arrives.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }

  @override
  bool operator ==(Object other) =>
      other is HalvedImage &&
      other.image == image &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(image, width, height);

  @override
  String toString() => 'HalvedImage($image, $width×$height)';
}

class HalvedImageKey {
  const HalvedImageKey._(this._image, this._width, this._height);

  final Object _image;
  final int _width;
  final int _height;

  @override
  bool operator ==(Object other) =>
      other is HalvedImageKey &&
      other._image == _image &&
      other._width == _width &&
      other._height == _height;

  @override
  int get hashCode => Object.hash(_image, _width, _height);
}
