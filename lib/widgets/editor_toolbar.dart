import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/screenshot/page_screenshot.dart';
import 'package:icarus/screenshot/save_screenshots.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/cloud_strategy_export.dart';
import 'package:icarus/services/video_export/video_export_errors.dart';
import 'package:icarus/services/video_export/video_export_source.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/cloud_sync_button.dart';
import 'package:icarus/widgets/dialogs/auth/auth_dialog.dart';
import 'package:icarus/widgets/dialogs/export_video_dialog.dart';
import 'package:icarus/widgets/dialogs/screenshot_progress_dialog.dart';
import 'package:icarus/widgets/page_choice_list.dart';
import 'package:icarus/widgets/platform_feature_toast.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:icarus/widgets/strategy_save_icon_button.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

/// Geometry shared by every control in the editor's floating toolbar, so the
/// save button (which swaps between local and cloud variants) matches its
/// neighbours exactly.
class EditorToolbarButtonStyle {
  const EditorToolbarButtonStyle({this.size = 32, this.iconSize = 18});

  final double size;
  final double iconSize;
}

const EditorToolbarButtonStyle kEditorToolbarButtonStyle =
    EditorToolbarButtonStyle();

/// The document actions of the open strategy, docked at the top-left of the
/// canvas as one card: save, export, video, screenshot, then settings.
class EditorToolbar extends ConsumerStatefulWidget {
  const EditorToolbar({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _EditorToolbarState();
}

class _EditorToolbarState extends ConsumerState<EditorToolbar> {
  bool _isCapturingScreenshot = false;

  /// From the click until the PNG is saved or the save dialog closes: a
  /// second click meanwhile would capture again and open a second dialog.
  bool _screenshotInProgress = false;

  final ShadPopoverController _screenshotPopover = ShadPopoverController();

  @override
  void dispose() {
    _screenshotPopover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const style = kEditorToolbarButtonStyle;
    final source = ref.watch(strategyProvider.select((value) => value.source));
    final isCloud = source == StrategySource.cloud;
    final strategyId =
        ref.watch(strategyProvider.select((value) => value.strategyId));
    // Read through a share link the reader hasn't added: nothing here saves.
    // Signed out, the button signs in; signed in, it adds the strategy.
    final viewingThroughLink = isCloud &&
        ref.watch(shareLinkViewProvider)?.strategyPublicId == strategyId;
    // Asked only for a link view: the editor has no other use for it.
    final signedIn = viewingThroughLink &&
        ref.watch(authProvider.select((auth) => auth.isAuthenticated));
    // Local saving exists only where the local library does; the web beta
    // never offers it, even if an editor somehow opens with no cloud strategy.
    final allowsLocalSave =
        ref.watch(platformPolicyProvider).allowsLocalLibrary;

    // The strategy view owns the spacing around this card, so it aligns
    // with the map card above it.
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Settings.tacticalVioletTheme.card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Settings.tacticalVioletTheme.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (viewingThroughLink && !signedIn)
                EditorToolbarButton(
                  style: style,
                  tooltip: 'View only · Sign in to add it to your library',
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const AuthDialog(),
                  ),
                  icon: const Icon(LucideIcons.logIn200),
                )
              else if (viewingThroughLink)
                EditorToolbarButton(
                  key: const ValueKey('editor-add-to-library'),
                  style: style,
                  tooltip: 'View only · Add to my library',
                  onPressed: () => ref
                      .read(shareLinkControllerProvider.notifier)
                      .addViewedLinkToLibrary(),
                  icon: const Icon(LucideIcons.bookmarkPlus200),
                )
              else if (isCloud)
                const CloudSyncButton(style: style)
              else if (allowsLocalSave)
                const AutoSaveButton(style: style),
              EditorToolbarButton(
                style: style,
                tooltip: 'Export .ica',
                onPressed: _exportStrategy,
                icon: const Icon(LucideIcons.upload200),
              ),
              EditorToolbarButton(
                style: style,
                tooltip: 'Export video',
                onPressed: _exportVideo,
                icon: const Icon(LucideIcons.clapperboard200),
              ),
              ShadPopover(
                controller: _screenshotPopover,
                padding: const EdgeInsets.all(14),
                anchor: const ShadAnchor(
                  offset: Offset(0, 8),
                  childAlignment: Alignment.topLeft,
                  overlayAlignment: Alignment.bottomLeft,
                ),
                popover: (context) => _ScreenshotPopover(
                  onSave: (pageIds) {
                    _screenshotPopover.hide();
                    final current =
                        ref.read(strategyPageSessionProvider).activePageId;
                    if (pageIds.length == 1 && pageIds.single == current) {
                      _captureScreenshot();
                    } else {
                      _captureScreenshots(pageIds);
                    }
                  },
                ),
                child: EditorToolbarButton(
                  style: style,
                  tooltip: 'Screenshot',
                  onPressed: _openScreenshotPopover,
                  icon: _isCapturingScreenshot
                      ? SizedBox(
                          width: style.iconSize - 2,
                          height: style.iconSize - 2,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Settings.tacticalVioletTheme.mutedForeground,
                            ),
                          ),
                        )
                      : const Icon(LucideIcons.camera200),
                ),
              ),
              const EditorToolbarDivider(),
              EditorToolbarButton(
                style: style,
                tooltip: 'Settings',
                onPressed: () {
                  showShadDialog(
                    context: context,
                    builder: (context) => const SettingsTab(),
                  );
                },
                icon: const Icon(LucideIcons.settings200),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _exportStrategy() async {
    if (!ensureFeatureAvailable(ref, PlatformFeature.exportFiles)) return;

    final strategy = ref.read(strategyProvider);
    final strategyId = strategy.strategyId;
    if (strategyId == null || strategy.source == null) {
      throw StateError('No strategy is open for export.');
    }

    final exporter = StrategyImportExportService(ref);
    switch (strategy.source!) {
      case StrategySource.cloud:
        await runCloudStrategyExport(ref, strategyId);
      case StrategySource.local:
        await exporter.exportFile(strategyId);
    }
  }

  void _exportVideo() {
    if (!ensureFeatureAvailable(ref, PlatformFeature.videoExport)) return;
    showShadDialog(
      context: context,
      builder: (context) => const ExportVideoDialog(),
    );
  }

  /// The camera asks how to take the shot, with the last answer ticked.
  void _openScreenshotPopover() {
    if (!ensureFeatureAvailable(ref, PlatformFeature.screenshot)) return;
    if (_screenshotInProgress) return;
    _screenshotPopover.toggle();
  }

  /// Captures [pageIds] from the strategy as saved. One page saves like the
  /// open page's shot does; several go into a folder the user picks
  /// (desktop) or one .zip download (the browser).
  Future<void> _captureScreenshots(Set<String> pageIds) async {
    if (_screenshotInProgress) return;
    final strategy = ref.read(strategyProvider);
    if (strategy.strategyId == null) return;
    final strategyName = strategy.strategyName ?? 'new image';
    _screenshotInProgress = true;
    try {
      // Where several go is settled first, so a dismissed dialog costs
      // nothing.
      String? folder;
      if (pageIds.length > 1 && !kIsWeb) {
        folder = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Choose a folder for the screenshots',
        );
        if (folder == null || !mounted) return;
      }
      setState(() => _isCapturingScreenshot = true);
      // Modal while it runs: the capture borrows the app's coordinates.
      final progress = ValueNotifier<ScreenshotProgress?>(null);
      var cancelled = false;
      final navigator = Navigator.of(context, rootNavigator: true);
      var dialogOpen = true;
      final dialogClosed = showShadDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ScreenshotProgressDialog(
          progress: progress,
          onCancel: () => cancelled = true,
        ),
      );
      // Closing the dialog any other way (its X, Escape) cancels too, and
      // leaves nothing for the cleanup below to pop.
      unawaited(dialogClosed.whenComplete(() {
        dialogOpen = false;
        cancelled = true;
      }));
      late final List<PageScreenshot> shots;
      try {
        shots = await captureStrategyPages(
          ref,
          pageIds: pageIds,
          transparentBackground:
              ref.read(appPreferencesProvider).transparentScreenshotBackground,
          onPage: (page, total) => progress.value = (page: page, total: total),
          isCancelled: () => cancelled,
        );
      } finally {
        if (dialogOpen) navigator.pop();
        unawaited(dialogClosed.whenComplete(progress.dispose));
        if (mounted) {
          ref.read(screenshotProvider.notifier).setIsScreenShot(false);
          ref
              .read(drawingProvider.notifier)
              .rebuildAllPaths(CoordinateSystem.instance);
          setState(() => _isCapturingScreenshot = false);
        }
      }
      if (!mounted) return;
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
      _reportCaptureWarning(error.userMessage, error, stackTrace);
    } on VideoExportPagesChanged catch (error, stackTrace) {
      _reportCaptureWarning(error.userMessage, error, stackTrace);
    } on CaptureImagesUnavailable catch (error, stackTrace) {
      _reportCaptureWarning(error.userMessage, error, stackTrace);
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Could not export the screenshots. Please try again.',
        error: error,
        stackTrace: stackTrace,
        source: 'EditorToolbar.screenshot',
      );
    } finally {
      _screenshotInProgress = false;
    }
  }

  void _reportCaptureWarning(
    String message,
    Object error,
    StackTrace stackTrace,
  ) =>
      AppErrorReporter.reportWarning(
        message,
        error: error,
        stackTrace: stackTrace,
        source: 'EditorToolbar.screenshot',
        promptUser: true,
      );

  Future<void> _captureScreenshot() async {
    if (!ensureFeatureAvailable(ref, PlatformFeature.screenshot)) return;
    if (_screenshotInProgress) return;
    final strategy = ref.read(strategyProvider);
    if (strategy.strategyId == null) return;
    _screenshotInProgress = true;
    setState(() => _isCapturingScreenshot = true);
    try {
      late final Uint8List image;
      try {
        image = await captureEditorPage(ref);
      } finally {
        if (mounted) setState(() => _isCapturingScreenshot = false);
      }
      if (!mounted) return;
      // Desktop asks where to save and writes the bytes there; the browser
      // downloads them.
      await FilePicker.platform.saveFile(
        type: FileType.custom,
        dialogTitle: 'Please select an output file:',
        fileName:
            '${sanitizeStrategyFileName(strategy.strategyName ?? 'new image')}.png',
        allowedExtensions: ['png'],
        bytes: image,
      );
    } on CaptureImagesUnavailable catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        error.userMessage,
        error: error,
        stackTrace: stackTrace,
        source: 'EditorToolbar.screenshot',
        promptUser: true,
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Could not export the screenshot. Please try again.',
        error: error,
        stackTrace: stackTrace,
        source: 'EditorToolbar.screenshot',
      );
    } finally {
      _screenshotInProgress = false;
    }
  }
}

