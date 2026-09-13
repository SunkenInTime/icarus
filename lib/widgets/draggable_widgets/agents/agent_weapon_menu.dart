import 'package:flutter/material.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/widgets/draggable_widgets/agents/weapon_icon.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

List<ShadContextMenuItem> buildAgentWeaponMenu({
  required WeaponType selectedWeapon,
  required ValueChanged<WeaponType> onSelected,
}) {
  Widget selectionMark(WeaponType weapon) => SizedBox(
        width: 16,
        height: 16,
        child: selectedWeapon == weapon
            ? const Icon(LucideIcons.check, size: 16)
            : null,
      );

  return [
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
    ShadContextMenuItem(
      trailing: selectionMark(WeaponType.none),
      onPressed: () => onSelected(WeaponType.none),
      child: const Text('None'),
    ),
  ];
}
