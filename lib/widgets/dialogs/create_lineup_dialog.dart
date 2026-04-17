import 'dart:typed_data' show Uint8List;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/services/clipboard_service.dart';
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

  Future<void> _enqueueLineupMediaJobs({
    required String lineupId,
    required List<SimpleImageData> images,
  }) async {
    final strategyState = ref.read(strategyProvider);
    if (strategyState.source != StrategySource.cloud ||
        strategyState.strategyId == null) {
      return;
    }

    final pageId = ref.read(strategyPageSessionProvider).activePageId;
    if (pageId == null) {
      return;
    }

    for (final image in images) {
      await ref.read(cloudMediaUploadQueueProvider.notifier).enqueueJobForLocalFile(
            strategyPublicId: strategyState.strategyId!,
            pagePublicId: pageId,
            ownerType: CloudMediaOwnerType.lineup,
            ownerPublicId: lineupId,
            assetPublicId: image.id,
            fileExtension: image.fileExtension,
          );
    }
  }

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
                await _enqueueLineupMediaJobs(
                  lineupId: lineUp.id,
                  images: lineUp.images,
                );
              } else {
                final id = const Uuid().v4();

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
                await _enqueueLineupMediaJobs(
                  lineupId: currentLineUp.id,
                  images: currentLineUp.images,
                );
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
                allowedExtensions: ["png", "jpg", "gif", "webp", "bmp"],
              );

              if (result == null) return;
              final imageFile = result.files.first.xFile;
              final String fileExtension = path.extension(imageFile.path);
              final Uint8List imageBytes = await imageFile.readAsBytes();
              final id = const Uuid().v4();
              final strategyId = ref.read(strategyProvider).strategyId;

              final SimpleImageData imageData =
                  SimpleImageData(id: id, fileExtension: fileExtension);

              await ref
                  .read(placedImageProvider.notifier)
                  .saveSecureImage(
                    imageBytes,
                    id,
                    fileExtension,
                    strategyId: strategyId,
                  );

              setState(() {
                _imagePaths.add(imageData);
              });
            },
            onPasteImage: () async {
              final (bytes, _) =
                  await ClipboardService.trySelectImageFromClipboard();
              if (bytes == null) {
                Settings.showToast(
                  message: 'No image found in clipboard',
                  backgroundColor: Settings.tacticalVioletTheme.destructive,
                );
                return;
              }

              final String? fileExtension =
                  PlacedImageSerializer.detectImageFormat(bytes);

              if (fileExtension == null) {
                Settings.showToast(
                  message: 'Clipboard image type not supported',
                  backgroundColor: Settings.tacticalVioletTheme.destructive,
                );
                return;
              }

              final id = const Uuid().v4();
              final strategyId = ref.read(strategyProvider).strategyId;
              final SimpleImageData imageData =
                  SimpleImageData(id: id, fileExtension: fileExtension);

              await ref
                  .read(placedImageProvider.notifier)
                  .saveSecureImage(
                    bytes,
                    id,
                    fileExtension,
                    strategyId: strategyId,
                  );

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
