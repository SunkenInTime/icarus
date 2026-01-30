import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class SettingsTab extends ConsumerWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Text(
                            "Apply scale to all pages",
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ShadCheckbox(
                          value: ref.watch(applyScaleToAllPagesProvider),
                          onChanged: (value) {
                            ref
                                .read(applyScaleToAllPagesProvider.notifier)
                                .set(value);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
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
                      onChanged: (value) async {
                        final oldSize =
                            ref.read(strategySettingsProvider).agentSize;
                        if (oldSize == value) return;
                        ref
                            .read(strategySettingsProvider.notifier)
                            .updateAgentSize(value);

                        ref
                            .read(agentProvider.notifier)
                            .recenterAllForAgentSizeChange(oldSize, value);
                        ref
                            .read(lineUpProvider.notifier)
                            .recenterAgentsForAgentSizeChange(oldSize, value);

                        if (ref.read(applyScaleToAllPagesProvider)) {
                          await ref
                              .read(strategyProvider.notifier)
                              .applySettingsToAllPages(agentSize: value);
                        }

                        ref.read(strategyProvider.notifier).setUnsaved();
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
                      onChanged: (value) async {
                        ref
                            .read(strategySettingsProvider.notifier)
                            .updateAbilitySize(value);

                        if (ref.read(applyScaleToAllPagesProvider)) {
                          await ref
                              .read(strategyProvider.notifier)
                              .applySettingsToAllPages(abilitySize: value);
                        }

                        ref.read(strategyProvider.notifier).setUnsaved();
                      },
                    )
                  ],
                ),
                // SettingsSection(
                //   title: "Map",
                //   children: [
                //     Row(
                //       mainAxisAlignment: MainAxisAlignment.spaceBetween,
                //       children: [
                //         const Text(
                //           "Show Spawn Barrier",
                //           style: TextStyle(fontSize: 15),
                //         ),
                //         const SizedBox(height: 10),
                //         ShadCheckbox(
                //           value: ref.watch(mapProvider).showSpawnBarrier,
                //           onChanged: (value) {
                //             ref
                //                 .read(mapProvider.notifier)
                //                 .updateSpawnBarrier(value);
                //           },
                //         )
                //       ],
                //     ),
                //     const SizedBox(height: 10),
                //     Row(
                //       mainAxisAlignment: MainAxisAlignment.spaceBetween,
                //       children: [
                //         const Text(
                //           "Show Region Names",
                //           style: TextStyle(fontSize: 15),
                //         ),
                //         const SizedBox(height: 10),
                //         ShadCheckbox(
                //           value: ref.watch(mapProvider).showRegionNames,
                //           onChanged: (value) {
                //             ref
                //                 .read(mapProvider.notifier)
                //                 .updateRegionNames(value);
                //           },
                //         )
                //       ],
                //     ),
                //     const SizedBox(height: 10),
                //     Row(
                //       mainAxisAlignment: MainAxisAlignment.spaceBetween,
                //       children: [
                //         const Text(
                //           "Show Ult Orbs",
                //           style: TextStyle(fontSize: 15),
                //         ),
                //         const SizedBox(height: 10),
                //         ShadCheckbox(
                //           value: ref.watch(mapProvider).showUltOrbs,
                //           onChanged: (value) {
                //             ref.read(mapProvider.notifier).updateUltOrbs(value);
                //           },
                //         )
                //       ],
                //     ),
                //   ],
                // ),
              ],
            ),
          ),
        ),
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
