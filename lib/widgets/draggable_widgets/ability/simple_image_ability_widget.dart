import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class SimpleImageAbilityWidget extends ConsumerWidget {
  const SimpleImageAbilityWidget({
    super.key,
    required this.imagePath,
    required this.size,
    this.index,
    required this.id,
    this.lineUpId,
    this.lineUpItemId,
  });

  final double size;
  final String imagePath;
  final int? index;
  final String? id;
  final String? lineUpId;
  final String? lineUpItemId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final deleteTarget = lineUpId != null
        ? HoveredDeleteTarget.lineup(id: lineUpId!, ownerToken: Object())
        : (id?.isNotEmpty ?? false)
            ? HoveredDeleteTarget.ability(id: id!, ownerToken: Object())
            : null;

    return MouseWatch(
      lineUpId: lineUpId,
      lineUpItemId: lineUpItemId,
      cursor: SystemMouseCursors.click,
      deleteTarget: deleteTarget,
      child: SizedBox(
        width: coordinateSystem.scale(size),
        height: coordinateSystem.scale(size),
        child: Image.asset(imagePath),
      ),
    );
  }
}
