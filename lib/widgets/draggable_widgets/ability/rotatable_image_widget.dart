import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class RotatableImageWidget extends ConsumerWidget {
  const RotatableImageWidget({
    super.key,
    required this.imagePath,
    required this.height,
    required this.width,
    required this.id,
    this.lineUpId,
  });
  final String imagePath;
  final double height;
  final double width;
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
      child: Column(
        children: [
          SizedBox(
            height: coordinateSystem.scale(30),
          ),
          SizedBox(
            width: coordinateSystem.scale(width),
            height: coordinateSystem.scale(height),
            child: Image.asset(imagePath),
          ),
        ],
      ),
    );
  }
}
