import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:icarus/widgets/dialogs/lineup_panel_dialog.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_range_fill.dart';
import 'package:icarus/widgets/draggable_widgets/adjacent_page_copy_menu.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/widgets/platform_feature_toast.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

bool supportsAbilityVisibilityMenu(Ability? ability) {
  return supportsAbilityInactiveState(ability) ||
      ability is SquareAbility ||
      ability is CenterSquareAbility ||
      ability is CircleAbility ||
      ability is SectorCircleAbility ||
      ability is DeadlockBarrierMeshAbility;
}

bool supportsAbilityInactiveState(Ability? ability) {
  return switch (ability) {
    ImageAbility() => ability.supportsInactiveState,
    SquareAbility() => ability.supportsInactiveState,
    _ => false,
  };
}

/// Context menu for a placed ability. With [landingId] the ability is a
/// lineup landing spot and gets the lineup actions; [context] is needed for
/// the ones that open dialogs.
List<ShadContextMenuItem>? buildAbilityContextMenuItems(
  WidgetRef ref,
  PlacedAbility ability, {
  String? landingId,
  BuildContext? context,
}) {
  final abilityData = ability.data.abilityData;
  final visibilityItems = _buildVisibilityItems(
    ref,
    ability,
    abilityData,
    landingId: landingId,
  );
  final adjacentPageItems = landingId == null
      ? buildAdjacentPageCopyMenuItems(ref, ability.id)
      : const <ShadContextMenuItem>[];
  final lineUpItems = landingId == null
      ? const <ShadContextMenuItem>[]
      : buildLandingLineUpMenuItems(ref, landingId, context: context);

  if (visibilityItems.isEmpty &&
      adjacentPageItems.isEmpty &&
      lineUpItems.isEmpty) {
    return null;
  }

  return [
    ...lineUpItems,
    ...visibilityItems,
    ...adjacentPageItems,
  ];
}

/// Lineup actions for a landing spot: add another lineup into it from a new
/// throw spot, edit, delete.
List<ShadContextMenuItem> buildLandingLineUpMenuItems(
  WidgetRef ref,
  String landingId, {
  BuildContext? context,
}) {
  final state = ref.read(lineUpProvider);
  final links = state.linksToLanding(landingId);
  final landing = state.landingById(landingId);

  return [
    ShadContextMenuItem(
      leading: const Icon(LucideIcons.plus, size: 16),
      child: const Text('Add lineup here'),
      onPressed: () {
        if (landing == null) return;
        if (!ensureFeatureAvailable(ref, PlatformFeature.addLineups)) return;
        ref
            .read(abilityBarProvider.notifier)
            .updateData(AgentData.agents[landing.ability.data.type]!);
        ref.read(lineUpProvider.notifier).startToLanding(landingId);
        ref
            .read(interactionStateProvider.notifier)
            .update(InteractionState.lineUpPlacing);
      },
    ),
    ShadContextMenuItem(
      leading: const Icon(LucideIcons.pencil, size: 16),
      child: Text(links.length > 1 ? 'Show lineups' : 'Edit media'),
      onPressed: () {
        if (context == null) return;
        if (links.length == 1) {
          showDialog(
            context: context,
            builder: (context) => CreateLineupDialog(linkId: links.single.id),
          );
        } else {
          showLineUpPanel(context, landingId: landingId);
        }
      },
    ),
    ShadContextMenuItem(
      leading: Icon(
        LucideIcons.trash2,
        size: 16,
        color: Settings.tacticalVioletTheme.destructive,
      ),
      child: Text(links.length > 1 ? 'Delete spot' : 'Delete lineup'),
      onPressed: () {
        ref.read(lineUpProvider.notifier).deleteLanding(landingId);
      },
    ),
  ];
}

List<ShadContextMenuItem> _buildVisibilityItems(
  WidgetRef ref,
  PlacedAbility ability,
  Ability? abilityData, {
  String? landingId,
}) {
  final controls = [
    ..._buildVisibilityControls(abilityData, ability.visualState),
    if (landingId == null &&
        AbilityVisionConeSpec.forAbility(ability.data) != null)
      _AbilityVisibilityControl(
        label: 'Vision Cone',
        isEnabled: ability.visualState.showVisionCone,
        toggle: (state) => state.copyWith(
          showVisionCone: !state.showVisionCone,
        ),
      ),
  ];
  return controls
      .map(
        (control) => _buildToggleItem(
          label: control.label,
          isEnabled: control.isEnabled,
          onPressed: () => _updateVisualState(
            ref,
            ability,
            control.toggle(ability.visualState),
            landingId: landingId,
          ),
        ),
      )
      .toList();
}

List<_AbilityVisibilityControl> _buildVisibilityControls(
  Ability? abilityData,
  AbilityVisualState visualState,
) {
  if (supportsAbilityInactiveState(abilityData)) {
    return [
      _AbilityVisibilityControl(
        label: 'Active',
        isEnabled: visualState.showRangeFill,
        toggle: (state) => state.copyWith(
          showRangeFill: !state.showRangeFill,
        ),
      ),
    ];
  }

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
      if (_hasVisibleRangeFill(abilityData))
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

bool _hasVisibleRangeFill(Ability? ability) {
  return switch (ability) {
    CircleAbility() => hasVisibleAbilityRangeFill(
        rangeOutlineColor: ability.rangeOutlineColor,
        rangeFillColor: ability.rangeFillColor,
        opacity: ability.opacity,
      ),
    SectorCircleAbility() => hasVisibleAbilityRangeFill(
        rangeOutlineColor: ability.rangeOutlineColor,
        rangeFillColor: ability.rangeFillColor,
        opacity: ability.opacity,
      ),
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
      isEnabled ? LucideIcons.squareCheck : LucideIcons.square,
      size: 16,
    ),
    child: Text(label),
  );
}

void _updateVisualState(
  WidgetRef ref,
  PlacedAbility ability,
  AbilityVisualState visualState, {
  String? landingId,
}) {
  if (landingId != null) {
    ref.read(lineUpProvider.notifier).updateLandingAbilityVisualState(
          landingId: landingId,
          visualState: visualState,
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
