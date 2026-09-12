import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/cloud_strategy_export.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/screenshot/offscreen_capture.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:icarus/widgets/cloud_sync_button.dart';
import 'package:icarus/widgets/dialogs/export_video_dialog.dart';
import 'package:icarus/widgets/settings_tab.dart';
import 'package:icarus/widgets/strategy_save_icon_button.dart';
import 'package:screenshot/screenshot.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Geometry shared by every control in the editor's floating toolbar, so the
/// save button (which swaps between local and cloud variants) matches its
/// neighbours exactly.
class EditorToolbarButtonStyle {
  const EditorToolbarButtonStyle({
    this.size = 32,
    this.iconSize = 18,
  });

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
    final source = ref.watch(strategyProvider.select((value) => value.source));
    final isCloud = source == StrategySource.cloud;

    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
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
                if (isCloud)
                  const CloudSyncButton(style: style)
                else
                  const AutoSaveButton(style: style),
                EditorToolbarButton(
                  style: style,
                  tooltip: 'Export .ica',
                  onPressed: _exportStrategy,
                  icon: const Icon(LucideIcons.upload),
                ),
                EditorToolbarButton(
                  style: style,
                  tooltip: 'Export video',
                  onPressed: _exportVideo,
                  icon: const Icon(LucideIcons.clapperboard),
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
                      : const Icon(LucideIcons.camera),
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
                  icon: const Icon(LucideIcons.settings),
                ),
              ],
            ),
          ),
          if (_isViewOnly()) ...[
            const SizedBox(width: 8),
            const _ViewOnlyChip(),
          ],
        ],
      ),
    );
  }

  void _showDesktopOnlyToast() {
    Settings.showToast(
      message: 'This feature is only supported in the desktop app.',
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
  }

  Future<void> _exportStrategy() async {
    if (kIsWeb) {
      _showDesktopOnlyToast();
      return;
    }

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
    CoordinateSystem.instance.setIsScreenshot(true);

    final String id = ref.read(strategyProvider).strategyId!;

    await ref.read(strategyProvider.notifier).forceSaveNow(id);

    final newStrat = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .where((StrategyData strategy) => strategy.id == id)
        .firstOrNull;

    if (newStrat == null) {
      if (mounted) setState(() => _isCapturingScreenshot = false);
      CoordinateSystem.instance.setIsScreenshot(false);
      return;
    }
    final newController = ScreenshotController();
    final mapState = ref.read(mapProvider);
    final currentPageID = ref.read(strategyPageSessionProvider).activePageId;

    if (currentPageID == null) {
      if (mounted) setState(() => _isCapturingScreenshot = false);
      CoordinateSystem.instance.setIsScreenshot(false);
      return;
    }

    final activePage = newStrat.pages.firstWhere(
      (p) => p.id == currentPageID,
      orElse: () => newStrat.pages.first,
    );
    final screenshotContainer = ProviderContainer();

    try {
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
        lineUpGroups: activePage.lineUpGroups,
        themeProfileId: newStrat.themeProfileId,
        themeOverridePalette: newStrat.themeOverridePalette,
      );
      screenshotView.hydrateProviders(screenshotContainer);
      final image = await newController.captureFromWidget(
        targetSize: CoordinateSystem.screenShotSize,
        wrapForOffscreenCapture(
          screenshotView,
          container: screenshotContainer,
        ),
      );
      if (mounted) setState(() => _isCapturingScreenshot = false);
      String? outputFile = await FilePicker.platform.saveFile(
        type: FileType.custom,
        dialogTitle: 'Please select an output file:',
        fileName:
            "${ref.read(strategyProvider).strategyName ?? "new image"}.png",
        allowedExtensions: ['png'],
      );
      if (outputFile != null) {
        final file = File(outputFile);
        await file.writeAsBytes(image);
      }
    } catch (_) {
    } finally {
      screenshotContainer.dispose();
      if (mounted && _isCapturingScreenshot) {
        setState(() => _isCapturingScreenshot = false);
      }
      ref.read(screenshotProvider.notifier).setIsScreenShot(false);
      CoordinateSystem.instance.setIsScreenshot(false);
      ref
          .read(drawingProvider.notifier)
          .rebuildAllPaths(CoordinateSystem.instance);
    }
  }

  bool _isViewOnly() {
    final source = ref.watch(strategyProvider.select((value) => value.source));
    if (source != StrategySource.cloud) {
      return false;
    }
    // Read the cached role rather than the raw snapshot so the chip does not
    // flicker off while the snapshot is reloading or transiently errored; it
    // is absent only before the role has ever been known.
    final role = ref.watch(lastKnownCloudRoleProvider);
    return role == 'viewer';
  }
}

/// One control in the editor toolbar: a ghost icon button in full foreground
/// (muted glyphs vanish against the card) with a tonal hover. [icon] is any 18px glyph, so buttons can swap
/// in a spinner without changing size.
class EditorToolbarButton extends StatelessWidget {
  const EditorToolbarButton({
    super.key,
    required this.style,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.enabled = true,
    this.foregroundColor,
    this.semanticsLabel,
  });

  final EditorToolbarButtonStyle style;
  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool enabled;

  /// Overrides the resting color, e.g. destructive for a sync problem.
  final Color? foregroundColor;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final resting = foregroundColor ?? theme.foreground;
    return Semantics(
      label: semanticsLabel ?? tooltip,
      button: true,
      enabled: enabled,
      onTap: enabled ? onPressed : null,
      excludeSemantics: true,
      child: ShadTooltip(
        builder: (context) => Text(tooltip),
        child: IconTheme(
          data: IconThemeData(size: style.iconSize, color: resting),
          child: ShadIconButton.ghost(
            width: style.size,
            height: style.size,
            enabled: enabled,
            foregroundColor: resting,
            hoverForegroundColor: foregroundColor ?? theme.foreground,
            hoverBackgroundColor: theme.accent,
            onPressed: onPressed,
            icon: icon,
          ),
        ),
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

/// Non-interactive chip shown beside the toolbar when the open cloud strategy
/// is shared with view-only access.
class _ViewOnlyChip extends StatelessWidget {
  const _ViewOnlyChip();

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;

    return ShadTooltip(
      builder: (context) => const Text(
        'You have view access. Ask the owner for edit access to make changes.',
      ),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: theme.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.eye, size: 14, color: theme.mutedForeground),
            const SizedBox(width: 6),
            Text(
              'View only',
              style: TextStyle(
                color: theme.mutedForeground,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
