import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/widgets/sidebar_widgets/color_buttons.dart';

class DrawingTools extends ConsumerWidget {
  const DrawingTools({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDotted = ref.watch(penProvider).isDotted;
    final hasArrow = ref.watch(penProvider).hasArrow;

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Color"),
          const SizedBox(height: 10),
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
          const Text("Stroke"),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                height: 40,
                child: ToggleButtons(
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  isSelected: [!isDotted, isDotted],
                  fillColor: Colors.transparent,
                  children: const [
                    Icon(
                      CustomIcons.line,
                      size: 20,
                    ),
                    Icon(
                      CustomIcons.dottedline,
                      size: 21,
                    ),
                  ],
                  onPressed: (index) {
                    if (index == 0) {
                      ref
                          .read(penProvider.notifier)
                          .updateValue(isDotted: false);
                    } else {
                      ref
                          .read(penProvider.notifier)
                          .updateValue(isDotted: true);
                    }
                  },
                ),
              ),
              const SizedBox(width: 5),
              IconButton(
                isSelected: hasArrow,
                onPressed: () {
                  ref.read(penProvider.notifier).toggleArrow();
                },
                icon: const Icon(
                  CustomIcons.arrow,
                  size: 20,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
