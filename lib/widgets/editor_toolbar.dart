import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/screenshot/capture_geometry.dart';
import 'package:icarus/screenshot/offscreen_capture.dart';
import 'package:icarus/screenshot/persistent_offscreen_renderer.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:icarus/widgets/dialogs/export_video_dialog.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:icarus/widgets/strategy_save_icon_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Geometry shared by every control in the editor's floating toolbar, so the
/// save button matches its neighbours exactly.
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

  @override
  Widget build(BuildContext context) {
    const style = kEditorToolbarButtonStyle;

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
              EditorToolbarButton(
                style: style,
                tooltip: 'Screenshot',
                onPressed: _captureScreenshot,
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

  void _showDesktopOnlyToast() {
    Settings.showToast(
      message: 'This feature is only supported in the Windows version.',
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }

  Future<void> _exportStrategy() async {
    if (kIsWeb) {
      _showDesktopOnlyToast();
      return;
    }

    await ref
        .read(strategyProvider.notifier)
        .exportFile(ref.read(strategyProvider).id);
  }

  void _exportVideo() {
    if (kIsWeb) {
      _showDesktopOnlyToast();
      return;
    }
    showShadDialog(
      context: context,
      builder: (context) => const ExportVideoDialog(),
    );
  }

  Future<void> _captureScreenshot() async {
    if (kIsWeb) {
      _showDesktopOnlyToast();
      return;
    }
    if (_isCapturingScreenshot) return;
    setState(() => _isCapturingScreenshot = true);
    ProviderContainer? screenshotContainer;
    CaptureGeometryLease? captureGeometry;
    try {
      final String id = ref.read(strategyProvider).id;

      await ref.read(strategyProvider.notifier).forceSaveNow(id);
      if (!mounted) return;

      final newStrat = Hive.box<StrategyData>(
        HiveBoxNames.strategiesBox,
      ).values.where((StrategyData strategy) => strategy.id == id).firstOrNull;
      if (newStrat == null) return;

      final currentPageID = ref.read(strategyProvider.notifier).activePageID;
      final mapState = ref.read(mapProvider);
      if (currentPageID == null) return;

      final activePage = newStrat.pages.firstWhere(
        (p) => p.id == currentPageID,
        orElse: () => newStrat.pages.first,
      );
      final captureContainer = ProviderContainer();
      screenshotContainer = captureContainer;

      final screenshotView = ScreenshotView(
        isAttack: activePage.isAttack,
        mapValue: newStrat.mapData,
        showSpawnBarrier: mapState.showSpawnBarrier,
        showRegionNames: mapState.showRegionNames,
        showUltOrbs: mapState.showUltOrbs,
        agents: activePage.agentData,
        abilities: activePage.abilityData,
        text: activePage.textData,
        images: activePage.imageData,
        drawings: activePage.drawingData,
        utilities: activePage.utilityData,
        strategySettings: activePage.settings,
        strategyState: ref.read(strategyProvider),
        pageName: activePage.name,
        lineUpGraph: activePage.lineUpGraph,
        themeProfileId: newStrat.themeProfileId,
        themeOverridePalette: newStrat.themeOverridePalette,
      );
      // The sightline models load asynchronously; the capture waits for the
      // page's geometry before the first frame is taken.
      captureGeometry = await prepareCaptureGeometry(
        captureContainer,
        newStrat.mapData,
        [activePage],
      );
      late Uint8List image;
      try {
        image = await withScreenshotCoordinates(() async {
          screenshotView.hydrateProviders(captureContainer);
          final renderer = PersistentOffscreenRenderer(
              targetSize: CoordinateSystem.screenShotSize,
              waitForFrameData: captureGeometry?.waitForFrame,
              wrapWidget: (child) => wrapForOffscreenCapture(child,
                  container: captureContainer));
          try {
            await renderer.prepare(screenshotView,
                settleDuration: const Duration(milliseconds: 800));
            return await renderer.capture(screenshotView);
          } finally {
            await renderer.dispose();
          }
        });
      } finally {
        if (mounted) {
          ref.read(screenshotProvider.notifier).setIsScreenShot(false);
          ref
              .read(drawingProvider.notifier)
              .rebuildAllPaths(CoordinateSystem.instance);
        }
      }
      if (!mounted) return;
      setState(() => _isCapturingScreenshot = false);
      String? outputFile = await FilePicker.platform.saveFile(
        type: FileType.custom,
        dialogTitle: 'Please select an output file:',
        fileName: "${ref.read(strategyProvider).stratName ?? "new image"}.png",
        allowedExtensions: ['png'],
      );
      if (outputFile != null) {
        final file = File(outputFile);
        await file.writeAsBytes(image);
      }
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Could not export the screenshot. Please try again.',
        error: error,
        stackTrace: stackTrace,
        source: 'EditorToolbar.screenshot',
      );
    } finally {
      captureGeometry?.close();
      screenshotContainer?.dispose();
      if (mounted && _isCapturingScreenshot) {
        setState(() => _isCapturingScreenshot = false);
      }
    }
  }
}

/// One control in the editor toolbar. Glyphs are the 200 stroke weight: the
/// default 2px Lucide stroke reads heavy in white at 18px, and muted grey
/// vanishes against the card, so the weight carries the quietness instead. [icon] is any 18px glyph, so buttons can swap
/// in a spinner without changing size.
class EditorToolbarButton extends StatelessWidget {
  const EditorToolbarButton({
    super.key,
    required this.style,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.enabled = true,
    this.active = false,
    this.foregroundColor,
    this.semanticsLabel,
  });

  final EditorToolbarButtonStyle style;
  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool enabled;
  final bool active;

  /// Overrides the resting color, e.g. destructive for a problem.
  final Color? foregroundColor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final hasShadTheme = ShadTheme.maybeOf(context) != null;
    final resting = active
        ? theme.primaryForeground
        : foregroundColor ?? Settings.toolbarGlyph;
    final iconButton = hasShadTheme
        ? ShadIconButton.ghost(
            width: style.size,
            height: style.size,
            enabled: enabled,
            foregroundColor: resting,
            hoverForegroundColor: foregroundColor ?? theme.foreground,
            hoverBackgroundColor: theme.accent,
            onPressed: onPressed,
            icon: icon,
          )
        : IconButton(
            onPressed: enabled ? onPressed : null,
            icon: icon,
            color: resting,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(
              width: style.size,
              height: style.size,
            ),
            tooltip: tooltip,
          );
    final button = IconTheme(
      data: IconThemeData(size: style.iconSize, color: resting),
      child: iconButton,
    );
    return Semantics(
      label: semanticsLabel ?? tooltip,
      button: true,
      enabled: enabled,
      onTap: enabled ? onPressed : null,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: active ? Settings.raisedPrimary(8) : const BoxDecoration(),
        child: hasShadTheme
            ? ShadTooltip(
                builder: (context) => Text(tooltip),
                child: button,
              )
            : button,
      ),
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
