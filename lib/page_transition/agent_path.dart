import 'dart:ui';

import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';

/// A distance-normalized route used by page transitions.
///
/// Sampling by distance, instead of by waypoint index, keeps an agent's speed
/// constant even when A* produces differently sized route segments.
class AgentTransitionPath {
  AgentTransitionPath(List<Offset> points)
      : points = List<Offset>.unmodifiable(points),
        _cumulativeDistances = _buildCumulativeDistances(points);

  /// A move the map has no route for (off the map, onto a box, no map data)
  /// goes straight, as every other item does. It may cross a wall; an agent
  /// that holds still and then jumps reads as broken.
  AgentTransitionPath.straight(Offset start, Offset end) : this([start, end]);

  final List<Offset> points;
  final List<double> _cumulativeDistances;

  double get length =>
      _cumulativeDistances.isEmpty ? 0 : _cumulativeDistances.last;

  Offset positionAt(double progress) {
    if (points.isEmpty) return Offset.zero;
    if (points.length == 1 || length <= _epsilon) return points.last;

    final distance = length * progress.clamp(0.0, 1.0);
    var low = 1, high = points.length - 1;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_cumulativeDistances[middle] + _epsilon < distance) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final index = low;
    final segmentStart = _cumulativeDistances[index - 1];
    final segmentLength = _cumulativeDistances[index] - segmentStart;
    if (segmentLength <= _epsilon) return points[index];
    final localProgress = (distance - segmentStart) / segmentLength;
    return Offset.lerp(points[index - 1], points[index], localProgress) ??
        points[index];
  }

  static List<double> _buildCumulativeDistances(List<Offset> points) {
    if (points.isEmpty) return const [];
    final result = <double>[0];
    for (var index = 1; index < points.length; index += 1) {
      result.add(result.last + (points[index] - points[index - 1]).distance);
    }
    return List<double>.unmodifiable(result);
  }
}

class AgentTransitionPathPlanner {
  const AgentTransitionPathPlanner._();

  static Map<String, AgentTransitionPath> plan({
    required List<PageTransitionEntry> entries,
    NavigationGeometryMap? navigation,
    required CoordinateSystem coordinateSystem,
  }) {
    final native = navigation?.geometry;
    Offset centerFor(Offset position) =>
        position + coordinateSystem.virtualOffsetToWorld(storedAgentAnchor);
    // Without map data agents go straight. A path, not an empty plan: the
    // overlay draws a path from the agent's center, so an agent that changes
    // form between pages (a cone or circle composite) stays where it stands.
    if (native == null) {
      return {
        for (final entry in entries)
          if (entry.kind == TransitionKind.move &&
              entry.visualWidget is PlacedAgentNode)
            entry.id: AgentTransitionPath.straight(
              centerFor(entry.startPos),
              centerFor(entry.endPos),
            ),
      };
    }
    final observerHeight = navigation!.observerHeightCm;
    final defaultFloor = navigation.defaultFloorElevationCm;

    // Both artwork sides now use the canonical saved-position frame. A side
    // flip must query the same physical floor and route.
    double? elevationFor(PlacedWidget widget, Offset center) {
      final override =
          widget is PlacedViewConeAgent ? widget.visionElevation : null;
      if (override != null) return override;
      final floor =
          native.floorHeightAt(center, preferredElevation: defaultFloor);
      return floor == null ? null : floor + observerHeight;
    }

    return {
      for (final entry in entries)
        if (entry.kind == TransitionKind.move &&
            entry.visualWidget is PlacedAgentNode)
          entry.id: () {
            final startCenter = centerFor(entry.startPos);
            final endCenter = centerFor(entry.endPos);
            final startElevation = elevationFor(entry.from!, startCenter);
            final endElevation = elevationFor(entry.to!, endCenter);
            final route = native.findRoute(
              start: startCenter,
              end: endCenter,
              startFloorHeight: startElevation == null
                  ? null
                  : startElevation - observerHeight,
              endFloorHeight:
                  endElevation == null ? null : endElevation - observerHeight,
            );
            return route.isReachable
                ? AgentTransitionPath(route.points)
                : AgentTransitionPath.straight(startCenter, endCenter);
          }(),
    };
  }
}

const double _epsilon = 1e-6;
