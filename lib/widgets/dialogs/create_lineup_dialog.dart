import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
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

/// Media for a lineup. Without [linkId] it commits the current placement or,
/// with [variantLandingId], adds another way into that landing spot from one
/// of its origins ([variantOriginId] preselects one). With [linkId] it edits
/// that lineup.
class CreateLineupDialog extends ConsumerStatefulWidget {
  const CreateLineupDialog({
    super.key,
    this.linkId,
    this.variantOriginId,
    this.variantLandingId,
  }) : assert(variantOriginId == null || variantLandingId != null);

  final String? linkId;
  final String? variantOriginId;
  final String? variantLandingId;

  @override
  ConsumerState<CreateLineupDialog> createState() => _CreateLineupDialogState();
}

class _CreateLineupDialogState extends ConsumerState<CreateLineupDialog> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _youtubeLinkController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  final List<SimpleImageData> _imagePaths = [];

  String? _variantOriginId;

  bool get _isEditing => widget.linkId != null;

  bool get _isVariant => widget.variantLandingId != null;

  List<String> get _variantOriginIds {
    final links =
        ref.read(lineUpProvider).linksToLanding(widget.variantLandingId!);
    return <String>{for (final link in links) link.originId}.toList();
  }

  @override
  void initState() {
    super.initState();
    if (_isVariant) {
      final originIds = _variantOriginIds;
      _variantOriginId = widget.variantOriginId ??
          (originIds.length == 1 ? originIds.single : null);
    }
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
      if (_isVariant && _variantOriginId == null) {
        Settings.showToast(
          message: 'Pick which origin this lineup is thrown from',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        return;
      }
      final link = _isVariant
          ? notifier.addVariant(
              _variantOriginId!,
              widget.variantLandingId!,
              name: name,
              youtubeLink: _youtubeLinkController.text,
              notes: _notesController.text,
              images: _imagePaths,
            )
          : notifier.commitPlacement(
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

  Widget _originSelect() {
    final state = ref.watch(lineUpProvider);
    final originIds = _variantOriginIds;
    if (originIds.length < 2) return const SizedBox.shrink();

    String label(String originId) {
      final origin = state.originById(originId);
      final agentName = AgentData.agents[origin?.agent.type]?.name ?? 'Origin';
      final index = state.origins.indexWhere((entry) => entry.id == originId);
      return '$agentName ${index + 1}';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          const Text('From', style: TextStyle(color: Colors.white)),
          const SizedBox(width: 12),
          Expanded(
            child: ShadSelect<String>(
              initialValue: _variantOriginId,
              placeholder: const Text('Pick an origin'),
              selectedOptionBuilder: (context, value) => Text(label(value)),
              options: [
                for (final originId in originIds)
                  ShadOption(value: originId, child: Text(label(originId))),
              ],
              onChanged: (value) => setState(() => _variantOriginId = value),
            ),
          ),
        ],
      ),
    );
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
            header: _isVariant ? _originSelect() : null,
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
