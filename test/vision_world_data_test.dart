import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_world_data.dart';

Map<String, dynamic> fixture() => {
      'version': 1,
      'spatialOrder': 'bvh-median-v1',
      'map': 'split',
      'coordinateScale': 1000,
      'observerHeightCm': 175,
      'defaultFloorElevationCm': 300,
      'vertices': [0, 0, 1000, 0, 1000, 1000],
      'edges': [0, 1, 1, 2],
      'layers': [
        {
          'elevationCm': 474,
          'edges': [0, 1]
        },
        {
          'elevationCm': 475,
          'edges': [1]
        },
        {
          'elevationCm': 476,
          'edges': [0]
        },
      ],
      'menuElevationsCm': [475],
    };

VisionWorldData decode(Map<String, dynamic> data) => VisionWorldData.fromJson(
      MapValue.split,
      data,
      projectUv: (uv) => uv * 1000,
    );

void main() {
  test('shared edges select exact height layers and mirror without resizing',
      () {
    final data = decode(fixture());
    expect(data.spatiallyOrdered, isTrue);
    expect(data.nearestLayer(474.49), 0);
    expect(data.nearestLayer(474.5), 0);
    expect(data.nearestLayer(474.51), 1);
    expect(data.nearestLayer(-100), 0);
    expect(data.nearestLayer(1000), 2);
    expect(data.menuElevations, [475]);
    final attack = data.segmentsForLayer(1, isAttack: true).single;
    final defense = data.segmentsForLayer(1, isAttack: false).single;
    expect(attack.start, const Offset(1000, 0));
    expect(attack.end, const Offset(1000, 1000));
    expect(defense.start, const Offset(1000 * (16 / 9) - 1000, 1000));
    expect(defense.end, const Offset(1000 * (16 / 9) - 1000, 0));
  });

  test('rejects corrupted headers, tables, and unordered elevations', () {
    final invalid = <Map<String, dynamic>>[
      {...fixture(), 'map': 'sunset'},
      {...fixture(), 'version': 2},
      {...fixture(), 'spatialOrder': 'unknown'},
      {...fixture(), 'coordinateScale': double.infinity},
      {...fixture(), 'observerHeightCm': double.nan},
      {
        ...fixture(),
        'menuElevationsCm': [480]
      },
      {
        ...fixture(),
        'menuElevationsCm': [475, 475]
      },
      {
        ...fixture(),
        'menuElevationsCm': [476, 475]
      },
      {
        ...fixture(),
        'vertices': [0, 0, 1]
      },
      {
        ...fixture(),
        'vertices': [0, 0, 1.2, 2]
      },
      {
        ...fixture(),
        'edges': [0, 4]
      },
      {
        ...fixture(),
        'edges': [1, 1]
      },
      {...fixture(), 'layers': []},
      {
        ...fixture(),
        'layers': [
          {
            'elevationCm': 475,
            'edges': [2]
          }
        ]
      },
      {
        ...fixture(),
        'layers': [
          {
            'elevationCm': 475,
            'edges': [0, 0]
          }
        ]
      },
      {
        ...fixture(),
        'layers': [
          {
            'elevationCm': 476,
            'edges': [0]
          },
          {
            'elevationCm': 475,
            'edges': [1]
          },
        ]
      },
    ];
    for (final data in invalid) {
      expect(() => decode(data), throwsFormatException);
    }
  });
}
