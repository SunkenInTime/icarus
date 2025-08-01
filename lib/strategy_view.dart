import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/sidebar.dart';
import 'package:icarus/widgets/map_selector.dart';
import 'package:icarus/widgets/save_and_load_button.dart';
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
    _init();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  void _init() async {
    // Add this line to override the default close handler
    // await windowManager.setPreventClose(true);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
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
                    IconButton(
                        onPressed: () async {
                          await ref
                              .read(strategyProvider.notifier)
                              .saveToHive(ref.read(strategyProvider).id);

                          if (!context.mounted) return;
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.home)),
                    const SizedBox(width: 5),
                    const MapSelector(),
                  ],
                ),
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
                    // IconButton(
                    //   onPressed: () {
                    //     String id = ref.watch(strategyProvider).id;
                    //     ref.read(strategyProvider.notifier).exportFile(id);
                    //   },
                    //   icon: const Icon(Icons.file_open_outlined),
                    // )
                  ],
                )
              ],
            ),
          ),
          const Expanded(
            child: Stack(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: InteractiveMap(),
                ),
                Align(
                  alignment: Alignment.topLeft,
                  child: SaveButtonAndLoad(),
                ),
                SideBarUI()
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

    if (ref.read(strategyProvider).isSaved) {
      await windowManager.close(); // Close the window/app
      return;
    }

    await ref
        .read(strategyProvider.notifier)
        .saveToHive(ref.read(strategyProvider).id);
    await windowManager.close(); // Close the window/app
  }
}
