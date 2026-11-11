import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';
import 'package:icarus/screenshot/caption_export_layout.dart';
import 'package:icarus/services/analytics_service.dart';
import 'package:icarus/services/export_save_path.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/screenshot/refused_captions_watch.dart';
import 'package:icarus/services/video_export/browser_video_sink.dart';
import 'package:icarus/services/video_export/ffmpeg_video_encoder.dart';
import 'package:icarus/services/video_export/ffmpeg_video_sink.dart';
import 'package:icarus/services/video_export/quicktime_animation_sink.dart';
import 'package:icarus/services/video_export/video_export_source.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/services/video_export/video_exporter.dart';
import 'package:icarus/services/video_export/video_frame_sink.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/view_cone/vision_geometry.dart';
import 'package:icarus/widgets/dialogs/screenshot_dialog.dart';
import 'package:icarus/widgets/page_choice_list.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Settings + progress dialog for exporting the strategy's pages as an .mp4,
/// or a .mov with a transparent background (ADRs 0003, 0007): checkbox page
/// selection, one global step duration.
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

  /// Starts as the last export left it.
  bool _transparent = false;

  /// Starts as the last export left it.
  bool _includeCaptions = false;

  /// What each page's captions work out to, once measured. The check draws
  /// each page small, so it runs behind the dialog.
  final Map<String, CaptionExportLayout> _captions = {};
  int _captionRun = 0;
  Future<void> _captionCheck = Future.value();

  /// Checks a refused page again once it changes.
  late final _refusedWatch =
      RefusedCaptionsWatch(ref, onChange: _measureCaptions);

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
    _refusedWatch.dispose();
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
    _transparent = ref.read(appPreferencesProvider).transparentVideoBackground;
    _includeCaptions = ref.read(appPreferencesProvider).includeVideoCaptions;
    _pages = videoExportPageChoices(ref);
    _selectedPageIds.addAll(_pages.map((p) => p.id));
    _measureCaptions();
  }

  /// Works out every page's captions, once any older check has stopped:
  /// captures run one at a time. What an earlier check found stands until
  /// this one replaces it.
  void _measureCaptions() {
    final run = ++_captionRun;
    if (!_includeCaptions) return;
    bool stale() => !mounted || run != _captionRun;
    bool cancelled() => stale() || _isExporting;
    final thumbnailer = ref.read(pageThumbnailerProvider);
    _captionCheck = _captionCheck.whenComplete(() {
      if (cancelled()) return null;
      final checked = _refusedWatch.checkStarting();
      return thumbnailer(
        ref,
        pageIds: {for (final page in _pages) page.id},
        includeCaptions: true,
        onThumbnail: (_, image) => image.dispose(),
        onUnavailable: (_, __) {},
        onCaptions: (pageId, layout) {
          if (stale()) return;
          setState(() => _captions[pageId] = layout);
          _refusedWatch.watch({
            for (final MapEntry(:key, :value) in _captions.entries)
              if (!value.fits) key,
          }, checked: checked);
        },
        isCancelled: cancelled,
      );
    });
    unawaited(_captionCheck);
  }

  void _setIncludeCaptions(bool value) {
    setState(() {
      _includeCaptions = value;
      _captions.clear();
      _measureCaptions();
    });
    _refusedWatch.watch(const {});
    unawaited(
      ref.read(appPreferencesProvider.notifier).setIncludeVideoCaptions(value),
    );
  }

  /// Why Export is off: the first selected page whose captions can't be
  /// placed.
  String? get _captionRefusal {
    if (!_includeCaptions) return null;
    for (final (index, page) in _pages.indexed) {
      if (_selectedPageIds.contains(page.id) &&
          _captions[page.id]?.fits == false) {
        return captionsDontFitMessage(context.l10n, index + 1);
      }
    }
    return null;
  }

  /// What the Include captions box says: the selected page that takes longest
  /// to read, when that is longer than a step holds.
  String _captionHint(AppLocalizations l10n) {
    var slowestPage = 0;
    var slowestSeconds = 0;
    for (final (index, page) in _pages.indexed) {
      final layout = _captions[page.id];
      if (layout == null || !_selectedPageIds.contains(page.id)) continue;
      final seconds = captionReadSeconds(layout);
      if (seconds > slowestSeconds) {
        slowestPage = index + 1;
        slowestSeconds = seconds;
      }
    }
    final step = _stepDurationSeconds.round();
    if (slowestSeconds <= step) {
      return l10n.exportVideoIncludeCaptionsDescription;
    }
    return l10n.exportVideoCaptionsTooSlow(slowestPage, slowestSeconds, step);
  }

  void _setTransparent(bool value) {
    setState(() => _transparent = value);
    unawaited(
      ref
          .read(appPreferencesProvider.notifier)
          .setTransparentVideoBackground(value),
    );
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
    final l10n = context.l10n;
    final transparent = _transparent;
    final includeCaptions = _includeCaptions;
    final quality = _exportQuality;
    final extension = transparent ? 'mov' : 'mp4';
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
        "${sanitizeStrategyFileName(ref.read(strategyProvider).stratName ?? l10n.exportVideoDefaultFileName)}.$extension";

    // Where the video goes is settled first, so a dismissed save dialog or
    // a browser that cannot encode video costs nothing.
    final VideoFrameSink sink;
    if (transparent) {
      // Encoded in Dart, so it needs neither ffmpeg nor the browser's
      // encoder. The browser downloads the finished file.
      String? outputPath;
      if (!kIsWeb) {
        outputPath = await chooseExportPath(l10n, fileName);
        if (outputPath == null) return;
      }
      sink = QuickTimeAnimationSink(
        fps: quality.fps,
        outputPath: outputPath,
        l10n: l10n,
      );
    } else if (kIsWeb) {
      final totalSeconds = VideoExporter.plannedDurationSeconds(
        pageCount: pageIds.length,
        stepSeconds: stepDuration.inMilliseconds / 1000,
        fps: quality.fps,
      );
      if (!await browserCanEncodeVideo(
        quality,
        totalSeconds: totalSeconds,
      )) {
        Settings.showToast(
          message: l10n.exportVideoBrowserUnsupported,
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        return;
      }
      sink = createBrowserVideoSink(quality, l10n);
    } else {
      final ffmpegBinary = await FfmpegVideoEncoder.resolveBinary();
      if (ffmpegBinary == null) {
        Settings.showToast(
          message: l10n.exportVideoEncoderNotFound,
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        return;
      }
      final outputPath = await chooseExportPath(l10n, fileName);
      if (outputPath == null) return;
      sink = FfmpegVideoSink(
        binary: ffmpegBinary,
        outputPath: outputPath,
        quality: quality,
        l10n: l10n,
      );
    }
    if (!mounted) return;

    setState(() {
      _preparing = true;
      _cancelRequested = false;
      _progress = 0;
      _progressLabel = l10n.exportVideoSavingChanges;
    });
    CaptureImages? images;
    try {
      final source = await loadVideoExportSource(
        ref,
        pageIds: pageIds,
        // VideoExporter renders frames at 1:1.
        pixelRatio: 1,
        isCancelled: () => _cancelRequested,
      );
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
        backgroundDotOpacity:
            ref.read(appPreferencesProvider).backgroundDotOpacity,
        geometry: geometry,
        transparentBackground: transparent,
        includeCaptions: includeCaptions,
        imageSources: images.sources,
        navigation: navigation,
        requireNavigation: requireNavigation,
        l10n: l10n,
      );
      setState(() {
        _exporter = exporter;
        _progressLabel = l10n.exportVideoPreparing;
      });

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
      // A cancel that arrived while the export was wrapping up still wins.
      if (_cancelRequested) throw VideoExportCancelled();
      // The browser sink hands the finished video back to be downloaded;
      // the desktop one has already written it where the user chose.
      if (video != null) {
        await FilePicker.platform.saveFile(
          type: FileType.custom,
          fileName: fileName,
          allowedExtensions: [extension],
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
            'quality': transparent ? 'lossless' : quality.name,
            'fps': quality.fps,
            'transparent': transparent,
          },
        ),
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
      Settings.showToast(
        message: l10n.exportVideoExported,
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
    } on VideoExportCancelled {
      Settings.showToast(
        message: l10n.exportVideoCancelled,
        backgroundColor: Settings.tacticalVioletTheme.primary,
      );
    } on VideoExportNotSynced catch (error) {
      Settings.showToast(
        message: error.userMessage(l10n),
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    } on VideoExportPagesChanged catch (error) {
      Settings.showToast(
        message: error.userMessage(l10n),
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      if (mounted) {
        setState(() {
          _pages = videoExportPageChoices(ref);
          _selectedPageIds.retainAll({for (final page in _pages) page.id});
        });
      }
    } on CaptureImagesUnavailable catch (error) {
      Settings.showToast(
        message: error.userMessage(l10n),
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    } on CaptionsDontFit catch (error) {
      Settings.showToast(
        message: error.userMessage(l10n),
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    } on Object catch (error) {
      Settings.showToast(
        // Closing the dialog mid-preparation can fail the work it cut
        // short; the user asked to stop, so that is what they hear.
        message: _cancelRequested
            ? l10n.exportVideoCancelled
            : l10n.exportVideoFailed('$error'),
        backgroundColor: _cancelRequested
            ? Settings.tacticalVioletTheme.primary
            : Settings.tacticalVioletTheme.destructive,
      );
    } finally {
      await sink.close();
      images?.release();
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
      fps: _exportQuality.fps,
    );
  }

  bool get _canExport =>
      _selectedPageIds.isNotEmpty && _captionRefusal == null;

  /// The preset the export runs at. A transparent video is lossless, so the
  /// presets' size targets don't apply; it plays at Social's 30 fps.
  VideoExportQuality get _exportQuality =>
      _transparent ? VideoExportQuality.social : _quality;

  bool get _allPagesSelected => _selectedPageIds.length == _pages.length;

  static String _formatSeconds(AppLocalizations l10n, double seconds) {
    final total = seconds.round();
    if (total < 60) return l10n.exportVideoSeconds(total);
    return l10n.exportVideoMinutesSeconds(
      total ~/ 60,
      (total % 60).toString().padLeft(2, '0'),
    );
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
    final l10n = context.l10n;
    return ShadDialog(
      constraints: const BoxConstraints(maxWidth: _dialogWidth),
      title: Text(l10n.exportVideoExportingTitle),
      actions: [
        ShadButton.destructive(
          onPressed: _cancel,
          child: Text(l10n.exportVideoCancelExport),
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
                    l10n.exportVideoKeepTabOpen,
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
    final captionRefusal = _captionRefusal;
    final l10n = context.l10n;

    return ShadDialog(
      constraints: const BoxConstraints(maxWidth: _dialogWidth),
      title: Text(l10n.exportVideoTitle),
      description: Text(
        l10n.exportVideoDescription,
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
                    _SectionLabel(text: l10n.exportVideoStepDuration),
                    const Spacer(),
                    _ValueChip(
                      text: l10n.exportVideoSeconds(
                        _stepDurationSeconds.round(),
                      ),
                    ),
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
                  l10n.exportVideoStepDurationDescription,
                  style: TextStyle(
                    fontSize: 14,
                    color: colors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 24),
                ShadCheckbox(
                  value: _transparent,
                  onChanged: _setTransparent,
                  label: Text(l10n.exportVideoTransparentBackground),
                  sublabel: Text(
                    l10n.exportVideoTransparentBackgroundDescription,
                  ),
                ),
                const SizedBox(height: 12),
                ShadCheckbox(
                  value: _includeCaptions,
                  onChanged: _setIncludeCaptions,
                  label: Text(l10n.exportVideoIncludeCaptions),
                  sublabel: captionRefusal == null
                      ? Text(_captionHint(l10n))
                      : Text(
                          captionRefusal,
                          style: TextStyle(color: colors.destructive),
                        ),
                ),
                const SizedBox(height: 24),
                _SectionLabel(text: l10n.exportVideoQuality),
                const SizedBox(height: 10),
                // A transparent video is lossless, so the presets sit out:
                // dimmed, and without a tap they take no clicks or focus.
                AnimatedOpacity(
                  opacity: _transparent ? 0.4 : 1,
                  duration: const Duration(milliseconds: 150),
                  curve: Settings.easeOut,
                  // IntrinsicHeight bounds the stretch so all three cards
                  // share the tallest card's height; without it the
                  // scrollable dialog hands the Row an infinite height to
                  // stretch into.
                  child: IntrinsicHeight(
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
                              onTap: _transparent
                                  ? null
                                  : () => setState(() => _quality = quality),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_transparent) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.exportVideoTransparentQualityNote,
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.mutedForeground,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Row(
                  children: [
                    _SectionLabel(text: l10n.exportVideoPages),
                    const SizedBox(width: 8),
                    Text(
                      l10n.exportVideoPagesSelected(
                        selectedCount,
                        _pages.length,
                      ),
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
                      child: Text(_allPagesSelected
                          ? l10n.exportVideoClearAll
                          : l10n.exportVideoSelectAll),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                PageChoiceList(
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
                        outputHeight: estimatedSeconds == null || _transparent
                            ? 1080
                            : _quality.outputHeightForDuration(
                                estimatedSeconds,
                              ),
                        extension: _transparent ? 'mov' : 'mp4',
                        formatSeconds: (seconds) =>
                            _formatSeconds(l10n, seconds),
                      ),
                    ),
                    const SizedBox(width: 16),
                    ShadButton.secondary(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.commonCancel),
                    ),
                    const SizedBox(width: 8),
                    ShadButton(
                      enabled: _canExport,
                      onPressed: _export,
                      child: Text(l10n.commonExport),
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
  final VoidCallback? onTap;

  static const _icons = {
    VideoExportQuality.potato: LucideIcons.feather,
    VideoExportQuality.social: LucideIcons.share2,
    VideoExportQuality.max: LucideIcons.gem,
  };

  static String _title(AppLocalizations l10n, VideoExportQuality quality) =>
      switch (quality) {
        VideoExportQuality.potato => l10n.exportVideoQualityPotato,
        VideoExportQuality.social => l10n.exportVideoQualitySocial,
        VideoExportQuality.max => l10n.exportVideoQualityMax,
      };

  @override
  Widget build(BuildContext context) {
    final colors = ShadTheme.of(context).colorScheme;
    final l10n = context.l10n;
    return InkWell(
      mouseCursor:
          onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        curve: Settings.easeOut,
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
                  _title(l10n, quality),
                  style: const TextStyle(fontSize: 15),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              videoExportQualityCaption(l10n, quality),
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

/// Live one-line receipt of what Export will produce.
class _ExportSummary extends StatelessWidget {
  const _ExportSummary({
    required this.estimatedSeconds,
    required this.outputHeight,
    required this.extension,
    required this.formatSeconds,
  });

  final double? estimatedSeconds;
  final int outputHeight;

  /// The file type Export writes: mp4, or mov for a transparent video.
  final String extension;
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
              ? Text(context.l10n.exportVideoSelectAPage, style: muted)
              : Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: context.l10n.exportVideoSummaryLength(
                          formatSeconds(estimatedSeconds!),
                        ),
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.foreground,
                        ),
                      ),
                      TextSpan(
                        text: context.l10n.exportVideoSummaryFormat(
                          outputHeight,
                          extension.toUpperCase(),
                        ),
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
String videoExportQualityCaption(
  AppLocalizations l10n,
  VideoExportQuality quality,
) {
  return switch (quality) {
    VideoExportQuality.potato => l10n.exportVideoQualityPotatoCaption,
    VideoExportQuality.social => l10n.exportVideoQualitySocialCaption,
    VideoExportQuality.max => l10n.exportVideoQualityMaxCaption,
  };
}