/// What the camera asks before a screenshot: which pages, and whether to
/// leave the background out. The page on the canvas starts ticked, so the
/// usual shot is one more click; the background choice is remembered.
class _ScreenshotPopover extends ConsumerStatefulWidget {
  const _ScreenshotPopover({required this.onSave});

  /// Called with the pages to capture, in no particular order.
  final ValueChanged<Set<String>> onSave;

  @override
  ConsumerState<_ScreenshotPopover> createState() => _ScreenshotPopoverState();
}

class _ScreenshotPopoverState extends ConsumerState<_ScreenshotPopover> {
  late final List<VideoExportPageChoice> _pages;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _pages = videoExportPageChoices(ref);
    final current = ref.read(strategyPageSessionProvider).activePageId;
    if (current != null) _selected.add(current);
  }

  void _toggle(String pageId) => setState(() {
        if (!_selected.remove(pageId)) _selected.add(pageId);
      });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final transparent = ref.watch(appPreferencesProvider
        .select((value) => value.transparentScreenshotBackground));
    void setTransparent(bool value) => ref
        .read(appPreferencesProvider.notifier)
        .setTransparentScreenshotBackground(value);
    final allSelected = _selected.length == _pages.length;
    final count = _selected.length;

    // Text alignment is inherited from the editor, which centers, so pin it
    // here; the column's own alignment does not reach inside the Texts.
    return DefaultTextStyle.merge(
      textAlign: TextAlign.start,
      child: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_pages.length > 1) ...[
              Row(
                children: [
                  Text(
                    'Pages',
                    style: theme.textTheme.small.copyWith(
                      color: theme.colorScheme.foreground,
                    ),
                  ),
                  const Spacer(),
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: () => setState(() {
                      if (allSelected) {
                        _selected.clear();
                      } else {
                        _selected.addAll(_pages.map((page) => page.id));
                      }
                    }),
                    child: Text(allSelected ? 'Clear all' : 'Select all'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // The list's rows are InkWells; the popover has no Material.
              Material(
                color: Colors.transparent,
                child: PageChoiceList(
                  pages: _pages,
                  selectedPageIds: _selected,
                  onToggle: _toggle,
                  maxHeight: 180,
                ),
              ),
              const SizedBox(height: 12),
            ],
            ShadCheckbox(
              value: transparent,
              onChanged: setTransparent,
              label: const Text('Transparent background'),
              sublabel: const Text(
                'Leave out the background and dots, so the PNG is '
                'see-through around the map.',
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: ShadButton(
                size: ShadButtonSize.sm,
                autofocus: true,
                enabled: count > 0,
                onPressed: () => widget.onSave({..._selected}),
                leading: const Icon(LucideIcons.camera, size: 16),
                child: Text(
                  count > 1 ? 'Save $count screenshots' : 'Save screenshot',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One control in the editor toolbar. Glyphs are the 200 stroke weight and
/// rest in [Settings.toolbarGlyph]: the default 2px Lucide stroke reads heavy
/// at 18px, and full white on top of it shouts, so the weight and a step of
/// grey share the quietness. Hover brings the glyph up to foreground. [icon]
/// is any 18px glyph, so buttons can swap in a spinner without changing size.
class EditorToolbarButton extends StatelessWidget {
  // The ghost icon button's own corner radius (the theme default).
  static const double _buttonRadius = 6;

  const EditorToolbarButton({
    super.key,
    required this.style,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.enabled = true,
    this.active = false,
    this.showTooltip = true,
    this.foregroundColor,
    this.semanticsLabel,
  });

  final EditorToolbarButtonStyle style;
  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool enabled;
  final bool active;

  /// False where a bubble would cover the work, like the text format bar.
  /// [tooltip] still labels the button for screen readers.
  final bool showTooltip;

  /// Overrides the resting color, e.g. destructive for a sync problem.
  final Color? foregroundColor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    // An active toggle is a checked tool: a raised violet surface under a
    // white glyph. Violet on the glyph itself is unreadable at this stroke.
    final resting = active
        ? theme.primaryForeground
        : foregroundColor ?? Settings.toolbarGlyph;
    Widget button = ShadIconButton.ghost(
      width: style.size,
      height: style.size,
      enabled: enabled,
      foregroundColor: resting,
      hoverForegroundColor:
          active ? resting : foregroundColor ?? theme.foreground,
      hoverBackgroundColor: active ? Colors.transparent : theme.accent,
      onPressed: onPressed,
      icon: icon,
    );
    if (active) {
      button = DecoratedBox(
        decoration: Settings.raisedPrimary(_buttonRadius),
        child: button,
      );
    }
    button = IconTheme(
      data: IconThemeData(size: style.iconSize, color: resting),
      child: button,
    );
    return Semantics(
      label: semanticsLabel ?? tooltip,
      button: true,
      enabled: enabled,
      onTap: enabled ? onPressed : null,
      excludeSemantics: true,
      child: showTooltip
          ? ShadTooltip(builder: (context) => Text(tooltip), child: button)
          : button,
    );
  }
}

/// A 1px hairline between groups of toolbar controls.
class EditorToolbarDivider extends StatelessWidget {
  const EditorToolbarDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Settings.tacticalVioletTheme.border,
    );
  }
}
