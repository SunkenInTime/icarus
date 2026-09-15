import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'icebox_regional_standing_test.dart' as regional;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bundled =
      Platform.environment['ICARUS_VERIFY_BUNDLED_GAMEPLAY'] == 'true';
  final candidate =
      bundled ? null : Platform.environment['ICARUS_REGIONAL_CANDIDATE'];
  regional.runRegionalStandingTests(
      fixturePath: 'test/fixtures/split_regional_standing.json.gz',
      outputPath: 'work/split-regional-release-gate',
      candidatePath: candidate);
  final fixture = jsonDecode(
      File('test/fixtures/split_source_app_cases.json').readAsStringSync());
  for (final side in ['attack', 'defense']) {
    test(
        'Split $side source defaults, explicit roofs, crane and panels survive',
        () {
      final asset = File(candidate == null
          ? 'assets/maps/split_svg_height_$side.json.gz'
          : '$candidate/candidate-$side.json.gz');
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(utf8.decode(gzip.decode(asset.readAsBytesSync()))));
      expect(
          jsonDecode(
              utf8.decode(gzip.decode(asset.readAsBytesSync())))['version'],
          3);
      for (final row in fixture['cases']) {
        final xy = row['svg'][side];
        final point =
            Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
        final expected = (row['expectedFloorMeters'] as num).toDouble();
        expect(model.receiverContains(point), isTrue, reason: row['id']);
        final selected = model.standingSupportAt(point);
        final actual = selected?.surfaceElevationAt(point) ??
            model.ground?.heightAt(point);
        expect(actual, closeTo(expected, .02), reason: row['id']);
        if (row['savedReferenceEyeMeters'] != null) {
          final eye = (row['savedReferenceEyeMeters'] as num).toDouble();
          final saved =
              model.standingSupportAt(point, savedEyeElevationCm: eye * 100);
          final savedFloor =
              saved?.surfaceElevationAt(point) ?? model.ground?.heightAt(point);
          expect(savedFloor, closeTo(eye - 1.75, .02),
              reason: '${row['id']} explicit saved level');
          if (row['savedReferenceRole'] != null) {
            expect(saved, isNotNull,
                reason: 'Reviewed physical roof remains selectable');
            expect(saved!.automaticStandingAllowed, isFalse);
          }
        }
      }
    });
  }
}
