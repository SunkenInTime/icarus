import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

import 'display_warp_fixture.dart';

Map<String, dynamic> _combine(
    Map<String, dynamic> first, Map<String, dynamic> second) {
  final vertices = (first['sourceNativeMeters'] as List).length ~/ 2;
  for (final key in ['sourceNativeMeters', 'targetAttackSvg']) {
    first[key] = [...first[key] as List, ...second[key] as List];
  }
  first['triangles'] = [
    ...first['triangles'] as List,
    for (final index in second['triangles'] as List) (index as int) + vertices,
  ];
  return first;
}

final _identity = VisionWorldProjection(
    origin: Offset.zero, axisU: const Offset(1, 0), axisV: const Offset(0, 1));
final _hash = 'a' * 64;

Map<String, dynamic> _fixture({VisionWorldProjection? projection}) {
  final p = projection ?? _identity;
  List<double> xy(Offset point) => [point.dx, point.dy];
  final targets = [
    const Offset(0, 0),
    const Offset(10, 0),
    const Offset(10, 10),
    const Offset(0, 10),
    const Offset(6, 5)
  ];
  return {
    'format': 'icarus-display-warp-v1',
    'version': 1,
    'map': 'split',
    'outsideMesh': 'identity-in-source-svg',
    'outerHullMaximumDisplacementSvg': 0,
    'sourceGeometrySha256': _hash,
    'maximumStretch': 2,
    'projection': {
      'origin': xy(p.origin),
      'axisU': xy(p.axisU),
      'axisV': xy(p.axisV)
    },
    'sourceNativeMeters': <num>[0, 0, 10, 0, 10, 10, 0, 10, 5, 5],
    'targetAttackSvg': targets.expand((v) => xy(p.toCanvas(v))).toList(),
    'triangles': [0, 1, 4, 1, 2, 4, 2, 3, 4, 3, 0, 4],
    'attackViewBox': [0, 0, 10, 10],
    'defenseViewBox': [0, 0, 10, 10],
    'attackToDefenseSvg': <String, dynamic>{
      'axisU': [-1, 0],
      'axisV': [0, -1],
      'origin': [10, 10]
    },
    'art': {
      'attack': {'file': 'assets/maps/split_map.svg', 'sha256': _hash},
      'defense': {'file': 'assets/maps/split_map_defense.svg', 'sha256': _hash},
    },
    'provenance': {
      for (final key in [
        'warpSha256',
        'compositionProofSha256',
        'sideRegistrationSha256',
        'registrationSha256',
        'controlGeometryPackSha256',
        'unwarpedControlSourcePackSha256'
      ])
        key: _hash
    },
  };
}

