import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
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
    final coordinateSystem = CoordinateSystem.instance;
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
      child: Container(
        width: coordinateSystem.scale(abilitySize),
        height: coordinateSystem.scale(abilitySize),
        padding: EdgeInsets.all(coordinateSystem.scale(3)),
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(
            Radius.circular(3),
          ),
          color: (ref.watch(hoveredLineUpIdProvider) == lineUpId &&
                  lineUpId != null)
              ? Colors.deepPurple
              : Settings.abilityBGColor,
          border: Border.all(
            color: (ref.watch(hoveredLineUpIdProvider) == lineUpId &&
                    lineUpId != null)
                ? Colors.deepPurpleAccent
                : isAlly
                    ? Settings.allyOutlineColor
                    : Settings.enemyOutlineColor,
            // width: (ref.watch(hoveredLineUpIdProvider) == lineUpId &&
            //         lineUpId != null)
            //     ? 2.0
            //     : 1.0,
          ),
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(3)),
          child: Image.asset(
            iconPath,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
