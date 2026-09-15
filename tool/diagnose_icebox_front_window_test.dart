import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('classify all measured Nest target rays', () {
    const folder = 'work/all-map-vision-followup-2026-09-14/icebox-front-window';
    final fixtures = jsonDecode(File('$folder/target-rays.json').readAsStringSync())['rays'] as List;
    final results = <Map<String, dynamic>>[];
    for (final side in ['attack', 'defense']) {
      final data = jsonDecode(utf8.decode(gzip.decode(File('$folder/candidate/candidate-$side.json.gz').readAsBytesSync())));
      final model = SvgHeightVisibility.fromJson(data);
      ui.Offset point(List p) {
        final v = ui.Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
        return side == 'attack' ? v : const ui.Offset(387.459, 473) - v;
      }
      for (var i = 0; i < fixtures.length; i++) {
        final row = fixtures[i];
        final origin = point(row['start']);
        final target = point(row['target']);
        final support = model.automaticSupportAt(origin);
        final delta = target-origin;
        try {
        final cone = model.cone(origin: origin, directionRadians: math.atan2(delta.dy, delta.dx), range: 60, apertureRadians: math.pi/3, supportId: support?.id);
        final visible = cone.visibilityPath ?? (ui.Path()..addPolygon(cone.polygon,true));
        results.add({'side': side,'index':i,'originSupport':support?.id,'eye':cone.eyeElevationMeters,'sourceClear':row['clear'],'runtimeClear':visible.contains(target),'horizontalClear':(ui.Path()..addPolygon(cone.polygon,true)).contains(target)});
        } catch(e) {results.add({'side':side,'index':i,'error':e.toString()});}
      }
    }
    File('$folder/runtime-rays.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(results));
    print('mismatches: ${results.where((r)=>r['sourceClear']!=r['runtimeClear']).toList()}');
  });
}
