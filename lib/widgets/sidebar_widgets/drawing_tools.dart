import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/widgets/custom_segmented_tabs.dart';
import 'package:icarus/widgets/selectable_icon_button.dart';
import 'package:icarus/widgets/sidebar_widgets/color_library.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class DrawingTools extends ConsumerWidget {
  const DrawingTools({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDotted = ref.watch(penProvider).isDotted;
    final hasArrow = ref.watch(penProvider).hasArrow;
    final penMode = ref.watch(penProvider).penMode;
    final thickness = ref.watch(penProvider.select((state) => state.thickness));
    final traversalTimeEnabled = ref.watch(penProvider).traversalTimeEnabled;
    final activeTraversalSpeedProfile = ref.watch(
      penProvider.select((state) => state.activeTraversalSpeedProfile),
    );

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Color"),
          // const SizedBox(height: 10),
          ColorLibrary(
            selectedColorValue: ref.watch(
              penProvider.select((state) => state.color.toARGB32()),
            ),
            onSelected: (colorValue) async {
              if (colorValue == null) return;
              final notifier = ref.read(penProvider.notifier);
              notifier.updateValue(color: Color(colorValue));
              await notifier.buildCursors();
            },
          ),
          const SizedBox(height: 4),
          Row(
            spacing: 8,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Shape"),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Settings.tacticalVioletTheme.card,
                          borderRadius:
                              const BorderRadius.all(Radius.circular(8)),
                          border: Border.all(
                            color: Settings.tacticalVioletTheme.border,
                            width: 1,
                          ),
                          boxShadow: const [
                            Settings.cardForegroundBackdrop,
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(2.0),
                          child: Row(
                            spacing: 4,
                            children: [
                              SelectableIconButton(
                                icon: const Icon(
                                  LucideIcons.lineSquiggle,
                                  size: 20,
                                ),
                                isSelected: penMode == PenMode.freeDraw,
                                onPressed: () {
                                  ref
                                      .read(penProvider.notifier)
                                      .updateValue(penMode: PenMode.freeDraw);
                                },
                                tooltip: "Free draw",
                              ),
                              SelectableIconButton(
                                icon: const Icon(
                                  LucideIcons.minus,
                                  size: 20,
                                ),
                                isSelected: penMode == PenMode.line,
                                onPressed: () {
                                  ref
                                      .read(penProvider.notifier)
                                      .updateValue(penMode: PenMode.line);
                                },
                                tooltip: "Straight line",
                              ),
                              SelectableIconButton(
                                icon: const Icon(
                                  Icons.crop_square,
                                  size: 20,
                                ),
                                isSelected: penMode == PenMode.square,
                                onPressed: () {
                                  ref
                                      .read(penProvider.notifier)
                                      .updateValue(penMode: PenMode.square);
                                },
                                tooltip: "Rectangle",
                              ),
                              SelectableIconButton(
                                icon: const Icon(
                                  Icons.circle_outlined,
                                  size: 20,
                                ),
                                isSelected: penMode == PenMode.ellipse,
                                onPressed: () {
                                  ref
                                      .read(penProvider.notifier)
                                      .updateValue(penMode: PenMode.ellipse);
                                },
                                tooltip: "Ellipse",
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Stroke"),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      SelectableIconButton(
                        icon: const Icon(
                          CustomIcons.dottedline,
                          size: 20,
                        ),
                        isSelected: isDotted,
                        onPressed: () {
                          ref
                              .read(penProvider.notifier)
                              .updateValue(isDotted: !isDotted);
                        },
                        tooltip: "Dotted line",
                      ),
                      const SizedBox(width: 5),
                      SelectableIconButton(
                        icon: const Icon(
                          CustomIcons.arrow,
                          size: 20,
                        ),
                        isSelected: hasArrow,
                        onPressed: () {
                          ref.read(penProvider.notifier).toggleArrow();
                        },
                        tooltip: "Arrow",
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text("Thickness"),
          const SizedBox(height: 4),
          CustomSegmentedTabs<double>(
            compactness: 0.55,
            value: thickness,
            items: [
              for (final value in Settings.strokeThicknessOptions)
                SegmentedTabItem<double>(
                  value: value,
                  child: _ThicknessSwatch(thickness: value),
                ),
            ],
            onChanged: (value) {
              ref.read(penProvider.notifier).updateValue(thickness: value);
            },
          ),

          const SizedBox(height: 4),
          const Text("Traversal Time"),
          const SizedBox(height: 4),
          Row(
            spacing: 4,
            children: [
              SelectableIconButton(
                icon: const Icon(
                  LucideIcons.chevronsUp,
                  size: 20,
                ),
                isSelected: traversalTimeEnabled &&
                    activeTraversalSpeedProfile ==
                        TraversalSpeedProfile.running,
                onPressed: () {
                  ref
                      .read(penProvider.notifier)
                      .setTraversalMode(TraversalSpeedProfile.running);
                },
                tooltip: "Running w/ knife out",
              ),
              SelectableIconButton(
                icon: const Icon(
                  LucideIcons.chevronUp,
                  size: 20,
                ),
                isSelected: traversalTimeEnabled &&
                    activeTraversalSpeedProfile ==
                        TraversalSpeedProfile.walking,
                onPressed: () {
                  ref
                      .read(penProvider.notifier)
                      .setTraversalMode(TraversalSpeedProfile.walking);
                },
                tooltip: "Walking w/ knife out",
              ),
              SelectableIconButton(
                icon: Image.asset(
                  'assets/agents/Brimstone/1.webp',
                  width: 20,
                  height: 20,
                ),
                isSelected: traversalTimeEnabled &&
                    activeTraversalSpeedProfile ==
                        TraversalSpeedProfile.brimStim,
                onPressed: () {
                  ref
                      .read(penProvider.notifier)
                      .setTraversalMode(TraversalSpeedProfile.brimStim);
                },
                tooltip: "Brimstone Stim w/ knife out",
              ),
              SelectableIconButton(
                icon: Image.asset(
                  'assets/agents/Neon/3.webp',
                  width: 20,
                  height: 20,
                ),
                isSelected: traversalTimeEnabled &&
                    activeTraversalSpeedProfile ==
                        TraversalSpeedProfile.neonRun,
                onPressed: () {
                  ref
                      .read(penProvider.notifier)
                      .setTraversalMode(TraversalSpeedProfile.neonRun);
                },
                tooltip: "neon run",
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ThicknessSwatch extends StatelessWidget {
  const _ThicknessSwatch({required this.thickness});

  final double thickness;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 30,
      child: Center(
        child: Container(
          width: 20,
          height: thickness.clamp(2.0, 8.0),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }
}
