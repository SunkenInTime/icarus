import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

const String visionBoundaryReferenceAsset =
    'assets/maps/vision_collision_reference.json';
const String visionBoundaryEditsAsset =
    'assets/maps/vision_boundary_edits.json';

enum VisionBoundaryContourKind {
  outer,
  interior,
  heightBox,
  structuralChain,
}

enum VisionBoundaryEditScope { point, contour, all }

@immutable
class VisionBoundaryContourRef {
  const VisionBoundaryContourRef(this.kind, [this.index = 0]);

  final VisionBoundaryContourKind kind;
  final int index;

  String get label => switch (kind) {
        VisionBoundaryContourKind.outer => 'Outer boundary',
        VisionBoundaryContourKind.interior => 'Interior ${index + 1}',
        VisionBoundaryContourKind.heightBox => 'Height box ${index + 1}',
        VisionBoundaryContourKind.structuralChain => 'Wall chain ${index + 1}',
      };

  @override
  bool operator ==(Object other) =>
      other is VisionBoundaryContourRef &&
      other.kind == kind &&
      other.index == index;

  @override
  int get hashCode => Object.hash(kind, index);
}

@immutable
class VisionBoundarySelection {
  const VisionBoundarySelection({required this.contour, this.pointIndex});

  final VisionBoundaryContourRef contour;
  final int? pointIndex;

  String get label {
    final point = pointIndex;
    return point == null
        ? contour.label
        : '${contour.label} · Point ${point + 1}';
  }

  VisionBoundarySelection withoutPoint() =>
      VisionBoundarySelection(contour: contour);

  @override
  bool operator ==(Object other) =>
      other is VisionBoundarySelection &&
      other.contour == contour &&
      other.pointIndex == pointIndex;

  @override
  int get hashCode => Object.hash(contour, pointIndex);
}

@immutable
class VisionBoundaryMapDraft {
  VisionBoundaryMapDraft({
    required this.map,
    required this.sourceBounds,
    required List<Offset> outer,
    required List<List<Offset>> interiors,
    required List<List<Offset>> heightBoxes,
    List<List<Offset>> structuralChains = const [],
    Map<VisionBoundaryContourRef, double> collisionRadii = const {},
  })  : outer = List<Offset>.unmodifiable(outer),
        interiors = _immutableContours(interiors),
        heightBoxes = _immutableContours(heightBoxes),
        structuralChains = _immutableContours(structuralChains),
        collisionRadii = Map<VisionBoundaryContourRef, double>.unmodifiable(
          collisionRadii,
        ) {
    for (final entry in collisionRadii.entries) {
      if (!_isValidContourRef(entry.key) ||
          !entry.value.isFinite ||
          entry.value < 0) {
        throw ArgumentError.value(collisionRadii, 'collisionRadii');
      }
    }
  }

  factory VisionBoundaryMapDraft.fromJson({
    required MapValue map,
    required Object? value,
  }) {
    if (value is! Map<String, dynamic>) {
      throw FormatException('Missing collision boundary for ${map.name}.');
    }
    final sourceBounds = _rect(value['sourceBounds'], 'sourceBounds');
    if (sourceBounds.width <= 0 || sourceBounds.height <= 0) {
      throw FormatException('Invalid source bounds for ${map.name}.');
    }
    final interiors = _contours(value['interiors'], 'interiors');
    final heightBoxes = _contours(value['heightBoxes'], 'heightBoxes');
    final structuralChains = value['structuralChains'] == null
        ? const <List<Offset>>[]
        : _chains(value['structuralChains'], 'structuralChains');
    return VisionBoundaryMapDraft(
      map: map,
      sourceBounds: sourceBounds,
      outer: _contour(value['outer'], 'outer'),
      interiors: interiors,
      heightBoxes: heightBoxes,
      structuralChains: structuralChains,
      collisionRadii: _decodeCollisionRadii(
        value['collisionRadii'],
        interiorCount: interiors.length,
        heightBoxCount: heightBoxes.length,
        structuralChainCount: structuralChains.length,
      ),
    );
  }

