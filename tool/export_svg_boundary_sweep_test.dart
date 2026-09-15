// Export actual native cone polygons for an independent GEOS boundary audit.
import 'dart:convert';
import 'dart:io';
import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  test('export production cones for boundary attribution', () async {
    final root = Platform.environment['ICARUS_BOUNDARY_AUDIT']!;
    final cases =
        (jsonDecode(File('$root/cases.json').readAsStringSync()) as List);
    final output = File('$root/cones.jsonl').openWrite();
    final models = <String, SvgHeightVisibility>{};
    var emitted = 0, skipped = 0;
    final skippedCases = <Map<String, dynamic>>[];
    final assetPaths = <String>{};
    for (final raw in cases) {
      final row = raw as Map<String, dynamic>;
      final key = '${row['map']}-${row['side']}';
      final model = models.putIfAbsent(key, () {
        final path =
            'assets/maps/${row['map']}_svg_height_${row['side']}.json.gz';
        assetPaths.add(path);
        final model = SvgHeightVisibility.fromJson(
            jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
        expect(
            model.enableNativeAcceleration(
                libraryPath:
                    Platform.environment['ICARUS_SVG_NATIVE_LIBRARY']!),
            isTrue);
        return model;
      });
      final xy = row['originSvg'] as List;
      final origin =
          Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
      if (!model.receiverContains(origin) ||
          model.ground!.heightAt(origin) == null) {
        skipped++;
        skippedCases.add(
            {'id': row['id'], 'reason': 'outside-svg-floor-or-ground-domain'});
        continue;
      }
      final support = row['automaticStanding'] == true
          ? model.standingSupportAt(origin)?.id
          : row['supportId'] as String?;
      if (support != null &&
          !model.supportsAt(origin).any((s) => s.id == support)) {
        skipped++;
        skippedCases
            .add({'id': row['id'], 'reason': 'selected-support-not-local'});
        continue;
      }
      final cone = model.cone(
          origin: origin,
          directionRadians: (row['directionRadians'] as num).toDouble(),
          range: 90,
          apertureRadians: 1.5707963267948966,
          supportId: support,
          absoluteEyeElevationMeters: row['sourceStandingLevel'] == true
              ? (row['sourceExpectedFloorMeters'] as num).toDouble() +
                  model.defaultCameraHeightMeters
              : null);
      if (cone.polygon.length < 3) {
        skipped++;
        final floor = (row['sourceExpectedFloorMeters'] as num?)?.toDouble();
        final blockers = floor == null
            ? <String>[]
            : [
                for (final wall in model.walls)
                  if (wall.contains(origin) &&
                      wall.blocks(floor + model.defaultCameraHeightMeters))
                    wall.id
              ];
        skippedCases.add({
          'id': row['id'],
          'reason': blockers.isNotEmpty
              ? 'source-eye-inside-active-svg-wall'
              : 'no-visible-cone',
          'sourceEyeMeters':
              floor == null ? null : floor + model.defaultCameraHeightMeters,
          'wallIds': blockers
        });
        continue;
      }
      output.writeln(jsonEncode({
        ...row,
        'rangeSvg': 90,
        'apertureRadians': 1.5707963267948966,
        'eyeElevationMeters': cone.eyeElevationMeters,
        'polygonSvg': [
          for (final p in cone.polygon) [p.dx, p.dy]
        ],
        'activeWallIds': [
          for (final w in model.walls)
            if (w.blocks(cone.eyeElevationMeters!)) w.id
        ]
      }));
      emitted++;
    }
    await output.close();
    for (final model in models.values) {
      model.closeNativeAcceleration();
    }
    Future<String> hash(String path) async =>
        (await Sha256().hash(File(path).readAsBytesSync()))
            .bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
    final hashes = {for (final path in assetPaths) path: await hash(path)};
    File('$root/export-summary.json').writeAsStringSync(jsonEncode({
      'emitted': emitted,
      'skippedOutsideFloorOrInsideWall': skipped,
      'skippedCases': skippedCases,
      'assetSha256': hashes,
      'casesSha256': await hash('$root/cases.json'),
      'conesSha256': await hash('$root/cones.jsonl'),
      'nativeSha256':
          await hash(Platform.environment['ICARUS_SVG_NATIVE_LIBRARY']!),
    }));
    expect(emitted, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
