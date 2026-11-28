import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';

PlacedUtility _rectangle({double? width, double? length}) => PlacedUtility(
      id: 'rectangle',
      type: UtilityType.customRectangle,
      position: const Offset(500, 500),
      customWidth: width,
      customLength: length,
    );

Offset _placed(PlacedUtility rectangle, {required bool isAttack}) =>
    screenPositionForWidget(
      widget: rectangle,
      coordinateSystem: CoordinateSystem.instance,
      mapScale: Maps.mapScale[MapValue.ascent]!,
      agentSize: Settings.agentSize,
      abilitySize: Settings.abilitySize,
      isAttack: isAttack,
    );

void main() {
  setUp(() => CoordinateSystem(playAreaSize: const Size(1600, 900)));

  for (final isAttack in [true, false]) {
    test(
        'a rectangle saved without a size is placed where an empty one is, '
        'on ${isAttack ? 'attack' : 'defense'}, instead of throwing', () {
      final empty =
          _placed(_rectangle(width: 0, length: 0), isAttack: isAttack);

      expect(_placed(_rectangle(), isAttack: isAttack), empty);
      expect(_placed(_rectangle(width: 6), isAttack: isAttack), empty);
      expect(_placed(_rectangle(length: 18), isAttack: isAttack), empty);
    });
  }
}
