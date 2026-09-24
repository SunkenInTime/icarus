import 'dart:ui';

import 'package:icarus/page_transition/navigation_geometry.dart';

/// Movement surfaces and the same standing-height defaults used by sightlines.
class NavigationGeometryMap {
  const NavigationGeometryMap({
    required this.geometry,
    required this.observerHeightCm,
    required this.defaultFloorElevationCm,
    this.defenseOffsetCanvas = Offset.zero,
  });

  final NavigationGeometry geometry;
  final double observerHeightCm;
  final double defaultFloorElevationCm;
  final Offset defenseOffsetCanvas;
}
