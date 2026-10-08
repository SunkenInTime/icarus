import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/shared/framed_ability_icon_shell.dart';
import 'package:icarus/widgets/mouse_watch.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AbilityWidget extends ConsumerWidget {
  const AbilityWidget({
    super.key,
    required this.iconPath,
    required this.id,
    required this.isAlly,
    this.rotation,
    this.landingId,
    this.watchMouse = true,
    this.contextMenuItems,
    this.onTapOverride,
  });

  final String? landingId;

  final String? id;
  final bool isAlly;
  final String iconPath;

  /// Turns the glyph, not the tile: the team-coloured frame stays upright.
  final double? rotation;
  final bool watchMouse;
  final List<ShadContextMenuItem>? contextMenuItems;
  final VoidCallback? onTapOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final deleteTarget = landingId != null
        ? HoveredDeleteTarget.lineup(id: landingId!, ownerToken: Object())
        : (id?.isNotEmpty ?? false)
            ? HoveredDeleteTarget.ability(id: id!, ownerToken: Object())
            : null;

    final shell = FramedAbilityIconShell(
      size: abilitySize,
      isAlly: isAlly,
      landingId: landingId,
      child: _turned(
        Image.asset(
          iconPath,
          fit: BoxFit.contain,
        ),
      ),
    );

    if (!watchMouse) {
      return shell;
    }

    return MouseWatch(
      lineUpLandingId: landingId,
      cursor: SystemMouseCursors.click,
      deleteTarget: deleteTarget,
      contextMenuItems: contextMenuItems,
      onTap: onTapOverride,
      child: shell,
    );
  }

  Widget _turned(Widget glyph) {
    final angle = rotation ?? 0;
    if (angle == 0) return glyph;
    return Transform.rotate(angle: angle, child: glyph);
  }
}
