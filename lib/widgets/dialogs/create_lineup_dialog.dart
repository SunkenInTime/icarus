import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/services/clipboard_service.dart';
import 'package:icarus/widgets/dialogs/strategy/line_up_media_page.dart';
import 'package:path/path.dart' as path;
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

class CreateLineupDialog extends ConsumerStatefulWidget {
  const CreateLineupDialog({
    super.key,
    this.lineUpGroupId,
    this.lineUpItemId,
  });

  final String? lineUpGroupId;
  final String? lineUpItemId;

  @override
  ConsumerState<CreateLineupDialog> createState() => _CreateLineupDialogState();
}

class _CreateLineupDialogState extends ConsumerState<CreateLineupDialog> {
  final TextEditingController _youtubeLinkController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final List<SimpleImageData> _imagePaths = [];

  bool get _isEditing =>
      widget.lineUpGroupId != null && widget.lineUpItemId != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      final item = ref.read(lineUpProvider.notifier).getItemById(
            groupId: widget.lineUpGroupId!,
            itemId: widget.lineUpItemId!,
          );
      if (item != null) {
        _youtubeLinkController.text = item.youtubeLink;
        _notesController.text = item.notes;
        _imagePaths.addAll(item.images);
      }
    }
  }

  @override
  void dispose() {
    _youtubeLinkController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final lineUpState = ref.read(lineUpProvider);
    final notifier = ref.read(lineUpProvider.notifier);

    if (_isEditing) {
      final existingItem = notifier.getItemById(
        groupId: widget.lineUpGroupId!,
        itemId: widget.lineUpItemId!,
      );
      if (existingItem != null) {
        ref.read(actionProvider.notifier).performTransaction(
              groups: const [ActionGroup.lineUp],
              mutation: () {
                notifier.updateItem(
                  groupId: widget.lineUpGroupId!,
                  item: existingItem.copyWith(
                    youtubeLink: _youtubeLinkController.text,
                    notes: _notesController.text,
                    images: _imagePaths,
                  ),
                );
              },
            );
      }
    } else {
      final currentAbility = lineUpState.currentAbility;
      if (currentAbility == null) {
        return;
      }

      final item = LineUpItem(
        id: const Uuid().v4(),
        ability: currentAbility,
        youtubeLink: _youtubeLinkController.text,
        images: _imagePaths,
        notes: _notesController.text,
      );

      if (lineUpState.currentGroupId != null) {
        ref.read(actionProvider.notifier).performTransaction(
              groups: const [ActionGroup.lineUp],
              mutation: () {
                notifier.addItemToGroup(
                  groupId: lineUpState.currentGroupId!,
                  item: item.copyWith(
                    ability: item.ability.copyWith(
                      lineUpID: lineUpState.currentGroupId,
                    ),
                  ),
                );
              },
            );
      } else {
        final currentAgent = lineUpState.currentAgent;
        if (currentAgent == null) {
          return;
        }

        final groupId = const Uuid().v4();
        notifier.addGroup(
          LineUpGroup(
            id: groupId,
            agent: currentAgent.copyWith(lineUpID: groupId),
            items: [
              item.copyWith(
                ability: item.ability.copyWith(lineUpID: groupId),
              ),
            ],
          ),
        );
      }
    }

    ref
        .read(interactionStateProvider.notifier)
        .update(InteractionState.navigation);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          ref
              .read(interactionStateProvider.notifier)
              .update(InteractionState.navigation);
        }
      },
      child: ShadDialog(
        title: Text(_isEditing ? "Edit Line Up" : "Create Line Up"),
        actions: [
          ShadButton(
            onPressed: _save,
            child: const Text("Done"),
          ),
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
              final fileExtension = path.extension(imageFile.path);
              final imageBytes = await imageFile.readAsBytes();
              final id = const Uuid().v4();

              final imageData =
                  SimpleImageData(id: id, fileExtension: fileExtension);

              await ref
                  .read(placedImageProvider.notifier)
                  .saveSecureImage(imageBytes, id, fileExtension);

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

              final fileExtension =
                  PlacedImageSerializer.detectImageFormat(bytes);

              if (fileExtension == null) {
                Settings.showToast(
                  message: 'Clipboard image type not supported',
                  backgroundColor: Settings.tacticalVioletTheme.destructive,
                );
                return;
              }

              final id = const Uuid().v4();
              final imageData =
                  SimpleImageData(id: id, fileExtension: fileExtension);

              await ref
                  .read(placedImageProvider.notifier)
                  .saveSecureImage(bytes, id, fileExtension);

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
