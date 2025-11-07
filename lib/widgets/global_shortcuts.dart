import 'dart:developer';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:uuid/uuid.dart';

class GlobalShortcuts extends ConsumerWidget {
  const GlobalShortcuts({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Focus(
      autofocus: true,
      // canRequestFocus: true,
      child: Shortcuts(
        shortcuts: ShortcutInfo.globalShortcuts,
        child: Actions(
          actions: {
            UndoActionIntent: CallbackAction<UndoActionIntent>(
              onInvoke: (intent) {
                ref.read(actionProvider.notifier).undoAction();
                return null;
              },
            ),
            AddedTextIntent: CallbackAction<AddedTextIntent>(
              onInvoke: (intent) {
                const uuid = Uuid();
                ref.read(textProvider.notifier).addText(
                      PlacedText(
                        position: const Offset(500, 500),
                        id: uuid.v4(),
                      ),
                    );
                return null;
              },
            ),
            ToggleDrawingIntent: CallbackAction<ToggleDrawingIntent>(
              onInvoke: (intent) {
                if (ref.read(interactionStateProvider) ==
                    InteractionState.drawing) {
                  ref
                      .read(interactionStateProvider.notifier)
                      .update(InteractionState.navigation);
                } else {
                  ref
                      .read(interactionStateProvider.notifier)
                      .update(InteractionState.drawing);
                }
                return null;
              },
            ),
            ToggleErasingIntent: CallbackAction<ToggleErasingIntent>(
              onInvoke: (intent) {
                if (ref.read(interactionStateProvider) ==
                    InteractionState.erasing) {
                  ref
                      .read(interactionStateProvider.notifier)
                      .update(InteractionState.navigation);
                } else {
                  ref
                      .read(interactionStateProvider.notifier)
                      .update(InteractionState.erasing);
                }
                return null;
              },
            ),
            RedoActionIntent: CallbackAction<RedoActionIntent>(
              onInvoke: (intent) {
                log("I triggered");

                ref.read(actionProvider.notifier).redoAction();
                return null;
              },
            ),
            NavigationActionIntent: CallbackAction<NavigationActionIntent>(
              onInvoke: (intent) {
                log("I triggered");

                ref
                    .read(interactionStateProvider.notifier)
                    .update(InteractionState.navigation);
                return null;
              },
            ),
            ForwardPageIntent: CallbackAction<ForwardPageIntent>(
              onInvoke: (intent) async {
                log("I triggered");

                await ref.read(strategyProvider.notifier).forwardPage();
                return null;
              },
            ),
            BackwardPageIntent: CallbackAction<BackwardPageIntent>(
              onInvoke: (intent) async {
                log("I triggered");

                await ref.read(strategyProvider.notifier).backwardPage();
                return null;
              },
            ),
          },
          child: child,
        ),
      ),
    );
  }
}
