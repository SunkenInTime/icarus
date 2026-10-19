import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/screenshot/offscreen_capture.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

StrategyPage _page(String id, int agents, int sortIndex) => StrategyPage(
      id: id,
      name: id,
      drawingData: const [],
      agentData: [
        for (var i = 0; i < agents; i++)
          PlacedAgent(
            id: '$id-agent-$i',
            type: AgentType.jett,
            position: Offset(100.0 + i * 40, 100),
            isAlly: true,
          ),
      ],
      abilityData: const [],
      textData: const [],
      imageData: const [],
      utilityData: const [],
      sortIndex: sortIndex,
      isAttack: true,
      settings: StrategySettings(),
    );

ScreenshotView _view(StrategyPage page, StrategyState state) => ScreenshotView(
      mapValue: MapValue.ascent,
      showSpawnBarrier: false,
      showRegionNames: false,
      showUltOrbs: false,
      backgroundDotOpacity: 1,
      agents: page.agentData,
      abilities: page.abilityData,
      text: page.textData,
      images: page.imageData,
      drawings: page.drawingData,
      utilities: page.utilityData,
      strategySettings: page.settings,
      isAttack: page.isAttack,
      strategyState: state,
      pageName: page.name,
      lineUpGraph: LineUpGraph.empty,
      themeProfileId: null,
      themeOverridePalette: null,
    );

void main() {
  late Directory hiveDir;

  setUp(() async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    hiveDir = await Directory.systemTemp.createTemp('icarus_capture_box');
    Hive.init(hiveDir.path);
    registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await MapThemeProfilesProvider.bootstrap();
  });

  tearDown(() async {
    CoordinateSystem.instance.setIsScreenshot(false);
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  test('loading page after page into a capture never marks it unsaved',
      () async {
    // A local strategy open on page a. Video export and multi-page
    // screenshots load each page into one capture container in turn; the
    // editor's strategy provider took the second load for an edit and
    // autosaved page b over page a in the library.
    final pages = [_page('a', 1, 0), _page('b', 3, 1)];
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
      's',
      StrategyData(
        id: 's',
        name: 'S',
        mapData: MapValue.ascent,
        versionNumber: 1,
        lastEdited: DateTime(2026),
        folderID: null,
        pages: pages,
      ),
    );
    const editor = StrategyState(
      strategyId: 's',
      strategyName: 'S',
      source: StrategySource.local,
      storageDirectory: null,
      isOpen: true,
      activePageId: 'a',
    );

    final container = createCaptureContainer();
    addTearDown(container.dispose);
    for (final page in pages) {
      _view(page, editor).hydrateProviders(container);
      // Unsaved is what schedules the autosave.
      expect(container.read(strategySaveStateProvider).isDirty, isFalse);
      expect(container.read(strategyProvider).isSaved, isTrue);
    }

    final library =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get('s')!;
    expect([for (final page in library.pages) page.agentData.length], [1, 3]);
  });
}
