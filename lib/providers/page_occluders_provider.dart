import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/view_cone/page_occluders.dart';
import 'package:icarus/view_cone/vision_occluders.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_wall.dart';

Offset selectionDragInWorld(Offset by, {required bool isAttack}) =>
    CoordinateSystem.instance.screenToCoordinate(by) * (isAttack ? 1 : -1);

final heldAbilityProvider =
    NotifierProvider<HeldAbilityNotifier, PlacedAbility?>(
  HeldAbilityNotifier.new,
);

class HeldAbilityNotifier extends Notifier<PlacedAbility?> {
  @override
  PlacedAbility? build() => null;

  void hold(PlacedAbility asDrawn) => state = asDrawn;

  void letGo(String id) {
    if (state?.id == id) state = null;
  }
}

final pageOccludersProvider =
    NotifierProvider<PageOccludersNotifier, List<VisionOccluder>>(
  PageOccludersNotifier.new,
);

class PageOccludersNotifier extends Notifier<List<VisionOccluder>> {
  @override
  List<VisionOccluder> build() {
    final map = ref.watch(mapProvider.select((state) => state.currentMap));
    final isAttack = ref.watch(mapProvider.select((state) => state.isAttack));
    final held = ref.watch(heldAbilityProvider);
    final draft = ref.watch(wallDraftProvider);
    final group = ref.watch(canvasGroupDragProvider);
    final groupShift = group == null
        ? Offset.zero
        : selectionDragInWorld(group.by, isAttack: isAttack);

    PlacedAbility asDrawn(PlacedAbility saved) {
      var ability = held?.id == saved.id ? held! : saved;
      if (draft?.id == saved.id) {
        ability = ability.copyWith(wallPath: draft!.path);
      }
      if (group?.ids.contains(saved.id) ?? false) {
        ability = ability.copyWith(position: ability.position + groupShift);
      }
      return ability;
    }

    return pageOccluders(
      [
        for (final ability in ref.watch(abilityProvider))
          if (blocksSight(ability.data)) asDrawn(ability),
      ],
      mapScale: Maps.mapScale[map] ?? 1,
    );
  }

  @override
  bool updateShouldNotify(
    List<VisionOccluder> previous,
    List<VisionOccluder> next,
  ) =>
      !listEquals(previous, next);
}
