import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'vision_world_gzip_web.dart'
    if (dart.library.io) 'vision_world_gzip_io.dart' as platform;

/// archive uses native zlib on desktop and its Dart decoder on web. The SDK
/// accepts partial streams, so untrusted blocks also need their complete footer.
Uint8List decodeWorldGzip(Uint8List compressed, {bool verifyChecksum = true}) {
  checkWorldGzipHeader(compressed);
  final decoded = const GZipDecoder().decodeBytes(compressed, verify: true);
  final footer = ByteData.sublistView(compressed, compressed.length - 8);
  if (footer.getUint32(4, Endian.little) != decoded.length ||
      (verifyChecksum &&
          footer.getUint32(0, Endian.little) != getCrc32(decoded))) {
    throw const FormatException('Invalid world gzip checksum or length.');
  }
  return decoded;
}

/// [decodeWorldGzip] with the same checks. On the web the browser's own gzip
/// inflates and verifies the data: there the Dart decoder and CRC run on the
/// UI thread and take about 0.4 s per side of a large map.
Future<Uint8List> inflateWorldGzip(Uint8List compressed) =>
    platform.inflateWorldGzip(compressed);

void checkWorldGzipHeader(Uint8List compressed) {
  if (compressed.length < 18 ||
      compressed[0] != 0x1f ||
      compressed[1] != 0x8b) {
    throw const FormatException('Invalid world gzip header.');
  }
}
