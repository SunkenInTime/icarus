import 'dart:async';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/screenshot/page_screenshot.dart';
import 'package:icarus/screenshot/save_screenshots.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/video_export/video_export_errors.dart';
import 'package:icarus/services/video_export/video_export_source.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

/// Draws the thumbnails the screenshot dialog shows (see
/// [renderPageThumbnails]). Tests replace it: the real one renders offscreen
/// in real time.
typedef PageThumbnailer = Future<void> Function(
  WidgetRef ref, {
  required Set<String> pageIds,
  required void Function(String pageId, ui.Image image) onThumbnail,
  required void Function(Set<String> pageIds, Object error) onUnavailable,
  required bool Function() isCancelled,
});

final pageThumbnailerProvider =
    Provider<PageThumbnailer>((ref) => renderPageThumbnails);

/// What the camera opens: every page as a thumbnail to tick, whether to
/// leave the background out, and then the save itself, with its progress,
/// in the same dialog. The page on the canvas starts ticked, so the usual
/// shot is the camera and then Enter; the background choice is remembered.
///
/// The dialog stays up until the screenshots are written or the save is
/// given up, and only Stop ends a capture that is running.
class ScreenshotDialog extends ConsumerStatefulWidget {
  const ScreenshotDialog({super.key});

  @override
  ConsumerState<ScreenshotDialog> createState() => _ScreenshotDialogState();
}

class _ScreenshotDialogState extends ConsumerState<ScreenshotDialog> {
  static const double _gridWidth = 712;
  static const double _singleWidth = 372;
  static const double _gap = 12;

  late final List<VideoExportPageChoice> _pages;
  late final String? _openPageId;
  final Set<String> _selected = {};
  final Map<String, ui.Image> _thumbnails = {};
  final Set<String> _unavailable = {};

  /// From the click on Save until the dialog closes, or the folder dialog is
  /// dismissed: a second press meanwhile would start a second save.
  bool _busy = false;

  /// The pages being saved, in page order, once capturing has begun.
  List<String>? _saving;

  /// How many of [_saving] are captured.
  int _captured = 0;

  /// Whether this save can be stopped: the open page alone captures in one
  /// go, with nothing between to stop at.
  bool _stoppable = false;
  bool _stopping = false;
  bool _closed = false;

  bool get _single => _pages.length == 1;

  @override
  void initState() {
    super.initState();
    _openPageId = ref.read(strategyPageSessionProvider).activePageId;
    final pages = videoExportPageChoices(ref);
    // Before a cloud strategy's pages arrive, the open page is all there is.
    _pages = pages.isEmpty && _openPageId != null
        ? [(id: _openPageId, name: '')]
        : pages;
    if (_pages.any((page) => page.id == _openPageId)) {
      _selected.add(_openPageId!);
    }
    unawaited(ref.read(pageThumbnailerProvider)(
      ref,
      pageIds: {for (final page in _pages) page.id},
      onThumbnail: _showThumbnail,
      onUnavailable: (pageIds, _) {
        if (mounted) setState(() => _unavailable.addAll(pageIds));
      },
      // A save renders the pages again at full size; the previews give way.
      isCancelled: () => !mounted || _saving != null,
    ));
  }

  @override
  void dispose() {
    for (final image in _thumbnails.values) {
      image.dispose();
    }
    super.dispose();
  }

  void _showThumbnail(String pageId, ui.Image image) {
    if (!mounted) {
      image.dispose();
      return;
    }
    setState(() {
      _thumbnails.remove(pageId)?.dispose();
      _thumbnails[pageId] = image;
    });
  }

  void _toggle(String pageId) => setState(() {
        if (!_selected.remove(pageId)) _selected.add(pageId);
      });

  bool get _allSelected => _selected.length == _pages.length;

  void _toggleAll() => setState(() {
        if (_allSelected) {
          _selected.clear();
        } else {
          _selected.addAll(_pages.map((page) => page.id));
        }
      });

