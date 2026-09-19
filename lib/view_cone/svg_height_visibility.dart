import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'svg_ground_height.dart';
import 'svg_height_native.dart';
import 'svg_floor_visibility.dart';

/// Offline SVG ink footprints with vertical bands above connected local ground.
/// Ground slopes are not geometry here. The caller clips the result to SVG fill.
class SvgHeightVisibility {
  SvgHeightVisibility._(
      this.walls,
      this.supports,
      this.receivers,
      this.defaultCameraHeightMeters,
      this.cellSize,
      this.ground,
      this.requiresPhysicalGround,
      this.sightlineFloors) {
    for (var wall = 0; wall < walls.length; wall++) {
      for (final ring in walls[wall].rings) {
        final points = _runtimeRing(ring);
        for (var i = 0; i < points.length; i++) {
          final a = points[i], b = points[(i + 1) % points.length];
          if (a == b) continue;
          final edge = _Edge(a, b, wall);
          _edges.add(edge);
        }
      }
    }
    _tree = _edges.isEmpty
        ? null
        : _EdgeNode.build(_edges, List.generate(_edges.length, (i) => i));
  }

  factory SvgHeightVisibility.fromJson(Map<String, dynamic> json) {
    final physicalGround = json['version'] == 3;
    final sourceElevations = (json['version'] == 2 || physicalGround) &&
        json['verticalSpace'] == 'meters-source-elevation';
    final legacyRelative = json['version'] == 1 &&
        json['verticalSpace'] == 'meters-above-local-floor';
    if ((!sourceElevations && !legacyRelative) ||
        json['coordinateSpace'] != 'svg' ||
        (sourceElevations && json['ground'] == null)) {
      throw const FormatException('Unsupported SVG height visibility data.');
    }
    if (physicalGround && _map(json['ground'])['standingTriangles'] is! List) {
      throw const FormatException(
          'Physical ground eligibility must be explicit.');
    }
    final walls = <SvgHeightWall>[];
    final supports = <SvgHeightSupport>[];
    final receivers = <SvgHeightReceiver>[];
    final wallIds = <String>{}, supportIds = <String>{};
    for (final raw in _list(json['walls'], 'walls')) {
      final row = _map(raw);
      final id = _id(row);
      if (sourceElevations && row['floorElevationMeters'] == null) {
        throw FormatException('Missing source floor for $id.');
      }
      if (!wallIds.add(id)) throw FormatException('Duplicate wall $id.');
      final bands = <SvgHeightBand>[];
      for (final rawBand in _list(row['bands'], 'bands')) {
        final band = _list(rawBand, 'band');
        if (band.length != 2)
          throw const FormatException('Invalid height band.');
        final bottom = _number(band[0], 'band bottom');
        final top =
            band[1] == null ? double.infinity : _number(band[1], 'band top');
        if (top <= bottom) throw const FormatException('Reversed height band.');
        bands.add(SvgHeightBand(bottom, top));
      }
      if (row['unknownHeight'] is! bool) {
        throw const FormatException('Wall height confidence must be explicit.');
      }
      walls.add(SvgHeightWall._(
          id,
          _rings(row),
          _evenOdd(row),
          bands,
          row['unknownHeight'] as bool,
          _optionalNumber(row['floorElevationMeters'], 'wall floor')));
    }
    for (final raw in _list(json['supports'] ?? [], 'supports')) {
      final row = _map(raw);
      final id = _id(row);
      if (!supportIds.add(id)) throw FormatException('Duplicate support $id.');
      final height = _number(row['heightAboveFloorMeters'], 'support height');
      final floor =
          _optionalNumber(row['floorElevationMeters'], 'support floor');
      final surface =
          _optionalNumber(row['surfaceElevationMeters'], 'support surface');
      if (floor != null &&
          surface != null &&
          (floor + height - surface).abs() > 1e-6) {
        throw FormatException('Inconsistent support elevation for $id.');
      }
      final label = row['label'];
      if (label != null && (label is! String || label.trim().isEmpty)) {
        throw FormatException('Invalid support label for $id.');
      }
      final automatic = row['automaticStandingAllowed'] ?? false;
      if (automatic is! bool) {
        throw FormatException(
            'Invalid automatic standing eligibility for $id.');
      }
      final rawPlane = row['surfacePlane'];
      List<double>? plane;
      if (rawPlane != null) {
        final values = _list(rawPlane, 'support surface plane');
        if (!sourceElevations || values.length != 3 || surface == null) {
          throw FormatException('Invalid surface plane for $id.');
        }
        plane = List.unmodifiable([
          for (final value in values)
            _number(value, 'surface plane coefficient')
        ]);
      }
      supports.add(SvgHeightSupport._(id, _rings(row), _evenOdd(row), height,
          label as String?, floor, surface, automatic, plane));
    }
    for (final raw in _list(json['receiver'] ?? [], 'receiver')) {
      final row = _map(raw);
      receivers.add(SvgHeightReceiver._(_rings(row), _evenOdd(row)));
    }
    final camera =
        _number(json['defaultCameraHeightMeters'] ?? 1.75, 'camera height');
    final cellSize = _number(json['cellSizeSvg'] ?? 16, 'cell size');
    if (camera <= 0 || cellSize <= 0) {
      throw const FormatException(
          'Camera height and cell size must be positive.');
    }
    final sightlineFloors = <SvgHeightSupport>[];
    final targetIds = <String>{};
    for (final raw in _list(json['sightlineFloorSupportIds'] ?? [],
        'sightline floor support ids')) {
      if (!physicalGround || raw is! String || !targetIds.add(raw)) {
        throw const FormatException('Invalid sightline floor reference.');
      }
      final matches = supports.where((support) => support.id == raw);
      if (matches.length != 1) {
        throw FormatException('Missing sightline floor $raw.');
      }
      final support = matches.single;
      if (!support.automaticStandingAllowed ||
          support.surfaceElevationMeters == null ||
          (support.surfacePlane != null &&
              (support.surfacePlane![0] != 0 ||
                  support.surfacePlane![1] != 0))) {
        throw FormatException(
            'Sightline floor $raw must be measured and horizontal.');
      }
      sightlineFloors.add(support);
    }
    return SvgHeightVisibility._(
        List.unmodifiable(walls),
        List.unmodifiable(supports),
        List.unmodifiable(receivers),
        camera,
        cellSize,
        json['ground'] == null
            ? null
            : SvgGroundHeight.fromJson(_map(json['ground'])),
        physicalGround,
        List.unmodifiable(sightlineFloors));
  }

