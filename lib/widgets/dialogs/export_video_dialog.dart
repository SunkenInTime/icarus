import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/services/analytics_service.dart';
import 'package:icarus/services/video_export/ffmpeg_video_encoder.dart';
import 'package:icarus/services/video_export/video_exporter.dart';
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
  List<StrategyPage> _pages = const [];
  final Set<String> _selectedPageIds = {};
  double _stepDurationSeconds = 3.0;

  VideoExporter? _exporter;
  double _progress = 0;
  String _progressLabel = '';
  bool get _isExporting => _exporter != null;

  @override
  void initState() {
    super.initState();
    _stepDurationSeconds = ref
        .read(appPreferencesProvider)
        .videoExportStepDurationSeconds
        .clamp(1.0, 30.0);
    final doc = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .get(ref.read(strategyProvider).id);
    _pages = [...?doc?.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    _selectedPageIds.addAll(_pages.map((p) => p.id));
  }

  Future<void> _export() async {
    if (_selectedPageIds.isEmpty) return;

    final stepDuration =
        Duration(milliseconds: (_stepDurationSeconds * 1000).round());
    unawaited(
      ref
          .read(appPreferencesProvider.notifier)
          .setVideoExportStepDurationSeconds(_stepDurationSeconds),
    );

    final ffmpegBinary = await FfmpegVideoEncoder.resolveBinary();
    if (ffmpegBinary == null) {
      Settings.showToast(
        message:
            'Video encoder not found. Reinstalling Icarus should fix this.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return;
    }

    final outputPath = await FilePicker.platform.saveFile(
      type: FileType.custom,
      dialogTitle: 'Please select an output file:',
      fileName:
          "${StrategyProvider.sanitizeFileName(ref.read(strategyProvider).stratName ?? "new video")}.mp4",
      allowedExtensions: ['mp4'],
    );
    if (outputPath == null || !mounted) return;

    final strategyId = ref.read(strategyProvider).id;
    await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
    final doc =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategyId);
    if (doc == null || !mounted) return;

    // Resolve pages from the freshly saved document — the dialog's initial
    // snapshot may predate unsaved edits on the active page.
    final selectedPages = ([...doc.pages]
          ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)))
        .where((p) => _selectedPageIds.contains(p.id))
        .toList();
    if (selectedPages.isEmpty) return;

    final mapState = ref.read(mapProvider);
    VisionGeometryMap? geometry;
    try {
      geometry = await ref.read(
        viewConeGeometryProvider(mapState.currentMap).future,
      );
    } on Object {
      // Geometry is an enhancement; transitions fall back to direct paths.
    }
    if (!mounted) return;

    final exporter = VideoExporter(
      strategy: doc,
      strategyState: ref.read(strategyProvider),
      mapState: mapState,
      geometry: geometry,
    );
    setState(() {
      _exporter = exporter;
      _progress = 0;
      _progressLabel = 'Preparing';
    });

    CoordinateSystem.instance.setIsScreenshot(true);
    try {
      await exporter.export(
        pages: selectedPages,
        stepDuration: stepDuration,
        ffmpegBinary: ffmpegBinary,
        outputPath: outputPath,
        onProgress: (fraction, label) {
          if (!mounted) return;
          setState(() {
            _progress = fraction;
            _progressLabel = label;
          });
        },
      );
      unawaited(
        AnalyticsService.instance.capture(
          'content_exported',
          properties: {
            'content_type': 'video',
            'page_count': selectedPages.length,
            'step_duration_seconds': _stepDurationSeconds,
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
    } on Object catch (error) {
      Settings.showToast(
        message: 'Video export failed: $error',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    } finally {
      CoordinateSystem.instance.setIsScreenshot(false);
      if (mounted) {
        ref.read(screenshotProvider.notifier).setIsScreenShot(false);
        ref
            .read(drawingProvider.notifier)
            .rebuildAllPaths(CoordinateSystem.instance);
        setState(() {
          _exporter = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isExporting) {
      return ShadDialog(
        title: const Text('Exporting Video'),
        actions: [
          ShadButton.destructive(
            onPressed: () => _exporter?.cancel(),
            child: const Text('Cancel'),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_progressLabel),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _progress),
            ],
          ),
        ),
      );
    }

    final selectedCount = _selectedPageIds.length;
    return ShadDialog(
      title: const Text('Export Video'),
      description: const Text(
        'Each included page is shown for the step duration, with animated '
        'transitions between pages.',
      ),
      actions: [
        ShadButton.secondary(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton(
          onPressed: selectedCount == 0 ? null : _export,
          child: const Text('Export'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Step duration'),
                const Spacer(),
                Text('${_stepDurationSeconds.toStringAsFixed(0)}s'),
              ],
            ),
            Slider(
              value: _stepDurationSeconds,
              min: 1,
              max: 30,
              divisions: 29,
              onChanged: (value) {
                setState(() => _stepDurationSeconds = value);
              },
            ),
            const SizedBox(height: 8),
            Text('Pages ($selectedCount/${_pages.length})'),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final page in _pages)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            ShadCheckbox(
                              value: _selectedPageIds.contains(page.id),
                              onChanged: (checked) {
                                setState(() {
                                  if (checked) {
                                    _selectedPageIds.add(page.id);
                                  } else {
                                    _selectedPageIds.remove(page.id);
                                  }
                                });
                              },
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                page.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
