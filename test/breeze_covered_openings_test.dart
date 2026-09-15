import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

import 'breeze_gameplay_sightlines_test.dart'
    show breezeData, breezePoint, floorAt, visible;

void main() {
  for (final side in ['attack', 'defense']) {
    test('Breeze $side courtyard walk stays below both ceiling slabs', () {
      final model = SvgHeightVisibility.fromJson(breezeData(side));
      // Source volume 391 is the interior floor. Volumes 387 and 388 form
      // adjacent overhead slabs, including the seam crossed by this walk.
      for (var x = 40.0; x <= 58; x += .5) {
        for (var y = 299.0; y <= 320; y += .5) {
          final origin = breezePoint(side, x, y);
          expect(floorAt(model, origin), closeTo(4, .02),
              reason: 'Interior floor at $side $origin');
        }
      }
    });

    test('Breeze $side courtyard window has its full usable width', () {
      final model = SvgHeightVisibility.fromJson(breezeData(side));
      // Independent source sections through the frame have a sill at 5.10 m
      // and header at 7.90 m. A standing eye on the 4 m floor is between them.
      for (var x = 40.0; x <= 58; x += .5) {
        for (var y = 299.0; y <= 319; y += 2) {
          final origin = breezePoint(side, x, y);
          expect(visible(model, origin, breezePoint(side, x, 290)), isTrue,
              reason: 'Full courtyard opening from $side $origin');
        }
      }
      expect(
          visible(model, breezePoint(side, 48.5, 314.5),
              breezePoint(side, 37, 293.1)),
          isFalse,
          reason: 'Keep the source-measured solid end jamb.');
      expect(
          visible(model, breezePoint(side, 48.5, 314.5),
              breezePoint(side, 60.2, 293.1)),
          isFalse,
          reason: 'Keep the solid right jamb as well.');
    });

    test('Breeze $side nest floor and window stay continuous while moving', () {
      final model = SvgHeightVisibility.fromJson(breezeData(side));
      // Volumes 288 and 657 retain the 9 m room floor. The complete facade
      // sections have a 9.03 m sill and a 14.40 m header, not a solid roof band.
      for (var x = 187.0; x <= 201; x += .5) {
        for (var y = 110.0; y <= 124; y += 1) {
          final origin = breezePoint(side, x, y);
          expect(floorAt(model, origin), closeTo(9, .02));
          expect(visible(model, origin, breezePoint(side, x, 140)), isTrue,
              reason: 'Full nest opening from $side $origin');
        }
      }
      expect(
          visible(model, breezePoint(side, 193, 115),
              breezePoint(side, 183.6, 126.5)),
          isFalse,
          reason: 'Keep the solid left jamb beside the opening.');
      expect(
          visible(model, breezePoint(side, 193, 115),
              breezePoint(side, 203.6, 126.5)),
          isFalse,
          reason: 'Keep the solid right jamb beside the opening.');
    });

    test('Breeze $side nest boxes retain meaningful low cover', () {
      final model = SvgHeightVisibility.fromJson(breezeData(side));
      expect(floorAt(model, breezePoint(side, 193, 129)), closeTo(7.0017, .02));
      expect(floorAt(model, breezePoint(side, 199, 131)), closeTo(7.9876, .02));
      expect(
          visible(
              model, breezePoint(side, 193, 136), breezePoint(side, 199, 131)),
          isFalse,
          reason: 'The taller crate still blocks from the 6 m outside floor.');
      expect(
          visible(
              model, breezePoint(side, 193, 115), breezePoint(side, 199, 140)),
          isTrue,
          reason: 'The same crate is below the upper room eye.');
    });
  }
}
