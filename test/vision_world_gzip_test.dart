import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_world_gzip.dart';

void main() {
  test('desktop and web gzip decoding preserve identical baked bytes', () {
    for (final name in [
      'raw-v1.bin.gz',
      'delta-v1.bin.gz',
      'split_test_000.bin.gz'
    ]) {
      final compressed =
          File('test/fixtures/world_visibility/$name').readAsBytesSync();
      expect(decodeWorldGzip(compressed),
          const GZipDecoderWeb().decodeBytes(compressed, verify: true));
    }
  });

  test('truncated or damaged gzip cannot become a valid world chunk', () {
    final bytes = Uint8List.fromList(const GZipEncoder()
        .encode(utf8.encode('standing map geometry ' * 1000)));
    for (final length in [
      0,
      1,
      10,
      bytes.length ~/ 2,
      bytes.length - 8,
      bytes.length - 1
    ]) {
      expect(() => decodeWorldGzip(Uint8List.sublistView(bytes, 0, length)),
          throwsA(isA<Object>()),
          reason: 'truncated at $length');
    }
    final badCrc = Uint8List.fromList(bytes)..[bytes.length - 8] ^= 1;
    expect(() => decodeWorldGzip(badCrc), throwsA(isA<Object>()));
    final badLength = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 1;
    expect(() => decodeWorldGzip(badLength), throwsA(isA<Object>()));
    final badHeader = Uint8List.fromList(bytes)..[0] ^= 1;
    expect(() => decodeWorldGzip(badHeader), throwsA(isA<Object>()));
  });
}
