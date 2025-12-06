import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    return ShadSheet(
      title: Text("Settings", style: ShadTheme.of(context).textTheme.h3),
      description: const Text("Adjust your application settings here."),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: SizedBox(
          width: 325,
          child: Material(
            child: Column(
              children: [
                SettingsSection(
                  title: "Agents",
                  children: [
                    const Text(
                      "Scale",
                      style: TextStyle(fontSize: 15),
                    ),
                    const SizedBox(height: 10),
                    Slider(
                      min: Settings.agentSizeMin,
                      max: Settings.agentSizeMax,
                      inactiveColor: Settings.tacticalVioletTheme.secondary,
                      divisions: 15,
                      value: ref.watch(strategySettingsProvider).agentSize,
                      onChanged: (value) {
                        ref
                            .read(strategySettingsProvider.notifier)
                            .updateAgentSize(value);
                      },
                    )
                  ],
                ),
                SettingsSection(
                  title: "Abilities",
                  children: [
                    const Text(
                      "Scale",
                      style: TextStyle(fontSize: 15),
                    ),
                    const SizedBox(height: 10),
                    Slider(
                      min: Settings.abilitySizeMin,
                      max: Settings.abilitySizeMax,
                      inactiveColor: Settings.tacticalVioletTheme.secondary,
                      divisions: 15,
                      value: ref.watch(strategySettingsProvider).abilitySize,
                      onChanged: (value) {
                        ref
                            .read(strategySettingsProvider.notifier)
                            .updateAbilitySize(value);
                      },
                    )
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                Navigator.of(context).pop();
              },
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            child: SizedBox(
              height: coordinateSystem.playAreaSize.height,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Container(
                  width: 325,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    color: Settings.sideBarColor,
                    border: Border.all(
                      color: const Color.fromRGBO(210, 214, 219, 0.1),
                      width: 2,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              "Settings",
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Align(
                              alignment: Alignment.topRight,
                              child: IconButton(
                                onPressed: () {
                                  Navigator.of(context).pop();
                                },
                                icon: const Icon(Icons.close),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SettingsSection(
                          title: "Agents",
                          children: [
                            const Text(
                              "Scale",
                              style: TextStyle(fontSize: 15),
                            ),
                            const SizedBox(height: 10),
                            Slider(
                              min: Settings.agentSizeMin,
                              max: Settings.agentSizeMax,
                              divisions: 15,
                              value:
                                  ref.watch(strategySettingsProvider).agentSize,
                              onChanged: (value) {
                                ref
                                    .read(strategySettingsProvider.notifier)
                                    .updateAgentSize(value);
                              },
                            )
                          ],
                        ),
                        SettingsSection(
                          title: "Abilities",
                          children: [
                            const Text(
                              "Scale",
                              style: TextStyle(fontSize: 15),
                            ),
                            const SizedBox(height: 10),
                            Slider(
                              min: Settings.abilitySizeMin,
                              max: Settings.abilitySizeMax,
                              divisions: 15,
                              value: ref
                                  .watch(strategySettingsProvider)
                                  .abilitySize,
                              onChanged: (value) {
                                ref
                                    .read(strategySettingsProvider.notifier)
                                    .updateAbilitySize(value);
                              },
                            )
                          ],
                        ),
                        // SettingsSection(
                        //   title: "Abilities",
                        //   children: [
                        //     const Text(
                        //       "Scale",
                        //       style: TextStyle(fontSize: 15),
                        //     ),
                        //     const SizedBox(height: 10),
                        //     Slider(
                        //       min: Settings.abilitySizeMin,
                        //       max: Settings.abilitySizeMax,
                        //       divisions: 15,
                        //       value: ref
                        //           .watch(strategySettingsProvider)
                        //           .abilitySize,
                        //       onChanged: (value) {
                        //         ref
                        //             .read(strategySettingsProvider.notifier)
                        //             .updateAbilitySize(value);
                        //       },
                        //     )
                        //   ],
                        // ),
                        // SettingsSection(title: "Map Settings", children: [
                        //   Row(children: [
                        //     const Text("Show Spawn Barrier"),
                        //     const Spacer(),
                        //     Checkbox(
                        //         value: ref.watch(mapProvider).showSpawnBarrier,
                        //         onChanged: (value) {
                        //           if (value == null) return;

                        //           ref
                        //               .read(mapProvider.notifier)
                        //               .updateSpawnBarrier(value);
                        //         })
                        //   ])
                        // ])
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsSection extends StatelessWidget {
  const SettingsSection(
      {super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: ShadTheme.of(context).textTheme.lead),
        const SizedBox(
          height: 10,
        ),
        ...children
      ],
    );
  }
}
