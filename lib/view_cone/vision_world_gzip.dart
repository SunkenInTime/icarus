import 'dart:typed_data';

import 'package:archive/archive.dart';

/// archive uses native zlib on desktop and its Dart decoder on web. The SDK
/// accepts partial streams, so untrusted blocks also need their complete footer.
Uint8List decodeWorldGzip(Uint8List compressed, {bool verifyChecksum = true}) {
  if (compressed.length < 18 ||
      compressed[0] != 0x1f ||
      compressed[1] != 0x8b) {
    throw const FormatException('Invalid world gzip header.');
  }
  final decoded = const GZipDecoder().decodeBytes(compressed, verify: true);
  final footer = ByteData.sublistView(compressed, compressed.length - 8);
  if (footer.getUint32(4, Endian.little) != decoded.length ||
      (verifyChecksum &&
          footer.getUint32(0, Endian.little) != getCrc32(decoded))) {
    throw const FormatException('Invalid world gzip checksum or length.');
  }
  return decoded;
}
