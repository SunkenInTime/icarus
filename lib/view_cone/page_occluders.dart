import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/wall_path.dart';
import 'package:icarus/view_cone/cone_coverage.dart';
import 'package:icarus/view_cone/vision_occluders.dart';

Offset placedAbilityMiddle(PlacedAbility placed, {required double mapScale}) =>
    placed.position +
    CoordinateSystem.virtualToWorld(
      storedAbilityAnchor(ability: placed.data.abilityData!, mapScale: mapScale),
    );

VisionOccluder? occluderOf(PlacedAbility placed, {required double mapScale}) {
  final ability = placed.data.abilityData;
  if (ability == null || !blocksSight(placed.data)) return null;
  final anchor = placedAbilityMiddle(placed, mapScale: mapScale);
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

String sightBlockName(AbilityInfo ability) =>
    '${AgentData.agents[ability.type]!.name} ${ability.name}';

SightBlock? sightBlockOf(PlacedAbility placed, {required double mapScale}) =>
    switch (occluderOf(placed, mapScale: mapScale)) {
      final shape? => SightBlock(name: sightBlockName(placed.data), shape: shape),
      null => null,
    };

VisionOccluder movedOccluder(VisionOccluder occluder, Offset by) =>
    switch (occluder) {
      CircleOccluder() => occluder.map((point) => point + by, 1),
      LineOccluder() => occluder.map((point) => point + by),
    };

Offset selectionDragInWorld(Offset by, {required bool isAttack}) =>
    CoordinateSystem.instance.screenToCoordinate(by) * (isAttack ? 1 : -1);

class SightBlockersScope extends InheritedWidget {
  const SightBlockersScope({
    super.key,
    required this.blockers,
    required super.child,
  });

  final SightBlockers? blockers;

  static SightBlockers? of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<SightBlockersScope>();
    return scope == null
        ? ConeCoverageScope.maybeOf(context)?.blockers
        : scope.blockers;
  }

  @override
  bool updateShouldNotify(SightBlockersScope oldWidget) =>
      !identical(oldWidget.blockers, blockers);
}

class SightBlocker extends StatefulWidget {
  const SightBlocker({super.key, required this.block, required this.child});

  final SightBlock? block;
  final Widget child;

  @override
  State<SightBlocker> createState() => _SightBlockerState();
}

class _SightBlockerState extends State<SightBlocker> {
  SightBlockers? _blockers;

  void _declare() {
    final blockers = SightBlockersScope.of(context);
    if (!identical(blockers, _blockers)) {
      _blockers?.declare(this, null);
      _blockers = blockers;
    }
    blockers?.declare(this, widget.block);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _declare();
  }

  @override
  void didUpdateWidget(SightBlocker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _declare();
  }

  @override
  void dispose() {
    _blockers?.declare(this, null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