  final List<SvgHeightWall> walls;
  final List<SvgHeightSupport> supports;
  final List<SvgHeightReceiver> receivers;
  final double defaultCameraHeightMeters, cellSize;
  final SvgGroundHeight? ground;
  final bool requiresPhysicalGround;
  final List<SvgHeightSupport> sightlineFloors;
  late final _floorPaths = [
    for (final floor in sightlineFloors) _footprintPath(floor)
  ];
  late final _floorOccluders = [
    for (final wall in walls)
      SvgFloorOccluder(wall.rings, wall.evenOdd, [
        if (wall.unknownHeight)
          (double.negativeInfinity, double.infinity)
        else
          for (final band in wall.bands)
            (
              band.bottom == 0 && wall.floorElevationMeters != null
                  ? double.negativeInfinity
                  : (wall.floorElevationMeters ?? 0) + band.bottom,
              (wall.floorElevationMeters ?? 0) + band.top
            )
      ])
  ];
  final _edges = <_Edge>[];
  _EdgeNode? _tree;
  SvgHeightNative? _native;

  // A dragged cone asks for the same eye height frame after frame; the wall
  // activity mask only depends on that height. Callers read it, never write.
  double? _activeEye;
  List<bool>? _activeWalls;
  List<bool> _activeWallsAt(double eye) {
    if (_activeEye == eye && _activeWalls != null) return _activeWalls!;
    final active = List<bool>.unmodifiable([for (final wall in walls) wall.blocks(eye)]);
    _activeEye = eye;
    _activeWalls = active;
    return active;
  }
  // Static SVG topology, computed only if the Dart fallback is used.
  late final _crossings = _findCrossings();

  List<(Offset, int, int)> _findCrossings() {
    double cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
    final result = <(Offset, int, int)>[];
    final candidates = <int>[];
    for (var i = 0; i < _edges.length; i++) {
      final a = _edges[i], delta = a.b - a.a;
      candidates.clear();
      _tree?.query(Rect.fromPoints(a.a, a.b), candidates);
      for (final j in candidates) {
        if (j <= i) continue;
        final b = _edges[j], other = b.b - b.a;
        final determinant = cross(delta, other);
        if (determinant == 0) continue;
        final relative = b.a - a.a;
        final t = cross(relative, other) / determinant;
        final u = cross(relative, delta) / determinant;
        if (t > 0 && t < 1 && u > 0 && u < 1) {
          result.add((a.a + delta * t, a.wall, b.wall));
        }
      }
    }
    return result;
  }

  bool get usesNativeAcceleration => _native != null;

  /// Height selection and SVG footprints remain owned by this model. Native
  /// acceleration executes the same two-dimensional edge query only.
  bool enableNativeAcceleration({String? libraryPath}) {
    if (_native != null) return true;
    if (walls.any((wall) => wall.unknownHeight)) return false;
    _native = SvgHeightNative.tryOpen(
        wallIds: [for (final wall in walls) wall.id],
        edgeRecords: Float64List.fromList([
          for (final edge in _edges) ...[
            edge.a.dx,
            edge.a.dy,
            edge.b.dx,
            edge.b.dy,
            edge.wall.toDouble()
          ]
        ]),
        libraryPath: libraryPath);
    return _native != null;
  }

  void closeNativeAcceleration() {
    _native?.close();
    _native = null;
  }

  int get runtimeEdgeCount => _edges.length;

  /// Lists choices without silently selecting the highest overlapping surface.
  List<SvgHeightSupport> supportsAt(Offset point) => supports
      .where((support) => support.contains(point))
      .toList(growable: false);

  /// How far beneath a clear reference floor an automatic support may sit
  /// without meeting the ground anywhere. A room under a bridge meets the
  /// reference floor at its doorway; Fracture's void mesh never does.
  static const double buriedSupportMeters = 3;
  static const double _groundMeetingMeters = 1;
  final _meetsGroundCache = <String, bool>{};

  /// True when the reference ground comes within a metre of the support's
  /// surface somewhere on or beside its footprint: the level is walked onto,
  /// not buried. Ground vertices are checked inside the footprint and the
  /// reference is sampled along the footprint's edges, so a room under a
  /// bridge is found at its doorway while a void far below never matches.
  bool _meetsGround(SvgHeightSupport support) {
    final field = ground;
    if (field == null) return true;
    return _meetsGroundCache.putIfAbsent(support.id, () {
      final bounds = support.bounds;
      for (final (position, height) in field.vertices) {
        if (!bounds.contains(position)) continue;
        final surface = support.surfaceElevationAt(position);
        if (surface == null ||
            (height - surface).abs() > _groundMeetingMeters ||
            !support.contains(position)) continue;
        return true;
      }
      for (final ring in support.rings) {
        for (var i = 0; i < ring.length; i++) {
          final a = ring[i], b = ring[(i + 1) % ring.length];
          final edge = b - a;
          final length = edge.distance;
          if (length == 0) continue;
          final normal = Offset(-edge.dy, edge.dx) / length;
          final steps = math.max(1, length.ceil());
          for (var step = 0; step <= steps; step++) {
            final along = a + edge * (step / steps);
            for (final sign in const [0.3, -0.3]) {
              final p = along + normal * sign;
              final surface = support.surfaceElevationAt(p);
              final reference = field.heightAt(p);
              if (surface != null &&
                  reference != null &&
                  (reference - surface).abs() <= _groundMeetingMeters) {
                return true;
              }
            }
          }
        }
      }
      return false;
    });
  }

