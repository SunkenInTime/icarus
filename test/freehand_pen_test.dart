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

/// A hand moving in straight lines through [corners], as a mouse reports
/// it: [step] apart, each position snapped to a whole pixel.
List<Offset> _mouse(List<Offset> corners, {double step = 2}) {
  final reports = <Offset>[];
  for (var i = 1; i < corners.length; i++) {
    final from = corners[i - 1], to = corners[i];
    final length = (to - from).distance;
    for (var d = 0.0; d <= length; d += step) {
      final p = Offset.lerp(from, to, d / length)!;
      final snapped = Offset(p.dx.roundToDouble(), p.dy.roundToDouble());
      if (reports.isEmpty || reports.last != snapped) reports.add(snapped);
    }
  }
  return reports;
}

/// What the pen draws through [reports], after each one.
List<List<Offset>> _frames(List<Offset> reports, {double unit = 1}) {
  final pen = FreehandPen(reports.first, unit: unit);
  return [for (final report in reports.skip(1)) pen.moveTo(report)];
}

List<Offset> _drawn(List<Offset> reports, {double unit = 1}) =>
    _frames(reports, unit: unit).last;

/// The path the editor paints through [points], a point every half pixel.
List<Offset> _painted(List<Offset> points, CoordinateSystem coordinates) {
  final path = (FreeDrawing(
    listOfPoints: points.map(coordinates.screenToCoordinate).toList(),
    colorValue: 0xFFFFFFFF,
    isDotted: false,
    hasArrow: false,
    id: 'stroke',
  )..rebuildPath(coordinates))
      .path;
  final metric = path.computeMetrics().single;
  return [
    for (var d = 0.0; d <= metric.length; d += 0.5)
      metric.getTangentForOffset(d)!.position,
  ];
}

/// How much [path] turns, in degrees, taking its direction every 3 pixels.
/// A straight line turns 0.
double _turning(List<Offset> path) {
  final spaced = <Offset>[];
  for (final point in path) {
    if (spaced.isEmpty || (point - spaced.last).distance >= 3) {
      spaced.add(point);
    }
  }
  var total = 0.0;
  for (var i = 2; i < spaced.length; i++) {
    var turn = ((spaced[i] - spaced[i - 1]).direction -
            (spaced[i - 1] - spaced[i - 2]).direction)
        .abs();
    if (turn > math.pi) turn = 2 * math.pi - turn;
    total += turn;
  }
  return total * 180 / math.pi;
}

/// How far [point] is from the nearest place on [path].
double _distanceTo(List<Offset> path, Offset point) {
  var nearest = double.infinity;
  for (var i = 1; i < path.length; i++) {
    final a = path[i - 1], along = path[i] - a;
    final t = along.distanceSquared == 0
        ? 0.0
        : (((point - a).dx * along.dx + (point - a).dy * along.dy) /
                along.distanceSquared)
            .clamp(0.0, 1.0);
    nearest = math.min(nearest, (point - (a + along * t)).distance);
  }
  return nearest;
}

