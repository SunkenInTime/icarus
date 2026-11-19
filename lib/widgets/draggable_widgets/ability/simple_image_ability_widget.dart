import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/inactive_ability_trace.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_range_opacity.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:icarus/const/settings.dart';

class SimpleImageAbilityWidget extends ConsumerWidget {
  const SimpleImageAbilityWidget({
    super.key,
    required this.imagePath,
    required this.size,
    this.rotation,
    this.index,
    required this.id,
    this.landingId,
    this.visualState,
    this.inactiveTraceColor,
    this.watchMouse = true,
    this.contextMenuItems,
  });

  final double size;
  final String imagePath;
  final double? rotation;
  final int? index;
  final String? id;
  final String? landingId;
  final AbilityVisualState? visualState;
  final Color? inactiveTraceColor;
  final bool watchMouse;
  final List<ShadContextMenuItem>? contextMenuItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rangeOpacity = AbilityRangeOpacity.of(context);
    final coordinateSystem = CoordinateSystem.instance;
    final deleteTarget = landingId != null
        ? HoveredDeleteTarget.lineup(id: landingId!, ownerToken: Object())
        : (id?.isNotEmpty ?? false)
            ? HoveredDeleteTarget.ability(id: id!, ownerToken: Object())
            : null;
    final supportsInactiveState = inactiveTraceColor != null;
    final isActive =
        !supportsInactiveState || (visualState?.showRangeFill ?? true);
    final angle = rotation ?? 0;
    final image = SizedBox(
      width: coordinateSystem.scale(size),
      height: coordinateSystem.scale(size),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedOpacity(
            key: const ValueKey('image-ability-active-layer'),
            opacity: isActive ? rangeOpacity : 0,
            duration: abilityStateTransitionDuration,
            curve: Settings.easeOut,
            child: Image.asset(imagePath),
          ),
          if (supportsInactiveState)
            AnimatedOpacity(
              key: const ValueKey('image-ability-inactive-layer'),
              opacity: isActive ? 0 : rangeOpacity,
              duration: abilityStateTransitionDuration,
              curve: Settings.easeOut,
              child: InactiveCircleAbilityTrace(
                color: inactiveTraceColor!,
              ),
            ),
          Center(
            child: Opacity(
              key: const ValueKey('image-ability-center-dot'),
              opacity: rangeOpacity,
              child: IgnorePointer(
                child: _CenterDot(
                  size: coordinateSystem.scale(Settings.smokeCenterDotSize),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    final content =
        angle == 0 ? image : Transform.rotate(angle: angle, child: image);

    if (!watchMouse) {
      return content;
    }

    return MouseWatch(
      lineUpLandingId: landingId,
      cursor: SystemMouseCursors.click,
      deleteTarget: deleteTarget,
      contextMenuItems: contextMenuItems,
      child: content,
    );
  }
}

/// Marks a smoke's center, so it can be lined up against a wall corner for a
/// one-way. Faint and light with a dark rim, so it reads on dark and light
/// smoke art alike.
class _CenterDot extends StatelessWidget {
  const _CenterDot({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Settings.smokeCenterDotFill,
          border: Border.all(
            color: Settings.smokeCenterDotRim,
            width: size * 0.2,
            strokeAlign: BorderSide.strokeAlignOutside,
          ),
        ),
      ),
    );
  }
}
