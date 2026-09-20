import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'navigation_geometry_test.dart' as fixture;

void main() {
  test('sheet labels follow the selected floor and its same-height approach',
      () {
    final data = fixture.mesh([
      fixture.rect(0, 0, 10, 10, 0),
      fixture.rect(0, 0, 10, 10, 400),
      fixture.rect(10, 0, 20, 10, 400),
    ])
      ..['tacticalGroundChartIds'] = [0, 1, 1];
    final nav = fixture.load(data);
    expect(nav.maximumGroundChartId, 1);
    expect(nav.groundChartAt(const Offset(5, 5), preferredElevation: 0), 0);
    expect(nav.groundChartAt(const Offset(5, 5), preferredElevation: 400), 1);
    expect(nav.groundChartAt(const Offset(15, 5), preferredElevation: 400), 1);
    expect(
        nav.groundChartAt(const Offset(20.1, 5), preferredElevation: 400), 1);
    expect(nav.floorHeightAt(const Offset(20.1, 5)), isNull,
        reason: 'Continuing the visible sheet does not invent navigation');
  });

  test('invalid sheet metadata fails before navigation can select a worker',
      () {
    for (final ids in [
      [0, 1],
      [2],
      [-1]
    ]) {
      final data = fixture.mesh([fixture.rect(0, 0, 10, 10, 0)])
        ..['tacticalGroundChartIds'] = ids;
      expect(() => fixture.load(data), throwsFormatException);
    }
  });
}
