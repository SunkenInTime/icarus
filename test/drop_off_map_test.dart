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

  group('a drop out of sight', () {
    // A 1600x900 window: the canvas is 1600 px wide but only the 1312 px
    // left of the sidebar show, centred, so 144 px are cut off each side.
    final screen = CoordinateSystem.forSize(const Size(1600, 900));
    const view = Rect.fromLTWH(144, 0, 1312, 900);
    final pxToWorld = screen.worldNormalizedWidth / 1600;
    final viewRight = (144 + 1312) * pxToWorld;
    final viewLeft = 144 * pxToWorld;
    const inset = CoordinateSystem.dropEdge + 2;
    final agentDot = CoordinateSystem.virtualToWorld(storedAgentAnchor);

    Offset dotOf(Offset saved) => saved + agentDot;

    test('an agent under the sidebar comes back to its edge', () {
      final dropped = savedAt(const Offset(1700, 500), storedAgentAnchor);
      final landed = screen.anchoredDrop(
        dropped,
        storedAgentAnchor,
        view,
        isAttack: true,
      );
      expect(dotOf(landed).dx, closeTo(viewRight - inset, 0.001));
      expect(dotOf(landed).dy, closeTo(500, 0.001));
    });

    test('an agent past the window comes back to its edge', () {
      final dropped = savedAt(const Offset(60, 300), storedAgentAnchor);
      final landed = screen.anchoredDrop(
        dropped,
        storedAgentAnchor,
        view,
        isAttack: true,
      );
      expect(dotOf(landed).dx, closeTo(viewLeft + inset, 0.001));
      expect(dotOf(landed).dy, closeTo(300, 0.001));
    });

    test('an agent in sight lands where it was dropped', () {
      final dropped = savedAt(const Offset(1500, 500), storedAgentAnchor);
      expect(
        screen.anchoredDrop(dropped, storedAgentAnchor, view, isAttack: true),
        dropped,
      );
    });

    test('an agent dropped off the map stays there, for the drop to delete',
        () {
      final dropped = savedAt(const Offset(1775, 500), storedAgentAnchor);
      expect(
        screen.anchoredDrop(dropped, storedAgentAnchor, view, isAttack: true),
        dropped,
      );
      expect(screen.isAnchorOutOfBounds(dropped, storedAgentAnchor), isTrue);
    });

    test('on defense the view is read the other way up', () {
      // Scrolled to the canvas's left edge: the right 288 px are hidden.
      const scrolled = Rect.fromLTWH(0, 0, 1312, 900);
      // Saved at x 100 attack side up, defense draws the dot at 1677.
      final dropped = savedAt(const Offset(100, 500), storedAgentAnchor);
      final landed = screen.anchoredDrop(
        dropped,
        storedAgentAnchor,
        scrolled,
        isAttack: false,
      );
      final hiddenRight = screen.worldNormalizedWidth - 1312 * pxToWorld;
      expect(dotOf(landed).dx, closeTo(hiddenRight + inset, 0.001));
      expect(
        screen.anchoredDrop(
          dropped,
          storedAgentAnchor,
          scrolled,
          isAttack: true,
        ),
        dropped,
        reason: 'attack draws it at 100, in sight',
      );
    });

    test('a picture under the sidebar comes back until its middle shows', () {
      const box = Size(150, 300);
      final half = screen.screenSizeToWorld(box).center(Offset.zero);
      const dropped = Offset(1660, 400);
      final landed = screen.boxDrop(dropped, box, view, isAttack: true);
      expect((landed + half).dx, closeTo(viewRight - inset, 0.001));
      expect(landed.dy, 400);
    });

    test('a picture dropped off the map stays there, for the drop to delete',
        () {
      const box = Size(150, 300);
      const dropped = Offset(1790, 400);
      expect(screen.boxDrop(dropped, box, view, isAttack: true), dropped);
    });

    test('without a view nothing moves', () {
      final dropped = savedAt(const Offset(1700, 500), storedAgentAnchor);
      expect(
        screen.anchoredDrop(dropped, storedAgentAnchor, null, isAttack: true),
        dropped,
      );
      expect(
        screen.anchoredDrop(
          dropped,
          storedAgentAnchor,
          Rect.zero,
          isAttack: true,
        ),
        dropped,
      );
    });
  });
}