  /// Choose among supports verified as physically standable, including boosts.
  /// A support is local to its footprint; the highest face elsewhere on the
  /// same source object says nothing about the standing height at this point.
  SvgHeightSupport? automaticSupportAt(Offset point) {
    var elevation = requiresPhysicalGround
        ? ground?.standingHeightAt(point) ?? double.negativeInfinity
        : ground?.heightAt(point) ?? 0.0;
    final localWalls = walls.where((wall) => wall.contains(point)).toList();
    bool clearEye(double floor) => !localWalls
        .any((wall) => wall.blocks(floor + defaultCameraHeightMeters));
    // Interpolated ground can cross a raised wall at a stacked passage. That
    // blocked height must not hide a verified physical floor beneath it.
    if (ground != null && !clearEye(elevation)) {
      elevation = double.negativeInfinity;
    }
    // An uncertified reference floor still says where the ground is. A
    // measured surface far beneath it (Fracture's void mesh, Breeze's pit)
    // is not where the player stands unless the reference eye is walled in,
    // as at a passage under a bridge.
    final reference = ground?.heightAt(point);
    final floorLimit = reference != null && clearEye(reference)
        ? reference - buriedSupportMeters
        : double.negativeInfinity;
    SvgHeightSupport? selected;
    for (final support in supportsAt(point)) {
      if (!support.automaticStandingAllowed) continue;
      final height = ground == null
          ? support.heightAboveFloorMeters
          : support.surfaceElevationAt(point);
      if (height != null &&
          height > elevation &&
          (height >= floorLimit || _meetsGround(support)) &&
          clearEye(height)) {
        elevation = height;
        selected = support;
      }
    }
    return selected;
  }

  double? groundEyeElevationAt(Offset point) {
    final floor = ground?.heightAt(point);
    return floor == null ? null : floor + defaultCameraHeightMeters;
  }

  bool isGroundEyeElevation(Offset point, double? elevationCm) {
    if (requiresPhysicalGround) {
      final level = _savedLevelAt(point, elevationCm, toleranceCm: 2);
      return level != null && level.support == null;
    }
    final eye = groundEyeElevationAt(point);
    return eye != null &&
        elevationCm != null &&
        (eye * 100 - elevationCm).abs() <= .01;
  }

  /// Explicit saved levels remain selectable, including the lower ground.
  /// An unset or no-longer-applicable saved height uses the gameplay default.
  SvgHeightSupport? standingSupportAt(Offset point,
      {double? savedEyeElevationCm}) {
    if (requiresPhysicalGround) {
      final level = _savedLevelAt(point, savedEyeElevationCm, toleranceCm: 2);
      if (level != null) return level.support;
      return automaticSupportAt(point);
    }
    final explicit = supportForAbsoluteEyeElevation(point, savedEyeElevationCm);
    if (explicit != null) return explicit;
    if (isGroundEyeElevation(point, savedEyeElevationCm)) return null;
    return automaticSupportAt(point);
  }

  bool receiverContains(Offset point) =>
      receivers.any((receiver) => receiver.contains(point));

  /// Resolves the existing persisted absolute eye elevation to one explicit
  /// support. Measured data selects the closest local level within its source
  /// tolerance, including ground. Equally close different levels are unresolved.
  /// Earlier data retains its original exact-match behavior.
  SvgHeightSupport? supportForAbsoluteEyeElevation(
      Offset point, double? elevationCm,
      {double? toleranceCm}) {
    if (requiresPhysicalGround) {
      return _savedLevelAt(point, elevationCm, toleranceCm: toleranceCm ?? 2)
          ?.support;
    }
    final tolerance = toleranceCm ?? .01;
    if (elevationCm == null || !elevationCm.isFinite || tolerance < 0) {
      return null;
    }
    final matches = supportsAt(point).where((support) {
      final surface = support.surfaceElevationAt(point);
      return surface != null &&
          (surface * 100 + defaultCameraHeightMeters * 100 - elevationCm)
                  .abs() <=
              tolerance;
    }).toList(growable: false);
    if (matches.isEmpty) return null;
    final surface = matches.first.surfaceElevationAt(point);
    if (matches
        .any((support) => support.surfaceElevationAt(point) != surface)) {
      return null;
    }
    return matches.first;
  }

  ({SvgHeightSupport? support, double surface})? _savedLevelAt(
      Offset point, double? elevationCm,
      {required double toleranceCm}) {
    if (elevationCm == null ||
        !elevationCm.isFinite ||
        !toleranceCm.isFinite ||
        toleranceCm < 0) return null;
    ({SvgHeightSupport? support, double surface})? closest;
    var closestError = double.infinity;
    var ambiguous = false;
    void consider(double? surface, SvgHeightSupport? support) {
      if (surface == null || !surface.isFinite) return;
      final error =
          (surface * 100 + defaultCameraHeightMeters * 100 - elevationCm).abs();
      if (error > toleranceCm) return;
      if (error < closestError - 1e-6) {
        closest = (support: support, surface: surface);
        closestError = error;
        ambiguous = false;
      } else if ((error - closestError).abs() <= 1e-6 &&
          closest != null &&
          (surface - closest!.surface).abs() > 1e-8) {
        ambiguous = true;
      }
    }

    for (final support in supportsAt(point)) {
      consider(support.surfaceElevationAt(point), support);
    }
    consider(ground?.heightAt(point), null);
    return ambiguous ? null : closest;
  }

