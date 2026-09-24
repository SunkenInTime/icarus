import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
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
  final Set<String> _initialImageIds = {};

  Future<void> _enqueueLineupMediaJobs({
    required List<SimpleImageData> images,
  }) async {
    final strategyState = ref.read(strategyProvider);
    if (strategyState.source != StrategySource.cloud ||
        strategyState.strategyId == null) {
      return;
    }

    await ref
        .read(cloudMediaUploadQueueProvider.notifier)
        .enqueueLineupMediaJobs(
          strategyPublicId: strategyState.strategyId!,
          images: images,
        );
  }

  Future<void> _commitLineupMediaJobs({
    required List<SimpleImageData> images,
  }) async {
    final strategyState = ref.read(strategyProvider);
    if (strategyState.source != StrategySource.cloud ||
        strategyState.strategyId == null ||
        images.isEmpty) {
      return;
    }
    await ref
        .read(cloudMediaUploadQueueProvider.notifier)
        .commitStagedMediaReferences(
          strategyPublicId: strategyState.strategyId!,
          assetPublicIds: images.map((image) => image.id),
        );
  }

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
        _initialImageIds.addAll(link.images.map((image) => image.id));
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
    final existing = _isEditing ? notifier.linkById(widget.linkId!) : null;
    if (_isEditing && existing == null) return;
    if (!_isEditing &&
        !(ref.read(lineUpProvider).placement?.isComplete ?? false)) {
      return;
    }

    // Cloud images are queued before the lineup references them, so a
    // lineup never points at an image the server will not receive.
    final imagesNeedingUpload = _imagePaths
        .where((image) => !_initialImageIds.contains(image.id))
        .toList(growable: false);
    try {
      await _enqueueLineupMediaJobs(images: imagesNeedingUpload);
    } catch (_) {
      Settings.showToast(
        message: 'Could not queue these images for cloud sync. '
            'They remain on this device. Try again before closing.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    if (existing != null) {
      notifier.updateLink(
        existing.copyWith(
          name: name,
          youtubeLink: _youtubeLinkController.text,
          notes: _notesController.text,
          images: _imagePaths,
        ),
      );
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

    try {
      await _commitLineupMediaJobs(images: imagesNeedingUpload);
    } catch (_) {
      Settings.showToast(
        message: 'The lineup is kept in the editor, but its cloud work is '
            'still pending. Use Save before leaving.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
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
                // The browser hands over bytes, never a path.
                withData: true,
              );

              if (result == null || result.files.isEmpty) return;
              final picked = result.files.first;
              final fileExtension = path.extension(picked.name);
              final imageBytes =
                  picked.bytes ?? await picked.xFile.readAsBytes();
              final id = const Uuid().v4();
              final strategyId = ref.read(strategyProvider).strategyId;

              final imageData =
                  SimpleImageData(id: id, fileExtension: fileExtension);

              await ref.read(placedImageProvider.notifier).saveSecureImage(
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
              final strategyId = ref.read(strategyProvider).strategyId;
              final imageData =
                  SimpleImageData(id: id, fileExtension: fileExtension);

              await ref.read(placedImageProvider.notifier).saveSecureImage(
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
