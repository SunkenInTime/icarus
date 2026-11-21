import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/wall_path.dart';
import 'package:icarus/view_cone/vision_occluders.dart';

VisionOccluder? occluderOf(PlacedAbility placed, {required double mapScale}) {
  final ability = placed.data.abilityData;
  if (ability == null || !blocksSight(placed.data)) return null;
  final anchor = placed.position +
      CoordinateSystem.virtualToWorld(
        storedAbilityAnchor(ability: ability, mapScale: mapScale),
      );
  double inWorld(double virtual) =>
      CoordinateSystem.virtualLengthInWorld(virtual * mapScale);
  Offset ahead(double virtual) =>
      anchor +
      Offset.fromDirection(placed.rotation - math.pi / 2, inWorld(virtual));
  final shown = placed.visualState;
  return switch ((ability, placed.wallPath)) {
    (ImageAbility(:final size, :final supportsInactiveState), _)
        when shown.showRangeFill || !supportsInactiveState =>
      CircleOccluder(anchor, inWorld(size / 2)),
    (CircleAbility(:final size), _)
        when shown.showRangeFill || shown.showRangeOutline =>
      CircleOccluder(anchor, inWorld(size / 2)),
    (SquareAbility(isWall: true, :final height, :final distanceBetweenAOE), _)
        when shown.showRangeFill =>
      LineOccluder([
        ahead(distanceBetweenAOE),
        ahead(distanceBetweenAOE + height),
      ]),
    (GuidedWallAbility(), final path?) when path.isNotEmpty => LineOccluder(
        smoothWallLine([anchor, for (final point in path) anchor + point]),
      ),
    _ => null,
  };
}

List<VisionOccluder> pageOccluders(
  Iterable<PlacedAbility> abilities, {
  required double mapScale,
}) =>
    [
      for (final ability in abilities)
        if (occluderOf(ability, mapScale: mapScale) case final occluder?)
          occluder,
    ];

class PageOccludersScope extends InheritedWidget {
  const PageOccludersScope({
    super.key,
    required this.occluders,
    required super.child,
  });

  final List<VisionOccluder> occluders;

  static List<VisionOccluder>? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<PageOccludersScope>()
      ?.occluders;

  @override
  bool updateShouldNotify(PageOccludersScope oldWidget) =>
      !listEquals(oldWidget.occluders, occluders);
}