  double selectedSupportHeight(Offset origin, String id) {
    for (final support in supports) {
      if (support.id != id) continue;
      if (!support.contains(origin)) {
        throw ArgumentError('Selected support does not contain the observer.');
      }
      return support.heightAboveFloorMeters;
    }
    throw ArgumentError.value(id, 'supportId', 'Unknown support.');
  }

  SvgVisibilityHit? castRay({
    required Offset origin,
    required double directionRadians,
    required double range,
    double? cameraHeightMeters,
    double supportHeightAboveFloorMeters = 0,
    String? supportId,
    double? absoluteEyeElevationMeters,
  }) {
    _validateQuery(origin, directionRadians, range);
    final eye = _eye(origin, cameraHeightMeters, supportHeightAboveFloorMeters,
        supportId, absoluteEyeElevationMeters);
    final active = _activeWallsAt(eye);
    final stats = _Counters();
    final inside = _insideWall(origin, active);
    if (inside != null) return _hit(origin, Offset.zero, 0, inside);
    return _cast(
        origin,
        Offset(math.cos(directionRadians), math.sin(directionRadians)),
        range,
        active,
        stats);
  }

  /// Adds rays at footprint vertices as well as the range arc, so a straight
  /// wall and its corners do not depend on a coarse, fixed angular sample grid.
  SvgVisibilityCone cone({
    required Offset origin,
    required double directionRadians,
    required double range,
    required double apertureRadians,
    double? cameraHeightMeters,
    double supportHeightAboveFloorMeters = 0,
    String? supportId,
    double? absoluteEyeElevationMeters,
    int arcSteps = 96,
  }) {
    final timer = Stopwatch()..start();
    final base = _horizontalCone(
        origin: origin,
        directionRadians: directionRadians,
        range: range,
        apertureRadians: apertureRadians,
        cameraHeightMeters: cameraHeightMeters,
        supportHeightAboveFloorMeters: supportHeightAboveFloorMeters,
        supportId: supportId,
        absoluteEyeElevationMeters: absoluteEyeElevationMeters,
        arcSteps: arcSteps);
    if (sightlineFloors.isEmpty || base.polygon.length < 3) return base;
    final eye = base.eyeElevationMeters!;
    Path? visibility;
    Path? sector;
    for (var i = 0; i < sightlineFloors.length; i++) {
      final targetEye = sightlineFloors[i].surfaceElevationMeters! +
          (cameraHeightMeters ?? defaultCameraHeightMeters);
      if (targetEye == eye) continue;
      final floor = _floorPaths[i];
      if (!floor
          .getBounds()
          .overlaps(Rect.fromCircle(center: origin, radius: range))) {
        continue;
      }
      sector ??= Path()
        ..addPolygon([
          origin,
          for (var step = 0; step <= arcSteps; step++)
            origin +
                Offset(
                        math.cos(directionRadians -
                            apertureRadians / 2 +
                            apertureRadians * step / arcSteps),
                        math.sin(directionRadians -
                            apertureRadians / 2 +
                            apertureRadians * step / arcSteps)) *
                    range
        ], true);
      if (Path.combine(PathOperation.intersect, floor, sector)
          .getBounds()
          .isEmpty) {
        continue;
      }
      final visible = visibleSvgFloor(
          floor: floor,
          sector: sector,
          origin: origin,
          observerEye: eye,
          targetEye: targetEye,
          walls: _floorOccluders);
      visibility ??= Path()..addPolygon(base.polygon, true);
      visibility = Path.combine(PathOperation.union,
          Path.combine(PathOperation.difference, visibility, floor), visible);
    }
    if (visibility == null) return base;
    final stats = base.stats;
    return SvgVisibilityCone(
        base.polygon,
        base.eyeHeightAboveFloorMeters,
        SvgVisibilityStats(stats.rayCount, stats.edgeTests, stats.spatialNodes,
            stats.unknownWallHits, timer.elapsedMicroseconds,
            preparationMicros: stats.preparationMicros,
            candidateMicros: stats.candidateMicros,
            nativeMicros: stats.nativeMicros),
        eyeElevationMeters: eye,
        visibilityPath: visibility);
  }

