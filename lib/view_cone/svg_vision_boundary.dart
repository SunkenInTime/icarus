import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:path_parsing/path_parsing.dart';
import 'package:xml/xml.dart';

/// Builds line-of-sight walls from the exact base-fill path rendered by the
/// tactical-map SVG. This avoids projecting unrelated game-export coordinates
/// into the hand-cropped map artwork.
class SvgVisionBoundary {
  static const String _mapBaseFill = '#271406';

  static VisionBoundary parse({
    required MapValue map,
    required String source,
  }) {
    final document = XmlDocument.parse(source);
    final root = document.rootElement;
    final viewBox = _parseViewBox(root.getAttribute('viewBox'), map);
    final candidates = root.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'path')
        .where(
          (element) =>
              element.getAttribute('fill')?.toUpperCase() == _mapBaseFill,
        )
        .where((element) => (element.getAttribute('d') ?? '').isNotEmpty)
        .toList();
    if (candidates.isEmpty) {
      throw FormatException('Missing base map path for ${map.name}.');
    }

    // Some maps contain small, separately filled decorations before the main
    // floor path. The main mask is consistently the most detailed base path.
    candidates.sort(
      (left, right) => (right.getAttribute('d') ?? '').length.compareTo(
            (left.getAttribute('d') ?? '').length,
          ),
    );
    final pathElement = candidates.first;
    final collector = _ContourCollector();
    writeSvgPathDataToPath(pathElement.getAttribute('d'), collector);
    final svgContours = collector.finish();
    if (svgContours.isEmpty) {
      throw FormatException('Empty base map path for ${map.name}.');
    }

    final worldContours = List<List<Offset>>.unmodifiable([
      for (final contour in svgContours)
        List<Offset>.unmodifiable([
          for (final point in contour) _project(point, viewBox),
        ]),
    ]);
    final segments = List<VisionSegment>.unmodifiable([
      for (final contour in worldContours)
        for (var index = 1; index < contour.length; index += 1)
          if ((contour[index] - contour[index - 1]).distanceSquared > 1e-9)
            VisionSegment(contour[index - 1], contour[index]),
    ]);
    if (segments.isEmpty) {
      throw FormatException('No base map edges for ${map.name}.');
    }
    final primaryContour = worldContours.reduce(
      (best, candidate) =>
          _signedArea(candidate).abs() > _signedArea(best).abs()
              ? candidate
              : best,
    );
    final alwaysOnSegments = List<VisionSegment>.unmodifiable([
      for (var index = 1; index < primaryContour.length; index += 1)
        if ((primaryContour[index] - primaryContour[index - 1])
                .distanceSquared >
            1e-9)
          VisionSegment(primaryContour[index - 1], primaryContour[index]),
    ]);

    return VisionBoundary(
      segments: segments,
      contours: worldContours,
      alwaysOnSegments: alwaysOnSegments,
      fillRule: pathElement.getAttribute('fill-rule') == 'evenodd'
          ? VisionFillRule.evenOdd
          : VisionFillRule.nonZero,
    );
  }

  static double _signedArea(List<Offset> contour) {
    var area = 0.0;
    for (var index = 1; index < contour.length; index += 1) {
      final previous = contour[index - 1];
      final current = contour[index];
      area += previous.dx * current.dy - current.dx * previous.dy;
    }
    return area / 2;
  }

  static _SvgViewBox _parseViewBox(String? value, MapValue map) {
    final values =
        value?.trim().split(RegExp(r'[\s,]+')).map(double.tryParse).toList();
    if (values == null ||
        values.length != 4 ||
        values.any((value) => value == null) ||
        values[2]! <= 0 ||
        values[3]! <= 0) {
      throw FormatException('Invalid SVG viewBox for ${map.name}.');
    }
    return _SvgViewBox(
      left: values[0]!,
      top: values[1]!,
      width: values[2]!,
      height: values[3]!,
    );
  }

  static Offset _project(Offset point, _SvgViewBox viewBox) {
    const normalizedHeight = 1000.0;
    const mapWidth = normalizedHeight * CoordinateSystem.defaultMapAspectRatio;
    const worldWidth = normalizedHeight * (16 / 9);
    const mapLeft = (worldWidth - mapWidth) / 2;
    final scale = math.min(
      mapWidth / viewBox.width,
      normalizedHeight / viewBox.height,
    );
    final renderedWidth = viewBox.width * scale;
    final renderedHeight = viewBox.height * scale;
    final offset = Offset(
      mapLeft + (mapWidth - renderedWidth) / 2,
      (normalizedHeight - renderedHeight) / 2,
    );
    return offset +
        Offset(point.dx - viewBox.left, point.dy - viewBox.top) * scale;
  }
}

class _SvgViewBox {
  const _SvgViewBox({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;
}

class _ContourCollector extends PathProxy {
  static const double _curveTolerance = 1.5;

  final List<List<Offset>> _contours = [];
  List<Offset>? _current;

  @override
  void moveTo(double x, double y) {
    _finishCurrent();
    _current = [Offset(x, y)];
  }

  @override
  void lineTo(double x, double y) {
    _current ??= [Offset(x, y)];
    final point = Offset(x, y);
    if ((_current!.last - point).distanceSquared > 1e-9) {
      _current!.add(point);
    }
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
    final points = _current;
    if (points == null || points.isEmpty) {
      moveTo(x3, y3);
      return;
    }
    final start = points.last;
    final control1 = Offset(x1, y1);
    final control2 = Offset(x2, y2);
    final end = Offset(x3, y3);
    final controlLength = (control1 - start).distance +
        (control2 - control1).distance +
        (end - control2).distance;
    final steps = (controlLength / _curveTolerance).ceil().clamp(2, 64);
    for (var index = 1; index <= steps; index += 1) {
      final t = index / steps;
      final inverse = 1 - t;
      lineTo(
        inverse * inverse * inverse * start.dx +
            3 * inverse * inverse * t * control1.dx +
            3 * inverse * t * t * control2.dx +
            t * t * t * end.dx,
        inverse * inverse * inverse * start.dy +
            3 * inverse * inverse * t * control1.dy +
            3 * inverse * t * t * control2.dy +
            t * t * t * end.dy,
      );
    }
  }

  @override
  void close() => _finishCurrent();

  List<List<Offset>> finish() {
    _finishCurrent();
    return _contours;
  }

  void _finishCurrent() {
    final points = _current;
    _current = null;
    if (points == null || points.length < 2) return;
    if ((points.last - points.first).distanceSquared > 1e-9) {
      points.add(points.first);
    }
    if (points.length >= 4) _contours.add(points);
  }
}
