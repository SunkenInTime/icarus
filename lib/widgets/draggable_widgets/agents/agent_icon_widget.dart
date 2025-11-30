import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class AgentIconWidget extends ConsumerWidget {
  const AgentIconWidget({
    super.key,
    required this.imagePath,
    required this.size,
    this.index,
    required this.id,
    this.lineUpId,
  });

  final double size;
  final String imagePath;
  final int? index;
  final String? id;
  final String? lineUpId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;

    return MouseWatch(
      lineUpId: lineUpId,
      cursor: SystemMouseCursors.click,
      onDeleteKeyPressed: () {
        if (id == null) return;
        final action = UserAction(
            type: ActionType.deletion, id: id!, group: ActionGroup.ability);

        ref.read(actionProvider.notifier).addAction(action);
        ref.read(abilityProvider.notifier).removeAbility(id!);
      },
      child: SizedBox(
        width: coordinateSystem.scale(size),
        height: coordinateSystem.scale(size),
        child: Image.asset(imagePath),
      ),
    );
  }
}
