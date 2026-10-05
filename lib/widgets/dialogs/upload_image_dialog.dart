import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/services/clipboard_service.dart';
import 'package:icarus/widgets/sidebar_widgets/color_library.dart';

import 'package:shadcn_ui/shadcn_ui.dart';

class UploadImageResult {
  const UploadImageResult({
    required this.bytes,
    required this.tagColorValue,
  });

  final Uint8List bytes;
  final int? tagColorValue;
}

class UploadImageDialog extends ConsumerStatefulWidget {
  const UploadImageDialog({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _UploadImageDialogState();
}

class _UploadImageDialogState extends ConsumerState<UploadImageDialog> {
  bool _isDragging = false;
  final bool _isCheckingClipboard = false;
  Uint8List? _selectedBytes;
  String? _selectedName;
  int? _selectedTagColorValue;

  @override
  void initState() {
    super.initState();
    // Best-effort: if the clipboard contains an image (or an image data URI),
    // automatically select it.
    Future<void>(() async {
      final (bytes, name) =
          await ClipboardService.trySelectImageFromClipboard();
      if (bytes != null) {
        if (!mounted) return;
        setState(() {
          _selectedBytes = bytes;
          _selectedName = name;
        });
      }
    });
  }

  Future<void> _pickImage() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
      withData: true, // ensures bytes are available (esp. web)
      lockParentWindow: true,
    );

    if (!mounted || result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final Uint8List bytes = file.bytes ?? (await file.xFile.readAsBytes());

    if (!mounted) return;

    setState(() {
      _selectedBytes = bytes;
      _selectedName = file.name;
    });
  }

  Future<void> _handleDrop(List<XFile> files) async {
    if (files.isEmpty) return;

    XFile? imageFile;
    for (final f in files) {
      final name = f.name.toLowerCase();
      final ext = name.contains('.') ? name.split('.').last : '';
      if (const {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'}.contains(ext)) {
        imageFile = f;
        break;
      }
    }
    if (imageFile == null) {
      if (!mounted) return;
      setState(() => _isDragging = false);
      Settings.showToast(
        message: 'Unsupported image format',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    final XFile selectedFile = imageFile;
    final bytes = await selectedFile.readAsBytes();
    final detectedExtension = PlacedImageSerializer.detectImageFormat(bytes);
    if (!mounted) return;
    if (detectedExtension == null) {
      setState(() => _isDragging = false);
      Settings.showToast(
        message: 'Unsupported image format',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    setState(() {
      _selectedBytes = bytes;
      _selectedName = selectedFile.name;
      _isDragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bool hasSelection = _selectedBytes != null;
    final policy = ref.watch(platformPolicyProvider);
    final canDropFiles = policy.supports(PlatformFeature.fileDrop);

    Widget content = _UploadDropSquare(
      isDragging: _isDragging,
      hasSelection: hasSelection,
      selectedBytes: _selectedBytes,
      selectedName: _selectedName,
      isCheckingClipboard: _isCheckingClipboard,
      onPick: _pickImage,
      onClear: hasSelection
          ? () {
              setState(() {
                _selectedBytes = null;
                _selectedName = null;
              });
            }
          : null,
    );

    if (canDropFiles) {
      content = DropTarget(
        onDragEntered: (_) => setState(() => _isDragging = true),
        onDragExited: (_) => setState(() => _isDragging = false),
        onDragDone: (details) async {
          await _handleDrop(details.files);
        },
        child: content,
      );
    }

    return ShadDialog(
      title: const Text('Upload image'),
      description: Text(
        canDropFiles
            ? 'Drop an image here or click to choose a file.'
            : 'Click to choose a file.',
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop<UploadImageResult?>(null),
          child: const Text('Cancel'),
        ),
        ShadIconButton.secondary(
          icon: const Icon(LucideIcons.clipboard),
          onPressed: () async {
            final (bytes, name) =
                await ClipboardService.trySelectImageFromClipboard();
            if (bytes != null) {
              setState(() {
                _selectedBytes = bytes;
                _selectedName = name;
              });
            }
          },
        ),
        ShadButton(
          onPressed: hasSelection
              ? () => Navigator.of(context).pop<UploadImageResult?>(
                    UploadImageResult(
                      bytes: _selectedBytes!,
                      tagColorValue: _selectedTagColorValue,
                    ),
                  )
              : null,
          child: const Text('Use image'),
        ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints.tightFor(width: 520),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              content,
              const SizedBox(height: 12),
              Text(
                canDropFiles
                    ? 'Tip: You can also drag & drop an image from your desktop.'
                    : policy.unavailableMessage(PlatformFeature.fileDrop)!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              const Text('Tag color'),
              const SizedBox(height: 6),
              ColorLibrary(
                includeEmpty: true,
                selectedColorValue: _selectedTagColorValue,
                onSelected: (colorValue) => setState(
                  () => _selectedTagColorValue = colorValue,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UploadDropSquare extends StatelessWidget {
  const _UploadDropSquare({
    required this.isDragging,
    required this.hasSelection,
    required this.selectedBytes,
    required this.selectedName,
    required this.isCheckingClipboard,
    required this.onPick,
    required this.onClear,
  });

  final bool isDragging;
  final bool hasSelection;
  final Uint8List? selectedBytes;
  final String? selectedName;
  final bool isCheckingClipboard;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AspectRatio(
      aspectRatio: 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          borderRadius: BorderRadius.circular(16),
          onTap: onPick,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    // A step below the dialog: the square is a place to
                    // drop into, not a card to read.
                    color: Settings.tacticalVioletTheme.background,
                    border: Border.all(
                      color: Settings.tacticalVioletTheme.border,
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: hasSelection
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.memory(
                                selectedBytes!,
                                fit: BoxFit.contain,
                              ),
                              Positioned(
                                left: 10,
                                right: 10,
                                bottom: 10,
                                child: _SelectionFooter(
                                  fileName: selectedName,
                                  onClear: onClear,
                                ),
                              ),
                            ],
                          ),
                        )
                      : _EmptyState(
                          isDragging: isDragging,
                          isCheckingClipboard: isCheckingClipboard,
                        ),
                ),
              ),
              if (isDragging)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.isDragging,
    required this.isCheckingClipboard,
  });

  final bool isDragging;
  final bool isCheckingClipboard;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final headline = Theme.of(context).textTheme.titleMedium;
    final body = Theme.of(context).textTheme.bodySmall;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isDragging ? LucideIcons.download : LucideIcons.imagePlus,
              size: 44,
              color: isDragging ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            Text(
              isDragging ? 'Drop to upload' : 'Drop or click to upload',
              textAlign: TextAlign.center,
              style: headline?.copyWith(
                color: isDragging ? cs.primary : cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'PNG, JPG, WEBP, GIF, BMP',
              textAlign: TextAlign.center,
              style: body?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (isCheckingClipboard) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Checking clipboard…',
                style: body?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SelectionFooter extends StatelessWidget {
  const _SelectionFooter({required this.fileName, required this.onClear});

  final String? fileName;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: cs.onSurface,
          fontWeight: FontWeight.w600,
        );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          Settings.cardForegroundBackdrop,
        ],
        border: Border.all(color: Settings.tacticalVioletTheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            const Icon(LucideIcons.image, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                fileName ?? 'Selected image',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ),
            const SizedBox(width: 8),
            ShadButton.outline(
              size: ShadButtonSize.sm,
              onPressed: onClear,
              child: const Text('Clear'),
            ),
          ],
        ),
      ),
    );
  }
}
