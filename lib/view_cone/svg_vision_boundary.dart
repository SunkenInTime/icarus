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
  static const String _mapStructuralStroke = '#B27C40';

  static VisionBoundary parse({
    required MapValue map,
    required String source,
    VisionBoundaryAdditions additions = const VisionBoundaryAdditions(),
    bool isAttack = true,
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
    final svgMaskContours = _collectContours(
      pathElement,
      closeOpenContours: true,
    );
    if (svgMaskContours.isEmpty) {
      throw FormatException('Empty base map path for ${map.name}.');
    }

    final worldMaskContours = List<List<Offset>>.unmodifiable([
      for (final contour in svgMaskContours)
        List<Offset>.unmodifiable([
          for (final point in contour.points) _project(point, viewBox),
        ]),
    ]);
    final maskSegments = List<VisionSegment>.unmodifiable([
      for (final contour in worldMaskContours)
        for (var index = 1; index < contour.length; index += 1)
          if ((contour[index] - contour[index - 1]).distanceSquared > 1e-9)
            VisionSegment(contour[index - 1], contour[index]),
    ]);
    if (maskSegments.isEmpty) {
      throw FormatException('No base map edges for ${map.name}.');
    }
    var primaryIndex = 0;
    for (var index = 1; index < worldMaskContours.length; index += 1) {
      if (_signedArea(worldMaskContours[index]).abs() >
          _signedArea(worldMaskContours[primaryIndex]).abs()) {
        primaryIndex = index;
      }
    }

    final collisionGroups = <VisionCollisionGroup>[];
    for (var index = 0; index < worldMaskContours.length; index += 1) {
      collisionGroups.add(
        VisionCollisionGroup.geometry(
          points: worldMaskContours[index],
          kind: VisionCollisionKind.maskBoundary,
          isClosed: true,
          isOuterBoundary: index == primaryIndex,
          nestingDepth: _nestingDepth(index, primaryIndex, worldMaskContours),
        ),
      );
    }

    final detailElements = root.descendants.whereType<XmlElement>().where(
      (element) =>
          element.name.local == 'path' &&
          element != pathElement &&
          (element.getAttribute('d') ?? '').isNotEmpty &&
          (_hasStructuralStroke(element) ||
              element.getAttribute('fill')?.toUpperCase() == _mapBaseFill),
    );
    final existingKeys = <String>{
      for (final group in collisionGroups)
        for (final segment in group.segments) visionSegmentKey(segment),
    };

    void addDetailGroup(
      List<Offset> svgPoints, {
      String? id,
      required bool isClosed,
      required bool requiresEvidence,
    }) {
      final worldPoints = List<Offset>.unmodifiable([
        for (final point in svgPoints) _project(point, viewBox),
      ]);
      if (worldPoints.length < 2) return;
      VisionCollisionGroup group;
      try {
        group = VisionCollisionGroup.geometry(
          id: id,
          points: worldPoints,
          kind: isClosed
              ? VisionCollisionKind.structuralObstacle
              : VisionCollisionKind.structuralChain,
          isClosed: isClosed,
          requiresEvidence: requiresEvidence,
        );
      } on FormatException {
        return;
      }
      final duplicateCount = group.segments
          .where((segment) => existingKeys.contains(visionSegmentKey(segment)))
          .length;
      if (duplicateCount == group.segments.length) return;
      collisionGroups.add(group);
      existingKeys.addAll(group.segments.map(visionSegmentKey));
    }

    for (final element in detailElements) {
      final isFill =
          element.getAttribute('fill')?.toUpperCase() == _mapBaseFill;
      final collected = _collectContours(element, closeOpenContours: isFill);
      for (final contour in collected) {
        addDetailGroup(
          contour.points,
          isClosed: contour.isClosed || isFill,
          requiresEvidence: !isFill && _strokeRequiresEvidence(element),
        );
      }
    }
    for (final element in root.descendants.whereType<XmlElement>().where(
      (element) =>
          element.name.local != 'path' && _hasStructuralStroke(element),
    )) {
      for (final contour in _primitiveContours(element)) {
        addDetailGroup(
          contour.points,
          isClosed: contour.isClosed,
          requiresEvidence: _strokeRequiresEvidence(element),
        );
      }
    }
    for (final entry in additions.entriesFor(map, isAttack: isAttack)) {
      addDetailGroup(
        [
          for (final point in entry.points)
            Offset(
              viewBox.left + point.dx * viewBox.width,
              viewBox.top + point.dy * viewBox.height,
            ),
        ],
        id: entry.id,
        isClosed: entry.isClosed,
        requiresEvidence: false,
      );
    }

    final collisionSegments = <VisionSegment>[];
    final collisionKeys = <String>{};
    for (final group in collisionGroups) {
      for (final segment in group.segments) {
        if (collisionKeys.add(visionSegmentKey(segment))) {
          collisionSegments.add(segment);
        }
      }
    }
    final outerGroup = collisionGroups.firstWhere(
      (group) => group.isOuterBoundary,
    );

    return VisionBoundary(
      segments: List.unmodifiable(collisionSegments),
      maskSegments: maskSegments,
      contours: worldMaskContours,
      collisionGroups: List.unmodifiable(collisionGroups),
      outerGroupId: outerGroup.id,
      alwaysOnSegments: outerGroup.segments,
      fillRule: pathElement.getAttribute('fill-rule') == 'evenodd'
          ? VisionFillRule.evenOdd
          : VisionFillRule.nonZero,
    );
  }

  static List<_CollectedContour> _collectContours(
    XmlElement element, {
    required bool closeOpenContours,
  }) {
    final collector = _ContourCollector(closeOpenContours: closeOpenContours);
    writeSvgPathDataToPath(element.getAttribute('d'), collector);
    return collector.finish();
  }

  static bool _hasStructuralStroke(XmlElement element) =>
      element.getAttribute('stroke')?.toUpperCase() == _mapStructuralStroke;

  static bool _strokeRequiresEvidence(XmlElement element) {
    final opacity =
        double.tryParse(element.getAttribute('stroke-opacity') ?? '1') ?? 1;
    final width =
        double.tryParse(element.getAttribute('stroke-width') ?? '1') ?? 1;
    final dashArray = element.getAttribute('stroke-dasharray');
    return opacity < 0.5 ||
        width < 0.75 ||
        (dashArray != null && dashArray.toLowerCase() != 'none');
  }

  static List<_CollectedContour> _primitiveContours(XmlElement element) {
    double? number(String name, {double? fallback}) =>
        double.tryParse(element.getAttribute(name) ?? '') ?? fallback;
    final name = element.name.local;
    if (name == 'circle' || name == 'ellipse') {
      final centerX = number('cx', fallback: 0);
      final centerY = number('cy', fallback: 0);
      final radiusX = name == 'circle' ? number('r') : number('rx');
      final radiusY = name == 'circle' ? number('r') : number('ry');
      if (centerX == null ||
          centerY == null ||
          radiusX == null ||
          radiusY == null ||
          radiusX <= 0 ||
          radiusY <= 0) {
        return const [];
      }
      const steps = 32;
      return [
        _CollectedContour(
          List<Offset>.unmodifiable([
            for (var index = 0; index <= steps; index += 1)
              Offset(
                centerX + radiusX * math.cos(math.pi * 2 * index / steps),
                centerY + radiusY * math.sin(math.pi * 2 * index / steps),
              ),
          ]),
          true,
        ),
      ];
    }
    if (name == 'rect') {
      final x = number('x', fallback: 0);
      final y = number('y', fallback: 0);
      final width = number('width');
      final height = number('height');
      if (x == null ||
          y == null ||
          width == null ||
          height == null ||
          width <= 0 ||
          height <= 0) {
        return const [];
      }
      return [
        _CollectedContour(
          List.unmodifiable([
            Offset(x, y),
            Offset(x + width, y),
            Offset(x + width, y + height),
            Offset(x, y + height),
            Offset(x, y),
          ]),
          true,
        ),
      ];
    }
    if (name == 'line') {
      final x1 = number('x1', fallback: 0);
      final y1 = number('y1', fallback: 0);
      final x2 = number('x2', fallback: 0);
      final y2 = number('y2', fallback: 0);
      if (x1 == null || y1 == null || x2 == null || y2 == null) {
        return const [];
      }
      return [
        _CollectedContour(
          List.unmodifiable([Offset(x1, y1), Offset(x2, y2)]),
          false,
        ),
      ];
    }
    if (name == 'polyline' || name == 'polygon') {
      final values = element
          .getAttribute('points')
          ?.trim()
          .split(RegExp(r'[\s,]+'))
          .where((value) => value.isNotEmpty)
          .map(double.tryParse)
          .toList();
      if (values == null ||
          values.length < 4 ||
          values.length.isOdd ||
          values.any((value) => value == null)) {
        return const [];
      }
      final points = <Offset>[
        for (var index = 0; index < values.length; index += 2)
          Offset(values[index]!, values[index + 1]!),
      ];
      final isClosed = name == 'polygon';
      if (isClosed && (points.first - points.last).distanceSquared > 1e-9) {
        points.add(points.first);
      }
      return [_CollectedContour(List.unmodifiable(points), isClosed)];
    }
    return const [];
  }

  static int _nestingDepth(
    int contourIndex,
    int primaryIndex,
    List<List<Offset>> contours,
  ) {
    if (contourIndex == primaryIndex) return 0;
    final contour = contours[contourIndex];
    final probe = contour.first;
    final contourArea = _signedArea(contour).abs();
    var depth = 0;
    for (var index = 0; index < contours.length; index += 1) {
      if (index == contourIndex ||
          _signedArea(contours[index]).abs() <= contourArea) {
        continue;
      }
      if (_pointInContour(probe, contours[index])) depth += 1;
    }
    return depth;
  }

  static bool _pointInContour(Offset point, List<Offset> contour) {
    var inside = false;
    for (var index = 1; index < contour.length; index += 1) {
      final start = contour[index - 1];
      final end = contour[index];
      if ((start.dy > point.dy) == (end.dy > point.dy)) continue;
      final intersectionX =
          start.dx +
          (point.dy - start.dy) * (end.dx - start.dx) / (end.dy - start.dy);
      if (intersectionX > point.dx) inside = !inside;
    }
    return inside;
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
    final values = value
        ?.trim()
        .split(RegExp(r'[\s,]+'))
        .map(double.tryParse)
        .toList();
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

/// Hand-audited collision boundaries authored once in normalized SVG space.
///
/// Shared entries are mirrored onto the defense artwork, so a boundary maps to
/// every Riot elevation and both tactical orientations by default. Elevation
/// exceptions remain explicit and are converted into normal contour overrides.
class VisionBoundaryAdditions {
  const VisionBoundaryAdditions({this.maps = const {}});

  final Map<MapValue, VisionBoundaryAdditionSet> maps;

  bool get isEmpty => maps.isEmpty;

  factory VisionBoundaryAdditions.fromJson(Map<String, dynamic> json) {
    _validateKeys(json, const {'version', 'maps'}, 'boundary additions root');
    if (json['version'] != 1) {
      throw const FormatException(
        'Unsupported vision boundary additions version.',
      );
    }
    final values = json['maps'];
    if (values is! Map<String, dynamic>) {
      throw const FormatException('Vision boundary additions maps is invalid.');
    }
    final mapByName = {
      for (final entry in Maps.mapNames.entries) entry.value: entry.key,
    };
    final result = <MapValue, VisionBoundaryAdditionSet>{};
    for (final entry in values.entries) {
      final map = mapByName[entry.key];
      if (map == null) {
        throw FormatException(
          'Unknown map in vision boundary additions: ${entry.key}.',
        );
      }
      result[map] = VisionBoundaryAdditionSet.fromJson(entry.value);
    }
    return VisionBoundaryAdditions(maps: Map.unmodifiable(result));
  }

  List<VisionBoundaryAddition> entriesFor(
    MapValue map, {
    required bool isAttack,
  }) {
    final additions = maps[map];
    if (additions == null) return const [];
    return List.unmodifiable([
      for (final entry in additions.shared) isAttack ? entry : entry.mirrored(),
      ...(isAttack ? additions.attack : additions.defense),
    ]);
  }

  Map<String, VisionCollisionOverride> overridesFor(
    MapValue map, {
    required bool isAttack,
  }) => Map.unmodifiable({
    for (final entry in entriesFor(map, isAttack: isAttack))
      entry.id: entry.override,
  });

  static void _validateKeys(
    Map<String, dynamic> value,
    Set<String> allowed,
    String context,
  ) {
    final unknown = value.keys.where((key) => !allowed.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException('Unknown $context fields: ${unknown.join(', ')}.');
    }
  }
}

class VisionBoundaryAdditionSet {
  const VisionBoundaryAdditionSet({
    this.shared = const [],
    this.attack = const [],
    this.defense = const [],
  });

  final List<VisionBoundaryAddition> shared;
  final List<VisionBoundaryAddition> attack;
  final List<VisionBoundaryAddition> defense;

  factory VisionBoundaryAdditionSet.fromJson(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid map boundary additions.');
    }
    VisionBoundaryAdditions._validateKeys(value, const {
      'shared',
      'attack',
      'defense',
    }, 'map boundary additions');
    List<VisionBoundaryAddition> decode(String key) {
      final entries = value[key];
      if (entries == null) return const [];
      if (entries is! List) {
        throw FormatException('$key boundary additions must be a list.');
      }
      return List.unmodifiable([
        for (final entry in entries) VisionBoundaryAddition.fromJson(entry),
      ]);
    }

    final result = VisionBoundaryAdditionSet(
      shared: decode('shared'),
      attack: decode('attack'),
      defense: decode('defense'),
    );
    void validateUnique(
      List<VisionBoundaryAddition> common,
      List<VisionBoundaryAddition> side,
      String sideName,
    ) {
      final ids = <String>{};
      for (final entry in [...common, ...side]) {
        if (!ids.add(entry.id)) {
          throw FormatException(
            'Duplicate $sideName vision boundary addition id ${entry.id}.',
          );
        }
      }
    }

    validateUnique(result.shared, result.attack, 'attack');
    validateUnique(result.shared, result.defense, 'defense');
    return result;
  }
}

class VisionBoundaryAddition {
  const VisionBoundaryAddition({
    required this.id,
    required this.label,
    required this.points,
    required this.isClosed,
    this.activeElevations,
    this.inactiveElevations = const [],
    this.observerPassableElevations,
  });

  final String id;
  final String label;
  final List<Offset> points;
  final bool isClosed;
  final List<double>? activeElevations;
  final List<double> inactiveElevations;
  final List<double>? observerPassableElevations;

  VisionCollisionOverride get override => VisionCollisionOverride(
    enabled: true,
    activeElevations: activeElevations,
    inactiveElevations: inactiveElevations,
    observerPassableElevations: observerPassableElevations,
  );

  factory VisionBoundaryAddition.fromJson(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid vision boundary addition.');
    }
    VisionBoundaryAdditions._validateKeys(value, const {
      'id',
      'label',
      'points',
      'closed',
      'activeElevations',
      'inactiveElevations',
      'observerPassableElevations',
    }, 'vision boundary addition');
    final rawId = value['id'];
    final label = value['label'];
    final rawPoints = value['points'];
    final closed = value['closed'];
    if (rawId is! String ||
        !RegExp(r'^[a-z0-9][a-z0-9_-]{1,63}$').hasMatch(rawId)) {
      throw const FormatException('Invalid vision boundary addition id.');
    }
    if (label is! String || label.trim().isEmpty || label.length > 100) {
      throw const FormatException('Invalid vision boundary addition label.');
    }
    if (rawPoints is! List || rawPoints.length < (closed == true ? 3 : 2)) {
      throw const FormatException(
        'Vision boundary addition has too few points.',
      );
    }
    if (closed is! bool) {
      throw const FormatException('Vision boundary closed must be a boolean.');
    }
    final points = <Offset>[];
    for (final rawPoint in rawPoints) {
      if (rawPoint is! List ||
          rawPoint.length != 2 ||
          rawPoint[0] is! num ||
          rawPoint[1] is! num) {
        throw const FormatException('Invalid vision boundary point.');
      }
      final point = Offset(
        (rawPoint[0] as num).toDouble(),
        (rawPoint[1] as num).toDouble(),
      );
      if (point.dx < 0 || point.dx > 1 || point.dy < 0 || point.dy > 1) {
        throw const FormatException(
          'Vision boundary points must use normalized SVG coordinates.',
        );
      }
      points.add(point);
    }
    List<double>? elevations(String key) {
      final raw = value[key];
      if (raw == null) return null;
      if (raw is! List || raw.any((item) => item is! num)) {
        throw FormatException('$key must contain only numbers.');
      }
      return List.unmodifiable(raw.cast<num>().map((item) => item.toDouble()));
    }

    final active = elevations('activeElevations');
    final inactive = elevations('inactiveElevations') ?? const [];
    if (active != null && active.any(inactive.contains)) {
      throw const FormatException(
        'Vision boundary addition has conflicting elevations.',
      );
    }
    return VisionBoundaryAddition(
      id: 'audit_$rawId',
      label: label.trim(),
      points: List.unmodifiable(points),
      isClosed: closed,
      activeElevations: active,
      inactiveElevations: inactive,
      observerPassableElevations: elevations('observerPassableElevations'),
    );
  }

  VisionBoundaryAddition mirrored() => VisionBoundaryAddition(
    id: id,
    label: label,
    points: List.unmodifiable([
      for (final point in points) Offset(1 - point.dx, 1 - point.dy),
    ]),
    isClosed: isClosed,
    activeElevations: activeElevations,
    inactiveElevations: inactiveElevations,
    observerPassableElevations: observerPassableElevations,
  );
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

class _CollectedContour {
  const _CollectedContour(this.points, this.isClosed);

  final List<Offset> points;
  final bool isClosed;
}

class _ContourCollector extends PathProxy {
  _ContourCollector({required this.closeOpenContours});

  static const double _curveTolerance = 1.5;

  final bool closeOpenContours;
  final List<_CollectedContour> _contours = [];
  List<Offset>? _current;

  @override
  void moveTo(double x, double y) {
    _finishCurrent(isClosed: false);
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
    final controlLength =
        (control1 - start).distance +
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
  void close() => _finishCurrent(isClosed: true);

  List<_CollectedContour> finish() {
    _finishCurrent(isClosed: false);
    return _contours;
  }

  void _finishCurrent({required bool isClosed}) {
    final points = _current;
    _current = null;
    if (points == null || points.length < 2) return;
    final resolvedClosed = isClosed || closeOpenContours;
    if (resolvedClosed && (points.last - points.first).distanceSquared > 1e-9) {
      points.add(points.first);
    }
    if (points.length >= (resolvedClosed ? 4 : 2)) {
      _contours.add(
        _CollectedContour(List.unmodifiable(points), resolvedClosed),
      );
    }
  }
}
