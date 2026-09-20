import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_native.dart';

void main() {
  final library = Platform.environment['ICARUS_SVG_NATIVE_LIBRARY'];
  test('native cone retains the crossing of two active SVG walls', () {
    final native = SvgHeightNative.open(
        wallIds: ['horizontal', 'vertical'],
        edgeRecords:
            Float64List.fromList([-100, 1, 100, 1, 0, -5, -10, -5, 10, 1]),
        libraryPath: library);
    try {
      final result = native.query(
          origin: Offset.zero,
          directionRadians: math.pi,
          range: 90,
          apertureRadians: math.pi / 2,
          activeWalls: [true, true]);
      var nearest = double.infinity;
      for (var i = 0; i < result.xy.length; i += 2) {
        nearest = math.min(
            nearest,
            (Offset(result.xy[i], result.xy[i + 1]) - const Offset(-5, 1))
                .distance);
      }
      expect(nearest, lessThan(1e-7));
    } finally {
      native.close();
    }
  }, skip: library == null ? 'Set ICARUS_SVG_NATIVE_LIBRARY.' : false);
  test('native cone includes a long wall crossing the range circle', () {
    final native = SvgHeightNative.open(
        wallIds: ['wall'],
        edgeRecords: Float64List.fromList([-100, 1, 100, 1, 0]),
        libraryPath: library);
    try {
      final cone = native.query(
          origin: Offset.zero,
          directionRadians: math.pi,
          range: 90,
          apertureRadians: math.pi / 2,
          activeWalls: [true]);
      final contact = Offset(-math.sqrt(90 * 90 - 1), 1);
      var nearest = double.infinity;
      for (var i = 0; i < cone.xy.length; i += 2) {
        nearest = math.min(
            nearest, (Offset(cone.xy[i], cone.xy[i + 1]) - contact).distance);
      }
      expect(nearest, lessThan(1e-7));
    } finally {
      native.close();
    }
  }, skip: library == null ? 'Set ICARUS_SVG_NATIVE_LIBRARY.' : false);
  test('native geometry validation does not hide malformed edge records', () {
    expect(
        () => SvgHeightNative.tryOpen(
            wallIds: ['wall'],
            edgeRecords: Float64List.fromList([1, 1, 1, 1, 0])),
        throwsArgumentError);
  });
  test('native results are copied and context disposal is explicit', () {
    final native = SvgHeightNative.open(
        wallIds: ['wall'],
        edgeRecords: Float64List.fromList([5, -10, 5, 10, 0]),
        libraryPath: library);
    final blocked = native.query(
        origin: Offset.zero,
        directionRadians: 0,
        range: 10,
        apertureRadians: math.pi / 2,
        activeWalls: [true],
        arcSteps: 2);
    final retained = List<double>.from(blocked.xy);
    final clear = native.query(
        origin: Offset.zero,
        directionRadians: 0,
        range: 10,
        apertureRadians: math.pi / 2,
        activeWalls: [false],
        arcSteps: 2);
    expect(blocked.xy, retained);
    expect(blocked.xy[4], closeTo(5, 1e-12));
    expect(clear.xy[4], closeTo(10, 1e-12));
    expect(
        () => native.query(
            origin: Offset.zero,
            directionRadians: 0,
            range: 10,
            apertureRadians: 1,
            activeWalls: []),
        throwsArgumentError);
    native.close();
    native.close();
    expect(
        () => native.query(
            origin: Offset.zero,
            directionRadians: 0,
            range: 10,
            apertureRadians: 1,
            activeWalls: [true]),
        throwsStateError);
    expect(blocked.xy, retained, reason: 'copied output survives native close');
  },
      skip: library == null
          ? 'Set ICARUS_SVG_NATIVE_LIBRARY to the compiled desktop library.'
          : false);
}
