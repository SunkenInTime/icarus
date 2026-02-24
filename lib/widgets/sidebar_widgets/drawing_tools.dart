import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/widgets/selectable_icon_button.dart';
import 'package:icarus/widgets/sidebar_widgets/color_buttons.dart';

class DrawingTools extends ConsumerWidget {
  const DrawingTools({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDotted = ref.watch(penProvider).isDotted;
    final hasArrow = ref.watch(penProvider).hasArrow;
    final penMode = ref.watch(penProvider).penMode;

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Color"),
          // const SizedBox(height: 10),
          Row(
            children: [
              for (final (index, colorOption) in ref
                  .watch(penProvider.select(
                    (state) => state.listOfColors,
                  ))
                  .indexed)
                Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: ColorButtons(
                    height: 26,
                    width: 26,
                    color: colorOption.color,
                    isSelected: colorOption.isSelected,
                    onTap: () {
                      ref.read(penProvider.notifier).setColor(index);
                    },
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Text("Stroke"),
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                  decoration: BoxDecoration(
                    color: Settings.tacticalVioletTheme.card,
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
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
                            CustomIcons.line,
                            size: 20,
                          ),
                          isSelected: !isDotted,
                          onPressed: () {
                            ref
                                .read(penProvider.notifier)
                                .updateValue(isDotted: false);
                          },
                        ),
                        SelectableIconButton(
                          icon: const Icon(
                            CustomIcons.dottedline,
                            size: 20,
                          ),
                          isSelected: isDotted,
                          onPressed: () {
                            ref
                                .read(penProvider.notifier)
                                .updateValue(isDotted: true);
                          },
                        ),
                      ],
                    ),
                  )),
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
          const SizedBox(height: 4),
          const Text("Rectangle mode"),
          const SizedBox(height: 4),
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Settings.tacticalVioletTheme.card,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
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
                          CustomIcons.line,
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
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