  /// Captures the ticked pages. The open page alone is drawn as it is on
  /// screen; several are read as saved and go into a folder the user picks
  /// (desktop) or one .zip download (the browser).
  Future<void> _save() async {
    if (_busy || _selected.isEmpty) return;
    final strategy = ref.read(strategyProvider);
    if (strategy.strategyId == null) return;
    final strategyName = strategy.strategyName ?? 'new image';
    final pageIds = {..._selected};
    final openPageOnly = pageIds.length == 1 && pageIds.single == _openPageId;
    _busy = true;

    // Where several go is settled first, so a dismissed dialog costs
    // nothing and the choice stays open.
    String? folder;
    if (pageIds.length > 1 && !kIsWeb) {
      try {
        folder = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Choose a folder for the screenshots',
        );
      } catch (error, stackTrace) {
        _busy = false;
        AppErrorReporter.reportError(
          "Couldn't open the folder picker. Please try again.",
          error: error,
          stackTrace: stackTrace,
          source: 'ScreenshotDialog.save',
        );
        return;
      }
      if (folder == null || !mounted) {
        _busy = false;
        return;
      }
    }

    setState(() {
      _saving = [
        for (final page in _pages)
          if (pageIds.contains(page.id)) page.id,
      ];
      _stoppable = !openPageOnly;
    });
    try {
      if (openPageOnly) {
        final png = await captureEditorPage(ref);
        if (mounted) setState(() => _captured = 1);
        // Desktop asks where to save and writes the bytes there; the
        // browser downloads them.
        await FilePicker.platform.saveFile(
          type: FileType.custom,
          dialogTitle: 'Please select an output file:',
          fileName: '${sanitizeStrategyFileName(strategyName)}.png',
          allowedExtensions: ['png'],
          bytes: png,
        );
        return;
      }
      final shots = await captureStrategyPages(
        ref,
        pageIds: pageIds,
        transparentBackground:
            ref.read(appPreferencesProvider).transparentScreenshotBackground,
        onPage: (page, _) {
          if (mounted) setState(() => _captured = page - 1);
        },
        isCancelled: () => _stopping,
      );
      // A stop that landed during the last page still wins.
      if (_stopping) throw VideoExportCancelled();
      if (mounted) setState(() => _captured = shots.length);
      if (shots.length == 1) {
        await FilePicker.platform.saveFile(
          type: FileType.custom,
          dialogTitle: 'Please select an output file:',
          fileName: pageScreenshotFileName(strategyName, shots.single),
          allowedExtensions: ['png'],
          bytes: shots.single.png,
        );
      } else if (folder != null) {
        await writeScreenshotsToFolder(folder, strategyName, shots);
        Settings.showToast(
          message: 'Saved ${shots.length} screenshots to '
              '${p.basename(folder)}.',
          backgroundColor: Settings.tacticalVioletTheme.primary,
        );
      } else {
        await FilePicker.platform.saveFile(
          type: FileType.custom,
          fileName: '${sanitizeStrategyFileName(strategyName)}.zip',
          allowedExtensions: ['zip'],
          bytes: zipScreenshots(strategyName, shots),
        );
      }
    } on VideoExportCancelled {
      Settings.showToast(
        message: 'Screenshots cancelled.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
    } on VideoExportNotSynced catch (error, stackTrace) {
      _reportWarning(error.userMessage, error, stackTrace);
    } on VideoExportPagesChanged catch (error, stackTrace) {
      _reportWarning(error.userMessage, error, stackTrace);
    } on CaptureImagesUnavailable catch (error, stackTrace) {
      _reportWarning(error.userMessage, error, stackTrace);
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        pageIds.length > 1
            ? 'Could not export the screenshots. Please try again.'
            : 'Could not export the screenshot. Please try again.',
        error: error,
        stackTrace: stackTrace,
        source: 'ScreenshotDialog.save',
      );
    } finally {
      _close();
    }
  }

  void _reportWarning(String message, Object error, StackTrace stackTrace) =>
      AppErrorReporter.reportWarning(
        message,
        error: error,
        stackTrace: stackTrace,
        source: 'ScreenshotDialog.save',
        promptUser: true,
      );

  /// Closes this dialog's own route, even when another dialog has opened
  /// above it meanwhile, as the debug log (F12) does.
  void _close() {
    if (_closed || !mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    _closed = true;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final transparent = ref.watch(appPreferencesProvider
        .select((value) => value.transparentScreenshotBackground));
    final dotOpacity = ref.watch(
        appPreferencesProvider.select((value) => value.backgroundDotOpacity));
    final saving = _saving != null;
    final count = _selected.length;

    final title = switch ((saving, count > 1)) {
      (true, true) => 'Saving screenshots',
      (true, false) => 'Saving screenshot',
      (false, _) when _single => 'Save screenshot',
      _ => 'Save screenshots',
    };

    final columns = _pages.length <= 4 ? 2 : 3;
    final tileWidth = _single
        ? _singleWidth
        : (_gridWidth - _gap * (columns - 1)) / columns;
    final tiles = [
      for (final (index, page) in _pages.indexed)
        SizedBox(
          width: tileWidth,
          child: _PageTile(
            name: page.name,
            number: _single ? null : index + 1,
            thumbnail: _thumbnails[page.id],
            unavailable: _unavailable.contains(page.id),
            transparent: transparent,
            dotOpacity: dotOpacity,
            selected: _single || _selected.contains(page.id),
            showCheckbox: !_single && !saving,
            status: _statusOf(page.id),
            onTap: _single || saving ? null : () => _toggle(page.id),
          ),
        ),
    ];

    final transparentToggle = ShadCheckbox(
      value: transparent,
      enabled: !saving,
      onChanged: (value) => ref
          .read(appPreferencesProvider.notifier)
          .setTransparentScreenshotBackground(value),
      label: const Text('Transparent background'),
    );
    final cancel = ShadButton.secondary(
      onPressed: () => Navigator.of(context).maybePop(),
      child: const Text('Cancel'),
    );
    final save = ShadButton(
      autofocus: true,
      enabled: count > 0,
      onPressed: _save,
      leading: const Icon(LucideIcons.camera, size: 16),
      child: Text(count > 1 ? 'Save $count screenshots' : 'Save screenshot'),
    );

    final Widget footer;
    if (saving) {
      final total = _saving!.length;
      footer = Row(
        children: [
          Expanded(
            child: ShadProgress(
              value: _stoppable || _captured == total ? _captured / total : null,
              minHeight: 8,
            ),
          ),
          if (_stoppable && _captured < total) ...[
            const SizedBox(width: 16),
            ShadButton.destructive(
              onPressed: _stopping ? null : () => setState(() => _stopping = true),
              child: Text(_stopping ? 'Stopping…' : 'Stop'),
            ),
          ],
        ],
      );
    } else if (_single) {
      footer = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          transparentToggle,
          const SizedBox(height: 20),
          Row(
            children: [
              cancel,
              const SizedBox(width: 8),
              Expanded(child: save),
            ],
          ),
        ],
      );
    } else {
      footer = Row(
        children: [
          Expanded(child: transparentToggle),
          const SizedBox(width: 16),
          cancel,
          const SizedBox(width: 8),
          save,
        ],
      );
    }

    // A tile row is its thumbnail, the gap, and its label.
    final rowHeight = tileWidth * 9 / 16 + 8 + 20;
    return PopScope(
      canPop: !saving,
      child: ShadDialog(
        constraints: BoxConstraints(
          maxWidth: (_single ? _singleWidth : _gridWidth) + 48,
        ),
        closeIcon: saving ? const SizedBox.shrink() : null,
        title: Row(
          children: [
            Expanded(child: Text(title)),
            if (!_single && !saving)
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: _toggleAll,
                child: Text(_allSelected ? 'Clear all' : 'Select all'),
              ),
            // Clear of the close button in the corner.
            const SizedBox(width: 16),
          ],
        ),
        // The tiles' hover and the checkboxes' ink need a Material.
        child: Material(
          color: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  // Three rows show; more scroll.
                  constraints: BoxConstraints(
                    maxHeight: rowHeight * 3 + 16 * 2,
                  ),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: _gap,
                      runSpacing: 16,
                      children: tiles,
                    ),
                  ),
                ),
                SizedBox(height: saving ? 24 : 20),
                DefaultTextStyle.merge(
                  style: TextStyle(color: theme.colorScheme.foreground),
                  child: footer,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// What a tile says while the save runs: captured, capturing, or nothing
  /// for a page waiting its turn or left out.
  String? _statusOf(String pageId) {
    final order = _saving;
    if (order == null) return null;
    final index = order.indexOf(pageId);
    if (index < 0) return null;
    if (index < _captured) return 'Captured';
    if (index == _captured) return _stopping ? 'Stopping' : 'Capturing';
    return null;
  }
}

