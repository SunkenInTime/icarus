import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/inactive_ability_trace.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SimpleImageAbilityWidget extends ConsumerWidget {
  const SimpleImageAbilityWidget({
    super.key,
    required this.imagePath,
    required this.size,
    this.index,
    required this.id,
    this.lineUpId,
    this.lineUpItemId,
    this.visualState,
    this.inactiveTraceColor,
    this.watchMouse = true,
    this.contextMenuItems,
  });

  final double size;
  final String imagePath;
  final int? index;
  final String? id;
  final String? lineUpId;
  final String? lineUpItemId;
  final AbilityVisualState? visualState;
  final Color? inactiveTraceColor;
  final bool watchMouse;
  final List<ShadContextMenuItem>? contextMenuItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final deleteTarget = lineUpId != null
        ? HoveredDeleteTarget.lineup(id: lineUpId!, ownerToken: Object())
        : (id?.isNotEmpty ?? false)
            ? HoveredDeleteTarget.ability(id: id!, ownerToken: Object())
            : null;
    final supportsInactiveState = inactiveTraceColor != null;
    final isActive =
        !supportsInactiveState || (visualState?.showRangeFill ?? true);
    final content = SizedBox(
      width: coordinateSystem.scale(size),
      height: coordinateSystem.scale(size),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedOpacity(
            key: const ValueKey('image-ability-active-layer'),
            opacity: isActive ? 1 : 0,
            duration: abilityStateTransitionDuration,
            child: Image.asset(imagePath),
          ),
          if (supportsInactiveState)
            AnimatedOpacity(
              key: const ValueKey('image-ability-inactive-layer'),
              opacity: isActive ? 0 : 1,
              duration: abilityStateTransitionDuration,
              child: InactiveCircleAbilityTrace(
                color: inactiveTraceColor!,
              ),
            ),
        ],
      ),
    );

    if (!watchMouse) {
      return content;
    }

    return MouseWatch(
      lineUpId: lineUpId,
      lineUpItemId: lineUpItemId,
      cursor: SystemMouseCursors.click,
      deleteTarget: deleteTarget,
      contextMenuItems: contextMenuItems,
      child: content,
    );
  }
}
