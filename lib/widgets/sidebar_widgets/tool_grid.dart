import 'dart:async' show Completer;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
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
import 'package:icarus/widgets/custom_expansion_tile.dart';
import 'package:icarus/widgets/sidebar_widgets/delete_options.dart';
import 'package:icarus/widgets/sidebar_widgets/drawing_tools.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

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
      child: CustomExpansionTile(
        title: const Text(
          "Tools",
          style: TextStyle(fontSize: 20),
        ),
        initiallyExpanded: true,
        persistentRow: [
          GridView.count(
            shrinkWrap: true,
            crossAxisCount: 5,
            children: [
              IconButton(
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
                icon: const Icon(Icons.draw),
                isSelected: currentInteractionState == InteractionState.drawing,
              ),
              IconButton(
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
                isSelected: currentInteractionState == InteractionState.erasing,
              ),
              IconButton(
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
              IconButton(
                tooltip: "Add Text T",
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
              IconButton(
                tooltip: "Add Image",
                onPressed: () async {
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
            ],
          ),
          const DrawingTools(),
          const DeleteOptions(),
        ],
        children: [
          GridView.count(
            shrinkWrap: true,
            crossAxisCount: 5,
            children: [
              IconButton(
                tooltip: "Spike",
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
                isSelected: currentInteractionState == InteractionState.drawing,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
