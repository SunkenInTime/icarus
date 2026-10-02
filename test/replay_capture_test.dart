import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/replay/replay_capture.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:uuid/uuid.dart';

/// What the library's New Strategy makes: one blank page.
Future<StrategyData> createBlankStrategy(MapValue map, String name) async {
  final strategy = StrategyData(
    id: const Uuid().v4(),
    name: name,
    mapData: map,
    versionNumber: Settings.versionNumber,
    lastEdited: DateTime.now(),
    folderID: null,
    pages: [
      StrategyPage(
        id: const Uuid().v4(),
        name: 'Page 1',
        isAutoNamed: true,
        drawingData: const [],
        agentData: const [],
        abilityData: const [],
        textData: const [],
        imageData: const [],
        utilityData: const [],
        sortIndex: 0,
        isAttack: true,
        settings: StrategySettings(),
      ),
    ],
  );
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
      .put(strategy.id, strategy);
  return strategy;
}

ReplayFrame frame({Offset position = const Offset(500, 500)}) => ReplayFrame(
      timeMs: 1000,
      round: null,
      isAttack: false,
      agents: [
        PlacedViewConeAgent(
          id: 'replay-player-a',
          type: AgentType.jett,
          position: position,
          presetType: UtilityType.viewCone180,
          rotation: 1,
          length: 100,
        ),
      ],
      abilities: const [],
      utilities: const [],
    );

void main() {
  late Directory temp;
  late Box<StrategyData> box;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('icarus-replay-capture');
    Hive.init(temp.path);
    registerIcarusAdapters(Hive);
  });

  setUp(() async {
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await box.clear();
  });

  tearDownAll(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });

  ReplayCapture capture() => ReplayCapture(
        createStrategy: createBlankStrategy,
        map: MapValue.sunset,
        name: 'Sunset replay',
      );

  test('captures fill one strategy, the first replacing its blank page',
      () async {
    final session = capture();
    await session.capture(frame(), pageName: 'Round 1 · 0:10');
    await session.capture(frame(), pageName: 'Round 1 · 0:20');

    final strategy = box.values.single;
    expect(strategy.name, 'Sunset replay');
    expect(strategy.mapData, MapValue.sunset);
    expect(strategy.pages.map((page) => page.name),
        ['Round 1 · 0:10', 'Round 1 · 0:20']);
    expect(strategy.pages.map((page) => page.sortIndex), [0, 1]);
    expect(strategy.pages.last.id, session.lastPageId);
    final page = strategy.pages.first;
    expect(page.isAttack, isFalse);
    final agent = page.agentData.single as PlacedViewConeAgent;
    expect(agent.id, 'replay-player-a');
    expect(agent.position, const Offset(500, 500));
  });

  test('a deleted or re-mapped strategy is never written to again', () async {
    final session = capture();
    final first = await session.capture(frame(), pageName: 'one');
    await box.delete(first.id);

    final second = await session.capture(frame(), pageName: 'two');
    expect(second.id, isNot(first.id));
    expect(second.pages.single.name, 'two');

    await box.put(second.id, second.copyWith(mapData: MapValue.ascent));
    final third = await session.capture(frame(), pageName: 'three');
    expect(third.id, isNot(second.id));
    expect(box.get(second.id)!.pages.single.name, 'two');
  });

  test('a frame off the map is refused before anything is written', () async {
    final session = capture();
    await expectLater(
      session.capture(
        frame(position: const Offset(double.nan, 0)),
        pageName: 'bad',
      ),
      throwsStateError,
    );
    expect(box.isEmpty, isTrue);
  });
}
