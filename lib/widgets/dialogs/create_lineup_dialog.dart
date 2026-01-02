import 'dart:developer';
import 'dart:io' show Directory;
import 'dart:typed_data' show Uint8List;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/youtube_handler.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/dialogs/strategy/line_up_media_page.dart';
import 'package:path/path.dart' as path;
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

class CreateLineupDialog extends ConsumerStatefulWidget {
  const CreateLineupDialog({super.key, this.lineUpId});
  final String? lineUpId;

  @override
  ConsumerState<CreateLineupDialog> createState() => _CreateLineupDialogState();
}

class _CreateLineupDialogState extends ConsumerState<CreateLineupDialog> {
  final TextEditingController _youtubeLinkController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final List<SimpleImageData> _imagePaths = [];

  @override
  void initState() {
    super.initState();
    if (widget.lineUpId != null) {
      final lineUp =
          ref.read(lineUpProvider.notifier).getLineUpById(widget.lineUpId!);

      _youtubeLinkController.text = lineUp!.youtubeLink;
      _notesController.text = lineUp.notes;
      _imagePaths.addAll(lineUp.images);
    }
    // final state = ref.read(lineUpProvider);
    // if (state.currentAgent != null) {
    //   try {
    //     _selectedAgent = AgentData.agents[state.currentAgent!.type];
    //   } catch (e) {
    //     // Handle case where agent is not found
    //   }
    // }
    // if (state.currentAbility != null) {
    //   _selectedAbility = state.currentAbility!.data;
    // }
  }

  @override
  void dispose() {
    _youtubeLinkController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // final bool canSave = _selectedAgent != null && _selectedAbility != null;

    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          ref
              .read(interactionStateProvider.notifier)
              .update(InteractionState.navigation);
        }
      },
      child: ShadDialog(
        title: Text(
          widget.lineUpId != null ? "Edit Line Up" : "Create Line Up",
        ),
        actions: [
          ShadButton(
            onPressed: () async {
              if (widget.lineUpId != null) {
                LineUp lineUp = ref
                    .read(lineUpProvider.notifier)
                    .getLineUpById(widget.lineUpId!)!;

                lineUp = lineUp.copyWith(
                  youtubeLink: _youtubeLinkController.text,
                  notes: _notesController.text,
                  images: _imagePaths,
                );

                ref.read(lineUpProvider.notifier).updateLineUp(lineUp);
              } else {
                final id = const Uuid().v4();

                log("notes : ${_notesController.text}");

                final LineUp currentLineUp = LineUp(
                  id: id,
                  agent: ref
                      .read(lineUpProvider)
                      .currentAgent!
                      .copyWith(lineUpID: id),
                  ability: ref
                      .read(lineUpProvider)
                      .currentAbility!
                      .copyWith(lineUpID: id),
                  youtubeLink: _youtubeLinkController.text,
                  images: _imagePaths,
                  notes: _notesController.text,
                );

                ref.read(lineUpProvider.notifier).addLineUp(currentLineUp);
              }

              ref
                  .read(interactionStateProvider.notifier)
                  .update(InteractionState.navigation);
              Navigator.of(context).pop();
            },
            child: const Text("Done"),
          )
        ],
        child: SizedBox(
          width: 600,
          height: 504,
          child: LineupMediaPage(
            notesController: _notesController,
            youtubeLinkController: _youtubeLinkController,
            images: _imagePaths,
            onAddImage: () async {
              FilePickerResult? result = await FilePicker.platform.pickFiles(
                allowMultiple: false,
                type: FileType.custom,
                allowedExtensions: ["png", "jpg", "gif", "webp"],
              );

              if (result == null) return;
              final imageFile = result.files.first.xFile;
              final String fileExtension = path.extension(imageFile.path);
              final Uint8List imageBytes = await imageFile.readAsBytes();
              final id = const Uuid().v4();

              final SimpleImageData imageData =
                  SimpleImageData(id: id, fileExtension: fileExtension);

              await ref
                  .read(placedImageProvider.notifier)
                  .saveSecureImage(imageBytes, id, fileExtension);

              setState(() {
                _imagePaths.add(imageData);
              });
            },
            onRemoveImage: (index) {
              setState(() {
                _imagePaths.removeAt(index);
              });
            },
          ),
        ),
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  const _DialogHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text("Create Line Up", style: TextStyle(color: Colors.white)),
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, color: Colors.white),
          tooltip: "Close",
        ),
      ],
    );
  }
}
