import 'dart:ui';

import 'svg_height_visibility.dart';

/// Keeps the last cone for each observer in one immutable map model.
/// Call [retainObservers] when the page's observer list changes. Create a new
/// cache when the map model changes; cached cones cannot cross map revisions.
class SvgHeightConeCache {
  SvgHeightConeCache(this.model);

  final SvgHeightVisibility model;
  final _entries = <Object, (_ConeInputs, SvgVisibilityCone)>{};

  int get observerCount => _entries.length;
  int queryCount = 0, reuseCount = 0, totalQueryMicroseconds = 0;
  double totalNativeQueryMicroseconds = 0;

  void retainObservers(Iterable<Object> observers) {
    final active = observers.toSet();
    _entries.removeWhere((id, _) => !active.contains(id));
  }

  void removeObserver(Object observer) => _entries.remove(observer);

  void clear() => _entries.clear();

  /// A reused cone retains the statistics of its original calculation.
  /// Use [SvgCachedCone.reused] or an external timer to measure current work.
  SvgCachedCone cone({
    required Object observerId,
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
    final inputs = (
      origin,
      directionRadians,
      range,
      apertureRadians,
      cameraHeightMeters,
      supportHeightAboveFloorMeters,
      supportId,
      absoluteEyeElevationMeters,
      arcSteps
    );
    final previous = _entries[observerId];
    if (previous != null && previous.$1 == inputs) {
      reuseCount++;
      return SvgCachedCone(previous.$2, reused: true);
    }
    final result = model.cone(
        origin: origin,
        directionRadians: directionRadians,
        range: range,
        apertureRadians: apertureRadians,
        cameraHeightMeters: cameraHeightMeters,
        supportHeightAboveFloorMeters: supportHeightAboveFloorMeters,
        supportId: supportId,
        absoluteEyeElevationMeters: absoluteEyeElevationMeters,
        arcSteps: arcSteps);
    _entries[observerId] = (inputs, result);
    queryCount++;
    totalQueryMicroseconds += result.stats.elapsedMicroseconds;
    totalNativeQueryMicroseconds += result.stats.nativeMicros;
    return SvgCachedCone(result, reused: false);
  }
}

typedef _ConeInputs = (
  Offset,
  double,
  double,
  double,
  double?,
  double,
  String?,
  double?,
  int
);

class SvgCachedCone {
  const SvgCachedCone(this.cone, {required this.reused});
  final SvgVisibilityCone cone;
  final bool reused;
}