  SvgVisibilityCone _horizontalCone({
    required Offset origin,
    required double directionRadians,
    required double range,
    required double apertureRadians,
    double? cameraHeightMeters,
    double supportHeightAboveFloorMeters = 0,
    String? supportId,
    double? absoluteEyeElevationMeters,
    int arcSteps = 96,
  }) {
    _validateQuery(origin, directionRadians, range);
    if (!apertureRadians.isFinite ||
        apertureRadians <= 0 ||
        apertureRadians > math.pi * 2 ||
        arcSteps < 1 ||
        arcSteps > 4096) {
      throw ArgumentError('Invalid cone aperture or arc steps.');
    }
    final timer = Stopwatch()..start();
    final eye = _eye(origin, cameraHeightMeters, supportHeightAboveFloorMeters,
        supportId, absoluteEyeElevationMeters);
    final active = _activeWallsAt(eye);
    final stats = _Counters();
    final inside = _insideWall(origin, active);
    if (inside != null || range == 0) {
      return SvgVisibilityCone(
          [origin],
          eye - (ground?.heightAt(origin) ?? 0),
          SvgVisibilityStats(
              0,
              0,
              0,
              inside != null && walls[inside].unknownHeight ? 1 : 0,
              timer.elapsedMicroseconds),
          eyeElevationMeters: ground == null ? null : eye);
    }
    final native = _native;
    if (native != null) {
      final result = native.query(
          origin: origin,
          directionRadians: directionRadians,
          range: range,
          apertureRadians: apertureRadians,
          activeWalls: active,
          arcSteps: arcSteps);
      return SvgVisibilityCone.packed(
          result.xy,
          eye - (ground?.heightAt(origin) ?? 0),
          SvgVisibilityStats(result.rayCount, result.edgeTests,
              result.spatialNodes, 0, timer.elapsedMicroseconds,
              preparationMicros: result.preparationMicros.round(),
              candidateMicros: result.candidateMicros.round(),
              nativeMicros: result.queryMicros),
          eyeElevationMeters: ground == null ? null : eye);
    }
    final half = apertureRadians / 2;
    final angles = <double>{
      for (var i = 0; i <= arcSteps; i++)
        -half + apertureRadians * i / arcSteps,
    };
    final arcAngles = [
      for (var i = 0; i <= arcSteps; i++) -half + apertureRadians * i / arcSteps
    ];
    final arcHits = <SvgVisibilityHit?>[
      for (final angle in arcAngles)
        _cast(
            origin,
            Offset(math.cos(directionRadians + angle),
                math.sin(directionRadians + angle)),
            range,
            active,
            stats),
    ];
    final arcResults = <double, SvgVisibilityHit?>{
      for (var i = 0; i < arcAngles.length; i++) arcAngles[i]: arcHits[i],
    };
    bool hiddenEvent(double angle, Offset delta) {
      if (apertureRadians / arcSteps >= math.pi ||
          angle <= -half ||
          angle >= half) return false;
      final interval = ((angle + half) / apertureRadians * arcSteps)
          .floor()
          .clamp(0, arcSteps - 1);
      final first = arcHits[interval]?._edgeIndex;
      if (first == null ||
          first != arcHits[interval + 1]?._edgeIndex ||
          angle - 1e-8 < arcAngles[interval] ||
          angle + 1e-8 > arcAngles[interval + 1]) return false;
      final distance = delta.distance;
      final hit =
          _edges[first].intersection(origin, delta / distance, distance);
      return hit != null && hit < distance - 1e-7;
    }

    // Overlapping painted strokes create visibility corners at their crossing.
    // Events behind a proven nearer straight wall cannot change the boundary.
    for (final crossing in _crossings) {
      if (!active[crossing.$2] || !active[crossing.$3]) continue;
      final delta = crossing.$1 - origin;
      if (delta.distanceSquared > range * range || delta == Offset.zero)
        continue;
      final relative = math.atan2(delta.dy, delta.dx) - directionRadians;
      final angle = math.atan2(math.sin(relative), math.cos(relative));
      if (hiddenEvent(angle, delta)) continue;
      for (final offset in [-1e-8, 0.0, 1e-8]) {
        if (angle + offset >= -half && angle + offset <= half)
          angles.add(angle + offset);
      }
    }
    final preparationMicros = timer.elapsedMicroseconds;
    final candidates = <int>[];
    _tree?.query(Rect.fromCircle(center: origin, radius: range), candidates);
    final seenPoints = <Offset>{};
    for (final id in candidates) {
      final edge = _edges[id];
      if (!active[edge.wall]) continue;
      // A long wall can cross the range circle without either endpoint being
      // in range. Seed that exact transition so the polygon follows the wall
      // all the way to the circle instead of cutting diagonally short of it.
      final segment = edge.b - edge.a;
      final relative = edge.a - origin;
      final lengthSquared = segment.distanceSquared;
      final projection =
          -(relative.dx * segment.dx + relative.dy * segment.dy) /
              lengthSquared;
      final closest = relative + segment * projection;
      final remaining = range * range - closest.distanceSquared;
      if (remaining >= 0) {
        final offset = math.sqrt(remaining / lengthSquared);
        for (final t in [projection - offset, projection + offset]) {
          if (t < 0 || t > 1) continue;
          final delta = relative + segment * t;
          final relativeAngle =
              math.atan2(delta.dy, delta.dx) - directionRadians;
          final angle =
              math.atan2(math.sin(relativeAngle), math.cos(relativeAngle));
          if (angle >= -half && angle <= half && !hiddenEvent(angle, delta))
            angles.add(angle);
        }
      }
      for (final point in [edge.a, edge.b]) {
        if (!seenPoints.add(point)) continue;
        final delta = point - origin;
        if (delta.distanceSquared > range * range || delta == Offset.zero)
          continue;
        final relativeAngle = math.atan2(delta.dy, delta.dx) - directionRadians;
        final angle =
            math.atan2(math.sin(relativeAngle), math.cos(relativeAngle));
        // If both bounding arc rays hit the same straight segment, that
        // segment covers the angular interval. A vertex strictly behind it
        // cannot change the visible boundary. Nearer corners still add rays.
        if (apertureRadians / arcSteps < math.pi &&
            angle > -half &&
            angle < half) {
          final interval = ((angle + half) / apertureRadians * arcSteps)
              .floor()
              .clamp(0, arcSteps - 1);
          final first = arcHits[interval]?._edgeIndex;
          final last = arcHits[interval + 1]?._edgeIndex;
          if (first != null &&
              first == last &&
              angle - 1e-8 >= arcAngles[interval] &&
              angle + 1e-8 <= arcAngles[interval + 1]) {
            final distance = delta.distance;
            final hit =
                _edges[first].intersection(origin, delta / distance, distance);
            if (hit != null && hit < distance - 1e-7) continue;
          }
        }
        // Adjacent rays resolve the two sides of a corner. They do not offset
        // wall contacts: every endpoint still intersects the actual footprint.
        for (final offset in [-1e-8, 0.0, 1e-8]) {
          final value = angle + offset;
          if (value >= -half && value <= half) angles.add(value);
        }
      }
    }
    final sorted = angles.toList()..sort();
    final candidateMicros = timer.elapsedMicroseconds - preparationMicros;
    final polygon = <Offset>[origin];
    for (final angle in sorted) {
      final direction = Offset(math.cos(directionRadians + angle),
          math.sin(directionRadians + angle));
      final hit = arcResults.containsKey(angle)
          ? arcResults[angle]
          : _cast(origin, direction, range, active, stats);
      polygon.add(hit?.point ?? origin + direction * range);
    }
    return SvgVisibilityCone(
        List.unmodifiable(polygon),
        eye - (ground?.heightAt(origin) ?? 0),
        SvgVisibilityStats(sorted.length, stats.edgeTests, stats.cells,
            stats.unknownHits, timer.elapsedMicroseconds,
            preparationMicros: preparationMicros,
            candidateMicros: candidateMicros),
        eyeElevationMeters: ground == null ? null : eye);
  }

