import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('compare fourth screenshot cone headings without editing walls', () {
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(
        gzip.decode(File('assets/maps/fracture_svg_height_attack.json.gz')
            .readAsBytesSync()))));
    const origin = Offset(292.74060213018015, 309.49398476176566);
    final support = model.automaticSupportAt(origin);
    final rows = <Map<String, dynamic>>[];
    for (var degree = -115; degree <= -20; degree++) {
      final cone = model.cone(
          origin: origin,
          directionRadians: degree * math.pi / 180,
          apertureRadians: math.pi / 3,
          range: 120,
          supportId: support?.id);
      rows.add({
        'degrees': degree,
        'eye': cone.eyeElevationMeters,
        'polygon': [
          for (final p in cone.polygon) [p.dx, p.dy]
        ]
      });
    }
    File('work/fracture-wall-review-2026-09-14/fourth-heading-polygons.json')
        .writeAsStringSync(jsonEncode(rows));
  });
}
