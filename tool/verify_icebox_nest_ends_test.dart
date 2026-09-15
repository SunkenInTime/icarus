import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('both Nest ends preserve source openings and solid bases', () {
    final root = Platform.environment['ICARUS_HEIGHT_REVIEW']!;
    final rows = <Map<String, dynamic>>[];
    final cones = <Map<String, dynamic>>[];
    for (final side in ['attack', 'defense']) {
      SvgHeightVisibility load(String prefix) =>
          SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(gzip.decode(
              File('$root/icebox/$prefix-$side.json.gz').readAsBytesSync()))));
      final before = load('before'), current = load('candidate');
      final native = load('candidate');
      expect(
          native.enableNativeAcceleration(
              libraryPath: Platform.environment['ICARUS_SVG_NATIVE_LIBRARY']!),
          isTrue);
      Offset point(double x, double y) =>
          side == 'attack' ? Offset(x, y) : Offset(387.459 - x, 473 - y);
      final rotation = side == 'attack' ? 0.0 : math.pi;
      for (final sample in [
        (
          'saved-right-end',
          340.6530375033617,
          150.9722980260849,
          -.16361666325461216,
          30.0,
          false
        ),
        ('defender-left-end', 333.0, 148.0, math.pi, 23.0, false),
        ('defender-right-end', 333.0, 148.0, 0.0, 23.0, false),
        ('attacker-left-end', 335.0, 239.0, math.pi, 23.0, false),
        ('attacker-right-end', 335.0, 239.0, 0.0, 23.0, true),
      ]) {
        final origin = point(sample.$2, sample.$3);
        final direction = sample.$4 + rotation;
        final hit = current.castRay(
            origin: origin,
            directionRadians: direction,
            range: sample.$5,
            absoluteEyeElevationMeters: 7.45);
        expect(hit != null, sample.$6,
            reason: '$side ${sample.$1}: ${hit?.wallId} at ${hit?.distance}');
        expect(
            current.castRay(
                origin: origin,
                directionRadians: direction,
                range: sample.$5,
                absoluteEyeElevationMeters: 2.75),
            isNotNull,
            reason: '$side ${sample.$1} solid lower base');
        for (final eye in [7.45, 2.75]) {
          final oldCone = before.cone(
              origin: origin,
              directionRadians: direction,
              range: 56,
              apertureRadians: math.pi / 2,
              absoluteEyeElevationMeters: eye);
          final newCone = native.cone(
              origin: origin,
              directionRadians: direction,
              range: 56,
              apertureRadians: math.pi / 2,
              absoluteEyeElevationMeters: eye);
          List<List<double>> xy(List<Offset> points) => [
                for (final p in points) [p.dx, p.dy]
              ];
          final row = <String, dynamic>{
            'id': '${sample.$1}-$side-$eye',
            'map': 'icebox',
            'side': side,
            'originSvg': [origin.dx, origin.dy],
            'centerSvg': [origin.dx, origin.dy],
            'widthSvg': 100,
            'range': 56,
            'rangeSvg': 56,
            'markOrigin': true,
            'before': xy(oldCone.polygon),
            'current': xy(newCone.polygon),
          };
          rows.add(row);
          cones.add({
            ...row,
            'polygonSvg': xy(newCone.polygon),
            'activeWallIds': [
              for (final w in current.walls)
                if (w.blocks(eye)) w.id
            ]
          });
        }
      }
      final saved = point(340.6530375033617, 150.9722980260849);
      final support = current.automaticSupportAt(saved);
      expect(support?.id, 'icebox-a-stacked-interior-floor');
      expect(
          current
              .cone(
                  origin: saved,
                  directionRadians: rotation - .16361666325461216,
                  range: 56,
                  apertureRadians: math.pi / 2,
                  supportId: support?.id)
              .eyeElevationMeters,
          closeTo(7.45, .002));
      native.closeNativeAcceleration();
    }
    final output = Directory('$root/nest-regression')
      ..createSync(recursive: true);
    File('${output.path}/raster-cases.json')
        .writeAsStringSync(jsonEncode(rows));
    File('${output.path}/cones.jsonl')
        .writeAsStringSync('${cones.map(jsonEncode).join('\n')}\n');
  });
}
