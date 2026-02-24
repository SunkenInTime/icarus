import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class CustomShapeWidget extends ConsumerWidget {
  const CustomShapeWidget({
    super.key,
    required this.shape,
    required this.widthMeters,
    required this.heightMeters,
    required this.id,
    this.color = Colors.white,
  });

  final CustomShapeType shape;
  final double widthMeters;
  final double heightMeters;
  final String? id;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final scaledWidth = coordinateSystem
        .scale(widthMeters * AgentData.inGameMetersDiameter);
    final scaledHeight = coordinateSystem
        .scale(heightMeters * AgentData.inGameMetersDiameter);

    return MouseWatch(
      cursor: SystemMouseCursors.click,
      onDeleteKeyPressed: () {
        if (id == null) return;
        final action = UserAction(
            type: ActionType.deletion, id: id!, group: ActionGroup.utility);
        ref.read(actionProvider.notifier).addAction(action);
        ref.read(utilityProvider.notifier).removeUtility(id!);
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: scaledWidth,
            height: shape == CustomShapeType.circle ? scaledWidth : scaledHeight,
            decoration: BoxDecoration(
              color: color.withAlpha(40),
              shape: shape == CustomShapeType.circle
                  ? BoxShape.circle
                  : BoxShape.rectangle,
              borderRadius: shape == CustomShapeType.rectangle
                  ? BorderRadius.circular(2)
                  : null,
              border: Border.all(
                color: color.withAlpha(180),
                width: coordinateSystem.scale(2),
              ),
            ),
          ),
          Icon(
            shape == CustomShapeType.circle
                ? Icons.circle_outlined
                : Icons.rectangle_outlined,
            size: coordinateSystem.scale(14),
            color: color.withAlpha(200),
          ),
        ],
      ),
    );
  }
}
