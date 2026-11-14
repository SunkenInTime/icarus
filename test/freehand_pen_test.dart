import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/freehand_pen.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/providers/drawing_provider.dart';

/// A hand moving in a straight line from [from] to [to], as a mouse reports
/// it: [step] apart, each position snapped to a whole pixel.
List<Offset> _mouse(Offset from, Offset to, {double step = 2}) {
  final length = (to - from).distance;
  final reports = <Offset>[];
  for (var d = 0.0; d <= length; d += step) {
    final p = Offset.lerp(from, to, d / length)!;
    final snapped = Offset(p.dx.roundToDouble(), p.dy.roundToDouble());
    if (reports.isEmpty || reports.last != snapped) reports.add(snapped);
  }
  return reports;
}

/// How much the stroke painted through [points] turns, in degrees, measured
/// along the path it is painted with. A straight line turns 0.
double _turning(List<Offset> points, CoordinateSystem coordinates) {
  final path = (FreeDrawing(
    listOfPoints: points.map(coordinates.screenToCoordinate).toList(),
    colorValue: 0xFFFFFFFF,
    isDotted: false,
    hasArrow: false,
    id: 'stroke',
  )..rebuildPath(coordinates))
      .path;
  final metric = path.computeMetrics().single;
  final along = [
    for (var d = 0.0; d <= metric.length; d += 3)
      metric.getTangentForOffset(d)!.position,
  ];
  var total = 0.0;
  for (var i = 2; i < along.length; i++) {
    final before = (along[i - 1] - along[i - 2]).direction;
    final after = (along[i] - along[i - 1]).direction;
    var turn = (after - before).abs();
    if (turn > math.pi) turn = 2 * math.pi - turn;
    total += turn;
  }
  return total * 180 / math.pi;
}

/// How far [point] is from the nearest place between [a] and [b].
double _distanceToSegment(Offset point, Offset a, Offset b) {
  final along = b - a;
  final t = (((point - a).dx * along.dx + (point - a).dy * along.dy) /
          along.distanceSquared)
      .clamp(0.0, 1.0);
  return (point - (a + along * t)).distance;
}

List<Offset> _drawn(List<Offset> reports, {double lag = 8}) {
  final pen = FreehandPen(reports.first, lag: lag, spacing: 2.5);
  var points = pen.points;
  for (final report in reports.skip(1)) {
    points = pen.moveTo(report);
  }
  return points;
}

void main() {
  // A shallow diagonal: the pointer steps down one pixel every twelve
  // across, the staircase a stroke used to be drawn through.
  const from = Offset(160, 140);
  const to = Offset(440, 163);

  test('a straight drag across the pixel grid draws nearly straight', () {
    final coordinates = CoordinateSystem(playAreaSize: const Size(1351, 760));
    final reports = _mouse(from, to);

    // Through the reports themselves, as strokes were drawn before.
    final stepped = <Offset>[];
    for (final report in reports) {
      if (stepped.isEmpty || (report - stepped.last).distance >= 2.5) {
        stepped.add(report);
      }
    }

    final before = _turning(stepped, coordinates);
    final after = _turning(_drawn(reports), coordinates);
    expect(before, greaterThan(300));
    expect(after, lessThan(before / 3));
  });

  test('the stroke starts where the drag did and ends at the pointer', () {
    final reports = _mouse(from, to);
    final points = _drawn(reports);
    expect(points.first, reports.first);
    expect(points.last, reports.last);
  });

  test('the stroke stays within a pixel of a straight drag', () {
    final direction = (to - from) / (to - from).distance;
    for (final point in _drawn(_mouse(from, to))) {
      final offset = point - from;
      final across = offset.dx * direction.dy - offset.dy * direction.dx;
      expect(across.abs(), lessThan(1));
    }
  });

  test('a mouse that reports more often draws the same stroke', () {
    final sparse = _drawn(_mouse(from, to, step: 6));
    final dense = _drawn(_mouse(from, to, step: 0.5));
    // Each runs within half a pixel of the other all along.
    for (final point in sparse) {
      final nearest = [
        for (var i = 1; i < dense.length; i++)
          _distanceToSegment(point, dense[i - 1], dense[i]),
      ].reduce(math.min);
      expect(nearest, lessThan(0.5));
    }
  });

  test('a corner the hand turned is kept within the pen\'s lag', () {
    const corner = Offset(300, 130);
    final reports = [
      ..._mouse(const Offset(170, 130), corner),
      ..._mouse(corner, const Offset(300, 190)).skip(1),
    ];
    final points = _drawn(reports);
    final nearest =
        points.map((point) => (point - corner).distance).reduce(math.min);
    expect(nearest, lessThan(4));
  });

  test('a pointer that has not left the start is still one point', () {
    final pen = FreehandPen(from, lag: 8, spacing: 2.5);
    expect(pen.moveTo(from + const Offset(1, 0)), [from]);
  });

  test('no two points of a stroke are closer than the spacing, but the last',
      () {
    final points = _drawn(_mouse(from, to));
    for (var i = 1; i < points.length - 1; i++) {
      expect((points[i] - points[i - 1]).distance, greaterThanOrEqualTo(2.5));
    }
  });

  group('the editor', () {
    late ProviderContainer container;
    late CoordinateSystem coordinates;

    setUp(() {
      coordinates = CoordinateSystem(playAreaSize: const Size(1351, 760));
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    FreeDrawing draw(List<Offset> reports) {
      final drawing = container.read(drawingProvider.notifier);
      drawing.startFreeDrawing(
        reports.first,
        coordinates,
        Colors.white,
        Settings.defaultStrokeThickness,
        false,
        true,
        false,
        TraversalSpeed.defaultProfile,
      );
      for (final report in reports.skip(1)) {
        drawing.updateFreeDrawing(report, coordinates);
      }
      final live =
          container.read(drawingProvider).currentElement as FreeDrawing;
      // The ink reaches the pointer while the drag is still down.
      expect(
        (coordinates.coordinateToScreen(live.listOfPoints.last) - reports.last)
            .distance,
        lessThan(0.001),
      );
      drawing.finishFreeDrawing(null, coordinates);
      return container.read(drawingProvider).elements.single as FreeDrawing;
    }

    test('saves the smoothed stroke, ending where the pointer let go', () {
      final reports = _mouse(from, to);
      final saved = draw(reports);
      final screen =
          saved.listOfPoints.map(coordinates.coordinateToScreen).toList();

      expect((screen.first - reports.first).distance, lessThan(0.001));
      expect((screen.last - reports.last).distance, lessThan(0.001));
      expect(_turning(screen, coordinates), lessThan(160));

      // What it measures is the saved stroke, not the pointer's path.
      var length = 0.0;
      for (var i = 1; i < saved.listOfPoints.length; i++) {
        length += (saved.listOfPoints[i] - saved.listOfPoints[i - 1]).distance;
      }
      expect(saved.cachedPolylineLengthUnits, closeTo(length, 1e-9));
      for (final point in saved.listOfPoints) {
        expect(saved.boundingBox!.isWithinOrNear(point, 1e-9), isTrue);
      }
    });
  });
}
