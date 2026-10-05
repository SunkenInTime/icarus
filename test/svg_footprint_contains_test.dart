import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

/// Every edge of every ring, as containment read before edges were filed by
/// row: the answer the filed lookup must still give.
bool _everyEdge(List<List<Offset>> rings, bool evenOdd, Offset point) {
  var winding = 0;
  for (final ring in rings) {
    for (var i = 0; i < ring.length; i++) {
      final a = ring[i], b = ring[(i + 1) % ring.length];
      final side =
          (b.dx - a.dx) * (point.dy - a.dy) - (b.dy - a.dy) * (point.dx - a.dx);
      if (side == 0 &&
          point.dx >= math.min(a.dx, b.dx) &&
          point.dx <= math.max(a.dx, b.dx) &&
          point.dy >= math.min(a.dy, b.dy) &&
          point.dy <= math.max(a.dy, b.dy)) return true;
      if (a.dy <= point.dy && b.dy > point.dy && side > 0) winding++;
      if (a.dy > point.dy && b.dy <= point.dy && side < 0) winding--;
    }
  }
  return evenOdd ? winding.abs().isOdd : winding != 0;
}

void main() {
  test('walls and floor answer containment as reading every edge did', () {
    final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(
        gzip.decode(File('assets/maps/lotus_svg_height_defense.json.gz')
            .readAsBytesSync()))) as Map<String, dynamic>);
    final random = math.Random(7);
    final points = [
      for (var i = 0; i < 4000; i++)
        Offset(random.nextDouble() * 500, random.nextDouble() * 500),
      // Points on vertices and edges, where rows meet and boundaries count.
      for (final wall in model.walls.take(40))
        for (final ring in wall.rings)
          for (var i = 0; i < ring.length; i += 7) ...[
            ring[i],
            Offset.lerp(ring[i], ring[(i + 1) % ring.length], 0.5)!,
          ],
    ];
    final footprints = [
      for (final wall in model.walls)
        (wall.id, wall.rings, wall.evenOdd, wall.contains),
      for (final (i, receiver) in model.receivers.indexed)
        ('receiver $i', receiver.rings, receiver.evenOdd, receiver.contains),
    ];
    var inside = 0;
    for (final point in points) {
      for (final (id, rings, evenOdd, contains) in footprints) {
        final expected = _everyEdge(rings, evenOdd, point);
        expect(contains(point), expected, reason: '$id at $point');
        if (expected) inside++;
      }
    }
    expect(inside, greaterThan(1000));
  });
}
