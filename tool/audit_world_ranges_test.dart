import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

void main() {
  test('derive conservative physical range for every registered world', () {
    const folder = String.fromEnvironment('WORLD_DIRECTORY');
    const maxCanvasRange = 300 * 1000 / 831;
    final rows = <Map<String, dynamic>>[];
    for (final map in MapValue.values) {
      final path = File('$folder/${map.name}/geometry.json');
      if (!path.existsSync()) continue;
      final metadata =
          jsonDecode(path.readAsStringSync()) as Map<String, dynamic>;
      final transform = metadata['uiTransform'];
      final u = (transform['XMultiplier'] as num).abs().toDouble() * 100;
      final v = (transform['YMultiplier'] as num).abs().toDouble() * 100;
      final origin = VisionGeometryMap.projectUv(map, Offset.zero);
      final axisU = VisionGeometryMap.projectUv(map, Offset(u, 0)) - origin;
      final axisV = VisionGeometryMap.projectUv(map, Offset(0, v)) - origin;
      final aa = axisU.distanceSquared, bb = axisV.distanceSquared;
      final ab = axisU.dx * axisV.dx + axisU.dy * axisV.dy;
      final smallest = math
          .sqrt((aa + bb - math.sqrt((aa - bb) * (aa - bb) + 4 * ab * ab)) / 2);
      final maxMeters = maxCanvasRange / smallest;
      rows.add({
        'map': map.name,
        'maximumCanvasRange': maxCanvasRange,
        'canvasUnitsPerMeterU': axisU.distance,
        'canvasUnitsPerMeterV': axisV.distance,
        'maximumPhysicalMeters': maxMeters,
        'recommendedBakeMeters': maxMeters.ceil() + 1
      });
    }
    expect(rows.length, 13);
    final file = File('build/vision-audit/world-maximum-ranges.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(rows));
    // ignore: avoid_print
    print(jsonEncode(rows));
  });
}
