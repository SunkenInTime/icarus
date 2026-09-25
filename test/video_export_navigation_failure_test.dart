import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/services/video_export/ffmpeg_video_encoder.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/services/video_export/video_exporter.dart';

StrategyPage _page(String id, Offset position) => StrategyPage(
      id: id,
      name: id,
      sortIndex: 0,
      isAttack: true,
      agentData: [
        PlacedAgent(id: 'sova', type: AgentType.sova, position: position)
      ],
      abilityData: const [],
      utilityData: const [],
      drawingData: const [],
      textData: const [],
      imageData: const [],
      settings: StrategySettings(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final requireNavigation in [false, true]) {
    test(
        'video ${requireNavigation ? 'rejects missing native navigation before rendering' : 'retains the legacy loading behavior'}',
        () async {
      CoordinateSystem(playAreaSize: const Size(1600, 900));
      final pages = [
        _page('one', const Offset(200, 300)),
        _page('two', const Offset(600, 700))
      ];
      final strategy = StrategyData(
        id: 'test',
        name: 'test',
        mapData: MapValue.split,
        versionNumber: 1,
        lastEdited: DateTime(2026),
        folderID: null,
        pages: pages,
      );
      final exporter = VideoExporter(
        strategy: strategy,
        strategyState: StrategyState(
            isSaved: true,
            stratName: 'test',
            id: 'test',
            storageDirectory: null),
        mapState: MapState(currentMap: MapValue.split, isAttack: true),
        geometry: null,
        requireNavigation: requireNavigation,
      );
      var startedPreparing = false;
      final stopBeforeRendering =
          StateError('stop before opening the renderer');
      await expectLater(
          exporter.export(
            pages: pages,
            stepDuration: const Duration(seconds: 1),
            ffmpegBinary: 'must-not-run',
            outputPath: 'must-not-create.mp4',
            quality: VideoExportQuality.social,
            onProgress: (_, label) {
              startedPreparing = true;
              throw stopBeforeRendering;
            },
          ),
          requireNavigation
              ? throwsA(isA<VideoExportException>().having(
                  (error) => error.message,
                  'message',
                  contains('Movement paths could not load')))
              : throwsA(same(stopBeforeRendering)));
      expect(startedPreparing, !requireNavigation);
      expect(CoordinateSystem.instance.isScreenshot, isFalse);
    });
  }
}
