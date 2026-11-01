import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/clipboard_service.dart';

const _width = 64;
const _height = 36;

/// The file pasteboard's Windows plugin writes: 32 bits a pixel, no
/// compression, bottom row first, and a fourth channel that is padding.
Uint8List _windowsPasteBitmap({required int padding}) {
  final bytes = ByteData(54 + _width * _height * 4);
  bytes
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, bytes.lengthInBytes, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, _width, Endian.little)
    ..setInt32(22, _height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little)
    ..setUint32(34, _width * _height * 4, Endian.little);
  for (var i = 0; i < _width * _height; i++) {
    final at = 54 + i * 4;
    bytes
      ..setUint8(at, i & 0xFF)
      ..setUint8(at + 1, (i * 7) & 0xFF)
      ..setUint8(at + 2, (i * 13) & 0xFF)
      ..setUint8(at + 3, padding);
  }
  return bytes.buffer.asUint8List();
}

/// A bitmap whose fourth channel really is alpha: a BITMAPV4 header naming
/// the channels, as a saved .bmp with transparency has.
Uint8List _bitmapWithAlpha() {
  const header = 14 + 108;
  final bytes = ByteData(header + _width * _height * 4);
  bytes
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, bytes.lengthInBytes, Endian.little)
    ..setUint32(10, header, Endian.little)
    ..setUint32(14, 108, Endian.little)
    ..setInt32(18, _width, Endian.little)
    ..setInt32(22, _height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little)
    ..setUint32(30, 3, Endian.little) // BI_BITFIELDS
    ..setUint32(34, _width * _height * 4, Endian.little)
    ..setUint32(54, 0x00FF0000, Endian.little)
    ..setUint32(58, 0x0000FF00, Endian.little)
    ..setUint32(62, 0x000000FF, Endian.little)
    ..setUint32(66, 0xFF000000, Endian.little);
  for (var i = 0; i < _width * _height; i++) {
    final at = header + i * 4;
    bytes
      ..setUint8(at, (i * 3) & 0xFF)
      ..setUint8(at + 1, (i * 5) & 0xFF)
      ..setUint8(at + 2, (i * 11) & 0xFF)
      ..setUint8(at + 3, i & 0xFF);
  }
  return bytes.buffer.asUint8List();
}

/// [bytes] as Icarus draws them: decoded and premultiplied.
Future<({int width, int height, Uint8List pixels})> _drawn(
  Uint8List bytes,
) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  final image = frame.image;
  final pixels = await image.toByteData();
  final drawn = (
    width: image.width,
    height: image.height,
    pixels: pixels!.buffer.asUint8List(),
  );
  image.dispose();
  return drawn;
}

Future<void> _expectSamePicture(Uint8List bitmap, Uint8List png) async {
  expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  expect(png.length, lessThan(bitmap.length));
  final before = await _drawn(bitmap);
  final after = await _drawn(png);
  expect((after.width, after.height), (before.width, before.height));
  expect(after.pixels, before.pixels);
}

void main() {
  // Screenshots reach us with the padding at 0 or at 255, depending on who
  // put them on the clipboard. Taking 0 for alpha saves an invisible picture.
  for (final padding in [0, 255, 128]) {
    testWidgets('a pasted bitmap with padding $padding keeps every pixel',
        (tester) async {
      await tester.runAsync(() async {
        final bitmap = _windowsPasteBitmap(padding: padding);
        await _expectSamePicture(bitmap, await pngOfBitmap(bitmap));
      });
    });
  }

  testWidgets('a bitmap with real transparency keeps it', (tester) async {
    await tester.runAsync(() async {
      final bitmap = _bitmapWithAlpha();
      final png = await pngOfBitmap(bitmap);
      await _expectSamePicture(bitmap, png);
      final drawn = await _drawn(png);
      final alpha = {
        for (var i = 3; i < drawn.pixels.length; i += 4) drawn.pixels[i],
      };
      expect(alpha.length, greaterThan(100));
    });
  });

  testWidgets('bytes that only look like a bitmap stay as they came',
      (tester) async {
    await tester.runAsync(() async {
      final broken = Uint8List.fromList([0x42, 0x4D, 1, 2, 3, 4, 5, 6]);
      expect(await pngOfBitmap(broken), same(broken));
    });
  });

  testWidgets('a bitmap a PNG can not shrink stays as it came', (tester) async {
    await tester.runAsync(() async {
      // A 1-bit bitmap's rows are smaller than any PNG's headers.
      final tiny = Uint8List.fromList([
        0x42, 0x4D, 66, 0, 0, 0, 0, 0, 0, 0, 62, 0, 0, 0, //
        40, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0,
        4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 255, 255, 255, 0, 0x80, 0, 0, 0,
      ]);
      expect(await pngOfBitmap(tiny), same(tiny));
    });
  });

  test('anything but a bitmap passes straight through', () async {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]);
    expect(await pngOfBitmap(png), same(png));
  });
}
