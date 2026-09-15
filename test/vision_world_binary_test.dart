import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_world_binary.dart';
import 'package:icarus/view_cone/vision_world_data.dart';

Uint8List fixtureBytes() => const GZipDecoder().decodeBytes(
    File('test/fixtures/world_visibility/raw-v1.bin.gz').readAsBytesSync(),
    verify: true);

Uint8List rewriteHeader(
    Uint8List original, void Function(Map<String, dynamic>) change) {
  final size = ByteData.sublistView(original).getUint32(8, Endian.little);
  final oldStart = (12 + size + 3) & ~3;
  final header = jsonDecode(utf8.decode(original.sublist(12, 12 + size)))
      as Map<String, dynamic>;
  change(header);
  final encoded = utf8.encode(jsonEncode(header));
  final start = (12 + encoded.length + 3) & ~3;
  final result = Uint8List(start + original.length - oldStart);
  result.setRange(0, 8, original);
  ByteData.sublistView(result).setUint32(8, encoded.length, Endian.little);
  result.setRange(12, 12 + encoded.length, encoded);
  result.setRange(start, result.length, original, oldStart);
  return result;
}

void main() {
  test('Python delta encoder restores exact signed coordinates and edge IDs',
      () {
    final bytes = const GZipDecoder().decodeBytes(
        File('test/fixtures/world_visibility/delta-v1.bin.gz')
            .readAsBytesSync(),
        verify: true);
    final decoded = decodeVisionWorldBinary(bytes);
    expect(
        decoded,
        jsonDecode(File('test/fixtures/world_visibility/delta-v1.json')
            .readAsStringSync()));
    expect(decoded['vertices'], isA<Int32List>());
    final world = VisionWorldData.fromJson(MapValue.split, decoded,
        projectUv: (point) => point);
    expect(world.segmentsForLayer(0, isAttack: true).first.start.dx,
        closeTo(100 / 1048576, 1e-12));
    expect(world.segmentsForLayer(2, isAttack: true).length, 2);
  });

  test('Python raw encoder fixture preserves all geometry and metadata', () {
    final bytes = fixtureBytes();
    final decoded = decodeVisionWorldBinary(bytes);
    final expected = jsonDecode(
        File('test/fixtures/world_visibility/raw-v1.json').readAsStringSync());
    expect(decoded, expected);
    expect(decoded['vertices'], isA<Int32List>());
    expect(decoded['edges'], isA<Int32List>());
    expect(decoded['layers'][0]['edges'], isA<Int32List>());
    if (Endian.host == Endian.little) {
      expect((decoded['vertices'] as Int32List).buffer, bytes.buffer,
          reason: 'Large arrays remain shared typed views.');
    }
    final world = VisionWorldData.fromJson(MapValue.split, decoded,
        projectUv: (point) => point);
    expect(world.elevations, [475, 477.125, 480]);
    expect(world.segmentsForLayer(1, isAttack: true), isEmpty);
    expect(world.segmentsForLayer(0, isAttack: true).length, 2);
  });

  test('unaligned byte view is decoded without changing coordinates', () {
    final bytes = fixtureBytes();
    final padded = Uint8List(bytes.length + 1)
      ..setRange(1, bytes.length + 1, bytes);
    expect(decodeVisionWorldBinary(Uint8List.sublistView(padded, 1)),
        decodeVisionWorldBinary(bytes));
  });

  test('rejects unsupported encoding, corrupt directories and layer ranges',
      () {
    final changes = <void Function(Map<String, dynamic>)>[
      (h) => h['encoding'] = 'new-version',
      (h) => h['binaryArrays']['vertices']['byteOffset'] = 4,
      (h) => h['binaryArrays']['edges']['elementCount'] = -1,
      (h) => h['binaryArrays']['layerEdges']['elementCount'] = 100000,
      (h) => h['binaryArrays'].remove('vertices'),
      (h) => h['layers'][0]['edgeCount'] = 99,
      (h) => h['layers'][1]['edgeOffset'] = 1,
      (h) => h['layers'][2]['edgeCount'] = 1,
      (h) => h['layers'][0]['edges'] = [],
    ];
    for (final change in changes) {
      expect(
          () => decodeVisionWorldBinary(rewriteHeader(fixtureBytes(), change)),
          throwsFormatException);
    }
  });

  test('rejects truncated bytes, changed magic, and trailing payload', () {
    final original = fixtureBytes();
    for (final length in [0, 7, 11, 12, original.length - 1]) {
      expect(
          () => decodeVisionWorldBinary(
              Uint8List.sublistView(original, 0, length)),
          throwsFormatException);
    }
    final badMagic = Uint8List.fromList(original)..[4] = 2;
    expect(() => decodeVisionWorldBinary(badMagic), throwsFormatException);
    expect(() => decodeVisionWorldBinary(Uint8List.fromList([...original, 0])),
        throwsFormatException);
  });

  test('delta overflow fails instead of wrapping a coordinate', () {
    final bytes =
        rewriteHeader(fixtureBytes(), (h) => h['encoding'] = 'delta-int32-v1');
    final view = ByteData.sublistView(bytes);
    final start = (12 + view.getUint32(8, Endian.little) + 3) & ~3;
    view.setInt32(start, 2147483647, Endian.little);
    view.setInt32(start + 8, 1, Endian.little);
    expect(() => decodeVisionWorldBinary(bytes), throwsFormatException);
  });
}
