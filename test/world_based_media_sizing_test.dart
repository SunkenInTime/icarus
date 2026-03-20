import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/text_provider.dart';

void main() {
  test('coordinate size helpers round-trip world units', () {
    final coordinateSystem =
        CoordinateSystem(playAreaSize: const Size(1600, 900));

    expect(
      coordinateSystem.screenWidthToWorld(
        coordinateSystem.worldWidthToScreen(185),
      ),
      closeTo(185, 0.0001),
    );
    expect(
      coordinateSystem.screenHeightToWorld(
        coordinateSystem.worldHeightToScreen(12),
      ),
      closeTo(12, 0.0001),
    );

    coordinateSystem.setIsScreenshot(true);

    expect(
      coordinateSystem.screenWidthToWorld(
        coordinateSystem.worldWidthToScreen(185),
      ),
      closeTo(185, 0.0001),
    );
    expect(
      coordinateSystem.screenHeightToWorld(
        coordinateSystem.worldHeightToScreen(12),
      ),
      closeTo(12, 0.0001),
    );
  });

  test('text JSON migration converts legacy pixel width and font sizing once', () {
    final migrated = TextProvider.fromJson(jsonEncode([
      {
        'id': 'text-1',
        'position': {'dx': 10, 'dy': 20},
        'text': 'hello',
        'size': 200,
      }
    ])).single;

    expect(migrated.usesWorldSize, isTrue);
    expect(migrated.sizeVersion, worldSizedMediaVersion);
    expect(migrated.size, closeTo(185.1852, 0.001));
    expect(migrated.fontSize, closeTo(14.8148, 0.001));

    final alreadyWorldSized = TextProvider.fromJson(jsonEncode([
      {
        'id': 'text-2',
        'position': {'dx': 10, 'dy': 20},
        'text': 'hello',
        'size': 185,
        'fontSize': 16,
        'sizeVersion': worldSizedMediaVersion,
      }
    ])).single;

    expect(alreadyWorldSized.size, 185);
    expect(alreadyWorldSized.fontSize, 16);
    expect(alreadyWorldSized.sizeVersion, worldSizedMediaVersion);
  });

  test('image JSON migration converts legacy pixel width once', () async {
    final migrated = (await PlacedImageProvider.fromJson(
      jsonString: jsonEncode([
        {
          'id': 'image-1',
          'position': {'dx': 10, 'dy': 20},
          'aspectRatio': 1.5,
          'scale': 200,
          'fileExtension': null,
          'tagColorValue': null,
          'link': '',
        }
      ]),
      strategyID: 'strategy-id',
    ))
        .single;

    expect(migrated.usesWorldSize, isTrue);
    expect(migrated.sizeVersion, worldSizedMediaVersion);
    expect(migrated.scale, closeTo(185.1852, 0.001));

    final alreadyWorldSized = (await PlacedImageProvider.fromJson(
      jsonString: jsonEncode([
        {
          'id': 'image-2',
          'position': {'dx': 10, 'dy': 20},
          'aspectRatio': 1.5,
          'scale': 185,
          'sizeVersion': worldSizedMediaVersion,
          'fileExtension': null,
          'tagColorValue': null,
          'link': '',
        }
      ]),
      strategyID: 'strategy-id',
    ))
        .single;

    expect(alreadyWorldSized.scale, 185);
    expect(alreadyWorldSized.sizeVersion, worldSizedMediaVersion);
  });
}
