import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/shared/framed_icon_shell.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class AbilityWidget extends ConsumerWidget {
  const AbilityWidget({
    super.key,
    required this.iconPath,
    required this.id,
    required this.isAlly,
    this.lineUpId,
  });

  final String? lineUpId;

  final String? id;
  final bool isAlly;
  final String iconPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final deleteTarget = lineUpId != null
        ? HoveredDeleteTarget.lineup(id: lineUpId!, ownerToken: Object())
        : (id?.isNotEmpty ?? false)
            ? HoveredDeleteTarget.ability(id: id!, ownerToken: Object())
            : null;

    return MouseWatch(
      lineUpId: lineUpId,
      cursor: SystemMouseCursors.click,
      deleteTarget: deleteTarget,
      child: FramedIconShell(
        size: abilitySize,
        isAlly: isAlly,
        lineUpId: lineUpId,
        child: Image.asset(
          iconPath,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
