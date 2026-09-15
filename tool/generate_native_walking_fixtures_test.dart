// Offline fixture generator. Run with flutter test; never loads the library.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/view_cone/vision_world_gzip.dart';

const _root = 'E:/IcarusWorldAudit/2026-09-06';
const _compact = '$_root/compact-prototype';
const _frames = 420;
const _agents = 10;
const _speed = 5.4;
const _rangeCanvas = 361.0;
const _cone = 103 * math.pi / 180;
const _rates = [144, 240];

Future<Map<String, dynamic>> _read(String path) async =>
    jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;

Future<String> _sha(String path) async =>
    (await Sha256().hash(await File(path).readAsBytes()))
        .bytes
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();

List<double> _xy(Offset p) => [p.dx, p.dy];

class _Affine {
  _Affine(Offset Function(Offset) project)
      : origin = project(Offset.zero),
        x = project(const Offset(1, 0)) - project(Offset.zero),
        y = project(const Offset(0, 1)) - project(Offset.zero);
  final Offset origin, x, y;
  Offset apply(Offset point) => origin + vector(point);
  Offset vector(Offset point) => x * point.dx + y * point.dy;
  List<List<double>> get rows => [
        [x.dx, y.dx, origin.dx],
        [x.dy, y.dy, origin.dy]
      ];
}

class _Walk {
  _Walk(this.parents, this.points, this.distances, this.heightSamples);
  final List<int> parents;
  final List<Offset> points;
  final List<double> distances, heightSamples;
  double get length => distances.last;
  double get heightSpan =>
      heightSamples.reduce(math.max) - heightSamples.reduce(math.min);
  int get sampledHalfCmHeights =>
      heightSamples.map((h) => (h * 2).round()).toSet().length;
  ({Offset position, Offset direction}) at(double distance) {
    var along = distance % (2 * length);
    final reverse = along > length;
    if (reverse) along = 2 * length - along;
    var i = 1;
    while (i < distances.length - 1 && along > distances[i]) {
      i++;
    }
    final segment = points[i] - points[i - 1];
    final fraction =
        (along - distances[i - 1]) / (distances[i] - distances[i - 1]);
    return (
      position: points[i - 1] + segment * fraction,
      direction: segment / segment.distance * (reverse ? -1 : 1)
    );
  }
}

List<_Walk> _selectWalks(NavigationGeometry navigation) {
  final centers = [
    for (final polygon in navigation.polygons)
      polygon
              .map((i) => navigation.vertices[i].position)
              .reduce((a, b) => a + b) /
          polygon.length.toDouble()
  ];
  final candidates = <_Walk>[];
  for (final portal in navigation.links) {
    if (portal.from >= portal.to) continue;
    final points = [
      centers[portal.from],
      (portal.a + portal.b) / 2,
      centers[portal.to]
    ];
    final distances = [0.0, (points[1] - points[0]).distance];
    distances.add(distances.last + (points[2] - points[1]).distance);
    if (distances[1] < .01 ||
        distances[2] - distances[1] < .01 ||
        distances.last < 1) continue;
    final heights = <double>[];
    final walk = _Walk([portal.from, portal.to], points, distances, heights);
    var admitted = true;
    for (var sample = 0; sample <= (walk.length / .045).ceil(); sample++) {
      final point = walk.at(math.min(sample * .045, walk.length)).position;
      final floors = navigation.floorHeightsAt(point);
      if (floors.length != 1) {
        admitted = false;
        break;
      }
      heights.add(floors.single);
    }
    if (admitted && walk.heightSpan >= 10 && walk.sampledHalfCmHeights >= 3)
      candidates.add(walk);
  }
  candidates.sort((a, b) {
    final heightOrder =
        b.sampledHalfCmHeights.compareTo(a.sampledHalfCmHeights);
    return heightOrder != 0
        ? heightOrder
        : a.parents.first.compareTo(b.parents.first);
  });
  final chosen = <_Walk>[];
  for (final candidate in candidates) {
    if (chosen.any((other) => other.parents.any(candidate.parents.contains)))
      continue;
    final agent = chosen.length;
    var admitted = true;
    for (final rate in _rates) {
      for (var frame = 0; frame < _frames; frame++) {
        final p = candidate.at(frame * _speed / rate + agent * .071).position;
        if (navigation.floorHeightsAt(p).length != 1) {
          admitted = false;
          break;
        }
      }
      if (!admitted) break;
    }
    if (!admitted) continue;
    chosen.add(candidate);
    if (chosen.length == _agents) return chosen;
  }
  throw StateError(
      'Only ${chosen.length} independent admitted stair/slope corridors from ${candidates.length} candidates.');
}

