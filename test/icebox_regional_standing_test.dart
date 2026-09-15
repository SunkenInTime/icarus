import 'dart:convert';
import 'dart:io';

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bundled =
      Platform.environment['ICARUS_VERIFY_BUNDLED_GAMEPLAY'] == 'true';
  runRegionalStandingTests(
      fixturePath: Platform.environment['ICARUS_REGIONAL_FIXTURE'] ??
          'test/fixtures/icebox_regional_standing.json',
      outputPath: Platform.environment['ICARUS_REGIONAL_OUTPUT'] ??
          'work/icebox-acceptance',
      candidatePath:
          bundled ? null : Platform.environment['ICARUS_REGIONAL_CANDIDATE']);
}

void runRegionalStandingTests(
    {required String fixturePath,
    required String outputPath,
    String? candidatePath}) {
  Directory(outputPath).createSync(recursive: true);
  dynamic readFixture(File file) => jsonDecode(fixturePath.endsWith('.gz')
      ? utf8.decode(gzip.decode(file.readAsBytesSync()))
      : file.readAsStringSync());
  final mapName = (readFixture(File(fixturePath)) as Map)['map'] ?? 'icebox';
  File assetFor(String side) => File(candidatePath == null
      ? 'assets/maps/${mapName}_svg_height_$side.json.gz'
      : '$candidatePath/candidate-$side.json.gz');
  for (final side in ['attack', 'defense']) {
    test('$mapName $side source levels survive explicit saved selection',
        () async {
      final fixtureFile = File(fixturePath);
      final fixture = readFixture(fixtureFile);
      final asset = assetFor(side);
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(utf8.decode(gzip.decode(asset.readAsBytesSync()))));
      final rows = <Map<String, dynamic>>[];
      for (final row in fixture['defaultPlacements'] as List? ?? []) {
        final xy = row['svg'][side] as List;
        final point =
            Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
        final expected = (row['expectedFloorMeters'] as num).toDouble();
        final inside = model.receiverContains(point);
        final blocked = model.walls.any((w) =>
            w.contains(point) &&
            w.blocks(expected + model.defaultCameraHeightMeters));
        final selected = model.standingSupportAt(point,
            savedEyeElevationCm:
                (expected + model.defaultCameraHeightMeters) * 100);
        final actual = selected?.surfaceElevationAt(point) ??
            model.ground?.heightAt(point);
        rows.add({
          'id': row['id'],
          'expectedFloorMeters': expected,
          'actualFloorMeters': actual,
          'selectedSupport': selected?.id,
          'status': !inside
              ? 'outside-svg-floor'
              : blocked
                  ? 'inside-active-svg-wall'
                  : actual != null && (actual - expected).abs() <= .02
                      ? 'passed'
                      : 'wrong-saved-level',
        });
      }
      final failures =
          rows.where((r) => r['status'] == 'wrong-saved-level').toList();
      Future<String> hash(File file) async =>
          (await Sha256().hash(file.readAsBytesSync()))
              .bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
      File('$outputPath/regional-saved-levels-$side.json')
          .writeAsStringSync(jsonEncode({
        'status': failures.isEmpty ? 'passed' : 'wrong-saved-levels',
        'sourceFixtureSha256': await hash(fixtureFile),
        'assetSha256': await hash(asset),
        'rows': rows,
        'failures': failures,
      }));
      expect(failures, isEmpty, reason: jsonEncode(failures.take(10).toList()));
    });

    if (mapName == 'icebox')
      test('Icebox $side source ramp expectation detects inflated ground', () {
        final fixture = jsonDecode(File(fixturePath).readAsStringSync());
        final row = (fixture['cases'] as List)
            .firstWhere((r) => r['selection'] == 'automatic');
        final data = jsonDecode(
            utf8.decode(gzip.decode(assetFor(side).readAsBytesSync())));
        final vertices = data['ground']['vertices'] as List;
        for (var i = 2; i < vertices.length; i += 3) {
          vertices[i] = (vertices[i] as num) + .1;
        }
        final model = SvgHeightVisibility.fromJson(data);
        final xy = row['svg'][side] as List;
        final point =
            Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
        final actual =
            model.standingSupportAt(point)?.surfaceElevationAt(point) ??
                model.ground!.heightAt(point)!;
        expect((actual - (row['expectedFloorMeters'] as num)).abs(),
            greaterThan(.02));
      });

    test('$mapName $side regional source levels and ramp paths', () async {
      final fixtureFile = File(fixturePath);
      final fixture = readFixture(fixtureFile);
      final asset = assetFor(side);
      final model = SvgHeightVisibility.fromJson(
          jsonDecode(utf8.decode(gzip.decode(asset.readAsBytesSync()))));
      final rows = <Map<String, dynamic>>[];
      for (final row in fixture['cases'] as List) {
        final xy = row['svg'][side] as List;
        final p = Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
        final expected = (row['expectedFloorMeters'] as num).toDouble();
        final ground = model.ground?.heightAt(p);
        final levels = <double>[
          if (ground != null) ground,
          for (final support in model.supportsAt(p))
            if (support.automaticStandingAllowed &&
                support.surfaceElevationAt(p) != null)
              support.surfaceElevationAt(p)!,
        ];
        final inside = model.receiverContains(p);
        final blocked =
            model.walls.any((w) => w.contains(p) && w.blocks(expected + 1.75));
        final present = levels.any((z) => (z - expected).abs() <= .02);
        final chosen =
            model.standingSupportAt(p)?.surfaceElevationAt(p) ?? ground;
        final automatic = row['selection'] == 'automatic';
        final sourceLevels = (row['sourceLocalLevelsMeters'] as List?)
            ?.cast<num>()
            .map((z) => z.toDouble())
            .where((z) =>
                !model.walls.any((w) => w.contains(p) && w.blocks(z + 1.75)))
            .toList();
        final expectedDefault = sourceLevels == null ||
                sourceLevels.isEmpty ||
                row['defaultBoundaryAmbiguous'] == true
            ? null
            : sourceLevels.reduce((a, b) => a > b ? a : b);
        final correct = present &&
            (!automatic ||
                chosen != null && (chosen - expected).abs() <= .02) &&
            (expectedDefault == null ||
                chosen != null && (chosen - expectedDefault).abs() <= .02);
        rows.add({
          'id': row['id'],
          'domain': row['domain'],
          'expectedFloorMeters': expected,
          'levels': levels,
          'actualAutomaticFloorMeters': chosen,
          if (expectedDefault != null)
            'expectedAutomaticFloorMeters': expectedDefault,
          if (row['defaultBoundaryAmbiguous'] == true)
            'defaultScope':
                'source-boundary-rounding; level presence remains checked',
          'status': !inside
              ? 'outside-svg-floor'
              : blocked
                  ? 'inside-active-svg-wall'
                  : correct
                      ? 'passed'
                      : 'missing-level',
        });
      }
      Future<String> hash(File file) async =>
          (await Sha256().hash(file.readAsBytesSync()))
              .bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
      final failures =
          rows.where((r) => r['status'] == 'missing-level').toList();
      File('$outputPath/regional-runtime-$side.json')
          .writeAsStringSync(jsonEncode({
        'sourceFixtureSha256': await hash(fixtureFile),
        'assetSha256': await hash(asset),
        'status': failures.isEmpty ? 'passed' : 'missing-levels',
        'cases': rows.length,
        'failures': failures,
        'rows': rows,
      }));
      expect(failures.length, 0,
          reason: jsonEncode(failures.take(10).toList()));
    });
  }
}
