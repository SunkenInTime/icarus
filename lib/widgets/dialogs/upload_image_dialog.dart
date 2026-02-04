import 'dart:convert' show base64Decode;
import 'dart:developer';
import 'dart:typed_data' show Uint8List;

import 'package:cross_file/cross_file.dart';
import 'package:dash_painter/dash_painter.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class UploadImageDialog extends ConsumerStatefulWidget {
  const UploadImageDialog({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _UploadImageDialogState();
}

class _UploadImageDialogState extends ConsumerState<UploadImageDialog> {
  bool _isDragging = false;
  bool _isCheckingClipboard = false;
  Uint8List? _selectedBytes;
  String? _selectedName;

  @override
  void initState() {
    super.initState();
    // Best-effort: if the clipboard contains an image (or an image data URI),
    // automatically select it.
    Future<void>(() async {
      await _trySelectImageFromClipboard();
    });
  }

  Future<void> _pickImage() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
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
    if (kIsWeb) return;
    if (files.isEmpty) return;

    XFile? imageFile;
    for (final f in files) {
      final name = f.name.toLowerCase();
      final ext = name.contains('.') ? name.split('.').last : '';
      if (const {'png', 'jpg', 'jpeg', 'webp', 'gif'}.contains(ext)) {
        imageFile = f;
        break;
      }
    }
    imageFile ??= files.first;

    final bytes = await imageFile.readAsBytes();
    if (!mounted) return;

    setState(() {
      _selectedBytes = bytes;
      _selectedName = imageFile!.name;
      _isDragging = false;
    });
  }

  Future<bool> _trySelectImageFromClipboard() async {
    if (_selectedBytes != null) return false;
    log('trying to select image from clipboard');
    setState(() {
      _isCheckingClipboard = true;
    });

    try {
      log("yes I buy");
      final clipBoardImages = await Pasteboard.text;

      log('clipBoardImages: $clipBoardImages');
      // log('clipBoardImages: ${clipBoardImages.length}');
      // log('clipBoardImages: ${clipBoardImages.first}');
      // Flutter clipboard APIs don't reliably expose raw image bytes across
      // platforms, so we do a best-effort approach:
      // - Try image formats (some platforms may expose image data as text)
      // - Fallback to plain text and parse a data URI
      final ClipboardData? maybePng = await Clipboard.getData('image/png');
      final Uint8List? pngBytes = _tryDecodeImageDataUri(maybePng?.text);
      if (pngBytes != null) {
        if (!mounted) return true;
        setState(() {
          _selectedBytes = pngBytes;
          _selectedName = 'clipboard.png';
        });
        return true;
      }

      final ClipboardData? maybeJpeg = await Clipboard.getData('image/jpeg');
      final Uint8List? jpegBytes = _tryDecodeImageDataUri(maybeJpeg?.text);
      if (jpegBytes != null) {
        if (!mounted) return true;
        setState(() {
          _selectedBytes = jpegBytes;
          _selectedName = 'clipboard.jpg';
        });
        return true;
      }

      final ClipboardData? text = await Clipboard.getData(Clipboard.kTextPlain);
      final Uint8List? textBytes = _tryDecodeImageDataUri(text?.text);
      if (textBytes != null) {
        if (!mounted) return true;
        setState(() {
          _selectedBytes = textBytes;
          _selectedName = 'clipboard.png';
        });
        return true;
      }

      // If the clipboard contains a file path / file:// URL to an image (common
      // when copying files in desktop file managers), try loading it.
      if (!kIsWeb) {
        final pathBytes = await _tryLoadImageFromClipboardPath(text?.text);
        if (pathBytes != null) {
          if (!mounted) return true;
          setState(() {
            _selectedBytes = pathBytes.bytes;
            _selectedName = pathBytes.name;
          });
          return true;
        }
      }
    } catch (_) {
      // Best-effort only; ignore clipboard errors.
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingClipboard = false;
        });
      }
    }

    return false;
  }

  Future<({Uint8List bytes, String name})?> _tryLoadImageFromClipboardPath(
    String? text,
  ) async {
    if (text == null) return null;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;

    // Some clipboards include surrounding quotes.
    final unquoted = trimmed.startsWith('"') && trimmed.endsWith('"')
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;

    String? path;
    if (unquoted.startsWith('file://')) {
      try {
        path = Uri.parse(unquoted).toFilePath();
      } catch (_) {
        path = null;
      }
    } else {
      path = unquoted;
    }

    if (path == null || path.isEmpty) return null;

    final lower = path.toLowerCase();
    final ext = lower.contains('.') ? lower.split('.').last : '';
    if (!const {'png', 'jpg', 'jpeg', 'webp', 'gif'}.contains(ext)) return null;

    try {
      final file = XFile(path);
      final bytes = await file.readAsBytes();
      final name = file.name.isNotEmpty ? file.name : 'clipboard.$ext';
      return (bytes: bytes, name: name);
    } catch (_) {
      return null;
    }
  }

  Uint8List? _tryDecodeImageDataUri(String? text) {
    if (text == null) return null;
    final trimmed = text.trim();
    if (!trimmed.startsWith('data:image/')) return null;

    final commaIndex = trimmed.indexOf(',');
    if (commaIndex <= 0 || commaIndex >= trimmed.length - 1) return null;

    final metadata = trimmed.substring(0, commaIndex);
    final payload = trimmed.substring(commaIndex + 1);
    if (!metadata.contains(';base64')) return null;

    try {
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bool hasSelection = _selectedBytes != null;

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

    // Desktop drag/drop wrapper (no-op on web).
    if (!kIsWeb) {
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
      description: const Text('Drop an image here or click to choose a file.'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop<Uint8List?>(null),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: hasSelection
              ? () => Navigator.of(context).pop<Uint8List?>(_selectedBytes)
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
                kIsWeb
                    ? 'Tip: Drag & drop isn’t available on web.'
                    : 'Tip: You can also drag & drop an image from your desktop.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
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
    final borderColor = isDragging ? cs.primary : cs.outlineVariant;
    final bgColor = isDragging
        ? cs.primary.withOpacity(0.06)
        : cs.onSurface.withOpacity(0.03);

    return AspectRatio(
      aspectRatio: 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPick,
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Settings.tacticalVioletTheme.card,
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
                                fit: BoxFit.cover,
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
                      color: cs.primary.withOpacity(0.08),
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
              isDragging
                  ? Icons.file_download_outlined
                  : Icons.add_photo_alternate_outlined,
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
              'PNG, JPG, WEBP, GIF',
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
        color: Settings.tacticalVioletTheme.background,
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
            const Icon(Icons.image_outlined, size: 18),
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

class _DottedRRectBorderPainter extends CustomPainter {
  _DottedRRectBorderPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
    required this.dashLength,
    required this.dashGap,
  });

  final Color color;
  final double radius;
  final double strokeWidth;
  final double dashLength;
  final double dashGap;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final path = Path()..addRRect(rrect);
    DashPainter(span: dashLength, step: dashLength + dashGap)
        .paint(canvas, path, paint);
  }

  @override
  bool shouldRepaint(covariant _DottedRRectBorderPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.radius != radius ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.dashLength != dashLength ||
        oldDelegate.dashGap != dashGap;
  }
}
