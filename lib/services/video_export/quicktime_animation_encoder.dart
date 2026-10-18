import 'dart:typed_data';

/// Encodes frames as QuickTime Animation (`rle `, 32-bit ARGB): lossless,
/// with an alpha channel that DaVinci Resolve and Clipchamp both composite
/// correctly. VP9 WebM loses half-transparent pixels in Resolve and ProRes
/// 4444 breaks in Clipchamp; this format is right in both.
///
/// Each frame is run-length coded row by row. A keyframe codes every row; any
/// other frame codes only the rows that changed since the previous frame, and
/// within them skips the unchanged pixels, so a held page costs a few bytes a
/// frame. Pure Dart, so the desktop app and the browser make the same file.
///
/// The layout follows FFmpeg's `qtrle` decoder (libavcodec/qtrle.c): a
/// 32-bit sample size, a 16-bit header (8 when a range of rows follows), then
/// per row a skip byte (pixels to skip + 1) and codes until -1: 0 skips again,
/// -2..-128 repeats one pixel, 1..127 copies that many pixels.
class QuickTimeAnimationEncoder {
  QuickTimeAnimationEncoder({required this.width, required this.height}) {
    if (width <= 0 || width > 0xFFFF || height <= 0 || height > 0xFFFF) {
      throw ArgumentError('Video size must be within 1..65535 on each side.');
    }
  }

  final int width;
  final int height;

  /// The previous frame as ARGB words, or null before the first frame.
  Uint32List? _previous;

  /// Encodes one top-to-bottom straight-alpha RGBA frame. A [keyFrame]
  /// stands alone; any other frame is coded against the previous one.
  Uint8List encode(Uint8List rgba, {required bool keyFrame}) {
    if (rgba.length != width * height * 4) {
      throw ArgumentError(
        'Expected ${width * height * 4} RGBA bytes, got ${rgba.length}.',
      );
    }
    final previous = _previous;
    if (!keyFrame && previous == null) {
      throw StateError('The first frame must be a keyframe.');
    }
    final pixels = _argbWords(rgba);
    _previous = pixels;

    var firstRow = 0;
    var endRow = height;
    if (!keyFrame) {
      while (firstRow < height && _sameRow(pixels, previous!, firstRow)) {
        firstRow++;
      }
      while (endRow > firstRow && _sameRow(pixels, previous!, endRow - 1)) {
        endRow--;
      }
    }

    final out = _ByteSink()..u32(0); // sample size, patched below
    if (firstRow == height) {
      // Nothing changed. Under 8 bytes, decoders repeat the last frame.
      out
        ..u16(0)
        ..byte(0);
      return out.takeWithSize();
    }
    if (firstRow == 0 && endRow == height) {
      out.u16(0);
    } else {
      out
        ..u16(8)
        ..u16(firstRow)
        ..u16(0)
        ..u16(endRow - firstRow)
        ..u16(0);
    }
    for (var row = firstRow; row < endRow; row++) {
      _encodeRow(out, pixels, keyFrame ? null : previous, row);
    }
    out.byte(0); // end of frame
    return out.takeWithSize();
  }

  /// Packs RGBA bytes into ARGB words so a pixel compares in one step.
  Uint32List _argbWords(Uint8List rgba) {
    final words = Uint32List(width * height);
    for (var i = 0, p = 0; i < words.length; i++, p += 4) {
      words[i] = (rgba[p + 3] << 24) |
          (rgba[p] << 16) |
          (rgba[p + 1] << 8) |
          rgba[p + 2];
    }
    return words;
  }

  bool _sameRow(Uint32List a, Uint32List b, int row) {
    final start = row * width;
    for (var i = start; i < start + width; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Codes one row. With [previous], pixels equal to it are skipped; without,
  /// every pixel is written.
  void _encodeRow(
    _ByteSink out,
    Uint32List pixels,
    Uint32List? previous,
    int row,
  ) {
    final start = row * width;
    final end = start + width;
    bool unchanged(int i) => previous != null && pixels[i] == previous[i];

    var i = start;
    // The row opens with a skip byte. Longer skips continue as 0-codes.
    var skip = 0;
    while (i < end && unchanged(i)) {
      skip++;
      i++;
    }
    final firstSkip = skip < 254 ? skip : 254;
    out.byte(firstSkip + 1);
    _writeSkip(out, skip - firstSkip);

    while (i < end) {
      if (unchanged(i)) {
        var run = 0;
        while (i + run < end && unchanged(i + run)) {
          run++;
        }
        i += run;
        // Unchanged to the end of the row: the row simply ends.
        if (i < end) _writeSkip(out, run);
        continue;
      }
      final repeat = _repeatLength(pixels, i, end);
      if (repeat >= 2) {
        out
          ..byte(256 - repeat)
          ..u32(pixels[i]);
        i += repeat;
        continue;
      }
      // Copy pixels until a repeat or an unchanged pixel is worth breaking
      // for, at most 127.
      var count = 1;
      while (i + count < end &&
          count < 127 &&
          !unchanged(i + count) &&
          _repeatLength(pixels, i + count, end) < 2) {
        count++;
      }
      out.byte(count);
      for (var k = 0; k < count; k++) {
        out.u32(pixels[i + k]);
      }
      i += count;
    }
    out.byte(0xFF); // -1: end of row
  }

  /// How many pixels from [i] equal pixels[i], at most 128.
  int _repeatLength(Uint32List pixels, int i, int end) {
    var length = 1;
    while (
        i + length < end && length < 128 && pixels[i + length] == pixels[i]) {
      length++;
    }
    return length;
  }

  /// Skips [count] pixels mid-row: 0, then pixels + 1, in steps of 254.
  void _writeSkip(_ByteSink out, int count) {
    while (count > 0) {
      final step = count < 254 ? count : 254;
      out
        ..byte(0)
        ..byte(step + 1);
      count -= step;
    }
  }
}

/// A growable big-endian byte buffer.
class _ByteSink {
  Uint8List _bytes = Uint8List(1 << 16);
  int _length = 0;

  void _reserve(int extra) {
    if (_length + extra <= _bytes.length) return;
    var capacity = _bytes.length * 2;
    while (capacity < _length + extra) {
      capacity *= 2;
    }
    _bytes = Uint8List(capacity)..setRange(0, _length, _bytes);
  }

  void byte(int value) {
    _reserve(1);
    _bytes[_length++] = value;
  }

  void u16(int value) {
    _reserve(2);
    _bytes[_length++] = value >> 8;
    _bytes[_length++] = value & 0xFF;
  }

  void u32(int value) {
    _reserve(4);
    _bytes[_length++] = (value >> 24) & 0xFF;
    _bytes[_length++] = (value >> 16) & 0xFF;
    _bytes[_length++] = (value >> 8) & 0xFF;
    _bytes[_length++] = value & 0xFF;
  }

  /// The bytes written, with the leading 32-bit size set to their length.
  Uint8List takeWithSize() {
    final bytes = Uint8List.sublistView(_bytes, 0, _length);
    ByteData.sublistView(bytes).setUint32(0, _length);
    return Uint8List.fromList(bytes);
  }
}
