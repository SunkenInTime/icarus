import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';

void main() {
  final coordinates = CoordinateSystem.forSize(const Size(1512, 851));

  /// The saved position that puts a dot [anchor] from it at [dot].
  Offset savedAt(Offset dot, Offset anchor) =>
      dot - CoordinateSystem.virtualToWorld(anchor);

  group('an item with a dot', () {
    final kayoUlt = AgentData.agents[AgentType.kayo]!.abilities[3].abilityData!
        .getAnchorPoint(mapScale: 1.0, abilitySize: Settings.abilitySize);

    test('stays while the dot is on the map, however large the item', () {
      for (final dot in const [
        Offset(880, 30),
        Offset(880, 50),
        Offset(30, 500),
      ]) {
        expect(
          coordinates.isAnchorOutOfBounds(savedAt(dot, kayoUlt), kayoUlt),
          isFalse,
          reason: 'dot at $dot',
        );
      }
    });

    test('goes once the dot leaves the map', () {
      for (final dot in const [
        Offset(880, 5),
        Offset(880, 995),
        Offset(5, 500),
        Offset(1775, 500),
      ]) {
        expect(
          coordinates.isAnchorOutOfBounds(savedAt(dot, kayoUlt), kayoUlt),
          isTrue,
          reason: 'dot at $dot',
        );
      }
    });

    test('an agent just inside the top edge stays', () {
      expect(
        coordinates.isAnchorOutOfBounds(
          savedAt(const Offset(880, 12), storedAgentAnchor),
          storedAgentAnchor,
        ),
        isFalse,
      );
    });
  });

  group('a box without a dot', () {
    const box = Size(150, 300);
    // In world units: half the box is about 88 wide and 176 tall.

    test('stays hanging over the top edge', () {
      expect(
        coordinates.isBoxOutOfBounds(const Offset(880, -100), box),
        isFalse,
      );
    });

    test('stays hanging over the bottom edge', () {
      expect(
        coordinates.isBoxOutOfBounds(const Offset(880, 900), box),
        isFalse,
      );
    });

    test('goes once its middle leaves over the top edge', () {
      expect(
        coordinates.isBoxOutOfBounds(const Offset(880, -180), box),
        isTrue,
      );
    });

    test('goes once its top-left leaves over the bottom edge', () {
      expect(
        coordinates.isBoxOutOfBounds(const Offset(880, 995), box),
        isTrue,
      );
    });
  });
}
