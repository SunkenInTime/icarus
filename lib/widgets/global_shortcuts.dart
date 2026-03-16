import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/shortcut_info.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/placement_center_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/widgets/delete_helpers.dart';
import 'package:uuid/uuid.dart';

class GlobalShortcuts extends ConsumerStatefulWidget {
  const GlobalShortcuts({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<GlobalShortcuts> createState() => _GlobalShortcutsState();
}

class _GlobalShortcutsState extends ConsumerState<GlobalShortcuts> {
  void _dismissDeleteMenu() {
    ref.read(deleteMenuProvider.notifier).requestClose();
  }

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
                _dismissDeleteMenu();
                ref.read(actionProvider.notifier).undoAction();
                return null;
              },
            ),
            AddedTextIntent: CallbackAction<AddedTextIntent>(
              onInvoke: (intent) {
                _dismissDeleteMenu();
                const uuid = Uuid();
                final coordinateSystem = CoordinateSystem.instance;
                const screenPoint = Offset(200, 42);
                final virtualPoint =
                    coordinateSystem.screenToCoordinate(screenPoint);
                final placementCenter = ref.read(placementCenterProvider);
                final centeredTopLeft = placementCenter -
                    Offset(virtualPoint.dx / 2, virtualPoint.dy / 2);

                ref.read(textProvider.notifier).addText(
                      PlacedText(
                        position: centeredTopLeft,
                        id: uuid.v4(),
                      ),
                    );
                return null;
              },
            ),
            ToggleDrawingIntent: CallbackAction<ToggleDrawingIntent>(
              onInvoke: (intent) {
                _dismissDeleteMenu();
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
                _dismissDeleteMenu();
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
                _dismissDeleteMenu();
                ref.read(actionProvider.notifier).redoAction();
                return null;
              },
            ),
            SaveStrategyIntent: CallbackAction<SaveStrategyIntent>(
              onInvoke: (intent) async {
                _dismissDeleteMenu();
                final strategyId = ref.read(strategyProvider).id;
                await ref.read(strategyProvider.notifier).forceSaveNow(
                      strategyId,
                    );
                if (!mounted) return null;
                Settings.showToast(
                  message: 'File saved',
                  backgroundColor: Colors.green,
                );
                return null;
              },
            ),
            NavigationActionIntent: CallbackAction<NavigationActionIntent>(
              onInvoke: (intent) {
                _dismissDeleteMenu();
                ref
                    .read(interactionStateProvider.notifier)
                    .update(InteractionState.navigation);
                return null;
              },
            ),
            ToggleAgentFilterIntent: CallbackAction<ToggleAgentFilterIntent>(
              onInvoke: (intent) {
                _dismissDeleteMenu();
                ref.read(agentFilterProvider.notifier).toggleAllOnMap();
                return null;
              },
            ),
            ForwardPageIntent: CallbackAction<ForwardPageIntent>(
              onInvoke: (intent) async {
                _dismissDeleteMenu();
                await ref.read(strategyProvider.notifier).forwardPage();
                return null;
              },
            ),
            BackwardPageIntent: CallbackAction<BackwardPageIntent>(
              onInvoke: (intent) async {
                _dismissDeleteMenu();
                await ref.read(strategyProvider.notifier).backwardPage();
                return null;
              },
            ),
            AddPageIntent: CallbackAction<AddPageIntent>(
              onInvoke: (intent) async {
                _dismissDeleteMenu();
                await ref.read(strategyProvider.notifier).addPage();
                return null;
              },
            ),
            ToggleLineupIntent: CallbackAction<ToggleLineupIntent>(
              onInvoke: (intent) {
                _dismissDeleteMenu();
                if (ref.read(interactionStateProvider) ==
                    InteractionState.lineUpPlacing) {
                  ref
                      .read(interactionStateProvider.notifier)
                      .update(InteractionState.navigation);
                } else {
                  ref
                      .read(interactionStateProvider.notifier)
                      .update(InteractionState.lineUpPlacing);
                }
                return null;
              },
            ),
            OpenInAppDebugIntent: CallbackAction<OpenInAppDebugIntent>(
              onInvoke: (intent) async {
                _dismissDeleteMenu();
                await AppErrorReporter.openDebugLog();
                return null;
              },
            ),
            ContextualDeleteIntent: CallbackAction<ContextualDeleteIntent>(
              onInvoke: (intent) {
                final hoveredTarget = ref.read(hoveredDeleteTargetProvider);
                if (hoveredTarget != null) {
                  _dismissDeleteMenu();
                  ref.read(hoveredDeleteTargetProvider.notifier).state = null;
                  deleteHoveredTarget(ref, hoveredTarget);
                  return null;
                }

                final deleteMenuState = ref.read(deleteMenuProvider);
                if (deleteMenuState.isOpenRequested) {
                  _dismissDeleteMenu();
                  return null;
                }

                ref.read(deleteMenuProvider.notifier).requestOpen(
                      reason: DeleteMenuOpenReason.keyboard,
                    );
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
