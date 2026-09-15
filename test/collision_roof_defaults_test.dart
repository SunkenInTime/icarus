import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/collision_roof_defaults.json').readAsStringSync());
  for (final map in ['abyss', 'corrode', 'summit']) {
    for (final side in ['attack', 'defense']) {
      test(
          '$map $side defaults to covered interior and retains every saved roof',
          () {
        final root =
            const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
                ? null
                : Platform.environment['ICARUS_COLLISION_ROOF_MODELS'];
        final path = root == null
            ? 'assets/maps/${map}_svg_height_$side.json.gz'
            : '$root/$map/candidate-$side.json.gz';
        final model = SvgHeightVisibility.fromJson(
            jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
        for (final row in fixture['cases']) {
          if (row['map'] != map) continue;
          final xy = row['svg'][side];
          final point =
              Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
          expect(model.receiverContains(point), isTrue, reason: row['id']);
          final automatic = model.automaticSupportAt(point);
          final floor = automatic?.surfaceElevationAt(point) ??
              model.ground!.heightAt(point);
          expect(floor, closeTo(row['expectedFloorMeters'] as num, .02),
              reason:
                  '${row['id']} uses source floor ${row['lowerSourceDomain']}');
          final roof =
              model.supports.singleWhere((s) => s.id == row['upperSupportId']);
          expect(roof.contains(point), isTrue);
          expect(roof.automaticStandingAllowed, isFalse);
          expect(roof.surfaceElevationAt(point),
              closeTo(row['upperFloorMeters'] as num, .02));
          final saved = model.standingSupportAt(point,
              savedEyeElevationCm:
                  ((row['upperFloorMeters'] as num) + 1.75) * 100);
          expect(saved, isNotNull,
              reason: 'The physical upper level remains selectable');
          expect(saved!.surfaceElevationAt(point),
              closeTo(row['upperFloorMeters'] as num, .02));
        }
      });
    }
  }
}
