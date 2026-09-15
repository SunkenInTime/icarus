import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

class _FileBundle extends CachingAssetBundle {
  _FileBundle(this.directory);
  final String directory;
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
      await File('$directory/${key.split('/').last}').readAsBytes());
}

class _Walk {
  _Walk(this.parents, this.points, this.distances, this.heights, this.layers);
  final List<int> parents;
  final List<Offset> points;
  final List<double> distances;
  final List<double> heights;
  final Set<int> layers;
  double get length => distances.last;
  double get heightSpan => heights.reduce(math.max) - heights.reduce(math.min);

  ({Offset origin, double facing}) at(double distance) {
    var along = distance % (2 * length);
    final reverse = along > length;
    if (reverse) along = 2 * length - along;
    var i = 1;
    while (i < distances.length - 1 && along > distances[i]) {
      i++;
    }
    final direction = points[i] - points[i - 1];
    final fraction =
        (along - distances[i - 1]) / (distances[i] - distances[i - 1]);
    return (
      origin: points[i - 1] + direction * fraction,
      facing: math.atan2(direction.dy, direction.dx) + (reverse ? math.pi : 0)
    );
  }
}

List<_Walk> _walks(VisionGeometryMap geometry) {
  final navigation = geometry.navigationGeometry!;
  final world = geometry.worldData!;
  final projection = world.projection!;
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
    // Polygon centers and the shared portal midpoint form a corridor wholly
    // inside two convex, player-walkable native polygons.
    final points = [
      centers[portal.from],
      (portal.a + portal.b) / 2,
      centers[portal.to]
    ];
    final distances = <double>[0];
    for (var i = 1; i < points.length; i++) {
      distances.add(distances.last +
          projection.vectorToMeters(points[i] - points[i - 1]).distance);
    }
    if (distances[1] < .01 ||
        distances[2] - distances[1] < .01 ||
        distances.last < 1) continue;
    final heights = <double>[];
    final layers = <int>{};
    final walk =
        _Walk([portal.from, portal.to], points, distances, heights, layers);
    var admitted = true;
    for (var i = 0; i <= (walk.length / .045).ceil(); i++) {
      final sample = walk.at(math.min(i * .045, walk.length));
      final floors = navigation.floorHeightsAt(sample.origin);
      // Keep this benchmark about movement across slopes and stairs, without
      // introducing a stacked-floor selection ambiguity at the same XY.
      if (floors.length != 1) {
        admitted = false;
        break;
      }
      final eye = floors.single + geometry.observerHeight;
      heights.add(eye);
      layers.add(world.nearestLayer(eye));
    }
    if (admitted && layers.length >= 3 && walk.heightSpan >= 10)
      candidates.add(walk);
  }
  candidates.sort((a, b) {
    final layerOrder = b.layers.length.compareTo(a.layers.length);
    return layerOrder != 0
        ? layerOrder
        : a.parents.first.compareTo(b.parents.first);
  });
  final selected = <_Walk>[];
  for (final candidate in candidates) {
    if (selected.any((other) => other.parents.any(candidate.parents.contains)))
      continue;
    selected.add(candidate);
    if (selected.length == 10) return selected;
  }
  throw StateError(
      'Only ${selected.length} independent native stair/slope corridors found.');
}

Map<String, dynamic> _summary(List<int> values) {
  final sorted = values.toList()..sort();
  int percentile(double p) => sorted[((sorted.length - 1) * p).round()];
  return {
    'minMicros': sorted.first,
    'medianMicros': percentile(.5),
    'p95Micros': percentile(.95),
    'p99Micros': percentile(.99),
    'maxMicros': sorted.last
  };
}

