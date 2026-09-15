import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:icarus/view_cone/vision_world_index.dart';

/// Experimental zero-clearance shadow mask. Coordinates remain relative to the
/// observer until Canvas applies the physical-to-artwork transform.
/// This does not replace the production visibility polygon implementation.
class WorldShadowMeshBuilder {
  var _positions = Float32List(4096);
  var _first = Float64List(32);
  var _second = Float64List(32);
  var _count = 0;
  var _used = 0;
  var candidates = 0;
  var shadows = 0;
  var collinear = 0;

  Float32List build({
    required VisionWorldIndex index,
    required Offset origin,
    required double facingAngle,
    required double coneAngle,
    required double range,
    double clipPadding = 0,
  }) {
    _used = 0;
    candidates = 0;
    shadows = 0;
    collinear = 0;
    index.visitConeSegments(
      origin: origin,
      facingAngle: facingAngle,
      coneAngle: coneAngle,
      range: range,
      visit: (ax, ay, bx, by) {
        candidates++;
        ax -= origin.dx;
        ay -= origin.dy;
        bx -= origin.dx;
        by -= origin.dy;
        final cross = ax * by - ay * bx;
        // A segment on a line through the observer has zero angular area.
        // Its exact collinear ray remains blocked in the CPU reference, but a
        // zero-area ray has no filled pixels. No finite-width wedge is invented.
        if (cross == 0) {
          collinear++;
          return;
        }
        final dx = bx - ax, dy = by - ay;
        final lengthSquared = dx * dx + dy * dy;
        // The current CPU query ignores non-collinear hits at <= 1e-9 m.
        // Remove just that part of a wall before forming its shadow, so an
        // observer almost on its surface does not gain a new half-plane block.
        const originEpsilonSquared = 1e-18;
        if (cross * cross <= originEpsilonSquared * lengthSquared) {
          final length = math.sqrt(lengthSquared);
          final ux = dx / length, uy = dy / length;
          final signedDistance = cross / length;
          final halfGap = math.sqrt(math.max(
              0, originEpsilonSquared - signedDistance * signedDistance));
          final aAlong = ax * ux + ay * uy;
          final bAlong = bx * ux + by * uy;
          if (aAlong <= halfGap && bAlong >= -halfGap) {
            final closestX = uy * signedDistance;
            final closestY = -ux * signedDistance;
            if (aAlong < -halfGap) {
              _shadow(ax, ay, closestX - ux * halfGap, closestY - uy * halfGap,
                  range + clipPadding);
            }
            if (bAlong > halfGap) {
              _shadow(closestX + ux * halfGap, closestY + uy * halfGap, bx, by,
                  range + clipPadding);
            }
            return;
          }
        }
        // Padding covers the antialiased cone fringe outside its ideal square.
        // It changes only the finite clipping rectangle, never a wall plane.
        _shadow(ax, ay, bx, by, range + clipPadding);
      },
    );
    return Float32List.sublistView(_positions, 0, _used);
  }

  void _shadow(double ax, double ay, double bx, double by, double range) {
    final cross = ax * by - ay * bx;
    final sign = cross > 0 ? 1.0 : -1.0;
    _first[0] = -range;
    _first[1] = -range;
    _first[2] = range;
    _first[3] = -range;
    _first[4] = range;
    _first[5] = range;
    _first[6] = -range;
    _first[7] = range;
    _count = 4;
    // Intersect the viewport with the two endpoint rays and the far side
    // of the wall. Bounded clipping remains stable beside a nearby wall;
    // extruding endpoint rays to an arbitrary large distance would not.
    _clip(-sign * ay, sign * ax, 0);
    _clip(sign * by, -sign * bx, 0);
    _clip(sign * (by - ay), -sign * (bx - ax), -cross.abs());
    if (_count < 3) return;
    shadows++;
    for (var vertex = 1; vertex + 1 < _count; vertex++) {
      _append(_first[0], _first[1]);
      _append(_first[vertex * 2], _first[vertex * 2 + 1]);
      _append(_first[vertex * 2 + 2], _first[vertex * 2 + 3]);
    }
  }

  void _clip(double nx, double ny, double constant) {
    if (_count == 0) return;
    var output = 0;
    var previousX = _first[(_count - 1) * 2];
    var previousY = _first[(_count - 1) * 2 + 1];
    var previousDistance = nx * previousX + ny * previousY + constant;
    for (var index = 0; index < _count; index++) {
      final x = _first[index * 2], y = _first[index * 2 + 1];
      final distance = nx * x + ny * y + constant;
      if ((distance >= 0) != (previousDistance >= 0)) {
        final fraction = previousDistance / (previousDistance - distance);
        _second[output++] = previousX + (x - previousX) * fraction;
        _second[output++] = previousY + (y - previousY) * fraction;
      }
      if (distance >= 0) {
        _second[output++] = x;
        _second[output++] = y;
      }
      previousX = x;
      previousY = y;
      previousDistance = distance;
    }
    final swap = _first;
    _first = _second;
    _second = swap;
    _count = output ~/ 2;
  }

  void _append(double x, double y) {
    if (_used + 2 > _positions.length) {
      _positions = Float32List(_positions.length * 2)..setAll(0, _positions);
    }
    _positions[_used++] = x;
    _positions[_used++] = y;
  }
}

void paintWorldShadowMesh(Canvas canvas, Float32List positions) {
  if (positions.isEmpty) return;
  final vertices = Vertices.raw(VertexMode.triangles, positions);
  canvas.drawVertices(
      vertices, BlendMode.src, Paint()..blendMode = BlendMode.dstOut);
  vertices.dispose();
}
