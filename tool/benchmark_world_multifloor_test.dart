import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

class _WorldBundle extends CachingAssetBundle {
  _WorldBundle(this.directory);
  final String directory;
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(
      await File('$directory/${key.split('/').last}').readAsBytes());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ten occupied floor slices retain their geometry and stationary cones',
      () async {
    const directory = String.fromEnvironment('WORLD_DIRECTORY');
    const referenceDirectory = String.fromEnvironment('REFERENCE_DIRECTORY');
    const mapName =
        String.fromEnvironment('WORLD_MAP', defaultValue: 'fracture');
    const label =
        String.fromEnvironment('BENCHMARK_LABEL', defaultValue: 'current');
    const chunked = bool.fromEnvironment('WORLD_CHUNKED');
    final map = MapValue.values.byName(mapName);
    final geometry = await loadWorldViewConeGeometry(map,
        bundle: _WorldBundle(directory), binary: true, chunked: chunked);
    final reference = jsonDecode(
        await File('$referenceDirectory/$mapName.json').readAsString());
    final candidates = <double, ({Offset origin, int segments})>{};
    for (final ray in reference['rays'] as List) {
      if (!(ray['id'] as String).endsWith('-0')) continue;
      final uv = ray['startUv'] as List;
      final origin = VisionGeometryMap.projectUv(
          map, Offset((uv[0] as num).toDouble(), (uv[1] as num).toDouble()));
      final height =
          geometry.inferredHeightAt(isAttack: true, position: origin);
      if (height == null) continue;
      final index = geometry.worldData!.nearestLayer(height);
      final elevation = geometry.worldData!.elevations[index];
      if (candidates.containsKey(elevation)) continue;
      final layer = geometry.layerForPosition(isAttack: true, position: origin);
      candidates[elevation] = (origin: origin, segments: layer.segments.length);
    }
    final selected = candidates.entries.toList()
      ..sort((a, b) => b.value.segments.compareTo(a.value.segments));
    final agents = selected.take(10).toList();
    expect(agents.length, 10);
    final previousLayers = <int, VisionGeometryLayer>{};
    final frames = <Map<String, dynamic>>[];
    final watch = Stopwatch();
    for (var frame = 0; frame < 8; frame++) {
      watch
        ..reset()
        ..start();
      var rebuiltLayers = 0;
      for (var i = 0; i < agents.length; i++) {
        final origin = agents[i].value.origin;
        final layer =
            geometry.layerForPosition(isAttack: true, position: origin);
        if (!identical(previousLayers[i], layer)) rebuiltLayers++;
        previousLayers[i] = layer;
        final polygon = VisionPolygon.compute(
            layer: layer,
            origin: origin,
            facingAngle: i * .3,
            coneAngle: 103 * math.pi / 180,
            range: 361);
        expect(polygon.length, greaterThan(1));
      }
      frames.add({
        'frame': frame,
        'micros': watch.elapsedMicroseconds,
        'rebuiltLayers': rebuiltLayers
      });
    }
    final result = {
      'map': mapName,
      'label': label,
      'selection':
          'Ten largest distinct automatic slices among 512 held-out origins',
      'layers': [
        for (final entry in agents)
          {'elevationCm': entry.key, 'segments': entry.value.segments}
      ],
      'totalSegments':
          agents.fold<int>(0, (sum, entry) => sum + entry.value.segments),
      'frames': frames,
      'processRssBytes': ProcessInfo.currentRss,
      'profile':
          'Flutter test JIT; concurrent offline jobs may affect absolute timings'
    };
    final output = File('build/vision-audit/$mapName-multifloor-$label.json');
    output.parent.createSync(recursive: true);
    output.writeAsStringSync(jsonEncode(result));
    // ignore: avoid_print
    print(jsonEncode(result));
    for (final frame in frames.skip(1)) {
      expect(frame['rebuiltLayers'], 0,
          reason: 'Ten occupied floor slices must remain cached.');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
