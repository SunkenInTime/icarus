import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/fracture_covered_interiors_2026_09_13.json')
          .readAsStringSync());
  for (final side in ['attack', 'defense']) {
    final candidate =
        const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
            ? null
            : Platform.environment['ICARUS_FRACTURE_CANDIDATE'];
    final path = candidate == null
        ? 'assets/maps/fracture_svg_height_$side.json.gz'
        : '$candidate/candidate-$side.json.gz';
    final model = SvgHeightVisibility.fromJson(
        jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));

    test('Fracture $side excludes every reviewed ceiling and rooftop alias',
        () {
      final denied = (fixture['excludedSupportIds'] as List).toSet();
      expect(model.supports.where((s) => denied.contains(s.id)), isEmpty);
    });

    test('Fracture $side places agents on the measured covered interior', () {
      for (final row in fixture['cases']) {
        final xy = row['svg'][side];
        final point =
            Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
        final support = model.automaticSupportAt(point);
        final floor =
            support?.surfaceElevationAt(point) ?? model.ground!.heightAt(point);
        expect(floor, closeTo(row['expectedFloorMeters'], .02),
            reason: row['id']);
      }
    });
  }
}
