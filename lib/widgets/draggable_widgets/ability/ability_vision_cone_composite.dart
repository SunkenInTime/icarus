import 'package:flutter/material.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';

Offset abilityVisionConeChildOffsetVirtual({
  required Ability ability,
  required double mapScale,
  required double abilitySize,
}) {
  final abilityAnchor = ability.getAnchorPoint(
    mapScale: mapScale,
    abilitySize: abilitySize,
  );
  return ViewConeWidget.anchorPointVirtual - abilityAnchor;
}

Offset abilityVisionConeChildOffsetScreen({
  required CoordinateSystem coordinateSystem,
  required Ability ability,
  required double mapScale,
  required double abilitySize,
}) {
  final offset = abilityVisionConeChildOffsetVirtual(
    ability: ability,
    mapScale: mapScale,
    abilitySize: abilitySize,
  );
  return Offset(
    coordinateSystem.scale(offset.dx),
    coordinateSystem.scale(offset.dy),
  );
}

/// Places an ability at the apex of its vision cone. The composite rotates
/// around that apex while counter-rotating the ability so its icon stays
/// upright.
class AbilityVisionConeComposite extends StatelessWidget {
  const AbilityVisionConeComposite({
    super.key,
    required this.ability,
    required this.spec,
    required this.rotation,
    required this.length,
    required this.mapScale,
    required this.abilitySize,
    required this.child,
    this.coordinatePosition,
    this.applyRotation = true,
    this.clipToGeometry = true,
  });

  final PlacedAbility ability;
  final AbilityVisionConeSpec spec;
  final double rotation;
  final double length;
  final double mapScale;
  final double abilitySize;
  final Widget child;

  /// Stored top-left position used while rendering an animated transition.
  final Offset? coordinatePosition;
  final bool applyRotation;
  final bool clipToGeometry;

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final abilityData = ability.data.abilityData!;
    final resolvedLength = spec.resolveLength(
      storedLength: length,
      mapScale: mapScale,
    );
    final coneAnchor = ViewConeWidget.anchorPointVirtual.scale(
      coordinateSystem.scaleFactor,
      coordinateSystem.scaleFactor,
    );
    final childOffset = abilityVisionConeChildOffsetScreen(
      coordinateSystem: coordinateSystem,
      ability: abilityData,
      mapScale: mapScale,
      abilitySize: abilitySize,
    );
    final abilityAnchor = abilityData
        .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
        .scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);
    final storedAnchor = storedAbilityAnchor(
      ability: abilityData,
      mapScale: mapScale,
    );
    final worldOrigin = clipToGeometry
        ? (coordinatePosition ?? ability.position) +
            coordinateSystem.virtualOffsetToWorld(storedAnchor)
        : null;

    final composite = SizedBox(
      width: coordinateSystem.scale(ViewConeWidget.totalWidthVirtual),
      height: coordinateSystem.scale(ViewConeWidget.totalHeightVirtual),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: ViewConeWidget(
              key: const ValueKey('ability-vision-cone'),
              id: null,
              angle: spec.angleDegrees,
              rotation: rotation,
              length: resolvedLength,
              worldOrigin: worldOrigin,
              showCenterMarker: false,
            ),
          ),
          Positioned(
            left: childOffset.dx,
            top: childOffset.dy,
            child: Transform.rotate(
              angle: -rotation,
              alignment: Alignment.topLeft,
              origin: abilityAnchor,
              child: child,
            ),
          ),
        ],
      ),
    );

    if (!applyRotation || rotation == 0) {
      return composite;
    }

    return Transform.rotate(
      angle: rotation,
      alignment: Alignment.topLeft,
      origin: coneAnchor,
      child: composite,
    );
  }
}
