import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class RotatableImageWidget extends ConsumerWidget {
  const RotatableImageWidget({
    super.key,
    required this.imagePath,
    required this.height,
    required this.width,
    required this.id,
    this.lineUpId,
    this.lineUpItemId,
  });
  final String imagePath;
  final double height;
  final double width;
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
