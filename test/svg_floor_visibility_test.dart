import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_floor_visibility.dart';

List<Offset> rectangle(Rect r) =>
    [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

void main() {
  final window = SvgFloorOccluder(
      [rectangle(const Rect.fromLTRB(10, -5, 11, 5))],
      false,
      [(double.negativeInfinity, 4), (6, 10)]);
  Path visible(double eye, double target, {List<SvgFloorOccluder>? walls}) =>
      visibleSvgFloor(
          floor: Path()..addRect(const Rect.fromLTRB(12, -2, 25, 2)),
          sector: Path()..addRect(const Rect.fromLTRB(-30, -30, 30, 30)),
          origin: Offset.zero,
          observerEye: eye,
          targetEye: target,
          walls: walls ?? [window]);

  test('a lower observer can see up through a window without removing its sill',
      () {
    final result = visible(3.9, 4.75);
    expect(result.contains(const Offset(15, 0)), isTrue);
    expect(visible(2, 2).contains(const Offset(15, 0)), isFalse);
    expect(visible(7, 7).contains(const Offset(15, 0)), isFalse);
  });

  test(
      'the sill blocks a distant target whose sightline crosses below the opening',
      () {
    final result = visible(1, 4.75);
    expect(result.contains(const Offset(12.1, 0)), isTrue);
    expect(result.contains(const Offset(20, 0)), isFalse);
  });

  test('projection works downward and at the same eye height', () {
    expect(visible(5.5, 4.75).contains(const Offset(20, 0)), isTrue);
    expect(visible(4.75, 4.75).contains(const Offset(20, 0)), isTrue);
    expect(visible(9, 4.75).contains(const Offset(20, 0)), isFalse);
  });

  test('an overhead cap blocks a ray that starts beneath its footprint', () {
    final overhead = SvgFloorOccluder(
        [rectangle(const Rect.fromLTRB(-4, -5, 15, 5))], false, [(3, 4)]);
    expect(visible(1, 4.75, walls: [overhead]).contains(const Offset(12.1, 0)),
        isFalse);
  });

  test('a real hole in an overhead footprint remains open', () {
    final overhead = SvgFloorOccluder(
        [
          rectangle(const Rect.fromLTRB(-20, -20, 30, 20)),
          rectangle(const Rect.fromLTRB(-10, -10, 26, 10)),
        ],
        true,
        [(3, 4)]);
    expect(visible(1, 4.75, walls: [overhead]).contains(const Offset(20, 0)),
        isTrue);
  });
}