void main() {
  final coordinates = CoordinateSystem(playAreaSize: const Size(1351, 760));

  // A shallow diagonal: the pointer steps down one pixel every twelve
  // across, the staircase a stroke used to be drawn through.
  const shallow = [Offset(160, 140), Offset(440, 163)];

  // Out, a right angle, and down.
  const corner = Offset(300, 130);
  const elbow = [Offset(170, 130), corner, Offset(300, 250)];

  test('a straight drag across the pixel grid is drawn straight', () {
    final reports = _mouse(shallow);

    // Through the reports themselves, as strokes were drawn before.
    final stepped = <Offset>[];
    for (final report in reports) {
      if (stepped.isEmpty || (report - stepped.last).distance >= 2.5) {
        stepped.add(report);
      }
    }
    expect(_turning(_painted(stepped, coordinates)), greaterThan(300));

    expect(_turning(_painted(_drawn(reports), coordinates)), lessThan(20));
  });

  test(
      'the stroke starts where the drag did and reaches the pointer '
      'after every report', () {
    final reports = _mouse(elbow);
    final frames = _frames(reports);
    for (var i = 0; i < frames.length; i++) {
      expect(frames[i].first, reports.first);
      // Until the pointer has left the start, the stroke is a click.
      if (frames[i].length > 1) expect(frames[i].last, reports[i + 1]);
    }
    expect(frames.last.length, greaterThan(1));
  });

  test(
      'the painted stroke stays within the tolerance of where the pointer '
      'went', () {
    for (final shape in [shallow, elbow]) {
      final reports = _mouse(shape);
      final painted = _painted(_drawn(reports), coordinates);
      for (final report in reports) {
        expect(
          _distanceTo(painted, report),
          lessThan(FreehandPen.tolerance + 0.5),
        );
      }
    }
  });

  test('a corner the hand turned is painted as a corner', () {
    final painted = _painted(_drawn(_mouse(elbow)), coordinates);
    // The stroke goes to the corner itself: a pen that trailed the pointer,
    // or a curve fitted across the turn, would cut inside it.
    expect(_distanceTo(painted, corner), lessThan(0.75));
  });

  test('ink the pointer has left behind does not move again', () {
    // A long wandering stroke, so the curve is shaped and settled many times.
    final reports = _mouse([
      for (var x = 0.0; x <= 600; x += 12)
        Offset(100 + x, 300 + 60 * math.sin(x / 45) + 8 * math.sin(x / 7)),
    ]);
    final frames = _frames(reports);
    for (var i = 1; i < frames.length; i++) {
      final before = _painted(frames[i - 1], coordinates);
      final now = _painted(frames[i], coordinates);
      final pointer = reports[i];
      for (final point in before) {
        // Further behind the pointer than the pen still shapes: twice the
        // distance it settles at, and the tolerance either end.
        if ((point - pointer).distance <
            2 * FreehandPen.settleBehind + 2 * FreehandPen.tolerance + 2) {
          continue;
        }
        expect(_distanceTo(now, point), lessThan(0.01));
      }
    }
  });

  test(
      'lifting the pointer changes nothing: the stroke saved is the one '
      'on screen', () {
    final reports = _mouse(elbow);
    final pen = FreehandPen(reports.first, unit: 1);
    late List<Offset> last;
    for (final report in reports.skip(1)) {
      last = pen.moveTo(report);
    }
    expect(pen.points, last);
  });

  test('the same path reported more or less often is the same stroke', () {
    const path = [
      Offset(100, 100),
      Offset(230, 100),
      Offset(230, 191),
      Offset(360, 256),
    ];
    // Reports along the same straight runs, [apart] from one another.
    List<Offset> reported(double apart) => [
          path.first,
          for (var i = 1; i < path.length; i++)
            for (var d = apart;
                d < (path[i] - path[i - 1]).distance + apart;
                d += apart)
              Offset.lerp(
                path[i - 1],
                path[i],
                math.min(1, d / (path[i] - path[i - 1]).distance),
              )!,
        ];
    final often = _painted(_drawn(reported(1)), coordinates);
    final seldom = _painted(_drawn(reported(13)), coordinates);
    for (final point in often) {
      expect(_distanceTo(seldom, point), lessThan(0.01));
    }
    for (final point in seldom) {
      expect(_distanceTo(often, point), lessThan(0.01));
    }
  });

  test('zoomed in, the pen keeps detail as much finer', () {
    // The same drag at a quarter the size, with a screen pixel a quarter
    // as long: the same stroke at a quarter the size.
    final reports = _mouse(elbow);
    final full = _drawn(reports);
    final quarter = _drawn([for (final r in reports) r / 4], unit: 0.25);
    expect(quarter.length, full.length);
    for (var i = 0; i < full.length; i++) {
      expect((quarter[i] * 4 - full[i]).distance, lessThan(1e-6));
    }
  });

  test('a pointer that has barely left the start is still one point', () {
    final pen = FreehandPen(const Offset(50, 50), unit: 1);
    expect(pen.moveTo(const Offset(51, 50)), [const Offset(50, 50)]);
    expect(pen.moveTo(const Offset(52, 51)), [const Offset(50, 50)]);
    expect(pen.moveTo(const Offset(56, 53)).length, greaterThan(1));
  });

  test('a long sweep is saved as fewer points than the mouse reported', () {
    final reports = _mouse(shallow, step: 1);
    expect(_drawn(reports).length, lessThan(reports.length ~/ 4));
  });

  group('the editor', () {
    late ProviderContainer container;

    setUp(() {
      CoordinateSystem(playAreaSize: const Size(1351, 760));
      container = ProviderContainer();
      addTearDown(container.dispose);
    });

    test(
        'saves the stroke the pen drew, with the box and length of that '
        'stroke', () {
      final reports = _mouse(elbow);
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
      final live = [
        ...(container.read(drawingProvider).currentElement as FreeDrawing)
            .listOfPoints,
      ];
      drawing.finishFreeDrawing(null, coordinates);
      final saved =
          container.read(drawingProvider).elements.single as FreeDrawing;

      // What was on screen under the pointer is what is saved.
      expect(saved.listOfPoints, live);
      final screen =
          saved.listOfPoints.map(coordinates.coordinateToScreen).toList();
      expect((screen.first - reports.first).distance, lessThan(1e-6));
      expect((screen.last - reports.last).distance, lessThan(1e-6));
      expect(
        _distanceTo(_painted(screen, coordinates), corner),
        lessThan(0.75),
      );

      var length = 0.0;
      for (var i = 1; i < saved.listOfPoints.length; i++) {
        length += (saved.listOfPoints[i] - saved.listOfPoints[i - 1]).distance;
      }
      expect(saved.cachedPolylineLengthUnits, closeTo(length, 1e-9));
      final box = saved.boundingBox!;
      for (final point in saved.listOfPoints) {
        expect(box.isWithinOrNear(point, 1e-9), isTrue);
      }
      // No larger than the stroke: an edge of the box touches it each way.
      expect(saved.listOfPoints.map((p) => p.dx).reduce(math.min), box.min.dx);
      expect(saved.listOfPoints.map((p) => p.dy).reduce(math.max), box.max.dy);
    });
  });
}
