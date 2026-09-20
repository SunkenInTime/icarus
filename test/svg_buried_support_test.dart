import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// A measured floor far beneath an uncertified reference floor is not where
/// the player stands unless it meets the ground somewhere (a room under a
/// bridge) or the reference eye is walled in (a passage under a bridge).
/// Fracture's void mesh 58 m down covered a tenth of its floor before this.
void main() {
  Map<String, dynamic> support(String id, double surface,
          {List<double>? ring}) =>
      {
        'id': id,
        'rings': [
          ring ?? [0, 0, 10, 0, 10, 10, 0, 10]
        ],
        'heightAboveFloorMeters': surface,
        'floorElevationMeters': 0,
        'surfaceElevationMeters': surface,
        'automaticStandingAllowed': true,
      };

  Map<String, dynamic> data({
    required List<Map<String, dynamic>> supports,
    List<Map<String, dynamic>> walls = const [],
    List<num> vertices = const [-20, -20, 4, 50, -20, 4, 50, 50, 4, -20, 50, 4],
    List<int> triangles = const [0, 1, 2, 0, 2, 3],
  }) =>
      {
        'version': 3,
        'coordinateSpace': 'svg',
        'verticalSpace': 'meters-source-elevation',
        'walls': walls,
        'ground': {
          'vertices': vertices,
          'triangles': triangles,
          'standingTriangles': <int>[],
        },
        'supports': supports,
      };

  const point = Offset(5, 5);

  test('a floor far beneath a clear reference is not the default', () {
    final model =
        SvgHeightVisibility.fromJson(data(supports: [support('void', -58)]));
    expect(model.ground!.standingHeightAt(point), isNull);
    expect(model.standingSupportAt(point), isNull);
    expect(model.groundEyeElevationAt(point), 5.75);
  });

  test('a physical floor a little beneath the reference still wins', () {
    final model = SvgHeightVisibility.fromJson(
        data(supports: [support('lower-floor', 2)]));
    expect(model.standingSupportAt(point)?.id, 'lower-floor');
  });

  test('a room under a roof wins where its floor meets the ground outside', () {
    // Reference: roof at 6.5 over x < 10, ground at 2.5 beyond the doorway.
    final model = SvgHeightVisibility.fromJson(data(
      vertices: [
        0, 0, 6.5, 10, 0, 6.5, 10, 10, 6.5, 0, 10, 6.5, //
        10.0, 0, 2.5, 20, 0, 2.5, 20, 10, 2.5, 10.0, 10, 2.5,
      ],
      triangles: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7],
      supports: [support('room', 2.5)],
    ));
    expect(model.standingSupportAt(point)?.id, 'room');
  });

  test('a floor far beneath a walled-in reference eye still wins', () {
    final model = SvgHeightVisibility.fromJson(data(
      walls: [
        {
          'id': 'bridge',
          'rings': [
            [0, 0, 10, 0, 10, 10, 0, 10]
          ],
          'floorElevationMeters': 4,
          'bands': [
            [1, 3]
          ],
          'unknownHeight': false,
        }
      ],
      supports: [support('tunnel', -2)],
    ));
    expect(model.standingSupportAt(point)?.id, 'tunnel');
  });
}
