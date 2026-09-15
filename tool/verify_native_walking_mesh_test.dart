// Independent source -> Dart alpha -> Dart shadow mesh comparison with the DLL.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_collision.dart';
import 'package:icarus/view_cone/vision_world_index.dart';
import 'world_height_native.dart';
import 'world_shadow_mesh.dart';
import 'file:///E:/IcarusWorldAudit/2026-09-06/compact-prototype/height_alpha_clip.dart';
import 'file:///E:/IcarusWorldAudit/2026-09-06/compact-prototype/probe_height_triangles.dart';

const _compact = 'E:/IcarusWorldAudit/2026-09-06/compact-prototype';
const _pipeline = '$_compact/native-height/pipeline-v2';
const _dll = '$_pipeline/icarus_height_sized.dll';
const _dllSha =
    'd7dc7878133ffcb8742fb4abfc7c091eda08626914361a25efef2b60423d35ec';

Future<String> _sha(List<int> bytes) async => (await Sha256().hash(bytes))
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
Future<String> _fileSha(String path) => _sha(File(path).readAsBytesSync());
Map<String, dynamic> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

bool _intersects(double ax, double ay, double bx, double by, Float64List q) {
  final half = q[6] / 2, c = math.cos(q[6] / 2), s = math.sin(half);
  final lx = q[3] * c + q[4] * s, ly = q[4] * c - q[3] * s;
  final ux = q[3] * c - q[4] * s, uy = q[4] * c + q[3] * s;
  ax -= q[0];
  ay -= q[1];
  bx -= q[0];
  by -= q[1];
  var low = 0.0, high = 1.0;
  bool clip(double a, double b) {
    if (a >= 0 && b >= 0) return true;
    if (a < 0 && b < 0) return false;
    final t = a / (a - b);
    if (a < 0) {
      low = math.max(low, t);
    } else {
      high = math.min(high, t);
    }
    return low <= high;
  }

  if (!clip(lx * ay - ly * ax, lx * by - ly * bx) ||
      !clip(uy * ax - ux * ay, uy * bx - ux * by)) return false;
  final dx = bx - ax, dy = by - ay, den = dx * dx + dy * dy;
  final t = den == 0 ? low : (-(ax * dx + ay * dy) / den).clamp(low, high);
  final x = ax + dx * t, y = ay + dy * t;
  return x * x + y * y <= q[5] * q[5];
}

class _Expected {
  _Expected(this.source, this.metadata) {
    textures = [
      for (var i = 0; i < source.textures.length; i++)
        HeightAlphaTexture(source.header['textures'][i]['width'],
            source.header['textures'][i]['height'], source.textures[i])
    ];
    policies = {
      for (final entry in source.materials.entries)
        entry.key: HeightAlphaPolicy(
            threshold: (entry.value['threshold'] as num).toDouble(),
            scale: (entry.value['alphaScale'] as num).toDouble(),
            bias: (entry.value['alphaBias'] as num).toDouble(),
            wrapS: heightAlphaWrap(entry.value['wrapS']),
            wrapT: heightAlphaWrap(entry.value['wrapT']))
    };
  }
  final HeightTriangles source;
  final Map<String, dynamic> metadata;
  late List<HeightAlphaTexture> textures;
  late Map<int, HeightAlphaPolicy> policies;
  final builder = WorldShadowMeshBuilder();
  final materialCalls = <int, int>{};
  var sections = 0, maskedSections = 0, clippedSections = 0;
  Float32List build(Float64List q) {
    final segments = <VisionSegment>[];
    final facing = math.atan2(q[4], q[3]);
    // Candidates come only from source triangles. No native output participates
    // in selection, section coordinates, alpha intervals, or expected mesh.
    source.visitCone(q[0], q[1], q[2], facing, q[6], q[5],
        (face, ax, ay, bx, by) {
      if (!_intersects(ax, ay, bx, by, q)) return;
      sections++;
      final mask = source.faceMasks[face];
      if (mask < 0) {
        segments.add(VisionSegment.unthickened(Offset(ax, ay), Offset(bx, by)));
        return;
      }
      maskedSections++;
      if (!source.sectionAt(face, q[2], texture: true))
        throw StateError('Source UV section disappeared.');
      final p = source.section;
      expect([p[0], p[1], p[4], p[5]], [ax, ay, bx, by]);
      final material = source.maskedMaterials[mask];
      materialCalls[material] = (materialCalls[material] ?? 0) + 1;
      final texture = textures[source.materials[material]['texture']];
      visitHeightAlphaIntervals(
          texture, policies[material]!, p[2], p[3], p[6], p[7], (lo, hi) {
        final dx = bx - ax, dy = by - ay;
        final pax = ax + dx * lo,
            pay = ay + dy * lo,
            pbx = ax + dx * hi,
            pby = ay + dy * hi;
        if (_intersects(pax, pay, pbx, pby, q))
          segments.add(
              VisionSegment.unthickened(Offset(pax, pay), Offset(pbx, pby)));
      });
    });
    clippedSections += segments.length;
    return builder.build(
        index: VisionWorldIndex(segments, spatiallyOrdered: true),
        origin: Offset(q[0], q[1]),
        facingAngle: facing,
        coneAngle: q[6],
        range: q[5]);
  }
}

