import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_world_data.dart';
import 'package:archive/archive.dart';

import 'vision_world_geometry_test.dart' show navigationFixture;
import 'vision_world_binary_test.dart' show rewriteHeader;

const directory = 'test/fixtures/world_visibility';
Map<String, dynamic> manifest() => jsonDecode(
    File('$directory/split_visibility.manifest.json').readAsStringSync());
Map<String, Uint8List> chunks() => {
      for (var i = 0; i < 5; i++)
        'split_test_${i.toString().padLeft(3, '0')}.bin.gz':
            File('$directory/split_test_${i.toString().padLeft(3, '0')}.bin.gz')
                .readAsBytesSync(),
    };
VisionWorldData decode(
        Map<String, dynamic> index, Map<String, Uint8List> blocks,
        {int maxDecodedBytes = 128 * 1024 * 1024}) =>
    VisionWorldData.fromChunkManifest(MapValue.split, index,
        compressedChunks: blocks,
        projectUv: (uv) => uv * 1000,
        maxDecodedBytes: maxDecodedBytes);

class _ChunkBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key.endsWith('_navigation.json.gz')) {
      return ByteData.sublistView(Uint8List.fromList(const GZipEncoder()
          .encode(utf8.encode(jsonEncode(navigationFixture())))));
    }
    return ByteData.sublistView(
        await File('$directory/${key.split('/').last}').readAsBytes());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('local-only chunks preserve exact edges and bound inflated data', () {
    final world = decode(manifest(), chunks());
    final original = VisionWorldData.fromJson(
        MapValue.split,
        jsonDecode(
            File('$directory/split_chunk_monolithic.json').readAsStringSync()),
        projectUv: (uv) => uv * 1000);
    expect(world.residentChunks.blocks, 0);
    for (final layer in [0, 1, 2, 3, 4, 0, 4, 2]) {
      final actual = world.segmentsForLayer(layer, isAttack: true).single;
      final expected = original.segmentsForLayer(layer, isAttack: true).single;
      expect(actual.start, expected.start);
      expect(actual.end, expected.end);
      expect(world.residentChunks.blocks, lessThanOrEqualTo(12));
      expect(world.residentChunks.bytes, lessThan(32 * 1024 * 1024));
    }
    world.validateAllChunks();
    expect(world.residentChunks.blocks, 5);
  });
  test(
      'chunk manifests reject missing data, bad mappings and metadata mismatch',
      () {
    expect(() => decode(manifest(), chunks()..remove('split_test_000.bin.gz')),
        throwsFormatException);
    final badMapping = manifest();
    badMapping['layers'][1]['localLayerIndex'] = 5;
    expect(() => decode(badMapping, chunks()), throwsFormatException);
    final badSize = manifest();
    badSize['chunks'][0]['compressedBytes'] = 1;
    expect(() => decode(badSize, chunks()), throwsFormatException);
    final badRawSize = manifest();
    badRawSize['chunks'][0]['uncompressedBytes'] = 1;
    expect(() => decode(badRawSize, chunks()).validateAllChunks(),
        throwsFormatException);
    final mismatch = manifest();
    mismatch['layers'][2]['globalOrigins'] = true;
    final world = decode(mismatch, chunks());
    expect(() => world.validateAllChunks(), throwsFormatException);
  });
  test('a corrupt cold block fails validation instead of changing source', () {
    final broken = chunks();
    broken['split_test_004.bin.gz']![20] ^= 0xff;
    final world = decode(manifest(), broken);
    expect(world.segmentsForLayer(0, isAttack: true), isNotEmpty);
    expect(() => world.validateAllChunks(), throwsA(isA<Object>()));
  });
  test('chunked assets load off-thread through the production factory',
      () async {
    final geometry = await loadWorldViewConeGeometry(MapValue.split,
        bundle: _ChunkBundle(), chunked: true);
    expect(geometry.worldData!.residentChunks.blocks, 1);
    expect(geometry.elevations, [475]);
    geometry.worldData!.validateAllChunks();
    expect(geometry.worldData!.residentChunks.blocks, 5);
  });
  test('neighboring blocks for ten moving agents survive within a bounded LRU',
      () {
    final index = manifest();
    final raw = const GZipDecoder().decodeBytes(chunks().values.first);
    final blocks = <String, Uint8List>{};
    index['layers'] = <Map<String, dynamic>>[];
    index['chunks'] = <Map<String, dynamic>>[];
    index['menuElevationsCm'] = <int>[];
    for (var i = 0; i < 14; i++) {
      final height = 475 + i * 5;
      final name = 'test_$i.bin.gz';
      final bytes = rewriteHeader(raw, (header) {
        header['layers'][0]['elevationCm'] = height;
        header['layers'][0]['globalOrigins'] = true;
        header['menuElevationsCm'] = [height];
      });
      blocks[name] = Uint8List.fromList(const GZipEncoder().encode(bytes));
      index['layers'].add({
        'elevationCm': height,
        'globalOrigins': true,
        'chunkIndex': i,
        'localLayerIndex': 0
      });
      index['chunks'].add({'asset': name});
      index['menuElevationsCm'].add(height);
    }
    final budget =
        const GZipDecoder().decodeBytes(blocks.values.first).length * 12;
    final world = decode(index, blocks, maxDecodedBytes: budget);
    for (var i = 0; i < 10; i++) {
      world.segmentsForLayer(i, isAttack: true);
    }
    expect(world.residentChunks.blocks, 10);
    world.validateAllChunks();
    expect(world.residentChunks.blocks, 12);
    expect(world.residentChunks.bytes, lessThanOrEqualTo(budget));
    // Re-entering an evicted floor must reconstruct its exact geometry.
    expect(world.segmentsForLayer(0, isAttack: true).single.start,
        world.segmentsForLayer(13, isAttack: true).single.start);
    expect(world.residentChunks.blocks, 12);
  });
}
