import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class CustomRectangleUtilityWidget extends ConsumerWidget {
  const CustomRectangleUtilityWidget({
    super.key,
    required this.id,
    this.widthMeters,
    this.rectLengthMeters,
    this.colorValue,
    this.opacityPercent,
    this.mapScale,
  });

  final String? id;
  final double? widthMeters;
  final double? rectLengthMeters;
  final int? colorValue;
  final int? opacityPercent;
  final double? mapScale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coord = CoordinateSystem.instance;
    final utility = _getUtility(ref);
    final effectiveMapScale = mapScale ?? 1.0;

    final effectiveWidthMeters = utility?.customWidth ??
        widthMeters ??
        CustomRectangleUtility.defaultWidthMeters;
    final effectiveLengthMeters = utility?.customLength ??
        rectLengthMeters ??
        CustomRectangleUtility.defaultLengthMeters;
    final effectiveColorValue = utility?.customColorValue ??
        colorValue ??
        CustomRectangleUtility.defaultColorValue;
    final effectiveOpacityPercent = utility?.customOpacityPercent ??
        opacityPercent ??
        CustomRectangleUtility.defaultOpacityPercent;

    final color = Color(effectiveColorValue);
    final fillOpacity = (effectiveOpacityPercent / 100).clamp(0.0, 1.0);
    final widthInVirtual = effectiveWidthMeters *
        AgentData.inGameMetersDiameter *
        effectiveMapScale;
    final lengthInVirtual = effectiveLengthMeters *
        AgentData.inGameMetersDiameter *
        effectiveMapScale;
    final scaledWidth = coord.scale(widthInVirtual);
    final scaledLength = coord.scale(lengthInVirtual);
    final iconSize = coord.scale(Settings.utilityIconSize);

    return SizedBox(
      width: scaledLength,
      height: scaledWidth,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: fillOpacity),
                  border: Border.all(color: color, width: coord.scale(2)),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
          MouseWatch(
            cursor: SystemMouseCursors.click,
            onDeleteKeyPressed: () {
              if (id == null) return;
              final action = UserAction(
                type: ActionType.deletion,
                id: id!,
                group: ActionGroup.utility,
              );
              ref.read(actionProvider.notifier).addAction(action);
              ref.read(utilityProvider.notifier).removeUtility(id!);
            },
            child: Center(
              child: Container(
                width: iconSize * 0.8,
                height: iconSize * 0.8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.9),
                  border:
                      Border.all(color: Colors.white, width: coord.scale(2)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  PlacedUtility? _getUtility(WidgetRef ref) {
    if (id == null) return null;
    try {
      return ref
          .watch(utilityProvider)
          .firstWhere((element) => element.id == id);
    } catch (_) {
      return null;
    }
  }
}
