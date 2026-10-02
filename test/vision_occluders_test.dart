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
