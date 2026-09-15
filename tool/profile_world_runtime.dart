import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

/// Build as a release entry point, then supply ICARUS_WORLD_DIRECTORY,
/// ICARUS_REFERENCE_DIRECTORY, ICARUS_WORLD_MAP and ICARUS_AUDIT_OUTPUT.
/// No application widget tree or user library is opened.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized().deferFirstFrame();
  final output = File(Platform.environment['ICARUS_AUDIT_OUTPUT']!);
  try {
    final mapName = Platform.environment['ICARUS_WORLD_MAP'] ?? 'fracture';
    final map = MapValue.values.byName(mapName);
    final directory = Platform.environment['ICARUS_WORLD_DIRECTORY']!;
    final references = jsonDecode(await File(
            '${Platform.environment['ICARUS_REFERENCE_DIRECTORY']}/$mapName.json')
        .readAsString());
    final watch = Stopwatch()..start();
    final baselineRss = ProcessInfo.currentRss;
    final geometry = await loadWorldViewConeGeometry(map,
        bundle: _FileBundle(directory), chunked: true);
    final loadMicros = watch.elapsedMicroseconds;
    final loadedRss = ProcessInfo.currentRss;
    final candidates = <double, ({Offset origin, int segments})>{};
    final coldMicros = <int>[];
    for (final ray in references['rays'] as List) {
      if (!(ray['id'] as String).endsWith('-0')) continue;
      final uv = ray['startUv'] as List;
      final origin = VisionGeometryMap.projectUv(
          map, Offset((uv[0] as num).toDouble(), (uv[1] as num).toDouble()));
      final height =
          geometry.inferredHeightAt(isAttack: true, position: origin);
      if (height == null) continue;
      final elevation = geometry
          .worldData!.elevations[geometry.worldData!.nearestLayer(height)];
      if (candidates.containsKey(elevation)) continue;
      watch.reset();
      final layer = geometry.layerForPosition(isAttack: true, position: origin);
      coldMicros.add(watch.elapsedMicroseconds);
      candidates[elevation] = (origin: origin, segments: layer.segments.length);
    }
    final ranked = candidates.entries.toList()
      ..sort((a, b) => b.value.segments.compareTo(a.value.segments));
    final agents = ranked.take(10).toList();
    if (agents.length != 10)
      throw StateError('Ten distinct occupied floors required.');
    final previous = <int, VisionGeometryLayer>{};
    final frames = <Map<String, dynamic>>[];
    for (var frame = 0; frame < 10; frame++) {
      watch.reset();
      var rebuilt = 0;
      for (var i = 0; i < agents.length; i++) {
        final origin = agents[i].value.origin;
        final layer =
            geometry.layerForPosition(isAttack: true, position: origin);
        if (!identical(previous[i], layer)) rebuilt++;
        previous[i] = layer;
        final polygon = VisionPolygon.compute(
            layer: layer,
            origin: origin,
            facingAngle: i * .3,
            coneAngle: 103 * math.pi / 180,
            range: 361);
        if (polygon.length <= 1) throw StateError('Invalid benchmark origin.');
      }
      frames.add({
        'frame': frame,
        'micros': watch.elapsedMicroseconds,
        'rebuiltLayers': rebuilt
      });
      if (frame > 0 && rebuilt != 0)
        throw StateError('Active-floor cache thrashing.');
    }
    final movingFrames = <Map<String, dynamic>>[];
    for (var frame = 0; frame < 12; frame++) {
      watch.reset();
      final perCone = <int>[];
      for (var i = 0; i < agents.length; i++) {
        final origin = agents[i].value.origin;
        final layer =
            geometry.layerForPosition(isAttack: true, position: origin);
        final start = watch.elapsedMicroseconds;
        VisionPolygon.compute(
          layer: layer,
          origin: origin,
          facingAngle: i * .3 + (frame + 1) * .007,
          coneAngle: 103 * math.pi / 180,
          range: 361,
        );
        perCone.add(watch.elapsedMicroseconds - start);
      }
      movingFrames
          .add({'micros': watch.elapsedMicroseconds, 'perConeMicros': perCone});
    }
    await output.parent.create(recursive: true);
    await output.writeAsString(jsonEncode({
      'status': 'complete',
      'mode': 'Flutter Windows release AOT',
      'map': mapName,
      'source': directory,
      'loadMicros': loadMicros,
      'coldLayerMicros': coldMicros,
      'tenFloorFrames': frames,
      'tenRotatingConeFrames': movingFrames,
      'segmentsAcrossTenFloors':
          agents.fold<int>(0, (sum, e) => sum + e.value.segments),
      'residentBlocks': geometry.worldData!.residentChunks.blocks,
      'residentBlockBytes': geometry.worldData!.residentChunks.bytes,
      'baselineRssBytes': baselineRss,
      'loadedRssBytes': loadedRss,
      'finalRssBytes': ProcessInfo.currentRss,
    }));
    exit(0);
  } catch (error, stack) {
    await output.parent.create(recursive: true);
    await output.writeAsString(
        jsonEncode({'status': 'failed', 'error': '$error', 'stack': '$stack'}));
    exit(1);
  }
}