/// One page in the screenshot dialog: its thumbnail over the background it
/// will save with, a checkbox to tick it, and its number and name.
class _PageTile extends StatefulWidget {
  const _PageTile({
    required this.name,
    required this.number,
    required this.thumbnail,
    required this.unavailable,
    required this.transparent,
    required this.dotOpacity,
    required this.selected,
    required this.showCheckbox,
    required this.status,
    required this.onTap,
  });

  final String name;

  /// Null when the strategy has only this page.
  final int? number;
  final ui.Image? thumbnail;

  /// The page could not be drawn; it can still be saved, which says why if
  /// it fails again.
  final bool unavailable;
  final bool transparent;
  final double dotOpacity;
  final bool selected;
  final bool showCheckbox;
  final String? status;
  final VoidCallback? onTap;

  @override
  State<_PageTile> createState() => _PageTileState();
}

class _PageTileState extends State<_PageTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final thumbnail = widget.thumbnail;
    final borderColor = widget.selected && widget.number != null
        ? colors.primary
        : _hovered && widget.onTap != null
            ? colors.input
            : colors.border;

    final picture = Stack(
      fit: StackFit.expand,
      children: [
        if (widget.transparent)
          const CustomPaint(painter: _CheckerPainter())
        else
          FittedBox(
            fit: BoxFit.fill,
            child: SizedBox.fromSize(
              size: CoordinateSystem.screenShotSize,
              child: ScreenshotBackdrop(dotOpacity: widget.dotOpacity),
            ),
          ),
        if (thumbnail != null)
          RawImage(image: thumbnail, fit: BoxFit.fill)
        else if (widget.unavailable)
          Center(
            child: Icon(
              LucideIcons.imageOff,
              size: 18,
              color: colors.mutedForeground,
            ),
          )
        else
          Center(
            child: SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                valueColor: AlwaysStoppedAnimation(colors.mutedForeground),
              ),
            ),
          ),
      ],
    );

    final status = widget.status;
    final tile = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // A page left out sits back.
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 150),
                    opacity: widget.selected ? 1 : 0.55,
                    child: picture,
                  ),
                  if (widget.showCheckbox)
                    Positioned(
                      left: 10,
                      top: 10,
                      child: ShadCheckbox(
                        value: widget.selected,
                        onChanged: (_) => widget.onTap?.call(),
                      ),
                    ),
                  if (status != null)
                    Positioned(
                      left: 10,
                      top: 10,
                      child: _StatusChip(
                        text: status,
                        done: status == 'Captured',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (widget.number case final number?) ...[
              SizedBox(
                width: 14,
                child: Text(
                  '$number',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.mutedForeground,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: widget.selected
                      ? colors.foreground
                      : colors.mutedForeground,
                ),
              ),
            ),
          ],
        ),
      ],
    );

    if (widget.onTap == null) return tile;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: tile,
      ),
    );
  }
}

/// Where a page is in a save: captured, or being captured now.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, required this.done});

  final String text;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final ink = done ? colors.mutedForeground : colors.foreground;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (done)
            Icon(LucideIcons.check, size: 12, color: ink)
          else
            SizedBox.square(
              dimension: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                valueColor: AlwaysStoppedAnimation(ink),
              ),
            ),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, color: ink)),
        ],
      ),
    );
  }
}

/// The checkerboard a see-through screenshot is previewed on.
class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  static const double _square = 8;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Settings.transparencyCheckerDark,
    );
    final light = Paint()..color = Settings.transparencyCheckerLight;
    for (var y = 0.0; y < size.height; y += _square) {
      final odd = (y / _square).round().isOdd;
      for (var x = odd ? _square : 0.0; x < size.width; x += _square * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, _square, _square), light);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter oldDelegate) => false;
}
