import 'dart:developer';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/widgets/dialogs/in_app_debug_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

class GlobalShortcuts extends ConsumerStatefulWidget {
  const GlobalShortcuts({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<GlobalShortcuts> createState() => _GlobalShortcutsState();
}

class _GlobalShortcutsState extends ConsumerState<GlobalShortcuts> {
  bool _isDebugDialogOpen = false;

  @override
  Widget build(BuildContext context) {
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
              onInvoke: (intent) async {
                if (ref.read(interactionStateProvider) ==
                    InteractionState.erasing) {
                  ref
                      .read(interactionStateProvider.notifier)
                      .update(InteractionState.navigation);
                } else {
                  ref
                      .read(interactionStateProvider.notifier)
                      .update(InteractionState.erasing);
                  await ref.read(penProvider.notifier).buildCursors();
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
            OpenInAppDebugIntent: CallbackAction<OpenInAppDebugIntent>(
              onInvoke: (intent) async {
                if (_isDebugDialogOpen) return null;

                final navCtx = appNavigatorKey.currentContext ??
                    appNavigatorKey.currentState?.overlay?.context;
                if (navCtx == null) return null;

                _isDebugDialogOpen = true;
                await showShadDialog<void>(
                  context: navCtx,
                  builder: (context) => const InAppDebugDialog(),
                );
                _isDebugDialogOpen = false;
                return null;
              },
            ),
          },
          child: widget.child,
        ),
      ),
    );
  }
}
