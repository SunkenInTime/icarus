import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/media_bytes_source.dart';
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

/// Images picked in one lineup dialog that no lineup references yet. Their
/// bytes are kept as soon as they are picked (on web, for upload); they are
/// let go when removed, or when the dialog closes without saving.
class LineupImageDrafts {
  LineupImageDrafts(this._images, {required this.strategyId});

  final PlacedImageProvider _images;
  final String? strategyId;
  final Set<String> _ids = {};
  bool _closed = false;

  /// Keeps [bytes] as a new draft. Returns null, keeping nothing, when the
  /// dialog closed while they were being kept. Throws
  /// [MediaTooLargeException], keeping nothing, when the image can never
  /// upload.
  Future<SimpleImageData?> add(Uint8List bytes, String fileExtension) async {
    final id = const Uuid().v4();
    await _images.saveSecureImage(
      bytes,
      id,
      fileExtension,
      strategyId: strategyId,
    );
    if (_closed) {
      await _discard(id);
      return null;
    }
    _ids.add(id);
    return SimpleImageData(id: id, fileExtension: fileExtension);
  }

  /// Lets go of [imageId] if it is a draft; saved images are left alone.
  Future<void> remove(String imageId) async {
    if (_ids.remove(imageId)) await _discard(imageId);
  }

  /// Hands every draft to the upload queue before their jobs are written, so
  /// nothing can let their bytes go meanwhile. Pass the result to [takeBack]
  /// if queuing fails.
  Set<String> handOver() {
    final ids = {..._ids};
    _ids.clear();
    return ids;
  }

  /// Queuing [ids] failed: they are drafts again.
  Future<void> takeBack(Set<String> ids) async {
    if (!_closed) {
      _ids.addAll(ids);
      return;
    }
    for (final id in ids) {
      await _discard(id);
    }
  }

  /// The dialog closed. Drafts it still owns go, and so does any pick that
  /// finishes after this.
  Future<void> dismissed() async {
    _closed = true;
    final ids = _ids.toList();
    _ids.clear();
    for (final id in ids) {
      await _discard(id);
    }
  }

  Future<void> _discard(String id) =>
      _images.discardDraftImage(imageId: id, strategyId: strategyId);
}

class _CreateLineupDialogState extends ConsumerState<CreateLineupDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _youtubeLinkController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final List<SimpleImageData> _imagePaths = [];
  final Set<String> _initialImageIds = {};
  late final LineupImageDrafts _drafts = LineupImageDrafts(
    ref.read(placedImageProvider.notifier),
    strategyId: ref.read(strategyProvider).strategyId,
  );

  // While Save queues the images, the dialog cannot be closed.
  bool _saving = false;

  Future<void> _addDraftImage(Uint8List bytes, String fileExtension) async {
    final SimpleImageData? image;
    try {
      image = await _drafts.add(bytes, fileExtension);
    } on MediaTooLargeException catch (error) {
      Settings.showToast(
        message: error.userMessage,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }
    if (image == null) return;
    if (!mounted) {
      await _drafts.remove(image.id);
      return;
    }
    setState(() => _imagePaths.add(image!));
  }

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
    // The queue owns these images from here, before their jobs are written.
    setState(() => _saving = true);
    final handedOver = _drafts.handOver();
    try {
      await _enqueueLineupMediaJobs(images: imagesNeedingUpload);
    } catch (_) {
      await _drafts.takeBack(handedOver);
      if (mounted) setState(() => _saving = false);
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
      // Barrier taps and Escape wait for Save to finish queuing.
      canPop: !_saving,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          // Images handed to the queue by Save are not drafts any more.
          unawaited(_drafts.dismissed());
          ref
              .read(interactionStateProvider.notifier)
              .update(InteractionState.navigation);
        }
      },
      child: ShadDialog(
        title: Text(_isEditing ? "Edit Lineup" : "Create Lineup"),
        // The close button pops directly, past PopScope, so it steps aside
        // while Save is queuing.
        closeIcon: _saving ? const SizedBox.shrink() : null,
        actions: [
          ShadButton(
            onPressed: _saving ? null : _save,
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
              await _addDraftImage(imageBytes, fileExtension);
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

              await _addDraftImage(bytes, fileExtension);
            },
            onRemoveImage: (index) {
              final removed = _imagePaths[index];
              setState(() => _imagePaths.removeAt(index));
              unawaited(_drafts.remove(removed.id));
            },
          ),
        ),
      ),
    );
  }
}