  factory VisionBoundaryMapDraft.fromBoundary({
    required MapValue map,
    required VisionBoundary boundary,
  }) {
    final outer = boundary.outerGroup;
    final interiors = boundary.collisionGroups
        .where(
          (group) =>
              group.kind == VisionCollisionKind.maskBoundary &&
              !group.isOuterBoundary,
        )
        .toList(growable: false);
    final heightBoxes = boundary.collisionGroups
        .where(
          (group) =>
              group.kind != VisionCollisionKind.maskBoundary &&
              group.isClosed &&
              !group.requiresEvidence,
        )
        .toList(growable: false);
    final structuralGroups = boundary.collisionGroups
        .where(
          (group) =>
              group.kind != VisionCollisionKind.maskBoundary &&
              (!group.isClosed || group.requiresEvidence),
        )
        .toList(growable: false);
    final structuralPaths = [
      for (final group in structuralGroups)
        for (final path in group.paths)
          (
            points: List<Offset>.unmodifiable(path),
            radius: _groupCollisionRadius(group),
          ),
    ];
    return VisionBoundaryMapDraft(
      map: map,
      sourceBounds: outer.bounds,
      outer: _withoutClosingPoint(outer.points),
      interiors: [
        for (final group in interiors) _withoutClosingPoint(group.points),
      ],
      heightBoxes: [
        for (final group in heightBoxes) _withoutClosingPoint(group.points),
      ],
      structuralChains: [
        for (final path in structuralPaths) path.points,
      ],
      collisionRadii: {
        const VisionBoundaryContourRef(VisionBoundaryContourKind.outer):
            _groupCollisionRadius(outer),
        for (var index = 0; index < interiors.length; index += 1)
          VisionBoundaryContourRef(
            VisionBoundaryContourKind.interior,
            index,
          ): _groupCollisionRadius(interiors[index]),
        for (var index = 0; index < heightBoxes.length; index += 1)
          VisionBoundaryContourRef(
            VisionBoundaryContourKind.heightBox,
            index,
          ): _groupCollisionRadius(heightBoxes[index]),
        for (var index = 0; index < structuralPaths.length; index += 1)
          VisionBoundaryContourRef(
            VisionBoundaryContourKind.structuralChain,
            index,
          ): structuralPaths[index].radius,
      },
    );
  }

  final MapValue map;
  final Rect sourceBounds;
  final List<Offset> outer;
  final List<List<Offset>> interiors;
  final List<List<Offset>> heightBoxes;
  final List<List<Offset>> structuralChains;
  final Map<VisionBoundaryContourRef, double> collisionRadii;

  Iterable<VisionBoundaryContourRef> get contourRefs sync* {
    yield const VisionBoundaryContourRef(VisionBoundaryContourKind.outer);
    for (var index = 0; index < interiors.length; index += 1) {
      yield VisionBoundaryContourRef(VisionBoundaryContourKind.interior, index);
    }
    for (var index = 0; index < heightBoxes.length; index += 1) {
      yield VisionBoundaryContourRef(
        VisionBoundaryContourKind.heightBox,
        index,
      );
    }
    for (var index = 0; index < structuralChains.length; index += 1) {
      yield VisionBoundaryContourRef(
        VisionBoundaryContourKind.structuralChain,
        index,
      );
    }
  }

  List<Offset> contour(VisionBoundaryContourRef ref) => switch (ref.kind) {
        VisionBoundaryContourKind.outer => outer,
        VisionBoundaryContourKind.interior => interiors[ref.index],
        VisionBoundaryContourKind.heightBox => heightBoxes[ref.index],
        VisionBoundaryContourKind.structuralChain =>
          structuralChains[ref.index],
      };

  bool isClosed(VisionBoundaryContourRef ref) =>
      ref.kind != VisionBoundaryContourKind.structuralChain;

  double collisionRadius(VisionBoundaryContourRef ref) =>
      collisionRadii[ref] ?? 0;

  bool _isValidContourRef(VisionBoundaryContourRef ref) => switch (ref.kind) {
        VisionBoundaryContourKind.outer => ref.index == 0,
        VisionBoundaryContourKind.interior =>
          ref.index >= 0 && ref.index < interiors.length,
        VisionBoundaryContourKind.heightBox =>
          ref.index >= 0 && ref.index < heightBoxes.length,
        VisionBoundaryContourKind.structuralChain =>
          ref.index >= 0 && ref.index < structuralChains.length,
      };