Future<void> _verify(String name) async {
  final output = Directory('$_pipeline/walking-source-verification-v2/$name');
  if (output.existsSync())
    throw StateError('Previous proof remains immutable.');
  final prepared =
      '$_pipeline/${name == 'split' ? 'scoped-split' : 'walking-$name'}';
  final fixtureFolder = '$_compact/native-walking-fixtures-v1/$name';
  final manifest = _json('$fixtureFolder/manifest.json');
  final provenance = manifest['provenance'] as Map<String, dynamic>;
  final packed = File(provenance['packFile'] as String).readAsBytesSync();
  expect(await _sha(packed), provenance['packSha256']);
  final raw = Uint8List.fromList(gzip.decode(packed));
  expect(await _fileSha('$prepared/height-source.raw'), await _sha(raw));
  expect(await _fileSha(_dll), _dllSha);
  final model = HeightTriangles(raw);
  final expected =
      _Expected(model, _json(provenance['geometryMetadataFile'] as String));
  final worker = await HeightNativeWorker.open(_dll, prepared, 4);
  final watch = Stopwatch()..start();
  final rows = <Map<String, Object>>[], mismatches = <Map<String, Object>>[];
  final heights = <double>{}, directions = <String>{};
  var comparedCoordinates = 0,
      queries = 0,
      diagonalQueries = 0,
      maximumError = 0.0;
  final frames = [for (var i = 0; i < 64; i++) (i * 419 / 63).round()];
  output.createSync(recursive: true);
  try {
    for (final rate in [144, 240]) {
      final fixture = _json('$fixtureFolder/walking-${rate}hz.json');
      final bytes = File(fixture['queryFile'] as String).readAsBytesSync();
      expect(await _sha(bytes), fixture['querySha256']);
      final all = ByteData.sublistView(bytes);
      for (final frame in frames) {
        final batch = Float64List(70);
        for (var i = 0; i < 70; i++) {
          batch[i] = all.getFloat64((frame * 70 + i) * 8, Endian.little);
        }
        final native = await worker.compute(rate * 1000 + frame, batch);
        for (var agent = 0; agent < 10; agent++) {
          final q = Float64List.sublistView(batch, agent * 7, (agent + 1) * 7);
          heights.add(q[2]);
          directions.add('${q[3]},${q[4]}');
          if (q[3].abs() > 1e-4 && q[4].abs() > 1e-4) diagonalQueries++;
          final oracle = expected.build(q), actual = native.cone(agent);
          var firstMismatch = -1, changed = 0, maxError = 0.0;
          final count = math.min(oracle.length, actual.length);
          for (var i = 0; i < count; i++) {
            if (oracle[i] != actual[i]) {
              if (firstMismatch < 0) firstMismatch = i;
              changed++;
              maxError = math.max(maxError, (oracle[i] - actual[i]).abs());
            }
          }
          maximumError = math.max(maximumError, maxError);
          if (changed != 0 || oracle.length != actual.length) {
            final stem = 'hz${rate}_frame${frame}_agent$agent';
            if (mismatches.length < 12) {
              File('${output.path}/$stem.expected.f32').writeAsBytesSync(oracle
                  .buffer
                  .asUint8List(oracle.offsetInBytes, oracle.lengthInBytes));
              File('${output.path}/$stem.actual.f32').writeAsBytesSync(actual
                  .buffer
                  .asUint8List(actual.offsetInBytes, actual.lengthInBytes));
            }
            mismatches.add({
              'rate': rate,
              'frame': frame,
              'agent': agent,
              'query': q.toList(),
              'expectedFloats': oracle.length,
              'actualFloats': actual.length,
              'differentCoordinates': changed,
              'firstMismatch': firstMismatch,
              'maxAbsCoordinateError': maxError,
              if (firstMismatch >= 0) 'firstExpected': oracle[firstMismatch],
              if (firstMismatch >= 0) 'firstActual': actual[firstMismatch]
            });
          }
          queries++;
          comparedCoordinates += count;
          rows.add({
            'rate': rate,
            'frame': frame,
            'agent': agent,
            'float32Coordinates': actual.length
          });
        }
      }
    }
  } finally {
    await worker.close();
  }
  final structural = <Map<String, Object>>[];
  final materials = expected.metadata['materials'] as List;
  for (final entry in expected.materialCalls.entries) {
    final name = (materials[entry.key]['blenderName'] ??
        materials[entry.key]['name'] ??
        materials[entry.key]['source'] ??
        'unresolved material ${entry.key}') as String;
    if (RegExp(r'fence|grate|vent', caseSensitive: false).hasMatch(name)) {
      structural.add({
        'material': entry.key,
        'name': name,
        'sectionClipCalls': entry.value
      });
    }
  }
  final report = {
    'status': mismatches.isEmpty ? 'passed' : 'failed',
    'map': name,
    'simulatedRates': [144, 240],
    'sampledFramesPerRate': frames,
    'conesPerFrame': 10,
    'queries': queries,
    'sourceSections': expected.sections,
    'maskedSourceSections': expected.maskedSections,
    'clippedSections': expected.clippedSections,
    'float32CoordinatesCompared': comparedCoordinates,
    'exactFloat32MeshMatches': mismatches.isEmpty,
    'mismatches': mismatches,
    'maximumCoordinateError': maximumError,
    'distinctCameraHeights': heights.length,
    'cameraHeightRangeMeters': [
      heights.reduce(math.min),
      heights.reduce(math.max)
    ],
    'distinctFacings': directions.length,
    'diagonalQueries': diagonalQueries,
    'structuralCutoutsObserved': structural,
    'alphaMaterialCalls': {
      for (final e in expected.materialCalls.entries) '${e.key}': e.value
    },
    'dllFile': _dll,
    'dllSha256': _dllSha,
    'packSha256': provenance['packSha256'],
    'fixtureManifestSha256': await _fileSha('$fixtureFolder/manifest.json'),
    'independentTriangleQuerySha256':
        await _fileSha('$_compact/probe_height_triangles.dart'),
    'independentAlphaSha256':
        await _fileSha('$_compact/height_alpha_clip.dart'),
    'independentShadowMeshSha256':
        await _fileSha('tool/world_shadow_mesh.dart'),
    'ffiHelperSha256': await _fileSha('tool/world_height_native.dart'),
    'verifierSha256':
        await _fileSha('tool/verify_native_walking_mesh_test.dart'),
    'nativeInfo': worker.info,
    'elapsedSeconds': watch.elapsedMilliseconds / 1000,
    'proof':
        'Expected geometry is independently selected and sectioned from source triangles, alpha-clipped in Dart, then triangulated by WorldShadowMeshBuilder. DLL output is only the value under test.',
    'limits':
        'Finite source/rendering equivalence sample. No GPU rasterization, frame pacing or live-game completeness claim.',
    'rows': rows,
  };
  File('${output.path}/verification.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  // ignore: avoid_print
  print('NATIVE_WALKING_MESH_RESULT ${jsonEncode({
        for (final e in report.entries)
          if (e.key != 'rows' && e.key != 'mismatches') e.key: e.value
      })}');
  expect(mismatches, isEmpty, reason: '${output.path}/verification.json');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final name in (Platform.environment['ICARUS_MESH_VERIFY_MAPS'] ??
          'split,fracture,lotus')
      .split(',')) {
    test('actual-range native mesh equals independent source Dart for $name',
        () => _verify(name),
        timeout: const Timeout(Duration(minutes: 10)));
  }
}