Future<String> _sha(List<int> bytes) async => (await Sha256().hash(bytes))
    .bytes
    .map((v) => v.toRadixString(16).padLeft(2, '0'))
    .join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('rejects overlapping charts even when triangle indices are distinct',
      () {
    final json = _combine(
        displayWarpFixture(), displayWarpFixture(shift: const Offset(-1, 0)));
    // Both copies have fixed outer edges and positive triangle determinants.
    // The inverse would select the first copy while the GPU draws both.
    expect(() => DisplayWarp.fromJson(json), throwsFormatException);
  });

  test('rejects an overlapping interior chart with distinct vertex positions',
      () {
    final json = _combine(
        displayWarpFixture(),
        displayWarpFixture(
            bounds: const Rect.fromLTWH(20, 20, 40, 40),
            shift: const Offset(-1, 0)));
    // No duplicate source positions or index triples are necessary to create
    // overlapping domains. An independent inner boundary is fixed too.
    expect(() => DisplayWarp.fromJson(json), throwsFormatException);
  });

  test('display inverse preserves source points and has identity outside', () {
    final warp = DisplayWarp.fromJson(_fixture());
    for (final point in [
      const Offset(2, 1),
      const Offset(5, 5),
      const Offset(9, 8),
      const Offset(0, 0)
    ]) {
      expect((warp.sourceAt(warp.targetAt(point)) - point).distance,
          lessThan(1e-12));
    }
    expect(warp.targetAt(const Offset(2, 1)), const Offset(2.2, 1));
    expect(warp.sourceAt(const Offset(-1, -1)), const Offset(-1, -1));
    expect(warp.targetAt(const Offset(20, 20)), const Offset(20, 20));
    expect(warp.displacementBound(_identity), closeTo(1, 1e-12));
  });

  test('local derivative is available without changing heading automatically',
      () {
    final warp = DisplayWarp.fromJson(_fixture());
    final result =
        warp.sourceDirectionAt(const Offset(2.2, 1), const Offset(0, 1));
    expect((result - const Offset(-.2, 1)).distance, lessThan(1e-12));
    expect(warp.sourceDirectionAt(const Offset(-1, -1), const Offset(0, 1)),
        const Offset(0, 1));
  });

  test('side meshes are caller-owned and displacement follows side scale', () {
    final warp = DisplayWarp.fromJson(_fixture());
    final side = VisionWorldProjection(
        origin: const Offset(100, 100),
        axisU: const Offset(-3, 0),
        axisV: const Offset(0, -3));
    expect(warp.displacementBound(side), closeTo(3, 1e-12));
    final mesh = warp.createMesh(side);
    mesh.dispose();
  });

  test('rejects mismatched registration, source, folded cells and moving hull',
      () {
    expect(() => DisplayWarp.fromJson(_fixture(), expectedMap: 'pearl'),
        throwsFormatException);
    expect(
        () => DisplayWarp.fromJson(_fixture(),
            expectedSourceGeometrySha256: 'b' * 64),
        throwsFormatException);
    expect(
        () => DisplayWarp.fromJson(_fixture(),
            expectedProjection: VisionWorldProjection(
                origin: const Offset(1, 0),
                axisU: const Offset(1, 0),
                axisV: const Offset(0, 1))),
        throwsFormatException);
    for (final mutation in <void Function(Map<String, dynamic>)>[
      (j) => j['targetAttackSvg'][8] = 11.0,
      (j) => j['targetAttackSvg'][0] = -.1,
      (j) => j['triangles'][0] = 900,
      (j) => j['sourceNativeMeters'][0] = double.nan,
      (j) => j['maximumStretch'] = 1,
      (j) => j['art']['attack']['sha256'] = 'invalid',
    ]) {
      final json = _fixture();
      mutation(json);
      expect(() => DisplayWarp.fromJson(json), throwsFormatException);
    }
  });

  test('optional descriptor binds verified bytes, source, projection and side',
      () async {
    final catalog = jsonDecode(
        await File('$heightAssetDirectory/height_catalog.json').readAsString());
    final base = Map<String, dynamic>.from(catalog['maps']['split'] as Map);
    final original = HeightAssetEntry.fromJson(MapValue.split, base);
    expect(original.displayWarp, isNull);
    final json = _fixture(projection: original.svgProjection);
    json['sourceGeometrySha256'] = original.sourceGeometrySha256;
    final box = Offset.zero & Maps.mapViewBox[MapValue.split]!;
    json['attackViewBox'] = [box.left, box.top, box.width, box.height];
    json['defenseViewBox'] = json['attackViewBox'];
    final origin = box.topLeft * 2 +
        Offset(box.width, box.height) +
        original.defenseOffsetSvg;
    json['attackToDefenseSvg']['origin'] = [origin.dx, origin.dy];
    final compressed =
        Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(json))));
    final entry = HeightAssetEntry.fromJson(MapValue.split, {
      ...base,
      'displayWarp': {
        'file': 'split.display-warp.json.gz',
        'bytes': compressed.length,
        'sha256': await _sha(compressed),
      }
    });
    final warp =
        await decodeDisplayWarp((entry: entry, compressed: compressed));
    expect(warp.sourceGeometrySha256, original.sourceGeometrySha256);
    final broken = Uint8List.fromList(compressed)..[0] ^= 1;
    await expectLater(decodeDisplayWarp((entry: entry, compressed: broken)),
        throwsFormatException);
    expect(
        () => HeightAssetEntry.fromJson(MapValue.split, {
              ...base,
              'displayWarp': {
                'file': '../split.display-warp.json.gz',
                'bytes': compressed.length,
                'sha256': _hash,
              }
            }),
        throwsFormatException);
  });

  test('actual artwork must match both bound checksums', () async {
    final json = _fixture();
    json['art']['attack']['sha256'] = await _sha(utf8.encode('attack'));
    json['art']['defense']['sha256'] = await _sha(utf8.encode('defense'));
    final warp = DisplayWarp.fromJson(json);
    await verifyDisplayWarpArtwork(warp, 'attack', 'defense');
    await expectLater(verifyDisplayWarpArtwork(warp, 'changed', 'defense'),
        throwsFormatException);
    await expectLater(verifyDisplayWarpArtwork(warp, 'attack', 'changed'),
        throwsFormatException);
  });

  test('rejects duplicate cells before they can multiply lookup work', () {
    final json = _fixture();
    (json['triangles'] as List<int>).addAll([4, 1, 0]);
    expect(
        () => DisplayWarp.fromJson(json),
        throwsA(isA<FormatException>()
            .having((e) => e.message, 'message', contains('Duplicate'))));
  });

  test('bounds total grid memberships across otherwise admissible cells', () {
    final json = _fixture();
    final positions = <double>[];
    for (var i = 0; i < 17; i++) {
      final shift = i * .001;
      positions
          .addAll([-1000 + shift, -1000, 1000 + shift, -1000, shift, 1000]);
    }
    json['sourceNativeMeters'] = positions;
    json['targetAttackSvg'] = positions.toList();
    json['triangles'] = List.generate(51, (i) => i);
    expect(
        () => DisplayWarp.fromJson(json),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', contains('membership limit'))));
  });

  final folder = Platform.environment['DISPLAY_WARP_DIRECTORY'];
  if (folder != null) {
    test(
        'all staged projections decode against current source and artwork registration',
        () async {
      final catalog = jsonDecode(
          await File('$heightAssetDirectory/height_catalog.json')
              .readAsString());
      final manifest =
          jsonDecode(await File('$folder/manifest.json').readAsString());
      final timingOutput = Platform.environment['DISPLAY_WARP_TIMING_OUTPUT'];
      final timings = <Map<String, dynamic>>[];
      for (final row in manifest['maps'] as List) {
        final map = MapValue.values.byName(row['map'] as String);
        final base =
            Map<String, dynamic>.from(catalog['maps'][map.name] as Map);
        final entry = HeightAssetEntry.fromJson(map, {
          ...base,
          'displayWarp': {
            'file': row['file'],
            'bytes': row['bytes'],
            'sha256': row['sha256'],
          }
        });
        final compressed = await File('$folder/${row['file']}').readAsBytes();
        final decodeTimes = <int>[];
        late DisplayWarp warp;
        for (var repeat = 0;
            repeat < (timingOutput == null ? 1 : 5);
            repeat++) {
          final watch = Stopwatch()..start();
          warp =
              await decodeDisplayWarp((entry: entry, compressed: compressed));
          decodeTimes.add(watch.elapsedMicroseconds);
        }
        timings.add({
          'map': map.name,
          'compressedSha256': row['sha256'],
          'decodeMicros': decodeTimes,
        });
        expect(warp.map, map.name);
        await verifyDisplayWarpArtwork(
            warp,
            await File('assets/maps/${map.name}_map.svg').readAsString(),
            await File('assets/maps/${map.name}_map_defense.svg')
                .readAsString());
      }
      if (timingOutput != null) {
        await File(timingOutput)
            .writeAsString(const JsonEncoder.withIndent('  ').convert({
          'mode': 'flutter-test-debug',
          'measurement':
              'Verified compressed bytes, gzip, JSON, registration and topology '
                  'decode. Excludes disk reads, artwork hashing, and isolate startup. '
                  'Five sequential repeats per map; first includes local warmup.',
          'maps': timings,
        }));
      }
    });
  }
}