  Offset project(
    Offset sourcePoint, {
    required Rect attackTargetBounds,
    required bool isDefense,
  }) {
    final attackPoint = Offset(
      attackTargetBounds.left +
          (sourcePoint.dx - sourceBounds.left) *
              attackTargetBounds.width /
              sourceBounds.width,
      attackTargetBounds.top +
          (sourcePoint.dy - sourceBounds.top) *
              attackTargetBounds.height /
              sourceBounds.height,
    );
    if (!isDefense) return attackPoint;
    const worldWidth = 1000.0 * (16 / 9);
    return Offset(worldWidth - attackPoint.dx, 1000 - attackPoint.dy);
  }

  Offset unproject(
    Offset worldPoint, {
    required Rect attackTargetBounds,
    required bool isDefense,
  }) {
    const worldWidth = 1000.0 * (16 / 9);
    final attackPoint = isDefense
        ? Offset(worldWidth - worldPoint.dx, 1000 - worldPoint.dy)
        : worldPoint;
    return Offset(
      sourceBounds.left +
          (attackPoint.dx - attackTargetBounds.left) *
              sourceBounds.width /
              attackTargetBounds.width,
      sourceBounds.top +
          (attackPoint.dy - attackTargetBounds.top) *
              sourceBounds.height /
              attackTargetBounds.height,
    );
  }

  VisionBoundaryMapDraft move({
    required VisionBoundarySelection? selection,
    required VisionBoundaryEditScope scope,
    required Offset sourceDelta,
  }) {
    if (sourceDelta == Offset.zero) return this;
    if (scope != VisionBoundaryEditScope.all && selection == null) return this;

    List<Offset> shifted(List<Offset> points) => List<Offset>.unmodifiable([
          for (final point in points) point + sourceDelta,
        ]);

    if (scope == VisionBoundaryEditScope.all) {
      return VisionBoundaryMapDraft(
        map: map,
        sourceBounds: sourceBounds,
        outer: shifted(outer),
        interiors: [for (final points in interiors) shifted(points)],
        heightBoxes: [for (final points in heightBoxes) shifted(points)],
        structuralChains: [
          for (final points in structuralChains) shifted(points),
        ],
        collisionRadii: collisionRadii,
      );
    }

    final selected = selection!;
    if (scope == VisionBoundaryEditScope.point) {
      final pointIndex = selected.pointIndex;
      if (pointIndex == null) return this;
      return _replaceContour(selected.contour, [
        for (var index = 0;
            index < contour(selected.contour).length;
            index += 1)
          index == pointIndex
              ? contour(selected.contour)[index] + sourceDelta
              : contour(selected.contour)[index],
      ]);
    }

    return _replaceContour(
      selected.contour,
      shifted(contour(selected.contour)),
    );
  }

  VisionBoundaryMapDraft _replaceContour(
    VisionBoundaryContourRef ref,
    List<Offset> replacement,
  ) {
    switch (ref.kind) {
      case VisionBoundaryContourKind.outer:
        return VisionBoundaryMapDraft(
          map: map,
          sourceBounds: sourceBounds,
          outer: replacement,
          interiors: interiors,
          heightBoxes: heightBoxes,
          structuralChains: structuralChains,
          collisionRadii: collisionRadii,
        );
      case VisionBoundaryContourKind.interior:
        return VisionBoundaryMapDraft(
          map: map,
          sourceBounds: sourceBounds,
          outer: outer,
          interiors: [
            for (var index = 0; index < interiors.length; index += 1)
              index == ref.index ? replacement : interiors[index],
          ],
          heightBoxes: heightBoxes,
          structuralChains: structuralChains,
          collisionRadii: collisionRadii,
        );
      case VisionBoundaryContourKind.heightBox:
        return VisionBoundaryMapDraft(
          map: map,
          sourceBounds: sourceBounds,
          outer: outer,
          interiors: interiors,
          heightBoxes: [
            for (var index = 0; index < heightBoxes.length; index += 1)
              index == ref.index ? replacement : heightBoxes[index],
          ],
          structuralChains: structuralChains,
          collisionRadii: collisionRadii,
        );
      case VisionBoundaryContourKind.structuralChain:
        return VisionBoundaryMapDraft(
          map: map,
          sourceBounds: sourceBounds,
          outer: outer,
          interiors: interiors,
          heightBoxes: heightBoxes,
          structuralChains: [
            for (var index = 0; index < structuralChains.length; index += 1)
              index == ref.index ? replacement : structuralChains[index],
          ],
          collisionRadii: collisionRadii,
        );
    }
  }

