import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/selectable_icon_button.dart';
import 'package:icarus/widgets/sidebar_widgets/delete_options.dart';
import 'package:icarus/widgets/sidebar_widgets/drawing_tools.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

enum _ContextBarMode { drawing, deleting, none }

class BottomContextBar extends ConsumerWidget {
  const BottomContextBar({super.key});

  static const double _expandedHeight = 150.0;
  static const Duration _animationDuration = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interactionState = ref.watch(interactionStateProvider);

    final mode = switch (interactionState) {
      InteractionState.drawing => _ContextBarMode.drawing,
      InteractionState.deleting => _ContextBarMode.deleting,
      _ => _ContextBarMode.none,
    };

    final isExpanded = mode != _ContextBarMode.none;

    return ClipRect(
      child: AnimatedContainer(
        duration: _animationDuration,
        curve: Curves.easeInOut,
        height: isExpanded ? _expandedHeight : 0,
        child: SingleChildScrollView(
          child: AnimatedSwitcher(
            duration: _animationDuration,
            switchInCurve: Curves.easeIn,
            switchOutCurve: Curves.easeOut,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: animation,
                child: child,
              );
            },
            child: _buildContent(mode),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(_ContextBarMode mode) {
    return switch (mode) {
      _ContextBarMode.drawing => const DrawingTools(key: ValueKey('drawing')),
      _ContextBarMode.deleting =>
        const DeleteOptions(key: ValueKey('deleting')),
      _ContextBarMode.none => const SizedBox.shrink(key: ValueKey('none')),
    };
  }
}

class ToolGrid extends ConsumerWidget {
  const ToolGrid({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentInteractionState = ref.watch(interactionStateProvider);

    // void showImageDialog() {
    //   showDialog(
    //     context: context,
    //     builder: (dialogContext) {
    //       return const ImageSelector();
    //     },
    //   );
    // }

    return Theme(
      data: Theme.of(context).copyWith(
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        hoverColor: Colors.transparent,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              "Tools",
              style: TextStyle(fontSize: 20),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: GridView.count(
              shrinkWrap: true,
              crossAxisCount: 5,
              mainAxisSpacing: 5,
              crossAxisSpacing: 5,
              children: [
                SelectableIconButton(
                  icon: const Icon(Icons.draw),
                  tooltip: "Draw Q",
                  onPressed: () {
                    switch (currentInteractionState) {
                      case InteractionState.drawing:
                        ref
                            .read(interactionStateProvider.notifier)
                            .update(InteractionState.navigation);
                      default:
                        ref
                            .read(interactionStateProvider.notifier)
                            .update(InteractionState.drawing);
                    }
                  },
                  isSelected:
                      currentInteractionState == InteractionState.drawing,
                ),
                SelectableIconButton(
                  tooltip: "Eraser W",
                  onPressed: () {
                    switch (currentInteractionState) {
                      case InteractionState.erasing:
                        ref
                            .read(interactionStateProvider.notifier)
                            .update(InteractionState.navigation);
                      default:
                        ref
                            .read(interactionStateProvider.notifier)
                            .update(InteractionState.erasing);
                    }
                  },
                  icon: const Icon(
                    CustomIcons.eraser,
                    size: 20,
                  ),
                  isSelected:
                      currentInteractionState == InteractionState.erasing,
                ),
                SelectableIconButton(
                  tooltip: "Delete E",
                  onPressed: () {
                    switch (currentInteractionState) {
                      case InteractionState.deleting:
                        ref
                            .read(interactionStateProvider.notifier)
                            .update(InteractionState.navigation);
                      default:
                        ref
                            .read(interactionStateProvider.notifier)
                            .update(InteractionState.deleting);
                    }
                  },
                  isSelected:
                      currentInteractionState == InteractionState.deleting,
                  icon: const Icon(
                    Icons.delete,
                  ),
                ),
                ShadTooltip(
                  builder: (context) => const Text("Add Text"),
                  child: ShadIconButton.secondary(
                    onPressed: () {
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                      const uuid = Uuid();
                      ref.read(textProvider.notifier).addText(
                            PlacedText(
                              position: const Offset(500, 500),
                              id: uuid.v4(),
                            ),
                          );
                    },
                    icon: const Icon(Icons.text_fields),
                  ),
                ),
                ShadTooltip(
                  builder: (context) => const Text("Add Image"),
                  child: ShadIconButton.secondary(
                    onPressed: () async {
                      if (kIsWeb) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'This feature is only supported in the Windows version.',
                            ),
                          ),
                        );
                        return;
                      }

                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);

                      FilePickerResult? result =
                          await FilePicker.platform.pickFiles(
                        allowMultiple: false,
                        type: FileType.custom,
                        allowedExtensions: ["png", "jpg", "gif", "webp"],
                      );

                      if (result == null) return;
                      final data = result.files.first.xFile;

                      ref.read(placedImageProvider.notifier).addImage(data);
                      // showImageDialog();
                    },
                    icon: const Icon(Icons.image_outlined),
                  ),
                ),
                SelectableIconButton(
                  tooltip: "Add Lineup",
                  onPressed: () async {
                    if (kIsWeb) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'This feature is only supported in the Windows version.',
                          ),
                        ),
                      );
                      return;
                    }

                    if (ref.watch(interactionStateProvider) ==
                        InteractionState.lineUpPlacing) {
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                    } else {
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.lineUpPlacing);
                    }
                  },
                  icon: const Icon(LucideIcons.bookOpen400),
                  isSelected: ref.watch(interactionStateProvider) ==
                      InteractionState.lineUpPlacing,
                ),
                ShadTooltip(
                  builder: (context) => const Text("Spike"),
                  child: ShadIconButton.secondary(
                    onPressed: () {
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                      const uuid = Uuid();

                      ref.read(utilityProvider.notifier).addUtility(
                            PlacedUtility(
                              position: const Offset(500, 500),
                              id: uuid.v4(),
                              type: UtilityType.spike,
                            ),
                          );
                    },
                    icon: SvgPicture.asset(
                      "assets/spike.svg",
                      width: 20,
                      height: 20,
                    ),
                  ),
                ),
                ShadTooltip(
                  builder: (context) => const Text("View Cone 180°"),
                  child: ShadIconButton.secondary(
                    onPressed: () {
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                      const uuid = Uuid();

                      ref.read(utilityProvider.notifier).addUtility(
                            PlacedUtility(
                              position: const Offset(500, 500),
                              id: uuid.v4(),
                              type: UtilityType.viewCone180,
                              angle: 180,
                            ),
                          );
                    },
                    icon: const Icon(LucideIcons.eye, size: 20),
                  ),
                ),
                ShadTooltip(
                  builder: (context) => const Text("View Cone 90°"),
                  child: ShadIconButton.secondary(
                    onPressed: () {
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                      const uuid = Uuid();

                      ref.read(utilityProvider.notifier).addUtility(
                            PlacedUtility(
                              position: const Offset(500, 500),
                              id: uuid.v4(),
                              type: UtilityType.viewCone90,
                              angle: 90,
                            ),
                          );
                    },
                    icon: const Icon(LucideIcons.scanEye, size: 20),
                  ),
                ),
                ShadTooltip(
                  builder: (context) => const Text("View Cone 40°"),
                  child: ShadIconButton.secondary(
                    onPressed: () {
                      ref
                          .read(interactionStateProvider.notifier)
                          .update(InteractionState.navigation);
                      const uuid = Uuid();

                      ref.read(utilityProvider.notifier).addUtility(
                            PlacedUtility(
                              position: const Offset(500, 500),
                              id: uuid.v4(),
                              type: UtilityType.viewCone40,
                              angle: 40,
                            ),
                          );
                    },
                    icon: const Icon(LucideIcons.focus, size: 20),
                  ),
                ),
              ],
            ),
          ),
          const BottomContextBar(),
        ],
      ),
    );
  }
}
