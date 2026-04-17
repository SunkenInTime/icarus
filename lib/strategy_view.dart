import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/sidebar.dart';
import 'package:icarus/widgets/delete_capture.dart';
import 'package:icarus/widgets/demo_tag.dart';
import 'package:icarus/widgets/strategy_quick_switcher.dart';
import 'package:icarus/widgets/map_selector.dart';
import 'package:icarus/widgets/pages_bar.dart';
import 'package:icarus/widgets/save_and_load_button.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

class StrategyView extends ConsumerStatefulWidget {
  const StrategyView({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _StrategyViewState();
}

class _StrategyViewState extends ConsumerState<StrategyView>
    with WindowListener {
  bool _isClosingWindow = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      windowManager.addListener(this);
      _enableWindowCloseGuard();
    }
  }

  @override
  void dispose() {
    if (!kIsWeb) {
      windowManager.removeListener(this);
      windowManager.setPreventClose(false);
    }
    super.dispose();
  }

  Future<void> _enableWindowCloseGuard() async {
    await windowManager.setPreventClose(true);
  }

  Future<void> _leaveToLibrary() async {
    await guardUnsavedStrategyExit(
      context: context,
      ref: ref,
      source: 'StrategyView.leaveToLibrary',
      onContinue: () async {
        ref
            .read(interactionStateProvider.notifier)
            .update(InteractionState.navigation);
        ref
            .read(agentFilterProvider.notifier)
            .updateFilterState(FilterState.all);
        ref.read(deleteMenuProvider.notifier).requestClose();
        if (mounted) {
          Navigator.pop(context);
        }
        await ref.read(strategyProvider.notifier).clearCurrentStrategy();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(lineUpProvider, (previous, next) {
      if (previous?.isSelectingPosition == true &&
          next.isSelectingPosition == false) {
        showDialog(
          context: context,
          builder: (context) => const CreateLineupDialog(),
        );
      }
    });
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding:
                const EdgeInsets.only(left: 15, top: 15, bottom: 10, right: 15),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    ShadIconButton.ghost(
                      foregroundColor: Colors.white,
                      onPressed: _leaveToLibrary,
                      icon: const Icon(Icons.home),
                    ),
                    const SizedBox(width: 5),
                    const MapSelector(),
                    if (kIsWeb)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8.0),
                        child: DemoTag(),
                      )
                  ],
                ),
                const StrategyQuickSwitcher(),
                Row(
                  children: [
                    TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () async {
                          await launchUrl(Settings.dicordLink);
                        },
                        child: const Row(
                          children: [
                            Text("Have any bugs? Join the Discord"),
                            SizedBox(
                              width: 10,
                            ),
                            Icon(
                              CustomIcons.discord,
                              color: Colors.white,
                            )
                          ],
                        )),
                  ],
                )
              ],
            ),
          ),
          const Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: DeleteCapture()),
                Align(
                  alignment: Alignment.centerLeft,
                  child: InteractiveMap(),
                ),
                Align(
                  alignment: Alignment.topLeft,
                  child: SaveAndLoadButton(),
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: PagesBar(),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: SideBarUI(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void onWindowClose() async {
    if (kIsWeb) {
      return;
    }
    if (_isClosingWindow) {
      await windowManager.close();
      return;
    }

    await guardUnsavedStrategyExit(
      context: context,
      ref: ref,
      source: 'StrategyView.onWindowClose',
      onContinue: () async {
        _isClosingWindow = true;
        await windowManager.setPreventClose(false);
        await windowManager.close();
      },
    );
  }
}
