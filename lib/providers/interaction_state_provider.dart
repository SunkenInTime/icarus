import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';

enum InteractionState {
  navigation,
  drawing,
  erasing,
  visionCone,
  customShapes,
  textTools,
  roleIcons,
  lineUpPlacing,
  lineUpEditing,
}

extension CanvasInteraction on InteractionState {
  /// Placing a lineup or moving placed ones: the rest of the page dims and
  /// stays out of reach until the user finishes.
  bool get isLineUpMode =>
      this == InteractionState.lineUpPlacing ||
      this == InteractionState.lineUpEditing;

  /// Whether the items on the canvas can be pressed, moved and selected.
  /// Drawing and erasing take every press on the canvas for themselves, and
  /// a lineup mode puts the page out of reach. The other tools are panels of
  /// things to add, and leave the canvas as it is with no tool on.
  bool get itemsInReach =>
      this != InteractionState.drawing &&
      this != InteractionState.erasing &&
      !isLineUpMode;
}

final interactionStateProvider =
    NotifierProvider<InteractionStateProvider, InteractionState>(
  InteractionStateProvider.new,
);

class InteractionStateProvider extends Notifier<InteractionState> {
  @override
  InteractionState build() {
    return InteractionState.navigation;
  }

  void update(InteractionState newState) {
    if (newState == state) return;

    if (state == InteractionState.drawing) {
      final coordinateSystem = CoordinateSystem.instance;
      ref
          .read(drawingProvider.notifier)
          .finishFreeDrawing(null, coordinateSystem);
    } else if (state == InteractionState.lineUpPlacing) {
      ref.read(lineUpProvider.notifier).clearPlacement();
      ref.read(abilityBarProvider.notifier).updateData(null);
    } else if (state == InteractionState.lineUpEditing) {
      ref.read(lineUpProvider.notifier).cancelEdit();
    }

    // Pinned-end placements start themselves before switching state; a bare
    // switch is the fresh flow.
    if (newState == InteractionState.lineUpPlacing &&
        ref.read(lineUpProvider).placement == null) {
      ref.read(lineUpProvider.notifier).startFresh();
    }

    state = newState;
  }

  void forceUpdateToNavigation() {
    if (state == InteractionState.lineUpPlacing) {
      ref.read(lineUpProvider.notifier).clearPlacement();
      ref.read(abilityBarProvider.notifier).updateData(null);
    }
    ref.read(lineUpProvider.notifier).cancelEdit();
    state = InteractionState.navigation;
  }

  /// Opens placement editing for [linkId] and the lineups that share a spot
  /// with it, after ending whatever mode was on.
  void editLineUpPlacement(String linkId) {
    update(InteractionState.navigation);
    ref.read(lineUpProvider.notifier).startEdit(linkId);
    if (ref.read(lineUpProvider).edit == null) return;
    state = InteractionState.lineUpEditing;
  }
}
