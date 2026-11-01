import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PlacedUtility placedFrom(VisionConeToolData tool) => PlacedUtility(
        type: tool.type,
        position: const Offset(10, 20),
        id: 'cone',
        angle: tool.angle,
      )..length = tool.length;

  test('survives the JSON old builds write back', () {
    final saved = placedFrom(VisionConeToolData.fullCircle()).toJson();

    // The type every shipped build can read: a new one would make them
    // refuse the whole strategy.
    expect(saved['type'], 'viewCone180');
    final loaded = PlacedUtility.fromJson(saved);
    expect(loaded.viewCone.angle, 360);
    expect(
        loaded.viewCone.getAnchorPoint(),
        UtilityData.getViewConePreset(UtilityType.viewCone180)
            .getAnchorPoint());
    expect(clonedAngle(loaded), 360);
  });

  test('every preset still draws its own angle', () {
    for (final (type, degrees) in [
      (UtilityType.viewCone180, 103.0),
      (UtilityType.viewCone90, 60.0),
      (UtilityType.viewCone40, 20.0),
    ]) {
      final loaded = PlacedUtility.fromJson(
          placedFrom(VisionConeToolData.fromType(type)).toJson());
      expect(loaded.viewCone.angle, degrees);
      expect(loaded.isFullCircleCone, isFalse);
    }
    // Written before cones saved an angle.
    expect(
      PlacedUtility(
        type: UtilityType.viewCone180,
        position: Offset.zero,
        id: 'old',
      ).viewCone.angle,
      103,
    );
  });

  test('its aperture is one the cone query accepts', () {
    // The widget turns degrees into radians; a rounding up past two pi
    // would make the query refuse the cone.
    final aperture = ViewConeUtility.fullCircleDegrees * math.pi / 180;
    expect(aperture <= math.pi * 2, isTrue);
    expect(aperture >= 2 * math.pi, isTrue);

    final cone = SvgHeightVisibility.fromJson(_openRoom).horizontalCone(
      origin: const Offset(50, 50),
      directionRadians: 1,
      range: 20,
      apertureRadians: aperture,
    );
    // Reaches its range in every quarter, not a wedge of them.
    final around = {
      for (final point in cone.polygon)
        if ((point - const Offset(50, 50)).distance > 19)
          ((point - const Offset(50, 50)).direction / (math.pi / 2)).floor(),
    };
    expect(around, hasLength(4));
  });

  test('a preview with no map paints below its apex', () async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    ViewConePainter(angle: 360, length: 50)
        .paint(canvas, const ui.Size(100, 100));
    final picture = recorder.endRecording();
    final image = await picture.toImage(100, 100);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int alphaAt(int x, int y) => bytes.getUint8((y * 100 + x) * 4 + 3);
    expect(alphaAt(50, 25), greaterThan(0));
    expect(alphaAt(50, 75), greaterThan(0));
    expect(alphaAt(25, 50), greaterThan(0));
    expect(alphaAt(75, 50), greaterThan(0));
    image.dispose();
    picture.dispose();
  });
}

double clonedAngle(PlacedUtility utility) =>
    utility.deepCopy<PlacedUtility>().copyWith(id: 'copy').viewCone.angle;

const _openRoom = <String, dynamic>{
  'version': 1,
  'coordinateSpace': 'svg',
  'verticalSpace': 'meters-above-local-floor',
  'walls': [
    {
      'id': 'pillar',
      'rings': [
        [70.0, 45.0, 75.0, 45.0, 75.0, 55.0, 70.0, 55.0],
      ],
      'bands': [
        [0, null],
      ],
      'unknownHeight': false,
      'fillRule': 'nonzero',
    },
  ],
  'supports': <Object>[],
  'receiver': <Object>[],
  'cellSizeSvg': 4,
};
