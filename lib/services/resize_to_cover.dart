import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/painting.dart';

/// [image] decoded with only as many pixels as it needs to fill a box
/// [width] × [height] physical pixels: its full size, halved as many times
/// as it can be while it still fills the box. Drawn no larger than that
/// box, it holds a fraction of the memory.
///
/// Only halving, because the GPU shrinks a picture by halving it too
/// (mipmaps) when it draws it smaller. Shrunk straight to the box instead,
/// text in a picture drew visibly softer at the canvas's full zoom. The
/// decoder makes the halves in one step (a JPEG by its own scaling, other
/// formats with one linear resize), so below half size the result is close
/// to the GPU's, not identical; measured differences were at edges and not
/// visible at the sizes pictures are drawn.
///
/// Unlike [ResizeImage] it needs no aspect ratio up front: whichever side
/// needs more pixels to fill the box decides, which is enough for both
/// [BoxFit.contain] and [BoxFit.cover].
class ResizeToCover extends ImageProvider<ResizeToCoverKey> {
  ResizeToCover(this.image, {required Size box})
      : width = _pixels(box.width),
        height = _pixels(box.height);

  final ImageProvider image;
  final int width;
  final int height;

  static int _pixels(double extent) =>
      extent.isFinite ? math.max(1, extent.ceil()) : 0;

  /// The size to decode a picture [intrinsicWidth] × [intrinsicHeight] at
  /// to fill a box [width] × [height]. A box with no finite size decodes the
  /// whole picture.
  ///
  /// A halved side rounds to whole pixels, which changes the picture's
  /// shape a little. A halving that would move its edge by half a pixel or
  /// more, drawn at the box's size, is not taken: a long strip a few pixels
  /// tall keeps its pixels.
  static ui.TargetImageSize targetSize({
    required int intrinsicWidth,
    required int intrinsicHeight,
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0) return const ui.TargetImageSize();
    final needed = math.max(width / intrinsicWidth, height / intrinsicHeight);
    final longestSide = math.max(width, height);
    ui.TargetImageSize? best;
    for (var divisor = 2; needed * divisor <= 1; divisor *= 2) {
      final halvedWidth = (intrinsicWidth / divisor).ceil();
      final halvedHeight = (intrinsicHeight / divisor).ceil();
      final shapeChange =
          (halvedWidth * intrinsicHeight) / (halvedHeight * intrinsicWidth) - 1;
      if (shapeChange.abs() * longestSide < 0.5) {
        best = ui.TargetImageSize(width: halvedWidth, height: halvedHeight);
      }
    }
    return best ?? const ui.TargetImageSize();
  }

  @override
  Future<ResizeToCoverKey> obtainKey(ImageConfiguration configuration) {
    // Answers synchronously when [image] does, as ResizeImage does, so a
    // picture already decoded paints on the first frame.
    Completer<ResizeToCoverKey>? completer;
    SynchronousFuture<ResizeToCoverKey>? result;
    image.obtainKey(configuration).then((Object key) {
      final resized = ResizeToCoverKey._(key, width, height);
      if (completer == null) {
        result = SynchronousFuture<ResizeToCoverKey>(resized);
      } else {
        completer.complete(resized);
      }
    });
    if (result != null) return result!;
    completer = Completer<ResizeToCoverKey>();
    return completer.future;
  }

  @override
  ImageStreamCompleter loadImage(
    ResizeToCoverKey key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> decodeToCover(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) {
      assert(getTargetSize == null, 'ResizeToCover wraps a plain provider.');
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
      other is ResizeToCover &&
      other.image == image &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(image, width, height);

  @override
  String toString() => 'ResizeToCover($image, $width×$height)';
}

class ResizeToCoverKey {
  const ResizeToCoverKey._(this._image, this._width, this._height);

  final Object _image;
  final int _width;
  final int _height;

  @override
  bool operator ==(Object other) =>
      other is ResizeToCoverKey &&
      other._image == _image &&
      other._width == _width &&
      other._height == _height;

  @override
  int get hashCode => Object.hash(_image, _width, _height);
}