  double _eye(Offset origin, double? camera, double height, String? id,
      double? absolute) {
    final actualCamera = camera ?? defaultCameraHeightMeters;
    if (!actualCamera.isFinite || actualCamera <= 0 || !height.isFinite) {
      throw ArgumentError('Invalid observer height.');
    }
    if (absolute != null) {
      if (!absolute.isFinite || ground == null) {
        throw ArgumentError('Absolute eye elevation requires source ground.');
      }
      return absolute;
    }
    if (ground != null && id != null) {
      selectedSupportHeight(origin, id);
      final support = supports.firstWhere((support) => support.id == id);
      if (support.surfaceElevationMeters == null) {
        throw StateError('Selected support has no source elevation.');
      }
      return support.surfaceElevationAt(origin)! + actualCamera;
    }
    final floor = ground?.heightAt(origin);
    if (ground != null && floor == null) {
      throw ArgumentError('Observer is outside the baked ground domain.');
    }
    return (floor ?? 0) +
        actualCamera +
        (id == null ? height : selectedSupportHeight(origin, id));
  }

  int? _insideWall(Offset origin, List<bool> active) {
    for (var i = 0; i < walls.length; i++) {
      if (active[i] && walls[i].contains(origin)) return i;
    }
    return null;
  }

  SvgVisibilityHit _hit(
          Offset origin, Offset direction, double distance, int wall,
          [int? edgeIndex]) =>
      SvgVisibilityHit(origin + direction * distance, distance, walls[wall].id,
          walls[wall].unknownHeight, edgeIndex);

  SvgVisibilityHit? _cast(Offset origin, Offset direction, double range,
      List<bool> active, _Counters stats) {
    final tree = _tree;
    if (tree == null || range == 0) return null;
    var best = range;
    int? wall, bestEdge;
    final stack = <_EdgeNode>[tree];
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      stats.cells++;
      if (node.entry(origin, direction, best) == null) continue;
      final ids = node.ids;
      if (ids != null) {
        for (final id in ids) {
          final edge = _edges[id];
          if (!active[edge.wall]) continue;
          stats.edgeTests++;
          final distance = edge.intersection(origin, direction, best);
          if (distance != null && (distance < best || wall == null)) {
            best = distance;
            wall = edge.wall;
            bestEdge = id;
          }
        }
      } else {
        final left = node.left!, right = node.right!;
        final a = left.entry(origin, direction, best);
        final b = right.entry(origin, direction, best);
        // Visit the nearer branch first so its hit prunes the farther one.
        if (a != null && b != null) {
          if (a <= b) {
            stack.add(right);
            stack.add(left);
          } else {
            stack.add(left);
            stack.add(right);
          }
        } else if (a != null) {
          stack.add(left);
        } else if (b != null) {
          stack.add(right);
        }
      }
    }
    if (wall == null) return null;
    if (walls[wall].unknownHeight) stats.unknownHits++;
    return _hit(origin, direction, best, wall, bestEdge);
  }
}

/// Keep authored rings intact. Runtime intersections need only the ends of an
/// exactly straight horizontal/vertical run. Curves and diagonals stay literal.
List<Offset> _runtimeRing(List<Offset> ring) {
  final points = <Offset>[];
  for (final point in ring) {
    if (points.isEmpty || points.last != point) points.add(point);
  }
  if (points.length > 1 && points.first == points.last) points.removeLast();
  bool between(double a, double b, double c) =>
      (a < b && b < c) || (a > b && b > c);
  bool redundant(Offset a, Offset b, Offset c) =>
      (a.dx == b.dx && b.dx == c.dx && between(a.dy, b.dy, c.dy)) ||
      (a.dy == b.dy && b.dy == c.dy && between(a.dx, b.dx, c.dx));
  var changed = true;
  while (changed && points.length > 3) {
    changed = false;
    for (var i = points.length - 1; i >= 0 && points.length > 3; i--) {
      if (redundant(points[(i + points.length - 1) % points.length], points[i],
          points[(i + 1) % points.length])) {
        points.removeAt(i);
        changed = true;
      }
    }
  }
  return points;
}

class SvgHeightBand {
  const SvgHeightBand(this.bottom, this.top);
  final double bottom, top;
  // The top itself is solid. A camera above a box top clears it naturally.
  bool contains(double height) => height >= bottom && height <= top;
}

class SvgHeightWall extends _Footprint {
  SvgHeightWall._(this.id, super.rings, super.evenOdd,
      List<SvgHeightBand> bands, this.unknownHeight, this.floorElevationMeters)
      : bands = List.unmodifiable(bands);
  final String id;
  final List<SvgHeightBand> bands;
  final bool unknownHeight;
  final double? floorElevationMeters;
  bool blocks(double height) {
    if (unknownHeight) return true;
    final relative = height - (floorElevationMeters ?? 0);
    return bands.any((band) =>
        band.contains(relative) ||
        (floorElevationMeters != null && band.bottom == 0 && relative < 0));
  }
}

class SvgHeightSupport extends _Footprint {
  SvgHeightSupport._(
      this.id,
      super.rings,
      super.evenOdd,
      this.heightAboveFloorMeters,
      this.label,
      this.floorElevationMeters,
      this.surfaceElevationMeters,
      this.automaticStandingAllowed,
      this.surfacePlane);
  final String id;
  final double heightAboveFloorMeters;
  final String? label;
  final double? floorElevationMeters, surfaceElevationMeters;
  final List<double>? surfacePlane;

