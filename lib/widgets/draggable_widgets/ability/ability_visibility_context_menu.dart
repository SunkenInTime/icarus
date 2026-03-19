import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

bool supportsAbilityVisibilityMenu(Ability? ability) {
  return ability is SquareAbility ||
      ability is CenterSquareAbility ||
      ability is CircleAbility ||
      ability is SectorCircleAbility ||
      ability is DeadlockBarrierMeshAbility;
}

List<ShadContextMenuItem>? buildAbilityContextMenuItems(
  WidgetRef ref,
  PlacedAbility ability, {
  String? lineUpId,
  bool includeDelete = false,
}) {
  final abilityData = ability.data.abilityData;
  final visibilityItems = _buildVisibilityItems(
    ref,
    ability,
    abilityData,
    lineUpId: lineUpId,
  );

  if (visibilityItems.isEmpty && !includeDelete) {
    return null;
  }

  return [
    ...visibilityItems,
    if (includeDelete && lineUpId != null) _buildDeleteItem(ref, lineUpId),
  ];
}

List<ShadContextMenuItem> _buildVisibilityItems(
  WidgetRef ref,
  PlacedAbility ability,
  Ability? abilityData, {
  String? lineUpId,
}) {
  final controls = _buildVisibilityControls(abilityData, ability.visualState);
  return controls
      .map(
        (control) => _buildToggleItem(
          label: control.label,
          isEnabled: control.isEnabled,
          onPressed: () => _updateVisualState(
            ref,
            ability,
            control.toggle(ability.visualState),
            lineUpId: lineUpId,
          ),
        ),
      )
      .toList();
}

List<_AbilityVisibilityControl> _buildVisibilityControls(
  Ability? abilityData,
  AbilityVisualState visualState,
) {
  if (abilityData is CircleAbility || abilityData is SectorCircleAbility) {
    if (_hasInnerRange(abilityData)) {
      return [
        _AbilityVisibilityControl(
          label: 'Range Outline',
          isEnabled: visualState.showRangeOutline,
          toggle: (state) => state.copyWith(
            showRangeOutline: !state.showRangeOutline,
          ),
        ),
        _AbilityVisibilityControl(
          label: 'Inner Outline',
          isEnabled: visualState.showInnerOutline,
          toggle: (state) => state.copyWith(
            showInnerOutline: !state.showInnerOutline,
          ),
        ),
        _AbilityVisibilityControl(
          label: 'Inner Fill',
          isEnabled: visualState.showInnerFill,
          toggle: (state) => state.copyWith(
            showInnerFill: !state.showInnerFill,
          ),
        ),
      ];
    }

    return [
      _AbilityVisibilityControl(
        label: 'Range Outline',
        isEnabled: visualState.showRangeOutline,
        toggle: (state) => state.copyWith(
          showRangeOutline: !state.showRangeOutline,
        ),
      ),
      _AbilityVisibilityControl(
        label: 'Range Fill',
        isEnabled: visualState.showRangeFill,
        toggle: (state) => state.copyWith(
          showRangeFill: !state.showRangeFill,
        ),
      ),
    ];
  }

  if (abilityData is DeadlockBarrierMeshAbility) {
    return [
      _AbilityVisibilityControl(
        label: 'Mesh',
        isEnabled: visualState.showRangeFill,
        toggle: (state) => state.copyWith(
          showRangeFill: !state.showRangeFill,
        ),
      ),
    ];
  }

  if (abilityData is SquareAbility || abilityData is CenterSquareAbility) {
    return [
      _AbilityVisibilityControl(
        label: 'Range',
        isEnabled: visualState.showRangeFill,
        toggle: (state) => state.copyWith(
          showRangeFill: !state.showRangeFill,
        ),
      ),
    ];
  }

  return const [];
}

bool _hasInnerRange(Ability? ability) {
  return switch (ability) {
    CircleAbility() => ability.hasInnerRange,
    SectorCircleAbility() => ability.hasInnerRange,
    _ => false,
  };
}

ShadContextMenuItem _buildToggleItem({
  required String label,
  required bool isEnabled,
  required VoidCallback onPressed,
}) {
  return ShadContextMenuItem(
    onPressed: onPressed,
    leading: Icon(
      isEnabled ? Icons.check_box : Icons.check_box_outline_blank,
    ),
    child: Text(label),
  );
}

ShadContextMenuItem _buildDeleteItem(WidgetRef ref, String lineUpId) {
  return ShadContextMenuItem(
    leading: Icon(
      Icons.delete,
      color: Settings.tacticalVioletTheme.destructive,
    ),
    child: const Text('Delete'),
    onPressed: () {
      ref.read(lineUpProvider.notifier).deleteLineUpById(lineUpId);
    },
  );
}

void _updateVisualState(
  WidgetRef ref,
  PlacedAbility ability,
  AbilityVisualState visualState, {
  String? lineUpId,
}) {
  if (lineUpId != null) {
    ref.read(actionProvider.notifier).performTransaction(
      groups: const [ActionGroup.lineUp],
      mutation: () {
        ref
            .read(lineUpProvider.notifier)
            .updateAbilityVisualState(lineUpId, visualState);
      },
    );
    return;
  }

  final abilities = ref.read(abilityProvider);
  final index = PlacedWidget.getIndexByID(ability.id, abilities);
  if (index < 0) {
    return;
  }

  ref.read(abilityProvider.notifier).updateVisualState(index, visualState);
}

class _AbilityVisibilityControl {
  const _AbilityVisibilityControl({
    required this.label,
    required this.isEnabled,
    required this.toggle,
  });

  final String label;
  final bool isEnabled;
  final AbilityVisualState Function(AbilityVisualState state) toggle;
}
