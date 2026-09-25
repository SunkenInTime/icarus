import 'package:flutter/material.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/widgets/draggable_widgets/agents/weapon_icon.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// One "Weapon" entry whose submenu holds the categories. "None" leads the
/// submenu only while a weapon is equipped, since it is a no-op otherwise.
List<ShadContextMenuItem> buildAgentWeaponMenu({
  required WeaponType selectedWeapon,
  required ValueChanged<WeaponType> onSelected,
}) {
  final equipped = selectedWeapon != WeaponType.none;

  Widget selectionMark(WeaponType weapon) => SizedBox(
        width: 16,
        height: 16,
        child: selectedWeapon == weapon
            ? const Icon(LucideIcons.check, size: 16)
            : null,
      );

  return [
    ShadContextMenuItem(
      leading: const Icon(LucideIcons.crosshair),
      trailing: const Icon(LucideIcons.chevronRight, size: 16),
      items: [
        if (equipped)
          ShadContextMenuItem(
            onPressed: () => onSelected(WeaponType.none),
            child: const Text('None'),
          ),
        for (final category in WeaponCategory.values)
          ShadContextMenuItem(
            trailing: const Icon(LucideIcons.chevronRight, size: 16),
            items: [
              for (final weapon in category.weapons)
                ShadContextMenuItem(
                  leading: WeaponIcon(weapon: weapon, width: 36, height: 20),
                  trailing: selectionMark(weapon),
                  onPressed: () => onSelected(weapon),
                  child: Text(weapon.displayName),
                ),
            ],
            child: Text(category.label),
          ),
      ],
      child: const Text('Weapon'),
    ),
  ];
}
