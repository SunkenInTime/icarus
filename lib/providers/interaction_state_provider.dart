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
      ref.read(lineUpProvider.notifier).clearCurrentPlacing();
      ref.read(abilityBarProvider.notifier).updateData(null);
    }

    state = newState;
  }

  void forceUpdateToNavigation() {
    if (state == InteractionState.lineUpPlacing) {
      ref.read(lineUpProvider.notifier).clearCurrentPlacing();
      ref.read(abilityBarProvider.notifier).updateData(null);
    }
    state = InteractionState.navigation;
  }
}
