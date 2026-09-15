import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/view_cone/height_assets.dart';

class _Files extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await File(key).readAsBytes());
}

Future<String> _hash(List<int> bytes) async => (await Sha256().hash(bytes))
    .bytes
    .map((v) => v.toRadixString(16).padLeft(2, '0'))
    .join();

Future<({HeightAssetEntry entry, Uint8List raw, Uint8List compressed})> _tiny(
    {bool overlap = false, String? groundSha, String? catalogGroundSha}) async {
  final zeroHash = '0' * 64;
  final arrays = <String, dynamic>{};
  var offset = 0;
  void array(String name, String dtype, List<int> shape, int width) {
    offset = (offset + 7) ~/ 8 * 8;
    final count = shape.fold(1, (a, b) => a * b);
    arrays[name] = {
      'offset': offset,
      'dtype': dtype,
      'shape': shape,
      'count': count
    };
    offset += count * width;
  }

  array('vertices', 'float64', [3, 3], 8);
  array('faces', 'uint32', [1, 3], 4);
  array('bounds', 'float64', [1, 6], 8);
  array('nodes', 'int32', [1, 4], 4);
  array('faceMasks', 'int32', [1], 4);
  array('maskedUvs', 'float64', [0, 3, 2], 8);
  array('maskedMaterials', 'uint32', [0], 4);
  if (overlap) arrays['faces']['offset'] = 0;
  final header = utf8.encode(jsonEncode({
    'version': 1,
    'packerVersion': 2,
    'map': 'split',
    'sourceGeometrySha256': zeroHash,
    'policySha256': zeroHash,
    'heightDomainMeters': [0, 10],
    if (groundSha != null) ...{
      'coordinatePolicy': 'tactical-floor-relative-v1',
      'tacticalGroundFieldSha256': groundSha,
    },
    'arrays': arrays,
    'textures': [],
    'materials': []
  }));
  final base = (8 + header.length + 7) ~/ 8 * 8;
  final raw = Uint8List(base + offset);
  raw.setRange(0, 4, ascii.encode('IHD1'));
  ByteData.sublistView(raw).setUint32(4, header.length, Endian.little);
  raw.setRange(8, 8 + header.length, header);
  final compressed = Uint8List.fromList(gzip.encode(raw));
  final entry = HeightAssetEntry.fromJson(MapValue.split, {
    'pack': 'split.height.bin.gz',
    'packSha256': await _hash(compressed),
    'compressedBytes': compressed.length,
    'rawSha256': await _hash(raw),
    'rawBytes': raw.length,
    'navigation': 'split_navigation.json.gz',
    'navigationSha256': zeroHash,
    'navigationBytes': 1,
    'sourceGeometrySha256': zeroHash,
    'policySha256': zeroHash,
    'observerHeightCm': 175,
    'defaultFloorElevationCm': 0,
    'heightDomainMeters': [0, 10],
    'menuElevationsCm': [175],
    if (catalogGroundSha != null)
      'tacticalGroundField': {
        'file': 'split.tactical-ground.json.gz',
        'sha256': catalogGroundSha,
        'bytes': 20,
      },
    'uiTransform': {
      'XMultiplier': .000078,
      'YMultiplier': -.000078,
      'XScalarToAdd': .842188,
      'YScalarToAdd': .697578
    },
  });
  return (entry: entry, raw: raw, compressed: compressed);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('upper chart has independent checksums and shares map registration',
      () async {
    final catalog = jsonDecode(
        await File('$heightAssetDirectory/height_catalog.json')
            .readAsString()) as Map<String, dynamic>;
    final primary = Map<String, dynamic>.from(catalog['maps']['split'] as Map);
    final upper = <String, dynamic>{
      'pack': 'split.upper.height.bin.gz',
      'packSha256': 'a' * 64,
      'compressedBytes': 23,
      'rawSha256': 'b' * 64,
      'rawBytes': 42,
      'heightDomainMeters': [-4, 5],
      'tacticalGroundField': {
        'file': 'split.upper.tactical-ground.json.gz',
        'sha256': 'c' * 64,
        'bytes': 31,
      },
    };
    HeightAssetEntry parse(Map<String, dynamic> chart) =>
        HeightAssetEntry.fromJson(
            MapValue.split, {...primary, 'upperChart': chart});
    final entry = parse(upper);
    final variant = entry.variants.single;
    expect(variant.packSha256, 'a' * 64);
    expect(variant.rawSha256, 'b' * 64);
    expect(variant.navigationSha256, entry.navigationSha256);
    expect(variant.uiTransform, entry.uiTransform);
    expect(variant.defenseOffsetSvg, entry.defenseOffsetSvg);
    expect(variant.tacticalGroundField!.sha256, 'c' * 64);
    for (final key in upper.keys) {
      expect(() => parse({...upper}..remove(key)), throwsFormatException,
          reason: 'Missing upper chart $key must not inherit lower data.');
    }
    for (final override in [
      {'pack': 'split.height.bin.gz'},
      {'navigation': 'other_navigation.json.gz'},
      {'uiTransform': primary['uiTransform']},
      {'upperChart': upper},
    ]) {
      expect(() => parse({...upper, ...override}), throwsFormatException);
    }
  });

  test('tactical packs bind to exactly one ground field', () async {
    final hash = 'a' * 64;
    for (final input in [
      await _tiny(groundSha: hash),
      await _tiny(catalogGroundSha: hash),
      await _tiny(groundSha: hash, catalogGroundSha: 'b' * 64),
    ]) {
      expect(() => heightPackSidecars(input.raw, input.entry),
          throwsFormatException);
    }
    final matched = await _tiny(groundSha: hash, catalogGroundSha: hash);
    expect(heightPackSidecars(matched.raw, matched.entry), isNotEmpty);
  });

  test('ground asset checksum is verified before using its coordinates',
      () async {
    final compressed = Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode({
      'version': 1,
      'coordinateSpace': 'native-meters',
      'vertices': [0, 0, 2, 4, 0, 2, 0, 4, 2],
      'triangles': [0, 1, 2],
    }))));
    final asset = TacticalGroundAsset.fromJson(MapValue.split, {
      'file': 'split.tactical-ground.json.gz',
      'sha256': await _hash(compressed),
      'bytes': compressed.length,
    });
    final ground =
        await decodeTacticalGroundField((asset: asset, compressed: compressed));
    expect(ground.heightAt(const Offset(1, 1)), 2);
    final corrupted = Uint8List.fromList(compressed)..[12] ^= 1;
    await expectLater(
        decodeTacticalGroundField((asset: asset, compressed: corrupted)),
        throwsFormatException);
  });

  test('all 13 shipped packs match their catalog and native layout', () async {
    final catalog = await loadHeightCatalog(bundle: _Files());
    expect(catalog.keys.toSet(), MapValue.values.toSet());
    var compressedBytes = 0;
    for (final entry in catalog.values) {
      final compressed =
          await File('$heightAssetDirectory/${entry.pack}').readAsBytes();
      expect(compressed.length, entry.compressedBytes, reason: entry.map.name);
      expect(await _hash(compressed), entry.packSha256, reason: entry.map.name);
      final raw = Uint8List.fromList(gzip.decode(compressed));
      expect(raw.length, entry.rawBytes, reason: entry.map.name);
      expect(await _hash(raw), entry.rawSha256, reason: entry.map.name);
      expect(
          heightPackSidecars(raw, entry).keys,
          containsAll([
            'arrays.txt',
            'alpha-textures.txt',
            'alpha-materials.txt',
            'parameters.txt'
          ]));
      final nav =
          await loadVerifiedHeightNavigation(entry.map, bundle: _Files());
      final navigation = jsonDecode(utf8.decode(gzip.decode(nav))) as Map;
      expect(navigation['map'], entry.map.name);
      expect(navigation['observerHeightCm'], entry.observerHeightCm);
      expect(
          navigation['defaultFloorElevationCm'], entry.defaultFloorElevationCm);
      for (final point in [
        Offset.zero,
        const Offset(25, -38),
        const Offset(-81, 15)
      ]) {
        expect(
            (entry.projection.toMeters(entry.projection.toCanvas(point)) -
                    point)
                .distance,
            lessThan(1e-10));
      }
      compressedBytes += compressed.length;
    }
    expect(compressedBytes, 189473747);
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('rejects a corrupt compressed payload before creating native inputs',
      () async {
    final input = await _tiny();
    final root =
        await Directory.systemTemp.createTemp('icarus-height-assets-test-');
    addTearDown(() => root.delete(recursive: true));
    input.compressed[10] ^= 1;
    await expectLater(
        prepareHeightAsset((
          entry: input.entry,
          compressed: input.compressed,
          cacheRoot: root.path
        )),
        throwsFormatException);
    expect(await root.list().toList(), isEmpty);
  });

  test('native SVG and canonical canvas projections agree for every map',
      () async {
    final catalog = await loadHeightCatalog(bundle: _Files());
    const mapWidth = 1000 * CoordinateSystem.defaultMapAspectRatio;
    const worldWidth = 1000 * (16 / 9);
    for (final entry in catalog.values) {
      final box = Maps.mapViewBox[entry.map]!;
      final scale = math.min(mapWidth / box.width, 1000 / box.height);
      final offset = Offset((worldWidth - box.width * scale) / 2,
          (1000 - box.height * scale) / 2);
      for (final point in [
        Offset.zero,
        const Offset(37, -51),
        const Offset(-88, 26)
      ]) {
        final fromSvg = entry.svgProjection.toCanvas(point) * scale + offset;
        expect((fromSvg - entry.projection.toCanvas(point)).distance,
            lessThan(1e-9),
            reason: entry.map.name);
      }
    }
  });

  test('both side projections match the measured unchanged artwork', () async {
    final catalog = await loadHeightCatalog(bundle: _Files());
    final registrations = jsonDecode(
        await File('test/fixtures/height_side_registration.json')
            .readAsString()) as List;
    expect(registrations, hasLength(MapValue.values.length));
    for (final row in registrations) {
      final map = MapValue.values.byName(row['map'] as String);
      final entry = catalog[map]!;
      final assets = HeightAssets(folder: '', entry: entry);
      final box = Maps.mapViewBox[map]!;
      final scale = math.min(1240 / box.width, 1000 / box.height);
      final offset = Offset((1000 * 16 / 9 - box.width * scale) / 2,
          (1000 - box.height * scale) / 2);
      for (final attack in [true, false]) {
        final suffix = attack ? '' : '_defense';
        final svg =
            await File('assets/maps/${map.name}_map$suffix.svg').readAsBytes();
        expect(
            await _hash(svg), row[attack ? 'attackSha256' : 'defenseSha256']);
        final matrix =
            row[attack ? 'nativeToAttackSvg' : 'nativeToDefenseSvg'] as List;
        final projection =
            attack ? assets.projection : assets.defenseProjection;
        for (final point in [
          Offset.zero,
          const Offset(37, -51),
          const Offset(-88, 26)
        ]) {
          final expected = Offset(
              matrix[0][0] * point.dx + matrix[0][1] * point.dy + matrix[0][2],
              matrix[1][0] * point.dx + matrix[1][1] * point.dy + matrix[1][2]);
          final rendered = (projection.toCanvas(point) - offset) / scale;
          expect((rendered - expected).distance, lessThan(1e-9),
              reason: '${map.name} $attack');
          expect(
              (projection.toMeters(expected * scale + offset) - point).distance,
              lessThan(1e-9));
        }
      }
    }
  });

  test('repairs raw cache corruption and regenerates altered native sidecars',
      () async {
    final input = await _tiny();
    final root =
        await Directory.systemTemp.createTemp('icarus-height-assets-test-');
    addTearDown(() => root.delete(recursive: true));
    final request = (
      entry: input.entry,
      compressed: input.compressed,
      cacheRoot: root.path
    );
    final folder = await prepareHeightAsset(request);
    final rawFile = File('$folder/height-source.raw');
    final altered = await rawFile.readAsBytes();
    altered[altered.length - 1] ^= 1;
    await rawFile.writeAsBytes(altered);
    await File('$folder/arrays.txt').writeAsString('faces 0 9999999999');
    expect(await prepareHeightAsset(request), folder);
    expect(await rawFile.readAsBytes(), input.raw);
    expect(await File('$folder/arrays.txt').readAsString(),
        heightPackSidecars(input.raw, input.entry)['arrays.txt']);
    expect(
        await Directory(folder)
            .list()
            .where((item) => item is Directory)
            .toList(),
        isEmpty);
  });

  test('rejects overlapping native arrays even with valid payload hashes',
      () async {
    final input = await _tiny(overlap: true);
    expect(() => heightPackSidecars(input.raw, input.entry),
        throwsFormatException);
  });
}
