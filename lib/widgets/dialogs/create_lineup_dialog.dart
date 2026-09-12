import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/services/clipboard_service.dart';
import 'package:icarus/services/analytics_service.dart';
import 'package:icarus/widgets/dialogs/strategy/line_up_media_page.dart';
import 'package:path/path.dart' as path;
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:uuid/uuid.dart';

/// Media for a lineup. Without [linkId] it commits the current placement.
/// With [linkId] it edits that lineup.
class CreateLineupDialog extends ConsumerStatefulWidget {
  const CreateLineupDialog({super.key, this.linkId});

  final String? linkId;

  @override
  ConsumerState<CreateLineupDialog> createState() => _CreateLineupDialogState();
}

class _CreateLineupDialogState extends ConsumerState<CreateLineupDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _youtubeLinkController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final List<SimpleImageData> _imagePaths = [];

  bool get _isEditing => widget.linkId != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      final link = ref.read(lineUpProvider.notifier).linkById(widget.linkId!);
      if (link != null) {
        _nameController.text = link.name;
        _youtubeLinkController.text = link.youtubeLink;
        _notesController.text = link.notes;
        _imagePaths.addAll(link.images);
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _youtubeLinkController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final notifier = ref.read(lineUpProvider.notifier);
    final name = _nameController.text.trim();

    if (_isEditing) {
      final existing = notifier.linkById(widget.linkId!);
      if (existing != null) {
        ref.read(actionProvider.notifier).performTransaction(
          groups: const [ActionGroup.lineUp],
          mutation: () {
            notifier.updateLink(
              existing.copyWith(
                name: name,
                youtubeLink: _youtubeLinkController.text,
                notes: _notesController.text,
                images: _imagePaths,
              ),
            );
          },
        );
      }
    } else {
      final link = notifier.commitPlacement(
        name: name,
        youtubeLink: _youtubeLinkController.text,
        notes: _notesController.text,
        images: _imagePaths,
      );
      if (link == null) return;

      unawaited(
        AnalyticsService.instance.capture(
          'lineup_created',
          properties: {
            'has_video': _youtubeLinkController.text.trim().isNotEmpty,
            'has_notes': _notesController.text.trim().isNotEmpty,
            'has_images': _imagePaths.isNotEmpty,
            'has_name': name.isNotEmpty,
            'shares_origin': notifier.linksFromOrigin(link.originId).length > 1,
            'shares_landing':
                notifier.linksToLanding(link.landingId).length > 1,
          },
        ),
      );
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
        title: Text(_isEditing ? "Edit Lineup" : "Create Lineup"),
        actions: [
          ShadButton(
            onPressed: _save,
            child: const Text("Done"),
          ),
        ],
        child: SizedBox(
          width: 600,
          height: 576,
          child: LineupMediaPage(
            nameController: _nameController,
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
