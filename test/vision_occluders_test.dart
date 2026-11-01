import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_occluders.dart';

void main() {
  const smoke = CircleOccluder(Offset(40, 0), 10);

  test('a smoke hides itself and what lies behind it, nothing beside it', () {
    final hidden = occluderShadows(Offset.zero, 100, const [smoke])!;
    expect(hidden.contains(const Offset(40, 0)), isTrue, reason: 'inside');
    expect(hidden.contains(const Offset(80, 0)), isTrue, reason: 'behind');
    expect(hidden.contains(const Offset(80, 30)), isFalse, reason: 'beside');
    expect(hidden.contains(const Offset(20, 0)), isFalse, reason: 'in front');
    expect(hidden.contains(const Offset(-50, 0)), isFalse, reason: 'opposite');
  });

  test('standing in a smoke, or on its rim, hides everything', () {
    expect(standsInsideSmoke(const Offset(40, 2), const [smoke]), isTrue);
    expect(standsInsideSmoke(const Offset(50.005, 0), const [smoke]), isTrue);
    expect(standsInsideSmoke(const Offset(52, 0), const [smoke]), isFalse);
  });

  test('a smoke wall hides what lies behind it', () {
    final hidden = occluderShadows(Offset.zero, 100, const [
      LineOccluder([Offset(30, -20), Offset(30, 0), Offset(30, 20)])
    ])!;
    expect(hidden.contains(const Offset(60, 10)), isTrue);
    expect(hidden.contains(const Offset(60, -10)), isTrue);
    expect(hidden.contains(const Offset(20, 10)), isFalse);
    expect(hidden.contains(const Offset(60, 60)), isFalse);
  });

  test('a smoke wall right in front of the eye hides all the way out', () {
    final hidden = occluderShadows(Offset.zero, 100, const [
      LineOccluder([Offset(1, -10), Offset(1, 10)])
    ])!;
    for (final point in const [Offset(50, 0), Offset(95, 0), Offset(95, 40)]) {
      expect(hidden.contains(point), isTrue, reason: '$point');
    }
    expect(hidden.contains(const Offset(-50, 0)), isFalse);
  });

  test('overlapping smokes both hide, whichever way they wind', () {
    final hidden = occluderShadows(Offset.zero, 100, const [
      smoke,
      CircleOccluder(Offset(45, 5), 10),
      LineOccluder([Offset(30, 20), Offset(30, -20)]),
    ])!;
    for (final point in const [Offset(70, 0), Offset(70, 8), Offset(50, 5)]) {
      expect(hidden.contains(point), isTrue, reason: '$point');
    }
  });

  test('a smoke right beside the eye still has a bounded shadow', () {
    final hidden = occluderShadows(const Offset(29.95, 0), 100, const [smoke])!;
    expect(hidden.getBounds().width, lessThan(1e6));
    expect(hidden.contains(const Offset(80, 0)), isTrue);
  });

  test('nothing to hide gives no shadow', () {
    expect(occluderShadows(Offset.zero, 100, const []), isNull);
    expect(
      occluderShadows(Offset.zero, 100, const [
        LineOccluder([Offset(10, 0), Offset(20, 0)]),
      ]),
      isNull,
      reason: 'a wall seen edge on',
    );
  });

  group('a cone sees only part of a wall', () {
    // A ring of short segments all round the eye.
    final ring = LineOccluder([
      for (var i = 0; i <= 72; i++)
        Offset.fromDirection(i * math.pi / 36, 30),
    ]);
    const spread = 50 * math.pi / 180;

    for (final heading in [0.0, 1.0, math.pi, -math.pi, 3.0, -2.5, 7.0]) {
      test('a cone facing $heading loses none of it', () {
        final view = (heading: heading, spread: spread);
        final hidden = occluderShadows(Offset.zero, 100, [ring], view: view)!;
        for (var a = -spread + 0.001; a <= spread; a += spread / 40) {
          final direction = Offset.fromDirection(heading + a);
          expect(hidden.contains(direction * 60), isTrue, reason: '$a');
          expect(hidden.contains(direction * 20), isFalse, reason: '$a');
        }
      });

      test('a cone facing $heading skips what lies behind it', () {
        final view = (heading: heading, spread: spread);
        final all = ring.shadows(Offset.zero, 100);
        final seen = ring.shadows(Offset.zero, 100, view: view);
        expect(all, hasLength(72));
        // 100 degrees of 360, and a segment either end.
        expect(seen.length, inInclusiveRange(20, 23));
      });
    }

    test('a wall spanning the view with both ends outside it is seen', () {
      const across = LineOccluder([Offset(30, -60), Offset(30, 60)]);
      expect(
        across.shadows(Offset.zero, 100,
            view: (heading: 0.0, spread: 10 * math.pi / 180)),
        hasLength(1),
      );
    });

    test('a wall out of view casts nothing, so the cone needs no layer', () {
      expect(
        occluderShadows(
          Offset.zero,
          100,
          const [
            LineOccluder([Offset(-30, -10), Offset(-30, 10)]),
          ],
          view: (heading: 0.0, spread: spread),
        ),
        isNull,
      );
    });
  });

  test('only occluders within reach reach the cone', () {
    expect(smoke.reaches(Offset.zero, 25), isFalse);
    expect(smoke.reaches(Offset.zero, 35), isTrue);
    expect(
      const LineOccluder([Offset(0, 50), Offset(100, 50)])
          .reaches(Offset.zero, 40),
      isFalse,
    );
  });
}