/// Same environment as profile_world_runtime.dart, without requiring ray JSON.
/// Run as a dedicated Windows release target; never opens the user library.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized().deferFirstFrame();
  final output = File(Platform.environment['ICARUS_AUDIT_OUTPUT']!);
  try {
    final mapName = Platform.environment['ICARUS_WORLD_MAP'] ?? 'abyss';
    final map = MapValue.values.byName(mapName);
    final directory = Platform.environment['ICARUS_WORLD_DIRECTORY']!;
    final frames =
        int.parse(Platform.environment['ICARUS_WALKING_FRAMES'] ?? '180');
    if (frames < 2 || frames > 1800)
      throw ArgumentError('Expected 2–1800 frames.');
    final watch = Stopwatch()..start();
    final baselineRss = ProcessInfo.currentRss;
    final geometry = await loadWorldViewConeGeometry(map,
        bundle: _FileBundle(directory), chunked: true);
    final loadMicros = watch.elapsedMicroseconds;
    final loadedRss = ProcessInfo.currentRss;
    watch.reset();
    final walks = _walks(geometry);
    final routeSelectionMicros = watch.elapsedMicroseconds;
    final seen = Expando<bool>();
    final passes = <Map<String, dynamic>>[];
    final occupiedLayers = <int>{};
    for (var pass = 0; pass < 2; pass++) {
      final records = <Map<String, dynamic>>[];
      final previousLayers = List<int?>.filled(10, null);
      for (var frame = 0; frame < frames; frame++) {
        var layerMicros = 0,
            polygonMicros = 0,
            newLayers = 0,
            changedFloors = 0;
        final frameWatch = Stopwatch()..start();
        final decodeBefore = geometry.worldData!.chunkDecodeProfile;
        final elevations = <double>[];
        final positions = <List<double>>[];
        for (var i = 0; i < walks.length; i++) {
          final sample = walks[i].at(frame * 5.4 / 60 + i * .071);
          watch.reset();
          final eye = geometry.inferredHeightAt(
              isAttack: true, position: sample.origin);
          if (eye == null)
            throw StateError('Walking position left navigation.');
          final index = geometry.worldData!.nearestLayer(eye);
          occupiedLayers.add(index);
          final layer = geometry.layerForPosition(
              isAttack: true, position: sample.origin);
          if (seen[layer] != true) {
            newLayers++;
            seen[layer] = true;
          }
          if (previousLayers[i] != index) changedFloors++;
          previousLayers[i] = index;
          layerMicros += watch.elapsedMicroseconds;
          watch.reset();
          final polygon = VisionPolygon.compute(
              layer: layer,
              origin: sample.origin,
              // The second pass repeats the route with a small aim change, so it
              // measures warm geometry rather than cached finished polygons.
              facingAngle: sample.facing + pass * .00001,
              coneAngle: 103 * math.pi / 180,
              range: 361);
          polygonMicros += watch.elapsedMicroseconds;
          if (polygon.length <= 1)
            throw StateError('Walking cone was rejected.');
          elevations.add(layer.elevation);
          positions.add([sample.origin.dx, sample.origin.dy]);
        }
        records.add({
          'frame': frame,
          'micros': frameWatch.elapsedMicroseconds,
          'layerMicros': layerMicros,
          'polygonMicros': polygonMicros,
          'newLayerObjects': newLayers,
          'decodedChunks':
              geometry.worldData!.chunkDecodeProfile.count - decodeBefore.count,
          'decodeMicros': geometry.worldData!.chunkDecodeProfile.micros -
              decodeBefore.micros,
          'gzipMicros': geometry.worldData!.chunkDecodeProfile.gzipMicros -
              decodeBefore.gzipMicros,
          'binaryMicros': geometry.worldData!.chunkDecodeProfile.binaryMicros -
              decodeBefore.binaryMicros,
          'validationMicros':
              geometry.worldData!.chunkDecodeProfile.validationMicros -
                  decodeBefore.validationMicros,
          'changedAgentLayers': changedFloors,
          'elevationsCm': elevations,
          'originsCanvas': positions,
          'residentBlocks': geometry.worldData!.residentChunks.blocks,
          'residentBlockBytes': geometry.worldData!.residentChunks.bytes
        });
      }
      passes.add({
        'name': pass == 0 ? 'first-traversal' : 'repeated-traversal',
        'frames': records,
        'total': _summary([for (final row in records) row['micros'] as int]),
        'layers':
            _summary([for (final row in records) row['layerMicros'] as int]),
        'decode':
            _summary([for (final row in records) row['decodeMicros'] as int]),
        'decodedChunks': records.fold<int>(
            0, (sum, row) => sum + (row['decodedChunks'] as int)),
        'polygons':
            _summary([for (final row in records) row['polygonMicros'] as int]),
        'newLayerObjects': records.fold<int>(
            0, (sum, row) => sum + (row['newLayerObjects'] as int))
      });
    }
    await output.parent.create(recursive: true);
    await output.writeAsString(jsonEncode({
      'status': 'complete',
      'mode': 'Flutter Windows release AOT; geometry CPU only, no painting',
      'map': mapName,
      'source': directory,
      'framesPerPass': frames,
      'simulatedFps': 60,
      'walkingMetersPerSecond': 5.4,
      'sourceManifestSha256': (await Sha256().hash(
              await File('$directory/${mapName}_visibility.manifest.json')
                  .readAsBytes()))
          .bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
      'loadMicros': loadMicros,
      'routeSelectionMicros': routeSelectionMicros,
      'defaultLayerPrewarmedByLoader': true,
      'chunkDecodeProfiling':
          const bool.fromEnvironment('ICARUS_PROFILE_WORLD_DECODING'),
      'occupiedLayerCount': occupiedLayers.length,
      'routes': [
        for (final walk in walks)
          {
            'parentPolygons': walk.parents,
            'pointsCanvas': [
              for (final point in walk.points) [point.dx, point.dy]
            ],
            'lengthMeters': walk.length,
            'eyeHeightSpanCm': walk.heightSpan,
            'sampledLayerCount': walk.layers.length
          }
      ],
      'passes': passes,
      'baselineRssBytes': baselineRss,
      'loadedRssBytes': loadedRss,
      'finalRssBytes': ProcessInfo.currentRss,
      'peakRssBytes': ProcessInfo.maxRss
    }));
    exit(0);
  } catch (error, stack) {
    await output.parent.create(recursive: true);
    await output.writeAsString(
        jsonEncode({'status': 'failed', 'error': '$error', 'stack': '$stack'}));
    exit(1);
  }
}
