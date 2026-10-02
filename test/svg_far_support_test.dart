import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// No bundled surface 10 m or more above the ground beneath it is a default
/// standing level (Dara, 2026-10-02). Split's crane arm stood a dropped agent
/// 30 m above Mid, and Lotus's B Main boundary top 14 m above the floor; each
/// cone saw across half the map. Such a surface stays selectable by hand.
/// No real level sits between 8.2 m and 10.4 m above its ground in any map,
/// and no replay put a player above 13.6 m on Split, so the line is clear.
const _farMeters = 10.0;

void main() {
  test('no automatic standing surface floats far above its ground', () {
    final far = <String>[];
    for (final file in Directory('assets/maps').listSync()) {
      if (!file.path.endsWith('_svg_height_attack.json.gz') &&
          !file.path.endsWith('_svg_height_defense.json.gz')) {
        continue;
      }
      final model = SvgHeightVisibility.fromJson(
        jsonDecode(utf8.decode(gzip.decode(File(file.path).readAsBytesSync())))
            as Map<String, dynamic>,
      );
      final ground = model.ground;
      if (ground == null) continue;
      for (final support in model.supports) {
        if (!support.automaticStandingAllowed) continue;
        double nearestAbove(Iterable<Offset> points) {
          var nearest = double.infinity;
          for (final point in points) {
            final floor = ground.heightAt(point);
            final surface = support.surfaceElevationAt(point);
            if (floor == null || surface == null) continue;
            if (surface - floor < nearest) nearest = surface - floor;
          }
          return nearest;
        }

        // Far everywhere: far above the ground at every corner, and at every
        // point of a one-unit grid inside, where the ground may rise.
        var nearest = nearestAbove(support.rings.expand((ring) => ring));
        if (nearest < _farMeters) continue;
        final bounds = support.bounds;
        final inside = nearestAbove([
          for (var y = bounds.top.ceilToDouble(); y <= bounds.bottom; y++)
            for (var x = bounds.left.ceilToDouble(); x <= bounds.right; x++)
              if (support.contains(Offset(x, y))) Offset(x, y),
        ]);
        if (inside < nearest) nearest = inside;
        if (nearest >= _farMeters && nearest.isFinite) {
          far.add('${file.uri.pathSegments.last}: ${support.id} '
              '${nearest.toStringAsFixed(1)} m above the ground');
        }
      }
    }
    expect(far, isEmpty);
  });
}
