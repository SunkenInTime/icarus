import 'dart:convert';
import 'dart:ui' show Offset, Path;

import 'package:icarus/view_cone/svg_height_visibility.dart';

/// What one view cone computed, small enough to paste into a message and
/// complete enough to recompute the same cone away from the app. The builder
/// takes the exact inputs the cone was drawn from, so a report always
/// describes the cone the user is looking at.
class SightlineReport {
  const SightlineReport._(this.json, this.cone, this.eyeElevationMeters);

  /// The report body. Ordinary JSON values only, ready for [jsonEncode].
  final Map<String, Object?> json;

  /// The recomputed cone, or null when there is nothing to compute: a legacy
  /// map, or an origin the model does not cover.
  final SvgVisibilityCone? cone;

  /// The eye the cone and every ray were cast from, in source meters.
  final double? eyeElevationMeters;

  String encode() => const JsonEncoder.withIndent('  ').convert(json);

  /// What the user sees as the lit area, in source SVG coordinates. Measured
  /// destination floors live only in the path, so it is preferred over the
  /// horizontal polygon whenever the cone carries one.
  Path? get visibleArea {
    final result = cone;
    if (result == null) return null;
    final path = result.visibilityPath;
    if (path != null) return path;
    if (result.polygon.length < 3) return null;
    return Path()..addPolygon(result.polygon, true);
  }
}

/// Rays cast across the aperture, plus the centre ray.
const int sightlineReportRayCount = 24;

SightlineReport buildSightlineReport({
  required String map,
  required bool isAttack,
  required String appVersion,
  required Offset canonicalOrigin,
  required double facingRadians,
  required double apertureRadians,
  required double rangeSvg,
  required double? savedElevationCm,
  Offset? svgOrigin,
  SvgHeightVisibility? model,
}) {
  final side = isAttack ? 'attack' : 'defense';
  final report = <String, Object?>{
    'version': 1,
    'map': map,
    'side': side,
    'appVersion': appVersion,
    'runtime': model == null ? 'legacy' : 'svg-height',
    if (svgOrigin != null) 'svgOrigin': _point(svgOrigin),
    'canonicalOrigin': _point(canonicalOrigin),
    'facingRadians': _round(facingRadians),
    'apertureRadians': _round(apertureRadians),
    'rangeSvg': _round(rangeSvg),
    'savedElevationCm':
        savedElevationCm == null ? null : _round(savedElevationCm),
  };

  final origin = svgOrigin;
  if (model == null || origin == null) {
    report['note'] = '';
    return SightlineReport._(report, null, null);
  }

  final groundMeters = model.ground?.heightAt(origin);
  // The cone widget draws nothing from here, so there is no cone to describe.
  // Saying so is the finding.
  if (!model.receiverContains(origin) ||
      (model.ground != null && groundMeters == null)) {
    report['offModel'] = true;
    report['supportsHere'] = _supportsHere(model, origin);
    report['hits'] = const [];
    report['note'] = '';
    return SightlineReport._(report, null, null);
  }

  final support =
      model.standingSupportAt(origin, savedEyeElevationCm: savedElevationCm);
  final cone = model.cone(
    origin: origin,
    directionRadians: facingRadians,
    range: rangeSvg,
    apertureRadians: apertureRadians,
    supportId: support?.id,
  );
  final eye = cone.eyeElevationMeters;

  report['standing'] = <String, Object?>{
    'supportId': support?.id,
    'label': support?.label,
    'surfaceMeters': _optional(support?.surfaceElevationAt(origin)),
    'groundMeters': _optional(groundMeters),
    'eyeMeters': _optional(eye),
    'automatic': _isAutomatic(model, origin, savedElevationCm),
  };
  report['supportsHere'] = _supportsHere(model, origin);
  report['hits'] = _hits(
    model: model,
    origin: origin,
    facingRadians: facingRadians,
    apertureRadians: apertureRadians,
    rangeSvg: rangeSvg,
    supportId: support?.id,
    eyeElevationMeters: eye,
  );
  report['note'] = '';
  return SightlineReport._(report, cone, eye);
}

/// True when the saved height no longer picks out a level here, so the cone
/// fell back to the automatic standing choice.
bool _isAutomatic(
    SvgHeightVisibility model, Offset origin, double? savedElevationCm) {
  if (savedElevationCm == null) return true;
  return model.supportForAbsoluteEyeElevation(origin, savedElevationCm) ==
          null &&
      !model.isGroundEyeElevation(origin, savedElevationCm);
}

List<Map<String, Object?>> _supportsHere(
    SvgHeightVisibility model, Offset origin) {
  return [
    for (final support in model.supportsAt(origin))
      {
        'id': support.id,
        'label': support.label,
        'surfaceMeters': _optional(support.surfaceElevationAt(origin)),
        'automaticStandingAllowed': support.automaticStandingAllowed,
      }
  ];
}

List<Map<String, Object?>> _hits({
  required SvgHeightVisibility model,
  required Offset origin,
  required double facingRadians,
  required double apertureRadians,
  required double rangeSvg,
  required String? supportId,
  required double? eyeElevationMeters,
}) {
  final walls = {for (final wall in model.walls) wall.id: wall};
  final half = apertureRadians / 2;
  final angles = <double>[
    for (var i = 0; i < sightlineReportRayCount; i++)
      -half + apertureRadians * i / (sightlineReportRayCount - 1),
    0,
  ]..sort();
  final rows = <Map<String, Object?>>[];
  for (final offset in angles) {
    // Absolute, in the same frame as facingRadians, so one ray reads on its
    // own without knowing where the cone points.
    final angle = facingRadians + offset;
    final hit = model.castRay(
      origin: origin,
      directionRadians: angle,
      range: rangeSvg,
      supportId: supportId,
    );
    final wall = hit == null ? null : walls[hit.wallId];
    rows.add({
      'angleRadians': _round(angle),
      'distanceSvg': _round(hit?.distance ?? rangeSvg),
      'wallId': hit?.wallId,
      if (wall != null)
        'bands': [
          for (final band in wall.bands) [_round(band.bottom), _round(band.top)]
        ],
      if (wall != null) 'floorMeters': _optional(wall.floorElevationMeters),
      'blocks': wall != null &&
          (eyeElevationMeters == null || wall.blocks(eyeElevationMeters)),
    });
  }
  return rows;
}

List<double> _point(Offset point) => [_round(point.dx), _round(point.dy)];

double? _optional(double? value) => value == null ? null : _round(value);

double _round(double value) {
  if (!value.isFinite) return value;
  return (value * 1000).roundToDouble() / 1000;
}

/// `pearl-attack-20260917-142530`, the stem both report files share.
String sightlineReportFileStem(String map, bool isAttack, DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  final stamp = '${at.year}${two(at.month)}${two(at.day)}'
      '-${two(at.hour)}${two(at.minute)}${two(at.second)}';
  return '$map-${isAttack ? 'attack' : 'defense'}-$stamp';
}