  double? surfaceElevationAt(Offset point) {
    final plane = surfacePlane;
    return plane == null
        ? surfaceElevationMeters
        : plane[0] * point.dx + plane[1] * point.dy + plane[2];
  }

  /// Only explicitly verified standing surfaces can be selected automatically.
  final bool automaticStandingAllowed;

  // Source projection and floor partitioning both use a 1e-8 SVG-unit grid.
  // Their successive rounding can put a shared boundary more than one grid
  // step outside the source position. Admit two steps for support choices;
  // wall and receiver containment still follows their literal footprints.
  @override
  bool contains(Offset point) => _contains(point, 2e-8);
}

class SvgHeightReceiver extends _Footprint {
  SvgHeightReceiver._(super.rings, super.evenOdd);
}

class SvgVisibilityHit {
  const SvgVisibilityHit(
      this.point, this.distance, this.wallId, this.unknownHeight,
      [this._edgeIndex]);
  final int? _edgeIndex;
  final Offset point;
  final double distance;
  final String wallId;
  final bool unknownHeight;
}

class SvgVisibilityCone {
  SvgVisibilityCone(List<Offset> polygon, this.eyeHeightAboveFloorMeters, this.stats,
      {this.eyeElevationMeters, this.visibilityPath})
      : _polygon = polygon,
        xy = null;

  /// A native result keeps its packed x,y doubles. A dragged cone is drawn
  /// straight from them; [polygon] is only materialised when something asks.
  SvgVisibilityCone.packed(Float64List this.xy, this.eyeHeightAboveFloorMeters, this.stats,
      {this.eyeElevationMeters})
      : _polygon = null,
        visibilityPath = null;

  final List<Offset>? _polygon;
  final Float64List? xy;
  late final List<Offset> polygon = _polygon ??
      List.unmodifiable([
        for (var i = 0; i < xy!.length; i += 2) Offset(xy![i], xy![i + 1])
      ]);
  final double eyeHeightAboveFloorMeters;
  final double? eyeElevationMeters;
  final SvgVisibilityStats stats;

  /// Includes projected visibility on explicitly measured destination floors.
  /// The polygon retains the horizontal slice for native-query diagnostics.
  final Path? visibilityPath;