  Map<String, dynamic> toJson() => {
        'sourceBounds': [
          _encodedNumber(sourceBounds.left),
          _encodedNumber(sourceBounds.top),
          _encodedNumber(sourceBounds.right),
          _encodedNumber(sourceBounds.bottom),
        ],
        'outer': _encodedContour(outer),
        'interiors': [for (final points in interiors) _encodedContour(points)],
        'heightBoxes': [
          for (final points in heightBoxes) _encodedContour(points)
        ],
        'structuralChains': [
          for (final points in structuralChains) _encodedContour(points),
        ],
        'collisionRadii': _encodedCollisionRadii(),
      };

  String get signature => jsonEncode(toJson());

  static List<List<Offset>> _immutableContours(List<List<Offset>> contours) =>
      List<List<Offset>>.unmodifiable([
        for (final contour in contours) List<Offset>.unmodifiable(contour),
      ]);

  static Map<VisionBoundaryContourRef, double> _decodeCollisionRadii(
    Object? value, {
    required int interiorCount,
    required int heightBoxCount,
    required int structuralChainCount,
  }) {
    if (value == null) return const {};
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid collisionRadii.');
    }
    final interiors = _radii(
      value['interiors'],
      interiorCount,
      'collisionRadii.interiors',
    );
    final heightBoxes = _radii(
      value['heightBoxes'],
      heightBoxCount,
      'collisionRadii.heightBoxes',
    );
    final structuralChains = _radii(
      value['structuralChains'],
      structuralChainCount,
      'collisionRadii.structuralChains',
    );
    return {
      const VisionBoundaryContourRef(VisionBoundaryContourKind.outer):
          value['outer'] == null
              ? 0
              : _radius(value['outer'], 'collisionRadii.outer'),
      for (var index = 0; index < interiors.length; index += 1)
        VisionBoundaryContourRef(VisionBoundaryContourKind.interior, index):
            interiors[index],
      for (var index = 0; index < heightBoxes.length; index += 1)
        VisionBoundaryContourRef(VisionBoundaryContourKind.heightBox, index):
            heightBoxes[index],
      for (var index = 0; index < structuralChains.length; index += 1)
        VisionBoundaryContourRef(
          VisionBoundaryContourKind.structuralChain,
          index,
        ): structuralChains[index],
    };
  }

  Map<String, dynamic> _encodedCollisionRadii() {
    List<num> encode(VisionBoundaryContourKind kind, int count) => [
          for (var index = 0; index < count; index += 1)
            _encodedNumber(
              collisionRadius(VisionBoundaryContourRef(kind, index)),
            ),
        ];
    return {
      'outer': _encodedNumber(
        collisionRadius(
          const VisionBoundaryContourRef(VisionBoundaryContourKind.outer),
        ),
      ),
      'interiors': encode(
        VisionBoundaryContourKind.interior,
        interiors.length,
      ),
      'heightBoxes': encode(
        VisionBoundaryContourKind.heightBox,
        heightBoxes.length,
      ),
      'structuralChains': encode(
        VisionBoundaryContourKind.structuralChain,
        structuralChains.length,
      ),
    };
  }

  static List<double> _radii(Object? value, int count, String label) {
    if (value == null || (value is List && value.isEmpty)) {
      return List<double>.filled(count, 0);
    }
    if (value is! List || value.length != count) {
      throw FormatException('Invalid $label list.');
    }
    return List<double>.unmodifiable([
      for (final encoded in value) _radius(encoded, label),
    ]);
  }

  static double _radius(Object? value, String label) {
    final radius = _number(value);
    if (radius < 0) throw FormatException('Invalid $label radius.');
    return radius;
  }

  static double _groupCollisionRadius(VisionCollisionGroup group) =>
      group.segments.fold<double>(
        0,
        (radius, segment) => math.max(radius, segment.collisionRadius),
      );

  static Rect _rect(Object? value, String label) {
    if (value is! List || value.length != 4) {
      throw FormatException('Invalid $label.');
    }
    final values = value.map(_number).toList(growable: false);
    return Rect.fromLTRB(values[0], values[1], values[2], values[3]);
  }

  static List<List<Offset>> _contours(Object? value, String label) {
    if (value is! List) throw FormatException('Invalid $label list.');
    return List<List<Offset>>.unmodifiable([
      for (var index = 0; index < value.length; index += 1)
        _contour(value[index], '$label[$index]'),
    ]);
  }

  static List<List<Offset>> _chains(Object? value, String label) {
    if (value is! List) throw FormatException('Invalid $label list.');
    return List<List<Offset>>.unmodifiable([
      for (var index = 0; index < value.length; index += 1)
        _chain(value[index], '$label[$index]'),
    ]);
  }

  static List<Offset> _contour(Object? value, String label) {
    if (value is! List || value.length < 3) {
      throw FormatException('Invalid $label contour.');
    }
    final points = <Offset>[
      for (final encoded in value) _point(encoded, label),
    ];
    if (points.length > 3 &&
        (points.first - points.last).distanceSquared < 1e-9) {
      points.removeLast();
    }
    return List<Offset>.unmodifiable(points);
  }

  static List<Offset> _chain(Object? value, String label) {
    if (value is! List || value.length < 2) {
      throw FormatException('Invalid $label chain.');
    }
    return List<Offset>.unmodifiable([
      for (final encoded in value) _point(encoded, label),
    ]);
  }

  static List<Offset> _withoutClosingPoint(List<Offset> points) {
    if (points.length > 2 &&
        (points.first - points.last).distanceSquared < 1e-9) {
      return List<Offset>.unmodifiable(points.sublist(0, points.length - 1));
    }
    return List<Offset>.unmodifiable(points);
  }

  static Offset _point(Object? value, String label) {
    if (value is! List || value.length != 2) {
      throw FormatException('Invalid point in $label.');
    }
    return Offset(_number(value[0]), _number(value[1]));
  }

  static double _number(Object? value) {
    if (value is! num || !value.toDouble().isFinite) {
      throw const FormatException('Collision coordinates must be finite.');
    }
    return value.toDouble();
  }

  static List<List<num>> _encodedContour(List<Offset> points) => [
        for (final point in points)
          [_encodedNumber(point.dx), _encodedNumber(point.dy)],
      ];

  static num _encodedNumber(double value) {
    // Preserve the rendered SVG coordinates below a tenth of a world unit;
    // coarser three-decimal source bounds can rescale an otherwise exact wall
    // onto the neighboring pixel at high zoom.
    final rounded = (value * 1000000).round() / 1000000;
    return rounded == rounded.roundToDouble() ? rounded.toInt() : rounded;
  }
}

Map<String, dynamic> mergeVisionBoundaryDocuments({
  required Map<String, dynamic> reference,
  required Map<String, dynamic> edits,
}) {
  final referenceMaps = reference['maps'];
  final editMaps = edits['maps'];
  if (reference['version'] != 1 || referenceMaps is! Map<String, dynamic>) {
    throw const FormatException('Invalid collision reference manifest.');
  }
  if (edits['version'] != 1 || editMaps is! Map<String, dynamic>) {
    throw const FormatException('Invalid collision edit manifest.');
  }
  return <String, dynamic>{
    ...reference,
    'maps': <String, dynamic>{...referenceMaps, ...editMaps},
  };
}

Map<String, dynamic> withVisionBoundaryDraft({
  required Map<String, dynamic> document,
  required VisionBoundaryMapDraft draft,
}) {
  final maps = document['maps'];
  if (document['version'] != 1 || maps is! Map<String, dynamic>) {
    throw const FormatException('Invalid collision reference manifest.');
  }
  return <String, dynamic>{
    ...document,
    'maps': <String, dynamic>{...maps, draft.map.name: draft.toJson()},
  };
}
