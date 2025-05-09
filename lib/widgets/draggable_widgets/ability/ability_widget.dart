import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

class AbilityWidget extends ConsumerWidget {
  const AbilityWidget({
    super.key,
    required this.iconPath,
    required this.id,
    required this.isAlly,
  });

  final String? id;
  final bool isAlly;
  final String iconPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;

    return MouseWatch(
      onDeleteKeyPressed: () {
        if (id == null) return;
        ref.read(abilityProvider.notifier).removeAbility(id!);
      },
      child: Container(
        width: coordinateSystem.scale(Settings.abilitySize),
        height: coordinateSystem.scale(Settings.abilitySize),
        padding: EdgeInsets.all(coordinateSystem.scale(3)),
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(
            Radius.circular(3),
          ),
          color: Settings.abilityBGColor,
          border: Border.all(
            color: isAlly
                ? const Color.fromARGB(106, 105, 240, 175)
                : const Color.fromARGB(139, 255, 82, 82),
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
