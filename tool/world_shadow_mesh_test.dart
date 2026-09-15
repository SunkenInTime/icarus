import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_collision.dart';
import 'package:icarus/view_cone/vision_world_index.dart';

import 'world_shadow_mesh.dart';

bool _inside(Float32List triangles, Offset p) {
  for (var i = 0; i < triangles.length; i += 6) {
    double side(int a, int b) =>
        (triangles[i + b] - triangles[i + a]) * (p.dy - triangles[i + a + 1]) -
        (triangles[i + b + 1] - triangles[i + a + 1]) *
            (p.dx - triangles[i + a]);
    final a = side(0, 2), b = side(2, 4), c = side(4, 0);
    if ((a > 0 && b > 0 && c > 0) || (a < 0 && b < 0 && c < 0)) return true;
  }
  return false;
}

void main() {
  test('raster fringe padding changes only the finite outer clipping box', () {
    final index = VisionWorldIndex([
      VisionSegment.unthickened(const Offset(1, -20), const Offset(1, 20)),
    ]);
    final builder = WorldShadowMeshBuilder();
    final normal = Float32List.fromList(builder.build(
        index: index,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: 2 * math.pi,
        range: 10));
    final padded = builder.build(
        index: index,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: 2 * math.pi,
        range: 10,
        clipPadding: 1);
    expect(_inside(normal, const Offset(10.5, .123)), isFalse);
    expect(_inside(padded, const Offset(10.5, .123)), isTrue);
    for (final point in [
      const Offset(.999, .123),
      const Offset(1.001, .123),
      const Offset(8, 4),
      const Offset(-8, 4)
    ]) {
      expect(_inside(normal, point), _inside(padded, point));
    }
  });
  test(
      'the current ray-origin epsilon does not turn a near-zero hit into a wall',
      () {
    final index = VisionWorldIndex([
      VisionSegment.unthickened(
          const Offset(5e-10, -1), const Offset(5e-10, 1)),
    ]);
    final mesh = WorldShadowMeshBuilder().build(
        index: index,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: 2 * math.pi,
        range: 20);
    for (final point in [const Offset(10, .01), const Offset(1, 10)]) {
      final hit = index.nearestHit(
          origin: Offset.zero, direction: point / point.distance, range: 20);
      expect(_inside(mesh, point), hit != null && hit < point.distance);
    }
  });

  test(
      'an observer inside closed walls keeps the interior and blocks the outside',
      () {
    final index = VisionWorldIndex([
      VisionSegment.unthickened(const Offset(-2, -2), const Offset(2, -2)),
      VisionSegment.unthickened(const Offset(2, -2), const Offset(2, 2)),
      VisionSegment.unthickened(const Offset(2, 2), const Offset(-2, 2)),
      VisionSegment.unthickened(const Offset(-2, 2), const Offset(-2, -2)),
    ]);
    final mesh = WorldShadowMeshBuilder().build(
        index: index,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: 2 * math.pi,
        range: 65);
    expect(_inside(mesh, const Offset(.5, .7)), isFalse);
    expect(_inside(mesh, const Offset(20, .7)), isTrue);
    expect(_inside(mesh, const Offset(-20, .7)), isTrue);
    expect(_inside(mesh, const Offset(.5, 20)), isTrue);
    expect(_inside(mesh, const Offset(.5, -20)), isTrue);
  });

  test('bounded wall shadows match independent rays including an opening', () {
    final index = VisionWorldIndex([
      VisionSegment.unthickened(const Offset(1, -20), const Offset(1, -.1)),
      VisionSegment.unthickened(const Offset(1, .1), const Offset(1, 20)),
      VisionSegment.unthickened(const Offset(8, -4), const Offset(8, 4)),
      VisionSegment.unthickened(const Offset(-2, -1), const Offset(-2, 1)),
    ]);
    final builder = WorldShadowMeshBuilder();
    final mesh = builder.build(
        index: index,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: math.pi * 2,
        range: 20);
    final random = math.Random(98417);
    for (var i = 0; i < 20000; i++) {
      final angle = random.nextDouble() * math.pi * 2;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final distance = .01 + random.nextDouble() * 19.99;
      final hit = index.nearestHit(
          origin: Offset.zero, direction: direction, range: 20);
      if (hit != null && (hit - distance).abs() < .00001) continue;
      expect(_inside(mesh, direction * distance), hit != null && hit < distance,
          reason: 'angle=$angle distance=$distance hit=$hit');
    }
  });

  test('near wall uses bounded finite vertices without leaking at the range',
      () {
    final index = VisionWorldIndex([
      VisionSegment.unthickened(
          const Offset(.000001, -100), const Offset(.000001, 100)),
    ]);
    final mesh = WorldShadowMeshBuilder().build(
        index: index,
        origin: Offset.zero,
        facingAngle: 0,
        coneAngle: 2 * math.pi,
        range: 65);
    expect(mesh.every((value) => value.isFinite && value.abs() <= 65), isTrue);
    expect(_inside(mesh, const Offset(64, .123)), isTrue);
    expect(_inside(mesh, const Offset(-64, .123)), isFalse);
  });

  test('collinear walls do not acquire a made-up angular width', () {
    for (final endpoints in [
      [const Offset(1, 0), const Offset(2, 0)],
      [const Offset(-1, 0), const Offset(2, 0)],
      [Offset.zero, const Offset(2, 0)],
    ]) {
      final builder = WorldShadowMeshBuilder();
      final mesh = builder.build(
          index: VisionWorldIndex([
            VisionSegment.unthickened(endpoints[0], endpoints[1]),
          ]),
          origin: Offset.zero,
          facingAngle: 0,
          coneAngle: 2 * math.pi,
          range: 65);
      expect(mesh, isEmpty);
      expect(builder.collinear, 1);
    }
  });
}
