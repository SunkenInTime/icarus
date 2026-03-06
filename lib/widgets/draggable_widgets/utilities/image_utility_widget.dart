import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class ImageUtilityWidget extends ConsumerWidget {
  const ImageUtilityWidget({
    super.key,
    required this.imagePath,
    required this.size,
    required this.id,
  });
  final String imagePath;
  final double size;
  final String? id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;

    return MouseWatch(
      cursor: SystemMouseCursors.click,
      onDeleteKeyPressed: () {
        if (id == null) return;
        final action = UserAction(
            type: ActionType.deletion, id: id!, group: ActionGroup.utility);

        ref.read(actionProvider.notifier).addAction(action);
        ref.read(utilityProvider.notifier).removeUtility(id!);
      },
      child: SvgPicture.asset(
        imagePath,
        width: coordinateSystem.scale(size),
        height: coordinateSystem.scale(size),
        fit: BoxFit.cover,
      ),
    );
  }
}

