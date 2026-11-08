import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/coordinate_system.dart';
import 'package:path_parsing/path_parsing.dart';
import 'package:xml/xml.dart';

/// The lines a map's drawing shows, for Alt to snap a dragged item onto, in
/// world units with the attack side up, the way item positions are saved.
/// The defense side draws the same map turned half a turn, so the same lines
/// serve both.
///
/// They come from the map's artwork (`assets/maps/<map>_map.svg`): the edge
/// of the floor, which every map outlines in its wall colour, and every line
/// stroked in that colour (boxes, ledges, stairs). Lines drawn faint, at under
/// half strength, are left out, and so are the wall-coloured fills: those are
/// the floor's outline turned into shapes, so their edges sit either side of
/// the floor's edge. The vision walls (docs/vision-model.md) are a different
/// set of lines, which the user doesn't see.
class MapLines {
  MapLines(this.segments);

  /// The colours the artwork is drawn in, before a theme recolours it.
  static const _floor = '#271406';
  static const _wall = '#B27C40';

  final List<(Offset, Offset)> segments;

  factory MapLines.fromSvg(String source) {
    final root = XmlDocument.parse(source).rootElement;
    final project = _projection(root.getAttribute('viewBox'));
    final lines = _LineCollector();
    for (final element in root.descendants.whereType<XmlElement>()) {
      if (_isDefinition(element)) continue;
      final floor = _colour(element, 'fill') == _floor;
      final stroked = _colour(element, 'stroke') == _wall &&
          (double.tryParse(element.getAttribute('stroke-opacity') ?? '') ??
                  1) >=
              0.5;
      if (!floor && !stroked) continue;
      switch (element.name.local) {
        case 'path':
          writeSvgPathDataToPath(element.getAttribute('d'), lines);
        case 'circle':
          lines.circle(
            _number(element, 'cx'),
            _number(element, 'cy'),
            _number(element, 'r'),
          );
      }
    }
    return MapLines([
      for (final (start, end) in lines.segments) (project(start), project(end)),
    ]);
  }

  /// The point on a line nearest [point], when one is within [reach]. With
  /// [within], only the parts of lines inside it count.
  Offset? nearest(Offset point, double reach, {Rect? within}) {
    Offset? nearest;
    var distance = reach;
    for (final segment in segments) {
      final clipped = within == null ? segment : _clip(segment, within);
      if (clipped == null) continue;
      final (start, end) = clipped;
      final along = end - start;
      final length = along.distanceSquared;
      final t = length == 0
          ? 0.0
          : (((point - start).dx * along.dx + (point - start).dy * along.dy) /
                  length)
              .clamp(0.0, 1.0);
      final onLine = start + along * t;
      final away = (onLine - point).distance;
      if (away <= distance) {
        nearest = onLine;
        distance = away;
      }
    }
    return nearest;
  }

  /// The part of [segment] inside [rect], if any (Liang-Barsky).
  static (Offset, Offset)? _clip((Offset, Offset) segment, Rect rect) {
    final (start, end) = segment;
    final along = end - start;
    var from = 0.0, to = 1.0;
    for (final (p, q) in [
      (-along.dx, start.dx - rect.left),
      (along.dx, rect.right - start.dx),
      (-along.dy, start.dy - rect.top),
      (along.dy, rect.bottom - start.dy),
    ]) {
      if (p == 0) {
        if (q < 0) return null;
        continue;
      }
      final t = q / p;
      if (p < 0) {
        if (t > to) return null;
        if (t > from) from = t;
      } else {
        if (t < from) return null;
        if (t < to) to = t;
      }
    }
    return (start + along * from, start + along * to);
  }

  /// Masks and definitions are never drawn as they are.
  static bool _isDefinition(XmlElement element) {
    for (XmlNode? at = element; at is XmlElement; at = at.parent) {
      if (const {'mask', 'defs', 'clipPath'}.contains(at.name.local)) {
        return true;
      }
    }
    return false;
  }

  static String? _colour(XmlElement element, String attribute) =>
      element.getAttribute(attribute)?.toUpperCase();

  static double _number(XmlElement element, String attribute) =>
      double.parse(element.getAttribute(attribute)!);

  /// Where a point of the artwork is drawn, in world units: the artwork fits
  /// the map's area, which is centred in the world, as the canvas draws it.
  static Offset Function(Offset) _projection(String? viewBox) {
    final box = viewBox!.trim().split(RegExp(r'[\s,]+')).map(double.parse);
    final [left, top, width, height] = box.toList();
    const worldHeight = CoordinateSystem.worldHeight;
    const mapWidth = worldHeight * CoordinateSystem.defaultMapAspectRatio;
    const worldWidth = worldHeight * 16 / 9;
    final scale = math.min(mapWidth / width, worldHeight / height);
    final origin = Offset(
      (worldWidth - mapWidth) / 2 + (mapWidth - width * scale) / 2,
      (worldHeight - height * scale) / 2,
    );
    return (point) => origin + Offset(point.dx - left, point.dy - top) * scale;
  }
}

/// Collects a drawing's lines, curves as short straight pieces.
class _LineCollector extends PathProxy {
  final segments = <(Offset, Offset)>[];
  Offset _at = Offset.zero;
  Offset _start = Offset.zero;

  @override
  void moveTo(double x, double y) => _at = _start = Offset(x, y);

  @override
  void lineTo(double x, double y) {
    final to = Offset(x, y);
    if (to != _at) segments.add((_at, to));
    _at = to;
  }

  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    final from = _at;
    const pieces = 8;
    for (var piece = 1; piece <= pieces; piece++) {
      final t = piece / pieces;
      final u = 1 - t;
      lineTo(
        u * u * u * from.dx +
            3 * u * u * t * x1 +
            3 * u * t * t * x2 +
            t * t * t * x3,
        u * u * u * from.dy +
            3 * u * u * t * y1 +
            3 * u * t * t * y2 +
            t * t * t * y3,
      );
    }
  }

  @override
  void close() => lineTo(_start.dx, _start.dy);

  void circle(double x, double y, double radius) {
    const pieces = 24;
    moveTo(x + radius, y);
    for (var piece = 1; piece <= pieces; piece++) {
      final angle = piece / pieces * 2 * math.pi;
      lineTo(x + radius * math.cos(angle), y + radius * math.sin(angle));
    }
  }
}
