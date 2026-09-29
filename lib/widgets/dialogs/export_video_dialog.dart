import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';
import 'package:icarus/services/analytics_service.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/services/video_export/browser_video_sink.dart';
import 'package:icarus/services/video_export/ffmpeg_video_encoder.dart';
import 'package:icarus/services/video_export/ffmpeg_video_sink.dart';
import 'package:icarus/services/video_export/video_export_source.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/services/video_export/video_exporter.dart';
import 'package:icarus/services/video_export/video_frame_sink.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Settings + progress dialog for exporting the strategy's pages as an .mp4
/// (ADR 0003): checkbox page selection, one global step duration.
class ExportVideoDialog extends ConsumerStatefulWidget {
  const ExportVideoDialog({super.key});

  @override
  ConsumerState<ExportVideoDialog> createState() => _ExportVideoDialogState();
}

class _ExportVideoDialogState extends ConsumerState<ExportVideoDialog> {
  static const double _dialogWidth = 640;

  /// ShadDialog shrink-wraps its content to intrinsic widths, which cannot
  /// lay out Expanded/Spacer rows or the slider; a tight width fixes every
  /// descendant (same idiom as UploadImageDialog).
  static const double _contentWidth = _dialogWidth - 48;

  List<VideoExportPageChoice> _pages = const [];
  final Set<String> _selectedPageIds = {};
  double _stepDurationSeconds = 3.0;
  VideoExportQuality _quality = VideoExportQuality.social;

  /// Saving, syncing, and loading images, before any frame renders.
  bool _preparing = false;
  bool _cancelRequested = false;
  VideoExporter? _exporter;
  double _progress = 0;
  String _progressLabel = '';
  bool _exportRunning = false;
  bool get _isExporting => _preparing || _exporter != null;

  @override
  void dispose() {
    // Closing the dialog mid-export must not leave frames rendering and
    // the encoder running in the background.
    _cancel();
    super.dispose();
  }

  void _cancel() {
    _cancelRequested = true;
    _exporter?.cancel();
  }

  @override
  void initState() {
    super.initState();
    _stepDurationSeconds = ref
        .read(appPreferencesProvider)
        .videoExportStepDurationSeconds
        .clamp(1.0, 15.0);
    _pages = videoExportPageChoices(ref);
    _selectedPageIds.addAll(_pages.map((p) => p.id));
  }

  Future<void> _export() async {
    // The Export button stays enabled while the file picker is open; a
    // second tap must not start a second export.
    if (_exportRunning || !_canExport) return;
    _exportRunning = true;
    try {
      await _runExport();
    } finally {
      _exportRunning = false;
    }
  }