Future<void> _generate(String name) async {
  final selectorFile =
      File('$_root/completeness/combined-manifest-release-inputs-v2.json');
  final rows = (jsonDecode(await selectorFile.readAsString()) as List)
      .cast<Map<String, dynamic>>();
  final source = rows.singleWhere((row) => row['map'] == name);
  final world = source['combinedWorldFolder'] as String;
  final metadata = await _read('$world/geometry.json');
  final navPath = '$_root/candidate-world-final/${name}_navigation.json.gz';
  final navBytes = await File(navPath).readAsBytes();
  final navRaw = decodeWorldGzip(navBytes);
  final navJson = jsonDecode(utf8.decode(navRaw)) as Map<String, dynamic>;
  expect(navJson['map'], name);
  expect(navJson['observerHeightCm'], 175);
  expect(navJson['floorMesh'],
      (await _read('$world/floor-mesh.json'))['floorMesh']);
  expect(navJson['refinedFloorHeightsCm'],
      (await _read('$world/floor-refinement.json'))['refinedFloorHeightsCm']);
  expect(await _sha('$world/geometry.json'), source['metadataSha256']);
  final ui = metadata['uiTransform'] as Map<String, dynamic>;
  final xm = (ui['XMultiplier'] as num).toDouble(),
      ym = (ui['YMultiplier'] as num).toDouble();
  final xa = (ui['XScalarToAdd'] as num).toDouble(),
      ya = (ui['YScalarToAdd'] as num).toDouble();
  Offset toNative(Offset uv) =>
      Offset((uv.dy - ya) / (100 * ym), -(uv.dx - xa) / (100 * xm));
  Offset toUv(Offset point) =>
      Offset(xa - point.dy * 100 * xm, ya + point.dx * 100 * ym);
  final navigation = NavigationGeometry.fromJson(navJson, projectUv: toNative);
  final map = MapValue.values.byName(name);
  final viewBox = Maps.mapViewBox[map]!;
  final padding = Maps.visionGeometryPadding[map]!;
  final turns = Maps.visionGeometryCwQuarterTurns[map] ?? 0;
  final alignment = Maps.visionGeometryAlignment[map]!;
  expect([
    alignment.scaleX,
    alignment.scaleY,
    alignment.offset.dx,
    alignment.offset.dy
  ], [
    1,
    1,
    0,
    0
  ]);
  Offset toSvg(Offset point) {
    final uv = toUv(point);
    final rotated = switch (turns % 4) {
      1 => Offset(1 - uv.dy, uv.dx),
      2 => Offset(1 - uv.dx, 1 - uv.dy),
      3 => Offset(uv.dy, 1 - uv.dx),
      _ => uv,
    };
    return Offset(
        rotated.dx * (viewBox.width + padding.horizontal) - padding.left,
        rotated.dy * (viewBox.height + padding.vertical) - padding.top);
  }

  final nativeToSvg = _Affine(toSvg);
  final nativeToCanvas =
      _Affine((p) => VisionGeometryMap.projectUv(map, toUv(p)));
  const mapWidth = 1000 * CoordinateSystem.defaultMapAspectRatio;
  const worldWidth = 1000 * (16 / 9);
  final svgScale = math.min(mapWidth / viewBox.width, 1000 / viewBox.height);
  final svgOffset = Offset(
      (worldWidth - mapWidth) / 2 + (mapWidth - viewBox.width * svgScale) / 2,
      (1000 - viewBox.height * svgScale) / 2);
  final svgToCanvas = _Affine((p) => svgOffset + p * svgScale);
  var maximumProjectionError = 0.0;
  for (final p in [
    Offset.zero,
    const Offset(1, 0),
    const Offset(0, 1),
    ...navigation.vertices.map((v) => v.position)
  ]) {
    final error =
        (nativeToCanvas.apply(p) - svgToCanvas.apply(nativeToSvg.apply(p)))
            .distance;
    maximumProjectionError = math.max(maximumProjectionError, error);
    expect(error, lessThan(1e-8));
    expect((toNative(toUv(p)) - p).distance, lessThan(1e-10));
  }
  final scopeFile = '$_compact/all-map-svg-foliage-v2/$name/scope.json';
  final scope = await _read(scopeFile);
  final packFile =
      '$_compact/all-map-height-scoped-v2/$name/$name.height.bin.gz';
  final packSummary =
      await _read('$_compact/all-map-height-scoped-v2/$name/summary.json');
  expect(await _sha(packFile), packSummary['dataSha256']);
  expect(packSummary['sourceGeometrySha256'], metadata['geometrySha256']);
  expect((packSummary['scope'] as Map)['scopeSha256'], await _sha(scopeFile));
  final domain = (packSummary['heightDomainMeters'] as List).cast<num>();
  final svgSources = <Map<String, dynamic>>[];
  for (final entry
      in (scope['receiverSvgs'] as List).cast<Map<String, dynamic>>()) {
    final path = entry['path'] as String;
    expect(await _sha(path), entry['sha256']);
    final raw = await File(path).readAsString();
    final numbers = RegExp(r'viewBox="([^"]+)"')
        .firstMatch(raw)!
        .group(1)!
        .trim()
        .split(RegExp(r'\s+'))
        .map(double.parse)
        .toList();
    expect(numbers, [0, 0, viewBox.width, viewBox.height]);
    svgSources.add(
        {'path': path, 'sha256': entry['sha256'], 'defense': entry['defense']});
  }
  final provenance = {
    'sourceSelectorFile': selectorFile.path,
    'sourceSelectorSha256': await _sha(selectorFile.path),
    'geometryMetadataFile': '$world/geometry.json',
    'geometryMetadataSha256': await _sha('$world/geometry.json'),
    'geometrySha256': metadata['geometrySha256'],
    'navigationFile': navPath,
    'navigationGzipSha256': await _sha(navPath),
    'navigationJsonSha256': (await Sha256().hash(navRaw))
        .bytes
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join(),
    'floorRefinementSha256': await _sha('$world/floor-refinement.json'),
    'floorMeshSha256': await _sha('$world/floor-mesh.json'),
    'scopeFile': scopeFile,
    'scopeSha256': await _sha(scopeFile),
    'packFile': packFile,
    'packSha256': await _sha(packFile),
    'navigationImplementationSha256':
        await _sha('lib/page_transition/navigation_geometry.dart'),
    'mapProjectionImplementationSha256':
        await _sha('lib/view_cone/vision_geometry.dart'),
    'mapsImplementationSha256': await _sha('lib/const/maps.dart'),
    'fixtureGeneratorSha256':
        await _sha('tool/generate_native_walking_fixtures_test.dart'),
    'receiverSvgs': svgSources,
  };
  final projection = {
    'matrixLayout': 'two rows, [x coefficient, y coefficient, translation]',
    'nativeToSvg': nativeToSvg.rows,
    'nativeToCanvas': nativeToCanvas.rows,
    'svgToCanvas': svgToCanvas.rows,
    'maximumCompositionErrorCanvasUnits': maximumProjectionError,
    'uiTransform': ui,
    'svgViewBox': [0, 0, viewBox.width, viewBox.height],
    'normalizedCanvasSize': [worldWidth, 1000],
    'svgBoxFit': 'contain in centered 1240 by 1000 map area',
    'defenseSvgFromAttackSvg': [
      [-1, 0, viewBox.width],
      [0, -1, viewBox.height]
    ],
    'rangeRule':
        'rangeMeters = 361 / length(nativeToCanvas.linear * nativeUnitDirection)',
  };
  final walks = _selectWalks(navigation);
  final output = Directory('$_compact/native-walking-fixtures-v1/$name');
  if (await output.exists())
    throw StateError('Existing walking fixtures are preserved.');
  await output.create(recursive: true);
  final routeRows = [
    for (var i = 0; i < walks.length; i++)
      {
        'agent': i,
        'parentPolygons': walks[i].parents,
        'component': navigation.components[walks[i].parents.first],
        'pointsNativeMeters': walks[i].points.map(_xy).toList(),
        'distancesMeters': walks[i].distances,
        'lengthMeters': walks[i].length,
        'floorHeightSpanCm': walks[i].heightSpan,
        'sampledHalfCmHeights': walks[i].sampledHalfCmHeights,
        'initialDistanceMeters': i * .071,
      }
  ];
  final files = <Map<String, dynamic>>[];
  for (final rate in _rates) {
    final binary = ByteData(_frames * _agents * 7 * 8);
    final frameRows = <Map<String, dynamic>>[];
    var cursor = 0, floorChanges = 0;
    var minimumRange = double.infinity,
        maximumRange = 0.0,
        maxFrameMovement = 0.0;
    final previousPositions = List<Offset?>.filled(_agents, null);
    final previousHeights = List<double?>.filled(_agents, null);
    for (var frame = 0; frame < _frames; frame++) {
      final poses = <List<double>>[],
          floors = <double>[],
          svgPositions = <List<double>>[],
          canvasPositions = <List<double>>[];
      for (var agent = 0; agent < _agents; agent++) {
        final sample = walks[agent].at(frame * _speed / rate + agent * .071);
        final heightValues = navigation.floorHeightsAt(sample.position);
        expect(heightValues, hasLength(1));
        final floor = heightValues.single;
        final eye = (floor + 175) / 100;
        expect(eye, inInclusiveRange(domain[0], domain[1]));
        final range =
            _rangeCanvas / nativeToCanvas.vector(sample.direction).distance;
        expect(sample.direction.distance, closeTo(1, 1e-12));
        final pose = [
          sample.position.dx,
          sample.position.dy,
          eye,
          sample.direction.dx,
          sample.direction.dy,
          range,
          _cone
        ];
        for (final value in pose) {
          expect(value.isFinite, isTrue);
          binary.setFloat64(cursor, value, Endian.little);
          cursor += 8;
        }
        minimumRange = math.min(minimumRange, range);
        maximumRange = math.max(maximumRange, range);
        final previous = previousPositions[agent];
        if (previous != null) {
          final step = (sample.position - previous).distance;
          expect(step, lessThanOrEqualTo(_speed / rate + 1e-10));
          maxFrameMovement = math.max(maxFrameMovement, step);
          if ((floor - previousHeights[agent]!).abs() > 1e-7) floorChanges++;
        }
        previousPositions[agent] = sample.position;
        previousHeights[agent] = floor;
        poses.add(pose);
        floors.add(floor);
        svgPositions.add(_xy(nativeToSvg.apply(sample.position)));
        canvasPositions.add(_xy(nativeToCanvas.apply(sample.position)));
      }
      frameRows.add({
        'frame': frame,
        'timeSeconds': frame / rate,
        'poses': poses,
        'floorHeightsCm': floors,
        'positionsSvg': svgPositions,
        'positionsCanvas': canvasPositions
      });
    }
    final binaryFile = File('${output.path}/walking-${rate}hz.f64.bin');
    await binaryFile.writeAsBytes(binary.buffer.asUint8List());
    final jsonFile = File('${output.path}/walking-${rate}hz.json');
    final doc = {
      'format': 'icarus-native-walking-fixtures-v1',
      'map': name,
      'simulatedHz': rate,
      'frameCount': _frames,
      'agentCount': _agents,
      'horizontalMetersPerSecond': _speed,
      'observerHeightCm': 175,
      'rangeCanvasUnits': _rangeCanvas,
      'coneDegrees': 103,
      'queryColumns': ['x', 'y', 'z', 'dx', 'dy', 'range', 'cone'],
      'queryUnits': [
        'metres',
        'metres',
        'metres',
        'unit vector',
        'unit vector',
        'metres',
        'radians'
      ],
      'queryFile': binaryFile.path,
      'querySha256': await _sha(binaryFile.path),
      'queryBinary': {
        'dtype': 'float64',
        'byteOrder': 'little',
        'headerBytes': 0,
        'shape': [_frames, _agents, 7],
        'order': 'frame-major then agent-major'
      },
      'projection': projection,
      'provenance': provenance,
      'routes': routeRows,
      'checks': {
        'everyFloorQuerySingleValued': true,
        'everyPoseInsidePackedHeightDomain': true,
        'distinctParentPolygons': walks.expand((w) => w.parents).toSet().length,
        'floorChangesAcrossMovingFrames': floorChanges,
        'maximumFrameDisplacementMeters': maxFrameMovement,
        'minimumRangeMeters': minimumRange,
        'maximumRangeMeters': maximumRange
      },
      'trajectory':
          'Constant horizontal speed on connected native center-portal-center corridors, reflected at endpoints. Facing follows the current segment.',
      'limits':
          'Static standing floor interpolation. Stair height transitions follow exported floor data; camera smoothing, pitch, crouch, and dynamic states are not simulated.',
      'frames': frameRows,
    };
    await jsonFile.writeAsString(jsonEncode(doc));
    files.add({
      'simulatedHz': rate,
      'jsonFile': jsonFile.path,
      'jsonSha256': await _sha(jsonFile.path),
      'queryFile': binaryFile.path,
      'querySha256': await _sha(binaryFile.path),
      'checks': doc['checks']
    });
  }
  await File('${output.path}/manifest.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert({
    'status': 'passed',
    'format': 'icarus-native-walking-fixtures-v1',
    'map': name,
    'files': files,
    'provenance': provenance,
    'projection': projection,
    'routes': routeRows,
  }));
  // ignore: avoid_print
  print('WALKING_FIXTURES_READY ${output.path} ${jsonEncode(files)}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final maps =
      (Platform.environment['ICARUS_FIXTURE_MAPS'] ?? 'split,fracture,lotus')
          .split(',');
  for (final name in maps) {
    test('generate native walking fixtures for $name', () => _generate(name),
        timeout: const Timeout(Duration(minutes: 10)));
  }
}
