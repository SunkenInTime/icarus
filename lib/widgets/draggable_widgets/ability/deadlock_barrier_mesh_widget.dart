import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';

const double deadlockBarrierMeshMinArmLengthMeters = 1.0;
const double deadlockBarrierMeshMaxArmLengthMeters = 10.0;
const List<double> deadlockBarrierMeshDefaultArmLengthsMeters = <double>[
  10.0,
  10.0,
  10.0,
  10.0,
];
const double deadlockBarrierMeshArmThicknessVirtual = 4.0;
const double deadlockBarrierMeshHandleDiameterVirtual = 15.0;
const double deadlockBarrierMeshHandleVisualDiameterVirtual = 11.0;
const double deadlockBarrierMeshOverflowPaddingVirtual = 6.0;

enum DeadlockBarrierMeshArm {
  topRight,
  topLeft,
  bottomLeft,
  bottomRight,
}

extension DeadlockBarrierMeshArmGeometry on DeadlockBarrierMeshArm {
  double get angle {
    switch (this) {
      case DeadlockBarrierMeshArm.topRight:
        return -math.pi / 4;
      case DeadlockBarrierMeshArm.topLeft:
        return -3 * math.pi / 4;
      case DeadlockBarrierMeshArm.bottomLeft:
        return 3 * math.pi / 4;
      case DeadlockBarrierMeshArm.bottomRight:
        return math.pi / 4;
    }
  }

  Offset get unitVector {
    const diagonal = math.sqrt1_2;
    switch (this) {
      case DeadlockBarrierMeshArm.topRight:
        return const Offset(diagonal, -diagonal);
      case DeadlockBarrierMeshArm.topLeft:
        return const Offset(-diagonal, -diagonal);
      case DeadlockBarrierMeshArm.bottomLeft:
        return const Offset(-diagonal, diagonal);
      case DeadlockBarrierMeshArm.bottomRight:
        return const Offset(diagonal, diagonal);
    }
  }
}

List<double> normalizeDeadlockBarrierMeshArmLengths(List<double>? armLengths) {
  final normalized =
      List<double>.from(deadlockBarrierMeshDefaultArmLengthsMeters);
  if (armLengths == null) {
    return normalized;
  }

  final safeLength = math.min(armLengths.length, normalized.length);
  for (var i = 0; i < safeLength; i++) {
    normalized[i] = armLengths[i]
        .clamp(
          deadlockBarrierMeshMinArmLengthMeters,
          deadlockBarrierMeshMaxArmLengthMeters,
        )
        .toDouble();
  }
  return normalized;
}

List<double> reorderDeadlockBarrierMeshArmLengthsForSideSwitch(
  List<double> armLengths,
) {
  final normalized = normalizeDeadlockBarrierMeshArmLengths(armLengths);
  return <double>[
    normalized[2],
    normalized[3],
    normalized[0],
    normalized[1],
  ];
}

double deadlockBarrierMeshArmLengthVirtual(
  double armLengthMeters,
  double mapScale,
) {
  return armLengthMeters * AgentData.inGameMetersDiameter * mapScale;
}

class DeadlockBarrierMeshWidget extends ConsumerWidget {
  const DeadlockBarrierMeshWidget({
    super.key,
    required this.iconPath,
    required this.id,
    required this.isAlly,
    required this.color,
    required this.mapScale,
    required this.armLengthsMeters,
    this.lineUpId,
    this.showCenterAbility = true,
  });

  final String iconPath;
  final String? id;
  final bool isAlly;
  final Color color;
  final double mapScale;
  final List<double> armLengthsMeters;
  final String? lineUpId;
  final bool showCenterAbility;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final normalizedArmLengths =
        normalizeDeadlockBarrierMeshArmLengths(armLengthsMeters);
    final maxExtentVirtual = deadlockBarrierMeshMaxExtent(
      mapScale: mapScale,
      abilitySize: abilitySize,
    );
    final maxExtent = coordinateSystem.scale(maxExtentVirtual);
    final center = maxExtent / 2;
    final armThickness =
        coordinateSystem.scale(deadlockBarrierMeshArmThicknessVirtual);

    return SizedBox.square(
      dimension: maxExtent,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final arm in DeadlockBarrierMeshArm.values)
            _BarrierArm(
              center: center,
              arm: arm,
              length: coordinateSystem.scale(
                deadlockBarrierMeshArmLengthVirtual(
                  normalizedArmLengths[arm.index],
                  mapScale,
                ),
              ),
              thickness: armThickness,
              color: color,
            ),
          if (showCenterAbility)
            Positioned.fill(
              child: Align(
                alignment: Alignment.center,
                child: AbilityWidget(
                  lineUpId: lineUpId,
                  iconPath: iconPath,
                  id: id,
                  isAlly: isAlly,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

double deadlockBarrierMeshMaxExtent({
  required double mapScale,
  required double abilitySize,
}) {
  final meterScale = AgentData.inGameMetersDiameter * mapScale;
  final maxArmLengthVirtual =
      deadlockBarrierMeshMaxArmLengthMeters * meterScale;
  final projectedReachVirtual = maxArmLengthVirtual * math.cos(math.pi / 4);
  final contentExtent = math.max(abilitySize, projectedReachVirtual * 2) +
      deadlockBarrierMeshHandleDiameterVirtual;
  return contentExtent + (deadlockBarrierMeshOverflowPaddingVirtual * 2);
}

Offset deadlockBarrierMeshHandleCenter({
  required DeadlockBarrierMeshArm arm,
  required double armLengthMeters,
  required double mapScale,
  required double abilitySize,
  required CoordinateSystem coordinateSystem,
}) {
  final maxExtent = coordinateSystem.scale(
    deadlockBarrierMeshMaxExtent(
      mapScale: mapScale,
      abilitySize: abilitySize,
    ),
  );
  final center = maxExtent / 2;
  final armLength = coordinateSystem.scale(
    deadlockBarrierMeshArmLengthVirtual(armLengthMeters, mapScale),
  );
  final vector = arm.unitVector;
  return Offset(
    center + (vector.dx * armLength),
    center + (vector.dy * armLength),
  );
}

Offset deadlockBarrierMeshRotationHandleCenter({
  required double mapScale,
  required double abilitySize,
  required CoordinateSystem coordinateSystem,
}) {
  final maxExtent = coordinateSystem.scale(
    deadlockBarrierMeshMaxExtent(
      mapScale: mapScale,
      abilitySize: abilitySize,
    ),
  );
  final abilitySizePx = coordinateSystem.scale(abilitySize);
  final iconInset = (maxExtent - abilitySizePx) / 2;
  return Offset(maxExtent / 2, iconInset / 2);
}

class _BarrierArm extends StatelessWidget {
  const _BarrierArm({
    required this.center,
    required this.arm,
    required this.length,
    required this.thickness,
    required this.color,
  });

  final double center;
  final DeadlockBarrierMeshArm arm;
  final double length;
  final double thickness;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final vector = arm.unitVector;
    final bodyCenter = Offset(
      center + (vector.dx * (length / 2)),
      center + (vector.dy * (length / 2)),
    );

    return Positioned(
      left: bodyCenter.dx - (length / 2),
      top: bodyCenter.dy - (thickness / 2),
      child: IgnorePointer(
        child: Transform.rotate(
          angle: arm.angle,
          alignment: Alignment.center,
          child: Container(
            width: length,
            height: thickness,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );
  }
}
