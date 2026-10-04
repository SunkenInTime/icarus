import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Path;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// The bundled walls are Icarus's drawn walls carrying the heights of
/// VALORANT's own minimap vision lines (see docs/vision-model.md, "Blocking
/// from VALORANT's minimap lines").
Map<String, dynamic> _json(String name, String side) => jsonDecode(utf8.decode(
    gzip.decode(File('assets/maps/${name}_svg_height_$side.json.gz')
        .readAsBytesSync()))) as Map<String, dynamic>;

SvgHeightVisibility _model(String name, String side) =>
    SvgHeightVisibility.fromJson(_json(name, side));

/// Whether an agent standing at [from] on its default level sees [target].
bool _sees(SvgHeightVisibility model, Offset from, Offset target) {
  final support = model.automaticSupportAt(from);
  final toward = target - from;
  final cone = model.cone(
    origin: from,
    directionRadians: math.atan2(toward.dy, toward.dx),
    range: 120,
    apertureRadians: math.pi / 6,
    supportId: support?.id,
  );
  final visible =
      cone.visibilityPath ?? (Path()..addPolygon(cone.polygon, true));
  return visible.contains(target);
}

const _maps = [
  'abyss', 'ascent', 'bind', 'breeze', 'corrode', 'fracture', 'haven', //
  'icebox', 'lotus', 'pearl', 'split', 'summit', 'sunset',
];

void main() {
  test('every wall blocks a run of Riot layers and nothing else', () {
    // A wall in layer k blocks a viewer whose capsule centre (floor + 0.98 m)
    // stands in [th_k, th_k+1); stored as eye heights (capsule + 0.77 m)
    // over a floor 100 m down. Every band edge is one of those.
    for (final name in _maps) {
      for (final side in ['attack', 'defense']) {
        final json = _json(name, side);
        final layers = (json['riotVisionLayers'] as List).cast<num>();
        final edges = {for (final t in layers) (t + 0.77 + 100).toDouble()};
        for (final wall in (json['walls'] as List).cast<Map>()) {
          expect(wall['floorElevationMeters'], -100.0);
          for (final band in (wall['bands'] as List).cast<List>()) {
            for (final edge in band) {
              if (edge == null || edge == 0) continue;
              expect(edges.any((e) => ((edge as num) - e).abs() < 1e-3), isTrue,
                  reason: '$name $side ${wall['id']}: $edge is no layer edge');
            }
          }
        }
      }
    }
  });

  test('the Lotus defense platform wall stops a standing cone', () {
    // Dara's replay, round 2 at 0:11: Chamber on the 3 m platform looked
    // through this wall. Riot has no line along it; ours (an added line in
    // the vision-lines review data) blocks layers 1 to 3.
    final model = _model('lotus', 'defense');
    const platform = Offset(425, 325.4);
    expect(model.automaticSupportAt(platform)?.surfaceElevationAt(platform),
        closeTo(3.0, 0.05));
    expect(_sees(model, platform, const Offset(425, 346)), isFalse);
    expect(_sees(model, platform, const Offset(425, 335)), isTrue,
        reason: 'the platform in front of the wall stays lit');
  });

  test('Bind B container blocks a cone from the ground beside it', () {
    final model = _model('bind', 'attack');
    expect(
        _sees(model, const Offset(107.5, 158.5), const Offset(71.59, 147.35)),
        isFalse);
  });

  test('the Haven garage window stays open from the garage floor', () {
    // Dara, 2026-09-19: as a simplification the C Garage window is
    // see-through from the floor. VALORANT's minimap lines block it there.
    final model = _model('haven', 'attack');
    expect(
        _sees(model, const Offset(131.651, 246.013),
            const Offset(137.17, 202.36)),
        isTrue);
  },
      skip: 'Riot blocks the garage window from the garage floor, reversing '
          'the 2026-09-19 ruling: waiting on Dara');
}
