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
      this.sightlineFloors,
      [List<SvgRuntimeWall>? runtimeWalls])
      : runtimeWalls = runtimeWalls ??
            List.unmodifiable([
              for (var i = 0; i < walls.length; i++)
                SvgRuntimeWall._(i, walls[i].rings, walls[i].evenOdd)
            ]) {
    for (final shape in this.runtimeWalls) {
      final sides = shape.sides;
      var k = 0;
      for (final points in shape.edgeRings) {
        for (var i = 0; i < points.length; i++) {
          final a = points[i], b = points[(i + 1) % points.length];
          if (a == b) continue;
          final side = sides[k++];
          _edges.add(_Edge(a, b, shape.wall,
              interior: side == 0
                  ? null
                  : side > 0
                      ? _Side.left
                      : _Side.right));
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
    // Touching pieces with the same heights, merged offline into one outline
    // each: what cones are cast against. The pieces stay the model.
    List<SvgRuntimeWall>? runtimeWalls;
    if (json['runtimeWalls'] != null) {
      final index = {for (var i = 0; i < walls.length; i++) walls[i].id: i};
      final covered = List.filled(walls.length, false);
      runtimeWalls = [];
      for (final raw in _list(json['runtimeWalls'], 'runtimeWalls')) {
        final row = _map(raw);
        // A piece's own edges where its outline does not cover them (a bow
        // tie, a sliver): extra geometry under its heights, not a member.
        if (row['heightsOf'] != null) {
          if (_list(row['walls'] ?? const [], 'walls').isNotEmpty) {
            throw FormatException(
                'Runtime edges of ${row['heightsOf']} also name members.');
          }
          final owner = index[row['heightsOf']] ??
              (throw FormatException(
                  'Runtime edges name missing wall ${row['heightsOf']}.'));
          runtimeWalls.add(SvgRuntimeWall._(owner, _rings(row), _evenOdd(row)));
          continue;
        }
        final members = [
          for (final id in _list(row['walls'], 'runtime wall members'))
            index[id] ??
                (throw FormatException('Runtime wall names missing wall $id.'))
        ];
        if (members.isEmpty) {
          throw const FormatException('Runtime wall has no members.');
        }
        final first = walls[members.first];
        for (final member in members) {
          final wall = walls[member];
          if (covered[member] ||
              wall.floorElevationMeters != first.floorElevationMeters ||
              wall.unknownHeight != first.unknownHeight ||
              !_sameBands(wall.bands, first.bands)) {
            throw FormatException(
                'Runtime wall merges ${wall.id} with different heights.');
          }
          covered[member] = true;
        }
        runtimeWalls
            .add(SvgRuntimeWall._(members.first, _rings(row), _evenOdd(row)));
      }
      if (covered.contains(false)) {
        throw const FormatException('Runtime walls leave a wall out.');
      }
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
        List.unmodifiable(sightlineFloors),
        runtimeWalls == null ? null : List.unmodifiable(runtimeWalls));
  }

  static bool _sameBands(List<SvgHeightBand> a, List<SvgHeightBand> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].bottom != b[i].bottom || a[i].top != b[i].top) return false;
    }
    return true;
  }

  final List<SvgHeightWall> walls;
  final List<SvgHeightSupport> supports;
  final List<SvgHeightReceiver> receivers;
  final double defaultCameraHeightMeters, cellSize;
  final SvgGroundHeight? ground;
  final bool requiresPhysicalGround;
  final List<SvgHeightSupport> sightlineFloors;

  /// The outlines cones are cast against: [walls] themselves, or touching
  /// pieces with the same heights merged into one outline each.
  final List<SvgRuntimeWall> runtimeWalls;

  late final _floorOccluders = [
    for (final shape in runtimeWalls)
      SvgFloorOccluder(shape.edgeRings, shape.evenOdd,
          _absoluteBands(walls[shape.wall]), shape.sides)
  ];

  static List<(double, double)> _absoluteBands(SvgHeightWall wall) => [
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
      ];
  final _edges = <_Edge>[];
  _EdgeNode? _tree;
  SvgHeightNative? _native;

  // A dragged cone asks for the same eye height frame after frame; the wall
  // activity mask only depends on that height. Callers read it, never write.
  double? _activeEye;
  List<bool>? _activeWalls;
  List<bool> _activeWallsAt(double eye) {
    final previous = _activeWalls;
    if (_activeEye == eye && previous != null) return previous;
    _activeEye = eye;
    final active = [for (final wall in walls) wall.blocks(eye)];
    // On a ramp the eye moves every frame while the mask rarely changes;
    // keeping the same list keeps what is cached against it.
    if (previous != null) {
      var same = true;
      for (var i = 0; i < active.length && same; i++) {
        same = active[i] == previous[i];
      }
      if (same) return previous;
    }
    return _activeWalls = List.unmodifiable(active);
  }

  // Static SVG topology, computed only if the Dart fallback is used.
  late final _crossings = _findCrossings();
  late final _topology = _VertexTopology(_edges);

  /// Rays one either side of each vertex ray, resolving the two sides of a
  /// corner; the native query's offset.
  static const _cornerOffset = 1e-8;

  /// Whether no active boundary turns at [vertex]: the edges two touching
  /// pieces share cancel, and what remains runs straight through it, or
  /// nothing does. A ray there meets the wall the rays beside it meet, so it
  /// is not a visibility event. Pieces cut along one stroke leave such seams
  /// every metre or so; skipping them is most of a cone's rays.
  bool _seam(int vertex, List<bool> active) {
    if (!identical(active, _seamMask)) {
      _seamMask = active;
      _seams = Int8List(_topology.points.length);
    }
    final seams = _seams!;
    if (seams[vertex] == 0) seams[vertex] = _findSeam(vertex, active) ? 1 : 2;
    return seams[vertex] == 1;
  }

  // Whether a vertex is a seam depends only on the active walls, which stay
  // the same while a cone is dragged across one floor: 0 not yet known,
  // 1 a seam, 2 not.
  List<bool>? _seamMask;
  Int8List? _seams;

  // Reused by every Dart cone query, so a dragged cone allocates little.
  final _bins = _ConeBins();
  Int32List? _seenVertices;
  var _seenStamp = 0;

  bool _findSeam(int vertex, List<bool> active) {
    final topology = _topology;
    final live = [
      for (final id in topology.edgesAt[vertex])
        if (active[_edges[id].wall]) id
    ];
    final cancelled = List.filled(live.length, false);
    for (var i = 0; i < live.length; i++) {
      for (var j = i + 1; j < live.length && !cancelled[i]; j++) {
        if (cancelled[j]) continue;
        // A shared side only when the two walls lie on either side of it.
        final first = _edges[live[i]], second = _edges[live[j]];
        if (first.interior == null || second.interior == null) continue;
        final same = topology.aVertex[live[i]] == topology.aVertex[live[j]] &&
            topology.bVertex[live[i]] == topology.bVertex[live[j]];
        final reversed =
            topology.aVertex[live[i]] == topology.bVertex[live[j]] &&
                topology.bVertex[live[i]] == topology.aVertex[live[j]];
        if ((same && first.interior != second.interior) ||
            (reversed && first.interior == second.interior)) {
          cancelled[i] = cancelled[j] = true;
        }
      }
    }
    final at = topology.points[vertex];
    final away = [
      for (var i = 0; i < live.length; i++)
        if (!cancelled[i]) _away(live[i], vertex) - at
    ];
    if (away.isEmpty) return true;
    if (away.length != 2) return false;
    return _dot(away[0], away[1]) < 0 &&
        _cross(away[0], away[1]).abs() <=
            1e-12 * away[0].distance * away[1].distance;
  }

  /// Whether the wall runs straight across the ray at [vertex], [delta]
  /// from the origin: its two active edges there leave to either side of the
  /// ray's line. Rays just beside such a vertex meet those two edges, so only
  /// the vertex ray adds a corner. Rays beside the vertex matter where the
  /// wall turns back (a silhouette) and something further can show past it.
  bool _passThrough(int vertex, Offset delta, List<bool> active) {
    final at = _topology.points[vertex];
    var count = 0;
    var first = 0.0;
    for (final id in _topology.edgesAt[vertex]) {
      if (!active[_edges[id].wall]) continue;
      if (++count > 2) return false;
      final side = _cross(delta, _away(id, vertex) - at);
      if (count == 1) {
        first = side;
      } else if (first * side >= 0) {
        return false;
      }
    }
    return count == 2;
  }

  /// The far end of edge [id] from [vertex].
  Offset _away(int id, int vertex) =>
      _topology.aVertex[id] == vertex ? _edges[id].b : _edges[id].a;

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

  /// Builds the wall crossings and topology the Dart cone query reads, which
  /// it would otherwise build on its first cone: a frame-long stall the
  /// first time a cone is dragged on the web.
  void prepareDartQuery() {
    _crossings;
    _topology;
  }

  /// Height selection and SVG footprints remain owned by this model. Native
  /// acceleration executes the same two-dimensional edge query only.
  bool enableNativeAcceleration({String? libraryPath}) {
    if (_native != null) return true;
    if (walls.any((wall) => wall.unknownHeight)) return false;
    _native = SvgHeightNative.tryOpen(
        wallIds: [for (final wall in walls) wall.id],
        interiorSides: Uint8List.fromList([
          for (final edge in _edges)
            switch (edge.interior) {
              _Side.right => 0,
              _Side.left => 1,
              null => 2,
            }
        ]),
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

  /// Where a dragged agent's cone should stand when its centre sits inside
  /// wall ink or just off the painted floor. Wall strokes are drawn wider
  /// than the real wall, so an agent hugging a wall lands in ink several
  /// times per second; hiding the cone there reads as a flicker. The point
  /// is pushed out of every active wall it lies in and onto the floor, by at
  /// most [maxDistance] SVG units. Returns null when no such point exists.
  Offset? standablePointNear(Offset point, {double maxDistance = 2.5}) {
    var current = point;
    for (var step = 0; step < 4; step++) {
      final wall = _blockingWallAt(current);
      if (wall == null &&
          receiverContains(current) &&
          (ground == null || ground!.heightAt(current) != null)) {
        return current;
      }
      Offset? target;
      if (wall != null) {
        // Leave the ink onto open floor within reach. The nearest edge can be
        // a seam with the next piece of the same wall, or face the unplayable
        // side of a building, and stepping across either lands back in ink.
        // Failing that, step across the nearest edge and try again from there.
        target = _steppedAcross(current, wall, _inkClearance,
                reach: maxDistance - (current - point).distance,
                accept: (p) =>
                    (p - point).distance <= maxDistance &&
                    _blockingWallAt(p) == null &&
                    receiverContains(p)) ??
            _steppedAcross(current, wall, _inkClearance);
      } else {
        target = _pulledIn(current, 0.02);
      }
      if (target == null || (target - point).distance > maxDistance)
        return null;
      current = target;
    }
    return null;
  }

  /// How close to blocking ink still counts as in it. Two strokes drawn a
  /// couple of centimetres apart leave a slit no agent stands in; a cone
  /// from inside one is a hairline running down it.
  static const _inkMargin = 0.05;

  /// How far past the ink a nudged agent stands: clear of [_inkMargin].
  static const _inkClearance = 0.06;

  SvgHeightWall? _blockingWallAt(Offset point) {
    // A wall that does not block a standing eye (a kerb, a floor mark) is
    // not something an agent stands inside of.
    double? eye;
    for (final wall in walls) {
      if (!wall._contains(point, _inkMargin)) continue;
      eye ??= (ground?.heightAt(point) ?? 0) + defaultCameraHeightMeters;
      if (wall.blocks(eye)) return wall;
    }
    return null;
  }

  /// The point just inside the nearest floor, across its nearest edge.
  Offset? _pulledIn(Offset point, double clearance) {
    Offset? best;
    var bestDistance = double.infinity;
    for (final receiver in receivers) {
      final inside =
          _steppedAcross(point, receiver, clearance, wantInside: true);
      if (inside == null) continue;
      final d = (inside - point).distance;
      if (d < bestDistance) {
        bestDistance = d;
        best = inside;
      }
    }
    return best;
  }

  /// The nearest point on [footprint]'s boundary, stepped [clearance] to the
  /// side of the edge that the footprint reports as [wantInside]. With
  /// [accept], the nearest such point that [accept] also allows, on any edge
  /// no farther than [reach]. Null when no side satisfies the tests.
  static Offset? _steppedAcross(
      Offset point, _Footprint footprint, double clearance,
      {bool wantInside = false,
      bool Function(Offset)? accept,
      double reach = double.infinity}) {
    final List<int> edges;
    if (accept == null) {
      // The first nearest edge, as before any acceptance test existed.
      final nearest = footprint._nearestEdge(point);
      edges = nearest < 0 ? const [] : [nearest];
    } else {
      // Only edges within reach, usually a handful even on a long wall.
      final feet = <(double, int)>[];
      for (var e = 0; e < footprint._edgeCount; e++) {
        final d = footprint._distanceTo(e, point.dx, point.dy);
        if (d >= 0 && d <= reach) feet.add((d, e));
      }
      feet.sort((a, b) => a.$1.compareTo(b.$1));
      edges = [for (final (_, e) in feet) e];
    }
    for (final e in edges) {
      final (foot, normal) = footprint._footOn(e, point);
      for (final side in [
        foot + normal * clearance,
        foot - normal * clearance
      ]) {
        if (footprint.contains(side) == wantInside &&
            (accept?.call(side) ?? true)) {
          return side;
        }
      }
    }
    return null;
  }

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
  }) =>
      withSightlineFloors(
        horizontalCone(
            origin: origin,
            directionRadians: directionRadians,
            range: range,
            apertureRadians: apertureRadians,
            cameraHeightMeters: cameraHeightMeters,
            supportHeightAboveFloorMeters: supportHeightAboveFloorMeters,
            supportId: supportId,
            absoluteEyeElevationMeters: absoluteEyeElevationMeters,
            arcSteps: arcSteps),
        origin: origin,
        directionRadians: directionRadians,
        range: range,
        apertureRadians: apertureRadians,
        cameraHeightMeters: cameraHeightMeters,
        arcSteps: arcSteps,
      );

  /// Whether [withSightlineFloors] can change a cone at all on this map.
  bool get hasSightlineFloors => sightlineFloors.isNotEmpty;

  /// [base], a [horizontalCone], with the reviewed destination floors it
  /// overlooks cast down to a standing target (see `docs/vision-model.md`).
  /// Uses `dart:ui` path operations, so it runs on the root isolate only.
  SvgVisibilityCone withSightlineFloors(
    SvgVisibilityCone base, {
    required Offset origin,
    required double directionRadians,
    required double range,
    required double apertureRadians,
    double? cameraHeightMeters,
    int arcSteps = 96,
  }) {
    final timer = Stopwatch()..start();
    if (sightlineFloors.isEmpty || base.polygon.length < 3) return base;
    final eye = base.eyeElevationMeters!;
    final reach = Rect.fromCircle(center: origin, radius: range);
    final floors = <SvgFloorLayer>[];
    for (var i = 0; i < sightlineFloors.length; i++) {
      final targetEye = sightlineFloors[i].surfaceElevationMeters! +
          (cameraHeightMeters ?? defaultCameraHeightMeters);
      if (targetEye == eye) continue;
      final floor = sightlineFloors[i];
      final bounds = floor.bounds.intersect(reach);
      if (bounds.width <= 0 || bounds.height <= 0) continue;
      floors.add(SvgFloorLayer(
          floor.rings,
          floor.evenOdd,
          svgFloorShadows(
              bounds: bounds,
              origin: origin,
              observerEye: eye,
              targetEye: targetEye,
              walls: _floorOccluders)));
    }
    if (floors.isEmpty) return base;
    final sector = [
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
    ];
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
        floors: floors,
        sector: sector);
  }

  /// The cone cut by a horizontal sightline at eye height alone. Uses no
  /// `dart:ui` paths, so a worker isolate can run it.
  SvgVisibilityCone horizontalCone({
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
    // Every ray starts at the eye, so the walls near it are filed by the
    // angle they cover (see _ConeBins): a ray tests only the few edges in its
    // bin, and a corner that a nearer wall provably hides casts no rays.
    final half = apertureRadians / 2;
    final whole = half + 1e-6 >= math.pi;
    final bins = _bins;
    bins.file(this, origin, directionRadians, range, active,
        lowest: whole ? -math.pi : -half,
        span: whole ? 2 * math.pi : apertureRadians);

    final angles = <double>[
      for (var i = 0; i <= arcSteps; i++) -half + apertureRadians * i / arcSteps
    ];
    // Rays aimed at a vertex or at a wall's crossing of the range circle
    // stay in the outline even when their neighbours meet the same edge.
    final vertexAngles = <double>[];
    void add(double event, {required bool vertex}) {
      // Behind a full circle, a ray beside the seam wraps round to the
      // other end: -pi and pi are the same direction.
      if (whole && event < -half) event += 2 * math.pi;
      if (whole && event > half) event -= 2 * math.pi;
      if (event < -half || event > half) return;
      angles.add(event);
      if (vertex) vertexAngles.add(event);
    }

    void emit(double angle, {bool beside = true}) {
      if (beside) add(angle - _cornerOffset, vertex: false);
      add(angle, vertex: true);
      if (beside) add(angle + _cornerOffset, vertex: false);
    }

    // Whether an event at [angle] could start a ray in the aperture and is
    // not provably behind a nearer wall.
    bool open(double angle, double distance) {
      if (!whole && (angle < -half - 1e-6 || angle > half + 1e-6)) {
        return false;
      }
      return !bins.hides(angle, distance);
    }

    final rangeSquared = range * range;
    // Overlapping painted strokes create visibility corners at their crossing.
    for (final crossing in _crossings) {
      if (!active[crossing.$2] || !active[crossing.$3]) continue;
      final delta = crossing.$1 - origin;
      final distanceSquared = delta.distanceSquared;
      if (distanceSquared > rangeSquared || delta == Offset.zero) continue;
      final angle = bins.angleOf(delta.dx, delta.dy);
      if (!open(angle, math.sqrt(distanceSquared))) continue;
      emit(angle);
    }
    final preparationMicros = timer.elapsedMicroseconds;
    final topology = _topology;
    final seen = _seenVertices ??= Int32List(topology.points.length);
    final stamp = ++_seenStamp;
    for (var slot = 0; slot < bins.count; slot++) {
      final id = bins.edgeIds[slot];
      final edge = _edges[id];
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
      final remaining = rangeSquared - closest.distanceSquared;
      if (remaining >= 0) {
        final offset = math.sqrt(remaining / lengthSquared);
        for (var end = 0; end < 2; end++) {
          final t = end == 0 ? projection - offset : projection + offset;
          if (t < 0 || t > 1) continue;
          final delta = relative + segment * t;
          final angle = bins.angleOf(delta.dx, delta.dy);
          if (!open(angle, range)) continue;
          if (angle >= -half && angle <= half) {
            angles.add(angle);
            vertexAngles.add(angle);
          }
        }
      }
      for (var end = 0; end < 2; end++) {
        final vertex = end == 0 ? topology.aVertex[id] : topology.bVertex[id];
        if (seen[vertex] == stamp) continue;
        seen[vertex] = stamp;
        final distance = bins.vertexDistance[vertex];
        if (distance > range || distance == 0) continue;
        final angle = bins.vertexAngle[vertex];
        if (!open(angle, distance)) continue;
        if (_seam(vertex, active)) continue;
        // Rays just beside a vertex the wall runs straight across meet its
        // two edges, so only the vertex ray adds a corner.
        emit(angle,
            beside: !_passThrough(
                vertex, topology.points[vertex] - origin, active));
      }
    }
    final sorted = _sortedUnique(angles);
    final vertexSorted = _sortedUnique(vertexAngles);
    final candidateMicros = timer.elapsedMicroseconds - preparationMicros;

    final polygon = <Offset>[origin];
    SvgVisibilityHit? previousHit;
    var sameEdgeRun = 0;
    var runAnchor = Offset.zero;
    for (final angle in sorted) {
      final direction = Offset(math.cos(directionRadians + angle),
          math.sin(directionRadians + angle));
      final hit = bins.cast(this, origin, direction, angle, range, stats);
      final point = hit?.point ?? origin + direction * range;
      // Rays meeting the same edge in a row lie on one straight line; the
      // middle ones add nothing to the outline. Vertex rays always stay.
      if (_indexOf(vertexSorted, angle) < 0 &&
          hit != null &&
          previousHit != null &&
          hit._edgeIndex == previousHit._edgeIndex) {
        sameEdgeRun++;
        if (sameEdgeRun == 2) {
          polygon.add(point);
        } else if (_betweenOnSameLine(runAnchor, polygon.last, point)) {
          polygon[polygon.length - 1] = point;
        } else {
          // Endpoint roundoff can give an excursion the same edge as its
          // neighbours; keep it unless the points prove it redundant.
          runAnchor = polygon.last;
          polygon.add(point);
        }
      } else {
        previousHit = hit;
        sameEdgeRun = 1;
        runAnchor = point;
        polygon.add(point);
      }
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
    final rootEntry = tree.entry(origin, direction, best);
    if (rootEntry == null) {
      stats.cells++;
      return null;
    }
    // Each node with where the ray enters its bounds. A nearer hit found
    // since it was pushed rules it out once the entry lies beyond it.
    final stack = <_EdgeNode>[tree];
    final entries = <double>[rootEntry];
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      final entry = entries.removeLast();
      stats.cells++;
      if (entry > best) continue;
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
            stack
              ..add(right)
              ..add(left);
            entries
              ..add(b)
              ..add(a);
          } else {
            stack
              ..add(left)
              ..add(right);
            entries
              ..add(a)
              ..add(b);
          }
        } else if (a != null) {
          stack.add(left);
          entries.add(a);
        } else if (b != null) {
          stack.add(right);
          entries.add(b);
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

/// One outline cones are cast against, standing for [wall] and every piece
/// with the same heights merged into it.
class SvgRuntimeWall extends _Footprint {
  SvgRuntimeWall._(this.wall, super.rings, super.evenOdd);

  /// The index in [SvgHeightVisibility.walls] whose heights it carries.
  final int wall;

  /// [rings] without repeated points or points midway along straight
  /// horizontal and vertical runs: the edges rays are cast against.
  late final List<List<Offset>> edgeRings = [
    for (final ring in rings) _runtimeRing(ring)
  ];

  /// The side of each edge of [edgeRings] the wall lies on.
  late final Int8List sides = svgEdgeSides(edgeRings, evenOdd);
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
  SvgVisibilityCone(
      List<Offset> polygon, this.eyeHeightAboveFloorMeters, this.stats,
      {this.eyeElevationMeters, this.floors = const [], this.sector})
      : _polygon = polygon,
        xy = null;

  /// A native result keeps its packed x,y doubles. A dragged cone is drawn
  /// straight from them; [polygon] is only materialised when something asks.
  SvgVisibilityCone.packed(
      Float64List this.xy, this.eyeHeightAboveFloorMeters, this.stats,
      {this.eyeElevationMeters})
      : _polygon = null,
        floors = const [],
        sector = null;

  final List<Offset>? _polygon;
  final Float64List? xy;
  late final List<Offset> polygon = _polygon ??
      List.unmodifiable(
          [for (var i = 0; i < xy!.length; i += 2) Offset(xy![i], xy![i + 1])]);
  final double eyeHeightAboveFloorMeters;
  final double? eyeElevationMeters;
  final SvgVisibilityStats stats;

  /// Measured destination floors the cone overlooks, each lit inside
  /// [sector] less the shadows cast on it. Where a floor lies, it replaces
  /// the horizontal [polygon]; see [paintSvgConeArea].
  final List<SvgFloorLayer> floors;

  /// The cone's aperture out to its range, when it has [floors].
  final List<Offset>? sector;

  /// The lit area as one path, when the cone has [floors]: what
  /// [paintSvgConeArea] fills, built with path operations. Costly; for
  /// reports and tests, never for a frame.
  late final Path? visibilityPath = floors.isEmpty
      ? null
      : () {
          final sectorPath = Path()..addPolygon(sector!, true);
          var visibility = Path()..addPolygon(polygon, true);
          for (final layer in floors) {
            final visible = layer.shadows.subtractFrom(
                Path.combine(PathOperation.intersect, layer.floor, sectorPath));
            visibility = Path.combine(
                PathOperation.union,
                Path.combine(PathOperation.difference, visibility, layer.floor),
                visible);
          }
          return visibility;
        }();

  /// The cone outline under a 4x4 column-major affine [transform]. One
  /// polygon rather than a line per point: on the web each line is a call
  /// into CanvasKit, repeated every frame the outline is drawn.
  Path outlinePath(Float64List transform) {
    final points = xy;
    final count = points == null ? _polygon!.length : points.length ~/ 2;
    return Path()
      ..addPolygon(
          List.generate(count, (i) {
            final x = points == null ? _polygon![i].dx : points[2 * i];
            final y = points == null ? _polygon![i].dy : points[2 * i + 1];
            return Offset(transform[0] * x + transform[4] * y + transform[12],
                transform[1] * x + transform[5] * y + transform[13]);
          }),
          true);
  }
}

/// Fills the lit area of [cone] with [fill], in source coordinates:
/// [outline], its horizontal cut, and on each destination floor the floor
/// inside the cone's sector less the shadows cast on it. Floors are composed
/// in layers rather than path operations, so a cone that overlooks a floor
/// paints in the same time as one that does not. [bounds] holds the cone.
void paintSvgConeArea(Canvas canvas, SvgVisibilityCone cone, Path outline,
    Paint fill, Rect bounds) {
  if (cone.floors.isEmpty) {
    canvas.drawPath(outline, fill);
    return;
  }
  final sector = Path()..addPolygon(cone.sector!, true);
  final clear = Paint()..blendMode = BlendMode.clear;
  // Where a floor edge crosses lit ground, the cleared pixel keeps 1 - c of
  // the cut and the floor brings c; adding them, rather than laying one over
  // the other, restores the fill exactly, with every edge antialiased.
  final add = Paint()..blendMode = BlendMode.plus;
  canvas.saveLayer(bounds, Paint());
  canvas.drawPath(outline, fill);
  for (final layer in cone.floors) {
    // A floor replaces the horizontal cut where it lies, as the later of
    // two overlapping floors replaces the earlier.
    canvas.drawPath(layer.floor, clear);
    canvas.saveLayer(bounds, add);
    canvas.clipPath(sector);
    canvas.drawPath(layer.floor, fill);
    layer.shadows.erase(canvas);
    canvas.restore();
  }
  canvas.restore();
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

  /// The largest boundary tolerance [_contains] is asked for.
  static const _maxTolerance = 0.05;

  /// Rows are a unit tall, or taller for a footprint so tall that unit rows
  /// would number more than this.
  static const _maxRows = 4096;
  late final double _rowHeight =
      math.max(1.0, (bounds.height + 2 * _maxTolerance) / _maxRows);

  /// Every edge's two points as `ax, ay, bx, by`, ring after ring: what
  /// [_contains] and [_nearestEdge] read, without an [Offset] or a modulo
  /// per edge.
  late final Float64List _ends = () {
    final ends = Float64List(4 * rings.fold(0, (n, ring) => n + ring.length));
    var k = 0;
    for (final ring in rings) {
      for (var i = 0; i < ring.length; i++) {
        final a = ring[i], b = ring[i + 1 == ring.length ? 0 : i + 1];
        ends[k++] = a.dx;
        ends[k++] = a.dy;
        ends[k++] = b.dx;
        ends[k++] = b.dy;
      }
    }
    return ends;
  }();

  /// Every edge, as its index in [_ends], filed under each [_rowHeight] row
  /// its height, grown by [_maxTolerance], reaches. Only edges spanning a
  /// point's height add to its winding, and only edges that near can hold it
  /// on their boundary, so a test reads one row. A floor with every wall cut
  /// out of it is thousands of edges in one ring.
  late final List<Int32List> _rows = () {
    final rows = List.generate(_rowCount, (_) => <int>[]);
    final ends = _ends;
    for (var e = 0; e < ends.length ~/ 4; e++) {
      final ay = ends[4 * e + 1], by = ends[4 * e + 3];
      final first = _row(math.min(ay, by) - _maxTolerance);
      final last = _row(math.max(ay, by) + _maxTolerance);
      for (var row = first; row <= last; row++) rows[row].add(e);
    }
    return [for (final row in rows) Int32List.fromList(row)];
  }();

  late final int _rowCount =
      (bounds.height + 2 * _maxTolerance) ~/ _rowHeight + 1;

  int _row(double y) => ((y - bounds.top + _maxTolerance) / _rowHeight)
      .floor()
      .clamp(0, _rowCount - 1);

  bool _contains(Offset point, double boundaryTolerance) {
    assert(boundaryTolerance <= _maxTolerance);
    // Written so a NaN coordinate fails it, as it failed every edge before.
    if (!(point.dx >= bounds.left - boundaryTolerance &&
        point.dx <= bounds.right + boundaryTolerance &&
        point.dy >= bounds.top - boundaryTolerance &&
        point.dy <= bounds.bottom + boundaryTolerance)) return false;
    var winding = 0;
    final row = _rows[_row(point.dy)];
    final ends = _ends;
    final x = point.dx, y = point.dy;
    for (var n = 0; n < row.length; n++) {
      final k = 4 * row[n];
      final ax = ends[k], ay = ends[k + 1], bx = ends[k + 2], by = ends[k + 3];
      final ex = bx - ax, ey = by - ay;
      final side = ex * (y - ay) - ey * (x - ax);
      if ((side == 0 ||
              boundaryTolerance > 0 &&
                  side.abs() <=
                      boundaryTolerance * math.sqrt(ex * ex + ey * ey)) &&
          x >= math.min(ax, bx) - boundaryTolerance &&
          x <= math.max(ax, bx) + boundaryTolerance &&
          y >= math.min(ay, by) - boundaryTolerance &&
          y <= math.max(ay, by) + boundaryTolerance) return true;
      if (ay <= y && by > y && side > 0) winding++;
      if (ay > y && by <= y && side < 0) winding--;
    }
    return evenOdd ? winding.abs().isOdd : winding != 0;
  }

  int get _edgeCount => _ends.length ~/ 4;

  /// How far ([x], [y]) is from edge [e]; -1 for an edge of no length.
  double _distanceTo(int e, double x, double y) {
    final ends = _ends, k = 4 * e;
    final ax = ends[k], ay = ends[k + 1];
    final ex = ends[k + 2] - ax, ey = ends[k + 3] - ay;
    final length = ex * ex + ey * ey;
    if (length == 0) return -1;
    final t = (((x - ax) * ex + (y - ay) * ey) / length).clamp(0.0, 1.0);
    final dx = x - (ax + ex * t), dy = y - (ay + ey * t);
    return math.sqrt(dx * dx + dy * dy);
  }

  /// The point of edge [e] nearest [point], and the unit normal from it
  /// toward [point], or across the edge when [point] is on it. The same
  /// arithmetic as [_distanceTo], so the foot is as far as it said.
  (Offset, Offset) _footOn(int e, Offset point) {
    final k = 4 * e;
    final a = Offset(_ends[k], _ends[k + 1]);
    final edge = Offset(_ends[k + 2], _ends[k + 3]) - a;
    final t = (((point - a).dx * edge.dx + (point - a).dy * edge.dy) /
            edge.distanceSquared)
        .clamp(0.0, 1.0);
    final foot = a + edge * t;
    final d = (point - foot).distance;
    return (
      foot,
      d > 1e-9 ? (point - foot) / d : Offset(-edge.dy, edge.dx) / edge.distance
    );
  }

  /// The edge nearest [point], the first in ring order when several are
  /// equally near; -1 when no edge has length. Rows are read outward from the
  /// point's own. An edge filed in none of the rows within j of it lies more
  /// than j row heights away (rows are filed with [_maxTolerance] to spare),
  /// so the search ends once the nearest edge found is nearer than that:
  /// a point beside a floor reads a few rows of it, not its every edge.
  Int32List? _seenEdges;
  var _seenStamp = 0;

  int _nearestEdge(Offset point) {
    final x = point.dx, y = point.dy;
    var best = -1;
    var bestDistance = double.infinity;
    // Not a number, so far out that the squares overflow, or a footprint
    // too tall for rows: every edge, in order, as before rows were read.
    if (!(x.abs() < 1e100 && y.abs() < 1e100 && _rowHeight < 1e100)) {
      for (var e = 0; e < _edgeCount; e++) {
        final d = _distanceTo(e, x, y);
        // A NaN distance is kept when it comes first, as it was.
        if (d < 0) continue;
        if (best < 0 || d < bestDistance) {
          best = e;
          bestDistance = d;
        }
      }
      return best;
    }
    // A tall edge is filed in every row it spans: measure it once.
    final seen = _seenEdges ??= Int32List(_edgeCount);
    final stamp = ++_seenStamp;
    final center = _row(y);
    for (var j = 0; center - j >= 0 || center + j < _rowCount; j++) {
      for (final r in [center - j, if (j > 0) center + j]) {
        if (r < 0 || r >= _rowCount) continue;
        final row = _rows[r];
        for (var n = 0; n < row.length; n++) {
          final e = row[n];
          if (seen[e] == stamp) continue;
          seen[e] = stamp;
          final d = _distanceTo(e, x, y);
          if (d >= 0 &&
              (best < 0 || d < bestDistance || d == bestDistance && e < best)) {
            best = e;
            bestDistance = d;
          }
        }
      }
      // Strictly nearer, with room for rounding: an edge just beyond the rows
      // read must not tie with this one once both distances are rounded.
      if (bestDistance < j * _rowHeight * (1 - 1e-9)) break;
    }
    return best;
  }
}

enum _Side { left, right }

class _Edge {
  _Edge(this.a, this.b, this.wall, {required this.interior})
      : _inverseLength = 1 / (b - a).distance,
        _ex = b.dx - a.dx,
        _ey = b.dy - a.dy;
  final Offset a, b;
  final int wall;

  /// The side of the edge, going from [a] to [b], its own wall lies on; null
  /// when that could not be told.
  final _Side? interior;
  final double _inverseLength;

  /// `b - a`, kept as numbers: every ray tests many edges, and on the web
  /// each intermediate [Offset] is an allocation.
  final double _ex, _ey;

  double? intersection(Offset origin, Offset direction, double range) {
    final dx = direction.dx, dy = direction.dy;
    final rx = a.dx - origin.dx, ry = a.dy - origin.dy;
    final determinant = dx * _ey - dy * _ex;
    if (determinant == 0) {
      final relative = a - origin;
      if (_cross(relative, direction) != 0) return null;
      final first = _dot(relative, direction),
          last = _dot(b - origin, direction);
      final entry = math.max(0.0, math.min(first, last));
      return math.max(first, last) >= 0 && entry <= range ? entry : null;
    }
    final distance = (rx * _ey - ry * _ex) / determinant;
    final along = (rx * dy - ry * dx) / determinant;
    // atan2/sin/cos can put a ray aimed at an exact corner a few ulps beyond
    // both adjoining endpoints. Admit that much along the wall: a sliver of
    // what the 1e-8 radian rays beside a corner pass it by at the same
    // distance, which must still pass.
    final slack = (1e-13 + distance * 1e-10) * _inverseLength;
    return distance >= 0 &&
            distance <= range &&
            along >= -slack &&
            along <= 1 + slack
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

/// The edges' endpoints as vertex ids, the edges meeting at each vertex and
/// where each vertex is. Built once, so a cone query never hashes a point.
class _VertexTopology {
  factory _VertexTopology(List<_Edge> edges) {
    final ids = <Offset, int>{};
    final points = <Offset>[];
    int id(Offset point) => ids.putIfAbsent(point, () {
          points.add(point);
          return points.length - 1;
        });
    final a = Int32List(edges.length), b = Int32List(edges.length);
    for (var i = 0; i < edges.length; i++) {
      a[i] = id(edges[i].a);
      b[i] = id(edges[i].b);
    }
    final at = List.generate(points.length, (_) => <int>[]);
    for (var i = 0; i < edges.length; i++) {
      at[a[i]].add(i);
      at[b[i]].add(i);
    }
    return _VertexTopology._(
        a, b, [for (final list in at) Int32List.fromList(list)], points);
  }

  _VertexTopology._(this.aVertex, this.bVertex, this.edgesAt, this.points);

  final Int32List aVertex, bVertex;
  final List<Int32List> edgesAt;
  final List<Offset> points;
}

/// [values] sorted, with exact repeats removed.
List<double> _sortedUnique(List<double> values) {
  values.sort();
  final out = <double>[];
  for (final value in values) {
    if (out.isEmpty || out.last != value) out.add(value);
  }
  return out;
}

/// Where [value] is in the sorted [values], or -1.
int _indexOf(List<double> values, double value) {
  var low = 0, high = values.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    final candidate = values[middle];
    if (candidate < value) {
      low = middle + 1;
    } else if (candidate > value) {
      high = middle - 1;
    } else {
      return middle;
    }
  }
  return -1;
}

/// Whether [middle] lies on the segment from [first] to [last], up to
/// roundoff: the native query's test for a redundant outline point.
bool _betweenOnSameLine(Offset first, Offset middle, Offset last) {
  final span = last - first;
  final offset = middle - first;
  final lengthSquared = _dot(span, span);
  final along = _dot(offset, span);
  if (lengthSquared == 0 || along < 0 || along > lengthSquared) return false;
  final length = math.sqrt(lengthSquared);
  final roundoff = 64 * 2.220446049250313e-16 * math.max(1.0, length);
  return _cross(offset, span).abs() <= roundoff * length;
}

/// The active edges a cone's eye may see, filed by the angles they cover.
///
/// Every ray of a cone leaves the same eye. So rather than walk the map's
/// edge tree once per ray, a query files the edges it may meet once: each
/// gets its nearest distance to the eye and the span of angles it covers, and
/// goes into every bin of that span. A ray then tests only its bin's edges.
///
/// Each bin also gets a depth, the farthest any ray in it can travel. A run
/// of consecutive ring edges that crosses a bin from one boundary to the next
/// is an unbroken wall across it, so every ray in the bin stops no farther
/// than the run's farthest point there. The nearest such bound is the bin's
/// depth. Whatever begins beyond the depths it spans is hidden: an edge there
/// is not filed, and a corner there needs no rays, since they would land in
/// the middle of whatever hides it.
///
/// The edge tree is walked nearest node first, the way a renderer draws front
/// to back, and a node whose bounds begin beyond the depths of every bin they
/// span is skipped whole: most of a map is behind the walls nearest the eye.
/// Depths are only ever used with a margin, and whatever they let through is
/// tested exactly, so the outline is the one every edge would give.
class _ConeBins {
  /// Filed edges, by slot: edge id, nearest distance to the eye, and the span
  /// of angles from the cone's direction they cover, which may run past pi.
  int count = 0;
  Int32List edgeIds = Int32List(64);
  Float64List near = Float64List(64);
  Float64List from = Float64List(64);
  Float64List to = Float64List(64);

  /// Bins split [lowest, lowest + binCount * width] evenly.
  int binCount = 0;
  double lowest = 0, width = 1;

  /// Bin k's filed slots are items[offsets[k]] up to items[offsets[k + 1]].
  Int32List offsets = Int32List(1);
  Int32List items = Int32List(0);

  /// The farthest any ray in a bin can travel; infinite when unproven.
  Float64List depth = Float64List(0);

  /// The largest depth over ranges of bins: a segment tree whose leaves,
  /// from [_leaves] on, are the depths.
  Float64List _peaks = Float64List(0);
  int _leaves = 0;

  /// The world direction of each bin boundary.
  Float64List boundaryX = Float64List(0), boundaryY = Float64List(0);

  double _cosine = 1, _sine = 0;
  var _whole = false;
  double _relativeLowest = double.nan, _relativeWidth = double.nan;
  Float64List _relativeX = Float64List(0), _relativeY = Float64List(0);

  /// Per vertex this query, where [vertexMark] is [_vertexStamp]: its angle
  /// from the cone's direction and its distance from the eye.
  Float64List vertexAngle = Float64List(0), vertexDistance = Float64List(0);
  Int32List vertexMark = Int32List(0);
  var _vertexStamp = 0;
  double _ox = 0, _oy = 0;
  late _VertexTopology _topology;

  void _see(int vertex) {
    if (vertexMark[vertex] == _vertexStamp) return;
    vertexMark[vertex] = _vertexStamp;
    final point = _topology.points[vertex];
    final dx = point.dx - _ox, dy = point.dy - _oy;
    vertexAngle[vertex] = angleOf(dx, dy);
    vertexDistance[vertex] = math.sqrt(dx * dx + dy * dy);
  }

  /// Margins on the proofs: rounding in the angles and distances here is
  /// some 1e-15, far inside these.
  static const _angleMargin = 1e-9;
  static const _relativeMargin = 1e-9, _absoluteMargin = 1e-9;

  /// Rays beside a corner leave this far from its angle.
  static const _cornerSlack = SvgHeightVisibility._cornerOffset + _angleMargin;

  /// The narrowest bin; a cone's bins are about this wide.
  static const _binWidth = 2 * math.pi / 2048;

  /// The angle of [dx], [dy] from the cone's direction, in [-pi, pi].
  double angleOf(double dx, double dy) =>
      math.atan2(-dx * _sine + dy * _cosine, dx * _cosine + dy * _sine);

  /// [index] held to the boundaries just outside the cone; NaN, from an
  /// aperture so small its bins have no width, to the first.
  double _boundaryIndex(double index) =>
      index >= -1 ? (index <= binCount + 1 ? index : binCount + 1.0) : -1.0;

  int binOf(double angle) {
    // Clamped as a double: a narrow cone's bins are so fine that angles
    // outside it can lie past any integer.
    final k = ((angle - lowest) / width).floorToDouble();
    if (!(k >= 0)) return 0;
    return k >= binCount ? binCount - 1 : k.toInt();
  }

  /// Whether every ray within a corner offset of [angle] provably stops
  /// before [distance].
  bool hides(double angle, double distance) {
    final last = binOf(angle + _cornerSlack);
    for (var k = binOf(angle - _cornerSlack); k <= last; k++) {
      if (!_beyond(distance, depth[k])) return false;
    }
    // Behind a full circle, rays beside an angle at the seam wrap round.
    if (_whole) {
      if (angle - _cornerSlack < lowest &&
          !_beyond(distance, depth[binCount - 1])) {
        return false;
      }
      if (angle + _cornerSlack > lowest + binCount * width &&
          !_beyond(distance, depth[0])) {
        return false;
      }
    }
    return true;
  }

  static bool _beyond(double distance, double depth) =>
      distance > depth * (1 + _relativeMargin) + _absoluteMargin;

  void file(SvgHeightVisibility model, Offset origin, double direction,
      double range, List<bool> active,
      {required double lowest, required double span}) {
    _cosine = math.cos(direction);
    _sine = math.sin(direction);
    this.lowest = lowest;
    _topology = model._topology;
    _ox = origin.dx;
    _oy = origin.dy;
    final vertices = _topology.points.length;
    if (vertexMark.length < vertices) {
      vertexAngle = Float64List(vertices);
      vertexDistance = Float64List(vertices);
      vertexMark = Int32List(vertices);
    }
    _vertexStamp++;
    final edgeCount = model._edges.length;
    if (_slotMark.length < edgeCount) {
      _slotMark = Int32List(edgeCount);
      _dirty = Int32List(edgeCount);
    }
    _mark++;
    final bins = math.max(64, (span / _binWidth).ceil());
    binCount = bins;
    width = span / bins;
    _whole = span >= 2 * math.pi;
    if (depth.length < bins) {
      depth = Float64List(bins);
      boundaryX = Float64List(bins + 1);
      boundaryY = Float64List(bins + 1);
      offsets = Int32List(bins + 1);
    }
    // Boundary directions relative to the cone's direction depend only on
    // the bins, so they are kept between queries and turned to face it.
    if (_relativeLowest != lowest ||
        _relativeWidth != width ||
        _relativeX.length < bins + 1) {
      _relativeLowest = lowest;
      _relativeWidth = width;
      _relativeX = Float64List(bins + 1);
      _relativeY = Float64List(bins + 1);
      for (var j = 0; j <= bins; j++) {
        _relativeX[j] = math.cos(lowest + j * width);
        _relativeY[j] = math.sin(lowest + j * width);
      }
    }
    for (var j = 0; j <= bins; j++) {
      final x = _relativeX[j], y = _relativeY[j];
      boundaryX[j] = x * _cosine - y * _sine;
      boundaryY[j] = x * _sine + y * _cosine;
    }
    depth.fillRange(0, bins, double.infinity);
    _leaves = 1;
    while (_leaves < bins) {
      _leaves *= 2;
    }
    if (_peaks.length < 2 * _leaves) _peaks = Float64List(2 * _leaves);
    _peaks.fillRange(0, 2 * _leaves, double.infinity);
    count = 0;

    final root = model._tree;
    if (root != null) {
      _walk(model, root, origin, range, active);
    }

    // File each edge in the bins it may be seen in: count, then place.
    offsets.fillRange(0, bins + 1, 0);
    _place(false);
    for (var k = 0; k < bins; k++) {
      offsets[k + 1] += offsets[k];
    }
    if (items.length < offsets[bins]) {
      items = Int32List(math.max(offsets[bins], items.length * 2));
    }
    _place(true);
    // Placing advanced each bin's offset to the next bin's start.
    for (var k = bins; k > 0; k--) {
      offsets[k] = offsets[k - 1];
    }
    offsets[0] = 0;
    // Nearest first within each bin, so a ray stops at the first edge that
    // begins beyond its hit. The walk filed them nearly in this order.
    for (var k = 0; k < bins; k++) {
      final end = offsets[k + 1];
      for (var i = offsets[k] + 1; i < end; i++) {
        final slot = items[i];
        final key = near[slot];
        var j = i - 1;
        while (j >= offsets[k] && near[items[j]] > key) {
          items[j + 1] = items[j];
          j--;
        }
        items[j + 1] = slot;
      }
    }
  }

  // Tree nodes waiting to be visited, nearest first: a binary heap.
  final _heapNodes = <_EdgeNode>[];
  Float64List _heapKeys = Float64List(64);

  void _push(_EdgeNode node, double key) {
    var i = _heapNodes.length;
    _heapNodes.add(node);
    if (_heapKeys.length <= i) {
      _heapKeys = Float64List(_heapKeys.length * 2)..setAll(0, _heapKeys);
    }
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_heapKeys[parent] <= key) break;
      _heapNodes[i] = _heapNodes[parent];
      _heapKeys[i] = _heapKeys[parent];
      i = parent;
    }
    _heapNodes[i] = node;
    _heapKeys[i] = key;
  }

  /// Removes the nearest node; its key is left in [_popped].
  _EdgeNode _pop() {
    final top = _heapNodes[0];
    _popped = _heapKeys[0];
    final node = _heapNodes.removeLast();
    final n = _heapNodes.length;
    if (n > 0) {
      final key = _heapKeys[n];
      var i = 0;
      while (true) {
        var child = 2 * i + 1;
        if (child >= n) break;
        if (child + 1 < n && _heapKeys[child + 1] < _heapKeys[child]) child++;
        if (_heapKeys[child] >= key) break;
        _heapNodes[i] = _heapNodes[child];
        _heapKeys[i] = _heapKeys[child];
        i = child;
      }
      _heapNodes[i] = node;
      _heapKeys[i] = key;
    }
    return top;
  }

  double _popped = 0;

  static double _distanceTo(Rect bounds, double x, double y) {
    final dx = math.max(0.0, math.max(bounds.left - x, x - bounds.right));
    final dy = math.max(0.0, math.max(bounds.top - y, y - bounds.bottom));
    return math.sqrt(dx * dx + dy * dy);
  }

  void _walk(SvgHeightVisibility model, _EdgeNode root, Offset origin,
      double range, List<bool> active) {
    final ox = origin.dx, oy = origin.dy;
    _heapNodes.clear();
    _push(root, _distanceTo(root.bounds, ox, oy));
    // Depths are proven from the edges filed so far, again each time the
    // walk passes twice as far from the eye.
    var wave = math.max(range / 16, 1e-3);
    var proven = 0;
    while (_heapNodes.isNotEmpty) {
      final node = _pop();
      final distance = _popped;
      if (distance > range) break;
      if (distance > wave) {
        if (count > proven) {
          _walkChains(model, origin, _whole, proven);
          _raisePeaks();
          proven = count;
        }
        while (wave < distance) {
          wave *= 4;
        }
      }
      if (!_boundsMayShow(node.bounds, distance, ox, oy)) continue;
      final ids = node.ids;
      if (ids != null) {
        for (final id in ids) {
          _fileEdge(model, id, ox, oy, range, active);
        }
      } else {
        final left = node.left!, right = node.right!;
        final leftKey = _distanceTo(left.bounds, ox, oy);
        if (leftKey <= range) _push(left, leftKey);
        final rightKey = _distanceTo(right.bounds, ox, oy);
        if (rightKey <= range) _push(right, rightKey);
      }
    }
    if (count > proven) _walkChains(model, origin, _whole, proven);
  }

  /// Whether anything in [bounds], [distance] from the eye at its nearest,
  /// could show in the cone.
  bool _boundsMayShow(Rect bounds, double distance, double ox, double oy) {
    final column = ox < bounds.left ? 0 : (ox > bounds.right ? 2 : 1);
    final row = oy < bounds.top ? 0 : (oy > bounds.bottom ? 2 : 1);
    if (distance < _absoluteMargin || (column == 1 && row == 1)) return true;
    // Seen from outside, a box spans less than half a turn, between the two
    // corners that bound its silhouette. Which two depends only on where the
    // eye is around the box: per region, each corner as (right?, bottom?).
    final corners = _silhouettes[row * 3 + column];
    final ax = ((corners & 8) != 0 ? bounds.right : bounds.left) - ox;
    final ay = ((corners & 4) != 0 ? bounds.bottom : bounds.top) - oy;
    final bx = ((corners & 2) != 0 ? bounds.right : bounds.left) - ox;
    final by = ((corners & 1) != 0 ? bounds.bottom : bounds.top) - oy;
    final ta = angleOf(ax, ay), tb = angleOf(bx, by);
    final turn = ax * by - ay * bx;
    final first = turn > 0 ? ta : (turn < 0 ? tb : math.min(ta, tb));
    var last = turn > 0 ? tb : (turn < 0 ? ta : math.max(ta, tb));
    if (last < first) last += 2 * math.pi;
    return _mayShow(first - _cornerSlack, last + _cornerSlack, distance);
  }

  /// For each region around a box, rows top to bottom and columns left to
  /// right, the two corners of its silhouette as bits: first corner right,
  /// first bottom, second right, second bottom.
  static const _silhouettes = [
    0x9, 0x2, 0x3, //
    0x1, 0x0, 0xb, //
    0x3, 0x7, 0x9,
  ];

  /// Whether something [distance] from the eye, spanning angles [first] to
  /// [last] (which may run past pi), falls in the cone and is not provably
  /// behind the depths there.
  bool _mayShow(double first, double last, double distance) {
    const margin = 1e-6;
    final highest = lowest + binCount * width;
    for (var shift = 2 * math.pi; shift > -4 * math.pi; shift -= 2 * math.pi) {
      final start = first + shift, end = last + shift;
      if (end < lowest - margin || start > highest + margin) continue;
      if (!_beyond(distance, _peak(binOf(start), binOf(end)))) return true;
    }
    return false;
  }

  /// The largest depth over bins [first] to [last].
  double _peak(int first, int last) {
    var result = 0.0;
    var low = first + _leaves, high = last + _leaves + 1;
    while (low < high) {
      if (low.isOdd) result = math.max(result, _peaks[low++]);
      if (high.isOdd) result = math.max(result, _peaks[--high]);
      low >>= 1;
      high >>= 1;
    }
    return result;
  }

  void _raisePeaks() {
    _peaks.setRange(_leaves, _leaves + binCount, depth);
    for (var i = _leaves - 1; i > 0; i--) {
      _peaks[i] = math.max(_peaks[2 * i], _peaks[2 * i + 1]);
    }
  }

  void _fileEdge(SvgHeightVisibility model, int id, double ox, double oy,
      double range, List<bool> active) {
    final edge = model._edges[id];
    if (!active[edge.wall]) return;
    final ax = edge.a.dx - ox, ay = edge.a.dy - oy;
    final bx = edge.b.dx - ox, by = edge.b.dy - oy;
    final ex = edge._ex, ey = edge._ey;
    final lengthSquared = ex * ex + ey * ey;
    var t = lengthSquared == 0 ? 0.0 : -(ax * ex + ay * ey) / lengthSquared;
    t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
    final cx = ax + ex * t, cy = ay + ey * t;
    final distance = math.sqrt(cx * cx + cy * cy);
    if (distance > range) return;
    final va = _topology.aVertex[id], vb = _topology.bVertex[id];
    _see(va);
    _see(vb);
    var first = -math.pi, last = math.pi;
    if (distance >= _absoluteMargin) {
      final ta = vertexAngle[va], tb = vertexAngle[vb];
      final turn = ax * by - ay * bx;
      if (turn > 0) {
        first = ta;
        last = tb;
      } else if (turn < 0) {
        first = tb;
        last = ta;
      } else {
        first = math.min(ta, tb);
        last = math.max(ta, tb);
      }
      if (last < first) last += 2 * math.pi;
      if (!_mayShow(first - _cornerSlack, last + _cornerSlack, distance)) {
        return;
      }
    }
    if (count == edgeIds.length) {
      final size = count * 2;
      edgeIds = Int32List(size)..setAll(0, edgeIds);
      near = Float64List(size)..setAll(0, near);
      from = Float64List(size)..setAll(0, from);
      to = Float64List(size)..setAll(0, to);
    }
    if (distance >= _absoluteMargin) _slotMark[id] = _mark;
    edgeIds[count] = id;
    near[count] = distance;
    from[count] = first;
    to[count] = last;
    count++;
  }

  /// Edges filed this query that a run can pass through: [_slotMark] is
  /// [_mark]. An edge through the eye stops nothing reliably beside it.
  Int32List _slotMark = Int32List(0);
  var _mark = 0;

  // The runs to walk this wave: [_dirty] is [_dirtyStamp] on their edges.
  Int32List _dirty = Int32List(0);
  var _dirtyStamp = 0;
  final _heads = <int>[];

  /// Lowers each bin's depth to the farthest point of any run of consecutive
  /// ring edges that crosses the bin from one boundary to the next. Such a run
  /// is an unbroken wall across the bin, so it stops every ray in it. Single
  /// edges rarely span a bin: Riot's outlines are many short strokes.
  void _walkChains(
      SvgHeightVisibility model, Offset origin, bool whole, int firstNew) {
    final edges = model._edges;
    final mark = _mark;
    bool chained(int id) =>
        id >= 0 && id < edges.length && _slotMark[id] == mark;
    final ox = origin.dx, oy = origin.dy;
    final aVertex = _topology.aVertex, bVertex = _topology.bVertex;
    // Runs already walked have proven all they can; walk again only those
    // with an edge filed since, each from its first edge.
    final stamp = ++_dirtyStamp;
    _heads.clear();
    for (var slot = firstNew; slot < count; slot++) {
      var id = edgeIds[slot];
      if (_slotMark[id] != mark) continue;
      while (_dirty[id] != stamp) {
        _dirty[id] = stamp;
        if (!chained(id - 1) || bVertex[id - 1] != aVertex[id]) {
          _heads.add(id);
          break;
        }
        id--;
      }
    }
    for (final head in _heads) {
      var id = head;
      var raw = vertexAngle[aVertex[id]];
      // The run's angle, unwrapped so it never jumps by a turn.
      var angle = raw;
      // The last boundary crossed, and since then: the farthest point and
      // the angles the run has reached.
      var hasLast = false;
      var last = 0;
      var farthest = 0.0, lowAngle = 0.0, highAngle = 0.0;
      while (true) {
        final edge = edges[id];
        final next = bVertex[id];
        final nextRaw = vertexAngle[next];
        var turn = nextRaw - raw;
        if (turn > math.pi) {
          turn -= 2 * math.pi;
        } else if (turn <= -math.pi) {
          turn += 2 * math.pi;
        }
        final end = angle + turn;
        final ex = edge._ex, ey = edge._ey;
        final along = (edge.a.dx - ox) * ey - (edge.a.dy - oy) * ex;
        // Boundaries the edge plainly crosses, in the order it crosses them.
        final step = end > angle ? 1 : -1;
        var start = step > 0
            ? ((angle + _angleMargin - lowest) / width).ceilToDouble()
            : ((angle - _angleMargin - lowest) / width).floorToDouble();
        var finish = step > 0
            ? ((end - _angleMargin - lowest) / width).floorToDouble()
            : ((end + _angleMargin - lowest) / width).ceilToDouble();
        if (!whole) {
          // Boundaries outside the cone are skipped below, and a narrow
          // cone's bins are so fine those can lie past any integer.
          start = _boundaryIndex(start);
          finish = _boundaryIndex(finish);
        }
        var j = start.toInt();
        final stop = finish.toInt();
        for (; step > 0 ? j <= stop : j >= stop; j += step) {
          if (!whole && (j < 0 || j > binCount)) continue;
          final boundary = whole ? j % binCount : j;
          final distance =
              along / (boundaryX[boundary] * ey - boundaryY[boundary] * ex);
          final at = lowest + j * width;
          if (!(distance >= 0) || distance.isInfinite) {
            hasLast = false;
            continue;
          }
          if (hasLast && (j - last).abs() == 1) {
            final previous = lowest + last * width;
            // Between the two crossings the run stayed inside the bin.
            if (lowAngle >= math.min(at, previous) - 1e-8 &&
                highAngle <= math.max(at, previous) + 1e-8) {
              final k =
                  whole ? math.min(j, last) % binCount : math.min(j, last);
              final bound = math.max(farthest, distance);
              if (bound < depth[k]) depth[k] = bound;
            }
          }
          hasLast = true;
          last = j;
          farthest = distance;
          lowAngle = highAngle = at;
        }
        farthest = math.max(farthest, vertexDistance[next]);
        lowAngle = math.min(lowAngle, end);
        highAngle = math.max(highAngle, end);
        if (!chained(id + 1) || aVertex[id + 1] != next) break;
        id++;
        raw = nextRaw;
        angle = end;
      }
    }
  }

  /// Counts each slot into offsets[k + 1] for every bin k it is filed in, or,
  /// with [fill], writes it at offsets[k] and advances that.
  void _place(bool fill) {
    final highest = lowest + binCount * width;
    for (var slot = 0; slot < count; slot++) {
      final distance = near[slot];
      if (distance < _absoluteMargin) {
        // An edge through the eye can stop a ray in any direction.
        for (var k = 0; k < binCount; k++) {
          if (fill) {
            items[offsets[k]++] = slot;
          } else {
            offsets[k + 1]++;
          }
        }
        continue;
      }
      // Rays are admitted a sliver past an edge's ends; see _Edge.intersection.
      final pad = _angleMargin + 1e-12 / distance;
      // A span starting just below -pi also covers the bins just below pi.
      for (var shift = 2 * math.pi;
          shift > -4 * math.pi;
          shift -= 2 * math.pi) {
        final start = from[slot] + shift - pad, end = to[slot] + shift + pad;
        if (end < lowest) break;
        if (start > highest) continue;
        final first = binOf(start), last = binOf(end);
        for (var k = first; k <= last; k++) {
          if (distance > depth[k] * (1 + _relativeMargin) + _absoluteMargin) {
            continue;
          }
          if (fill) {
            items[offsets[k]++] = slot;
          } else {
            offsets[k + 1]++;
          }
        }
      }
    }
  }

  /// The nearest hit along [direction], [angle] from the cone's direction,
  /// within [range]; ties go to the lowest edge id.
  SvgVisibilityHit? cast(SvgHeightVisibility model, Offset origin,
      Offset direction, double angle, double range, _Counters stats) {
    final k = binOf(angle);
    stats.cells++;
    var best = range;
    var bestId = -1;
    for (var i = offsets[k]; i < offsets[k + 1]; i++) {
      final slot = items[i];
      if (near[slot] > best) break;
      final id = edgeIds[slot];
      stats.edgeTests++;
      final distance = model._edges[id].intersection(origin, direction, best);
      if (distance == null) continue;
      if (bestId < 0 || distance < best || (distance == best && id < bestId)) {
        best = distance;
        bestId = id;
      }
    }
    if (bestId < 0) return null;
    final wall = model._edges[bestId].wall;
    if (model.walls[wall].unknownHeight) stats.unknownHits++;
    return model._hit(origin, direction, best, wall, bestId);
  }
}