  Future<void> _runExport() async {
    // The root container outlives this dialog, so cleanup after a
    // mid-export dismissal can still reach the live providers.
    final container = ProviderScope.containerOf(context, listen: false);
    final quality = _quality;
    final pageIds = {..._selectedPageIds};
    final stepDuration = Duration(
      milliseconds: (_stepDurationSeconds * 1000).round(),
    );
    unawaited(
      ref
          .read(appPreferencesProvider.notifier)
          .setVideoExportStepDurationSeconds(_stepDurationSeconds),
    );
    final fileName =
        "${sanitizeStrategyFileName(ref.read(strategyProvider).stratName ?? "new video")}.mp4";

    // Where the video goes is settled first, so a dismissed save dialog or
    // a browser that cannot encode video costs nothing.
    final VideoFrameSink sink;
    if (kIsWeb) {
      if (!await browserCanEncodeVideo(quality)) {
        Settings.showToast(
          message: 'This browser cannot export video. Try the latest Chrome '
              'or Edge, or the desktop app.',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        return;
      }
      sink = createBrowserVideoSink(quality);
    } else {
      final ffmpegBinary = await FfmpegVideoEncoder.resolveBinary();
      if (ffmpegBinary == null) {
        Settings.showToast(
          message:
              'Video encoder not found. Reinstalling Icarus should fix this.',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        return;
      }
      final selectedOutputPath = await FilePicker.platform.saveFile(
        type: FileType.custom,
        dialogTitle: 'Please select an output file:',
        fileName: fileName,
        allowedExtensions: ['mp4'],
      );
      if (selectedOutputPath == null) return;
      sink = FfmpegVideoSink(
        binary: ffmpegBinary,
        outputPath: ensureMp4Extension(selectedOutputPath),
        quality: quality,
      );
    }
    if (!mounted) return;

    setState(() {
      _preparing = true;
      _cancelRequested = false;
      _progress = 0;
      _progressLabel = 'Saving your changes';
    });
    CaptureImages? images;
    try {
      final source = await loadVideoExportSource(ref, pageIds: pageIds);
      images = source.images;
      if (_cancelRequested) throw VideoExportCancelled();
      final selectedPages = ([...source.strategy.pages]
            ..sortBySortIndex((item) => item.sortIndex))
          .where((p) => pageIds.contains(p.id))
          .toList();

      final mapState = ref.read(mapProvider);
      final requireNavigation =
          ref.read(worldGeometryEnabledProvider(mapState.currentMap));
      VisionGeometryMap? geometry;
      NavigationGeometryMap? navigation;
      try {
        if (requireNavigation) {
          navigation = await ref
              .read(navigationGeometryProvider(mapState.currentMap).future);
        } else {
          geometry = await ref
              .read(viewConeGeometryProvider(mapState.currentMap).future);
        }
      } on Object {
        // The provider reports the failure. The exporter rejects movement on
        // enabled maps when their required navigation data is unavailable.
      }
      if (_cancelRequested) throw VideoExportCancelled();

      final exporter = VideoExporter(
        strategy: source.strategy,
        strategyState: ref.read(strategyProvider),
        mapState: mapState,
        geometry: geometry,
        imageSources: images.sources,
        navigation: navigation,
        requireNavigation: requireNavigation,
      );
      setState(() {
        _exporter = exporter;
        _progressLabel = 'Preparing';
      });

      CoordinateSystem.instance.setIsScreenshot(true);
      final video = await exporter.export(
        pages: selectedPages,
        stepDuration: stepDuration,
        sink: sink,
        quality: quality,
        onProgress: (fraction, label) {
          if (!mounted) return;
          setState(() {
            _progress = fraction;
            _progressLabel = label;
          });
        },
      );
      // The browser sink hands the finished video back to be downloaded;
      // the desktop one has already written it where the user chose.
      if (video != null) {
        await FilePicker.platform.saveFile(
          type: FileType.custom,
          fileName: fileName,
          allowedExtensions: ['mp4'],
          bytes: video,
        );
      }
      unawaited(
        AnalyticsService.instance.capture(
          'content_exported',
          properties: {
            'content_type': 'video',
            'page_count': selectedPages.length,
            'step_duration_seconds': _stepDurationSeconds,
            'quality': quality.name,
            'fps': quality.fps,
          },
        ),
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
      Settings.showToast(
        message: 'Video exported.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
    } on VideoExportCancelled {
      Settings.showToast(
        message: 'Video export cancelled.',
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
    } on VideoExportNotSynced catch (error) {
      Settings.showToast(
        message: error.userMessage,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    } on CaptureImagesUnavailable catch (error) {
      Settings.showToast(
        message: error.userMessage,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    } on Object catch (error) {
      Settings.showToast(
        // Closing the dialog mid-preparation can fail the work it cut
        // short; the user asked to stop, so that is what they hear.
        message: _cancelRequested
            ? 'Video export cancelled.'
            : 'Video export failed: $error',
        backgroundColor: _cancelRequested
            ? Settings.tacticalVioletTheme.primary
            : Settings.tacticalVioletTheme.destructive,
      );
    } finally {
      await sink.close();
      images?.release();
      CoordinateSystem.instance.setIsScreenshot(false);
      container.read(screenshotProvider.notifier).setIsScreenShot(false);
      container
          .read(drawingProvider.notifier)
          .rebuildAllPaths(CoordinateSystem.instance);
      if (mounted) {
        setState(() {
          _preparing = false;
          _exporter = null;
        });
      }
    }
  }

  /// Estimated length of the exported video for the current selection:
  /// one step-duration hold per page plus a transition between each pair.
  double get _estimatedVideoSeconds {
    return VideoExporter.plannedDurationSeconds(
      pageCount: _selectedPageIds.length,
      stepSeconds: _stepDurationSeconds,
      fps: _quality.fps,
    );
  }

  bool get _canExport => _selectedPageIds.isNotEmpty;

  bool get _allPagesSelected => _selectedPageIds.length == _pages.length;

  static String _formatSeconds(double seconds) {
    final total = seconds.round();
    if (total < 60) return '${total}s';
    return '${total ~/ 60}m ${(total % 60).toString().padLeft(2, '0')}s';
  }

  void _togglePage(String pageId) {
    setState(() {
      if (!_selectedPageIds.remove(pageId)) {
        _selectedPageIds.add(pageId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isExporting) {
      return _buildProgressDialog(context);
    }
    return _buildSettingsDialog(context);
  }

  Widget _buildProgressDialog(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return ShadDialog(
      constraints: const BoxConstraints(maxWidth: _dialogWidth),
      title: const Text('Exporting video'),
      actions: [
        ShadButton.destructive(
          onPressed: _cancel,
          child: const Text('Cancel export'),
        ),
      ],
      child: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints.tightFor(width: _contentWidth),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(_progressLabel)),
                    Text(
                      '${(_progress * 100).round()}%',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.mutedForeground,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ShadProgress(value: _progress, minHeight: 8),
                // A hidden tab stops painting frames, which stalls the render.
                if (kIsWeb) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Keep this tab open until the video downloads.',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.mutedForeground,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsDialog(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final selectedCount = _selectedPageIds.length;
    final estimatedSeconds = selectedCount == 0 ? null : _estimatedVideoSeconds;

    return ShadDialog(
      constraints: const BoxConstraints(maxWidth: _dialogWidth),
      title: const Text('Export video'),
      description: const Text(
        'Plays the selected pages in order. Each step holds for the step '
        'duration, then transitions into the next.',
      ),
      child: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints.tightFor(width: _contentWidth),
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const _SectionLabel(text: 'Step duration'),
                    const Spacer(),
                    _ValueChip(text: '${_stepDurationSeconds.round()}s'),
                  ],
                ),
                const SizedBox(height: 12),
                ShadSlider(
                  initialValue: _stepDurationSeconds,
                  min: 1,
                  max: 15,
                  divisions: 14,
                  onChanged: (value) {
                    setState(() => _stepDurationSeconds = value);
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  'How long each step holds on screen before its transition '
                  'plays.',
                  style: TextStyle(
                    fontSize: 14,
                    color: colors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 24),
                const _SectionLabel(text: 'Quality'),
                const SizedBox(height: 10),
                // IntrinsicHeight bounds the stretch so all three cards share
                // the tallest card's height; without it the scrollable dialog
                // hands the Row an infinite height to stretch into.
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final quality in VideoExportQuality.values) ...[
                        if (quality != VideoExportQuality.values.first)
                          const SizedBox(width: 8),
                        Expanded(
                          child: _QualityCard(
                            quality: quality,
                            selected: _quality == quality,
                            onTap: () => setState(() => _quality = quality),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    const _SectionLabel(text: 'Pages'),
                    const SizedBox(width: 8),
                    Text(
                      '$selectedCount of ${_pages.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.mutedForeground,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const Spacer(),
                    ShadButton.ghost(
                      size: ShadButtonSize.sm,
                      onPressed: () {
                        setState(() {
                          if (_allPagesSelected) {
                            _selectedPageIds.clear();
                          } else {
                            _selectedPageIds.addAll(_pages.map((p) => p.id));
                          }
                        });
                      },
                      child:
                          Text(_allPagesSelected ? 'Clear all' : 'Select all'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _PagesPanel(
                  pages: _pages,
                  selectedPageIds: _selectedPageIds,
                  onToggle: _togglePage,
                ),
                const SizedBox(height: 20),
                // Summary shares the bottom row with the buttons, so the
                // dialog's own actions slot stays empty. Bottom-aligned so
                // the summary sits on the buttons' bottom line.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: _ExportSummary(
                        estimatedSeconds: estimatedSeconds,
                        outputHeight: estimatedSeconds == null
                            ? 1080
                            : _quality.outputHeightForDuration(
                                estimatedSeconds,
                              ),
                        formatSeconds: _formatSeconds,
                      ),
                    ),
                    const SizedBox(width: 16),
                    ShadButton.secondary(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ShadButton(
                      onPressed: _canExport ? _export : null,
                      child: const Text('Export'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Muted eyebrow that names a settings section.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(fontSize: 14, color: colors.foreground),
    );
  }
}

/// Raised readout for the slider's current value.
class _ValueChip extends StatelessWidget {
  const _ValueChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: colors.secondary,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _QualityCard extends StatelessWidget {
  const _QualityCard({
    required this.quality,
    required this.selected,
    required this.onTap,
  });

  final VideoExportQuality quality;
  final bool selected;
  final VoidCallback onTap;

  static const _icons = {
    VideoExportQuality.potato: LucideIcons.feather,
    VideoExportQuality.social: LucideIcons.share2,
    VideoExportQuality.max: LucideIcons.gem,
  };

  static const _titles = {
    VideoExportQuality.potato: 'Potato',
    VideoExportQuality.social: 'Social',
    VideoExportQuality.max: 'Max',
  };

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return InkWell(
      mouseCursor: SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        curve: Curves.easeOut,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? colors.primary : colors.border,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _icons[quality],
                  size: 15,
                  color: selected ? colors.primary : colors.mutedForeground,
                ),
                const SizedBox(width: 7),
                Text(
                  _titles[quality]!,
                  style: const TextStyle(fontSize: 15),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              videoExportQualityCaption(quality),
              style: TextStyle(
                fontSize: 12,
                color: colors.mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bordered list of the strategy's pages in playback order; whole rows toggle.
class _PagesPanel extends StatelessWidget {
  const _PagesPanel({
    required this.pages,
    required this.selectedPageIds,
    required this.onToggle,
  });

  final List<VideoExportPageChoice> pages;
  final Set<String> selectedPageIds;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 236),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (index, page) in pages.indexed) ...[
                if (index > 0) Container(height: 1, color: colors.border),
                InkWell(
                  mouseCursor: SystemMouseCursors.click,
                  onTap: () => onToggle(page.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        ShadCheckbox(
                          value: selectedPageIds.contains(page.id),
                          onChanged: (_) => onToggle(page.id),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 18,
                          child: Text(
                            '${index + 1}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.mutedForeground,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            page.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Live one-line receipt of what Export will produce.
class _ExportSummary extends StatelessWidget {
  const _ExportSummary({
    required this.estimatedSeconds,
    required this.outputHeight,
    required this.formatSeconds,
  });

  final double? estimatedSeconds;
  final int outputHeight;
  final String Function(double) formatSeconds;

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: colors.mutedForeground);

    return Row(
      children: [
        Icon(LucideIcons.film, size: 15, color: colors.mutedForeground),
        const SizedBox(width: 10),
        Expanded(
          child: estimatedSeconds == null
              ? Text('Select at least one page to export.', style: muted)
              : Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '~${formatSeconds(estimatedSeconds!)} video',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.foreground,
                        ),
                      ),
                      TextSpan(
                        text: ' · ${outputHeight}p',
                        style: muted,
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// The one fact that distinguishes each quality option; the summary line
/// carries the live resolution, including Potato's adaptive 720p drop.
String videoExportQualityCaption(VideoExportQuality quality) {
  return switch (quality) {
    VideoExportQuality.potato => '~10 MB',
    VideoExportQuality.social => '~20 MB',
    VideoExportQuality.max => '60 fps, no size cap',
  };
}
