import 'dart:developer';

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
import 'package:icarus/sidebar.dart';
import 'package:icarus/widgets/delete_capture.dart';
import 'package:icarus/widgets/demo_tag.dart';
import 'package:icarus/widgets/strategy_quick_switcher.dart';
import 'package:icarus/widgets/temporary_session_bar.dart';
import 'package:icarus/widgets/map_selector.dart';
import 'package:icarus/widgets/pages_bar.dart';
import 'package:icarus/widgets/save_and_load_button.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/widgets/dialogs/create_lineup_dialog.dart';
import 'package:icarus/widgets/dialogs/strategy/temporary_session_flow.dart';
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
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // _init();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  // void _init() async {
  //   // Add this line to override the default close handler
  //   // await windowManager.setPreventClose(true);
  //   setState(() {});
  // }
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
                      onPressed: () async {
                        final canProceed =
                            await resolveTemporarySessionForNavigation(
                          context: context,
                          ref: ref,
                        );
                        if (!canProceed) return;
                        final state = ref.read(strategyProvider);
                        if (state.stratName != null &&
                            !state.isTemporarySession &&
                            !state.isSaved) {
                          await ref
                              .read(strategyProvider.notifier)
                              .forceSaveNow(state.id);
                        }

                        if (!context.mounted) return;
                        ref
                            .read(interactionStateProvider.notifier)
                            .update(InteractionState.navigation);
                        ref
                            .read(agentFilterProvider.notifier)
                            .updateFilterState(FilterState.all);

                        ref.read(deleteMenuProvider.notifier).requestClose();
                        Navigator.pop(context);
                        ref
                            .read(strategyProvider.notifier)
                            .clearCurrentStrategy();
                      },
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
          const TemporarySessionBar(),
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
    // bool isPreventClose = await windowManager.isPreventClose();
    // if (!isPreventClose) return;

    final canProceed = await resolveTemporarySessionForNavigation(
      context: context,
      ref: ref,
    );
    if (!canProceed) return;
    final state = ref.read(strategyProvider);
    if (state.isSaved) {
      await windowManager.close(); // Close the window/app
      return;
    }

    if (!state.isTemporarySession && state.stratName != null) {
      await ref.read(strategyProvider.notifier).forceSaveNow(state.id);
    }
    log("Window close");
    await windowManager.close(); // Close the window/app
  }
}
