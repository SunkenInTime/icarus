import 'dart:io';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

// The provider's initial state carries this id, so a strategy stored under it
// can be activated without going through the file-backed load path.
const _strategyId = 'testID';

StrategyPage _page(
  String id,
  int index, {
  required bool isAttack,
  bool withAgent = true,
}) {
  return StrategyPage(
    id: id,
    sortIndex: index,
    name: 'Page ${index + 1}',
    isAutoNamed: true,
    drawingData: const [],
    agentData: [
      if (withAgent)
        PlacedAgent(
          id: '$id-agent',
          type: AgentType.sova,
          position: Offset(10.0 * (index + 1), 20),
        ),
    ],
    abilityData: const [],
    textData: const [],
    imageData: const [],
    utilityData: const [],
    isAttack: isAttack,
    settings: StrategySettings(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ProviderContainer container;

  setUpAll(() async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    tempDir = await Directory.systemTemp.createTemp('icarus-switch-side');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(20)) {
      registerIcarusAdapters(Hive);
    }
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
  });

  setUp(() async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    await box.put(
      _strategyId,
      StrategyData(
        id: _strategyId,
        name: 'Mixed',
        mapData: MapValue.ascent,
        versionNumber: Settings.versionNumber,
        lastEdited: DateTime.utc(2026, 1, 1),
        folderID: null,
        pages: [
          // Activating a page first flushes the (empty) editor state into the
          // page that was active before, which defaults to the first page.
          _page('p1', 0, isAttack: true, withAgent: false),
          _page('p2', 1, isAttack: false),
          _page('p3', 2, isAttack: true),
        ],
      ),
    );

    container = ProviderContainer();
    final notifier = container.read(strategyProvider.notifier);
    await notifier.renameStrategy(_strategyId, 'Mixed');
    await notifier.setActivePage('p2');
  });

  tearDown(() async {
    container.dispose();
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).clear();
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  List<StrategyPage> storedPages() {
    final pages = [
      ...Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .get(_strategyId)!
          .pages,
    ]..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    return pages;
  }

  test('switching side on all pages unifies a mixed strategy', () async {
    expect(container.read(mapProvider).isAttack, isFalse);

    await container
        .read(strategyProvider.notifier)
        .switchSide(allPages: true);

    expect(container.read(mapProvider).isAttack, isTrue);
    final pages = storedPages();
    expect(pages.map((p) => p.isAttack), everyElement(isTrue));
    expect(
      pages.skip(1).map((p) => p.agentData.single.position).toList(),
      [const Offset(20, 20), const Offset(30, 20)],
      reason: 'side is a view choice; canonical placements must not move',
    );
  });

  test('switching side on this page leaves the other pages alone', () async {
    await container
        .read(strategyProvider.notifier)
        .switchSide(allPages: false);

    expect(container.read(mapProvider).isAttack, isTrue);
    expect(container.read(strategyProvider).isSaved, isFalse);
    expect(
      storedPages().map((p) => p.isAttack).toList(),
      [true, false, true],
      reason: 'the active page is written on the next save, not here',
    );
  });
}
