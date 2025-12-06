import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/widgets/sidebar_widgets/color_buttons.dart';

class DrawingTools extends ConsumerStatefulWidget {
  const DrawingTools({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _DrawingToolsState();
}

class _DrawingToolsState extends ConsumerState<DrawingTools> {
  @override
  Widget build(BuildContext context) {
    final isExpanded =
        ref.watch(interactionStateProvider) == InteractionState.drawing;
    final isDotted = ref.watch(penProvider).isDotted;
    // if (!isExpanded) return const SizedBox.shrink();
    final hasArrow = ref.watch(penProvider).hasArrow;
    return ClipRect(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: isExpanded ? 150 : 0, // Change height based on state
        curve: Curves.easeInOut,
        child: !isExpanded
            ? const SizedBox.shrink()
            : SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Padding(
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
                                  ref
                                      .read(penProvider.notifier)
                                      .setColor(index);
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
                              borderRadius:
                                  const BorderRadius.all(Radius.circular(8)),
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
                          const SizedBox(
                            width: 5,
                          ),
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
                ),
              ), // Return null when not expanded
      ),
    );
  }
}
