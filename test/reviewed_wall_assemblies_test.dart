import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/reviewed_wall_assemblies_2026_09_14.json')
          .readAsStringSync()) as Map<String, dynamic>;
  for (final entry in (fixture['maps'] as Map<String, dynamic>).entries) {
    for (final side in ['attack', 'defense']) {
      test('${entry.key} $side source-standing rays stop at complete walls',
          () {
        final root =
            const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
                ? null
                : Platform.environment['ICARUS_WALL_ASSEMBLY_MODELS'];
        final path = root == null
            ? 'assets/maps/${entry.key}_svg_height_$side.json.gz'
            : '$root/${entry.key}/candidate-$side.json.gz';
        final model = SvgHeightVisibility.fromJson(
            jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
        for (final row in entry.value as List) {
          Offset point(dynamic xy) =>
              Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
          final origin = point(row['originSvg'][side]);
          final target = point(row['targetSvg'][side]);
          final support = model.automaticSupportAt(origin);
          final floor = support?.surfaceElevationAt(origin) ??
              model.ground!.heightAt(origin);
          expect(floor, closeTo(row['expectedFloorMeters'] as num, .02),
              reason: row['id'] as String);
          final delta = target - origin;
          final hit = model.castRay(
              origin: origin,
              directionRadians: math.atan2(delta.dy, delta.dx),
              range: delta.distance,
              supportId: support?.id);
          expect(hit, isNotNull, reason: row['id'] as String);
          expect(hit!.distance, lessThan(delta.distance));
        }
      });
    }
  }
}