  /// The cone outline under a 4x4 column-major affine [transform], built
  /// without allocating a point object per vertex.
  Path outlinePath(Float64List transform) {
    final path = Path()..fillType = PathFillType.nonZero;
    final points = xy;
    if (points == null) {
      final source = _polygon!;
      for (var i = 0; i < source.length; i++) {
        final p = source[i];
        final x = transform[0] * p.dx + transform[4] * p.dy + transform[12];
        final y = transform[1] * p.dx + transform[5] * p.dy + transform[13];
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
    } else {
      for (var i = 0; i < points.length; i += 2) {
        final x = transform[0] * points[i] + transform[4] * points[i + 1] + transform[12];
        final y = transform[1] * points[i] + transform[5] * points[i + 1] + transform[13];
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
    }
    path.close();
    return path;
  }
}

Path _footprintPath(_Footprint footprint) {
  final path = Path()
    ..fillType =
        footprint.evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
  for (final ring in footprint.rings) {
    path.addPolygon(ring, true);
  }
  return path;
}

class SvgVisibilityStats {
  const SvgVisibilityStats(this.rayCount, this.edgeTests, this.spatialNodes,
      this.unknownWallHits, this.elapsedMicroseconds,
      {this.preparationMicros = 0,
      this.candidateMicros = 0,
      this.nativeMicros = 0});
  final double nativeMicros;
  final int preparationMicros, candidateMicros;
  final int rayCount,
      edgeTests,
      spatialNodes,
      unknownWallHits,
      elapsedMicroseconds;
}

class _Counters {
  int edgeTests = 0, cells = 0, unknownHits = 0;
}

class _Footprint {
  _Footprint(this.rings, this.evenOdd) {
    final points = rings.expand((ring) => ring);
    bounds = Rect.fromLTRB(
        points.map((p) => p.dx).reduce(math.min),
        points.map((p) => p.dy).reduce(math.min),
        points.map((p) => p.dx).reduce(math.max),
        points.map((p) => p.dy).reduce(math.max));
  }
  final List<List<Offset>> rings;
  final bool evenOdd;
  late final Rect bounds;
  bool contains(Offset point) => _contains(point, 0);

  bool _contains(Offset point, double boundaryTolerance) {
    if (point.dx < bounds.left - boundaryTolerance ||
        point.dx > bounds.right + boundaryTolerance ||
        point.dy < bounds.top - boundaryTolerance ||
        point.dy > bounds.bottom + boundaryTolerance) return false;
    var winding = 0;
    for (final ring in rings) {
      for (var i = 0; i < ring.length; i++) {
        final a = ring[i], b = ring[(i + 1) % ring.length];
        final side = _cross(b - a, point - a);
        if ((side == 0 ||
                boundaryTolerance > 0 &&
                    side.abs() <= boundaryTolerance * (b - a).distance) &&
            point.dx >= math.min(a.dx, b.dx) - boundaryTolerance &&
            point.dx <= math.max(a.dx, b.dx) + boundaryTolerance &&
            point.dy >= math.min(a.dy, b.dy) - boundaryTolerance &&
            point.dy <= math.max(a.dy, b.dy) + boundaryTolerance) return true;
        if (a.dy <= point.dy && b.dy > point.dy && side > 0) winding++;
        if (a.dy > point.dy && b.dy <= point.dy && side < 0) winding--;
      }
    }
    return evenOdd ? winding.abs().isOdd : winding != 0;
  }
}

class _Edge {
  const _Edge(this.a, this.b, this.wall);
  final Offset a, b;
  final int wall;
  double? intersection(Offset origin, Offset direction, double range) {
    final edge = b - a, relative = a - origin;
    final determinant = _cross(direction, edge);
    if (determinant == 0) {
      if (_cross(relative, direction) != 0) return null;
      final first = _dot(relative, direction),
          last = _dot(b - origin, direction);
      final entry = math.max(0.0, math.min(first, last));
      return math.max(first, last) >= 0 && entry <= range ? entry : null;
    }
    final distance = _cross(relative, edge) / determinant;
    final along = _cross(relative, direction) / determinant;
    // atan2/sin/cos can put an exact corner a few ulps beyond both adjoining
    // endpoints. Admit endpoint roundoff without moving the supporting line.
    const endpointRoundoff = 1e-12;
    return distance >= 0 &&
            distance <= range &&
            along >= -endpointRoundoff &&
            along <= 1 + endpointRoundoff
        ? distance
        : null;
  }
}

/// A static bounding tree changes only which literal edges are tested.
/// It never approximates an edge or becomes a visibility boundary itself.
class _EdgeNode {
  _EdgeNode(this.bounds, this.ids, this.left, this.right);
  final Rect bounds;
  final List<int>? ids;
  final _EdgeNode? left, right;

  static _EdgeNode build(List<_Edge> edges, List<int> ids) {
    var bounds = Rect.fromPoints(edges[ids.first].a, edges[ids.first].b);
    for (final id in ids.skip(1)) {
      bounds =
          bounds.expandToInclude(Rect.fromPoints(edges[id].a, edges[id].b));
    }
    if (ids.length <= 8) return _EdgeNode(bounds, ids, null, null);
    final horizontal = bounds.width >= bounds.height;
    double center(int id) => horizontal
        ? edges[id].a.dx + edges[id].b.dx
        : edges[id].a.dy + edges[id].b.dy;
    ids.sort((a, b) => center(a).compareTo(center(b)));
    final middle = ids.length ~/ 2;
    return _EdgeNode(bounds, null, build(edges, ids.sublist(0, middle)),
        build(edges, ids.sublist(middle)));
  }

  void query(Rect area, List<int> output) {
    if (bounds.left > area.right ||
        bounds.right < area.left ||
        bounds.top > area.bottom ||
        bounds.bottom < area.top) return;
    if (ids != null) {
      output.addAll(ids!);
    } else {
      left!.query(area, output);
      right!.query(area, output);
    }
  }

  double? entry(Offset origin, Offset direction, double range) {
    var lo = 0.0, hi = range;
    // Broad-phase padding protects exact corner rays from division rounding.
    // Only the unmodified segment intersection determines the actual hit.
    const padding = 1e-10;
    if (direction.dx == 0) {
      if (origin.dx < bounds.left - padding ||
          origin.dx > bounds.right + padding) return null;
    } else {
      final a = (bounds.left - padding - origin.dx) / direction.dx;
      final b = (bounds.right + padding - origin.dx) / direction.dx;
      lo = math.max(lo, math.min(a, b));
      hi = math.min(hi, math.max(a, b));
      if (lo > hi) return null;
    }
    if (direction.dy == 0) {
      if (origin.dy < bounds.top - padding ||
          origin.dy > bounds.bottom + padding) return null;
    } else {
      final a = (bounds.top - padding - origin.dy) / direction.dy;
      final b = (bounds.bottom + padding - origin.dy) / direction.dy;
      lo = math.max(lo, math.min(a, b));
      hi = math.min(hi, math.max(a, b));
      if (lo > hi) return null;
    }
    return lo;
  }
}

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;
double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;
void _validateQuery(Offset origin, double angle, double range) {
  if (!origin.dx.isFinite ||
      !origin.dy.isFinite ||
      !angle.isFinite ||
      !range.isFinite ||
      range < 0) throw ArgumentError('Invalid visibility query.');
}

Map<String, dynamic> _map(Object? value) {
  if (value is! Map) throw const FormatException('Expected an object.');
  return Map<String, dynamic>.from(value);
}

List _list(Object? value, String label) {
  if (value is! List) throw FormatException('Expected $label array.');
  return value;
}

double _number(Object? value, String label) {
  if (value is! num || !value.isFinite)
    throw FormatException('Invalid $label.');
  return value.toDouble();
}

double? _optionalNumber(Object? value, String label) =>
    value == null ? null : _number(value, label);

String _id(Map<String, dynamic> row) {
  final id = row['id'];
  if (id is! String || id.isEmpty)
    throw const FormatException('Missing record ID.');
  return id;
}

bool _evenOdd(Map<String, dynamic> row) {
  final rule = row['fillRule'] ?? 'nonzero';
  if (rule != 'nonzero' && rule != 'evenodd')
    throw const FormatException('Unknown fill rule.');
  return rule == 'evenodd';
}

List<List<Offset>> _rings(Map<String, dynamic> row) {
  final result = <List<Offset>>[];
  for (final raw in _list(row['rings'], 'rings')) {
    final values = _list(raw, 'ring');
    if (values.length < 6 || values.length.isOdd)
      throw const FormatException('Invalid footprint ring.');
    final points = <Offset>[
      for (var i = 0; i < values.length; i += 2)
        Offset(_number(values[i], 'X'), _number(values[i + 1], 'Y')),
    ];
    // Translate near the ring before summing. Absolute SVG coordinates can be
    // hundreds of units while a valid semantic partition is microscopic;
    // summing their absolute cross products can cancel to exactly zero.
    final origin = points.first;
    var area = 0.0;
    for (var i = 0; i < points.length; i++)
      area +=
          _cross(points[i] - origin, points[(i + 1) % points.length] - origin);
    if (area == 0) throw const FormatException('Degenerate footprint ring.');
    result.add(List.unmodifiable(points));
  }
  if (result.isEmpty) throw const FormatException('Empty footprint.');
  return List.unmodifiable(result);
}
