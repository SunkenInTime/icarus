import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:hive_ce/src/hive_impl.dart';
import 'package:hive_ce/src/util/logger.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';

import 'desktop_4_6_3_adapters_test_support.dart';

const _note = 'Plant behind the box\nhttps://youtu.be/9vxdjCd272k?t=330';

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

class _TestStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => StrategyState(
        isSaved: true,
        stratName: null,
        id: 'caption-test',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

PlacedAbility _ability(String id) => PlacedAbility(
      id: id,
      data: AgentData.agents[AgentType.breach]!.abilities.first,
      position: const Offset(30, 40),
    );

PlacedAgent _agent(String id) => PlacedAgent(
      id: id,
      type: AgentType.jett,
      position: const Offset(200, 300),
    );

/// One of every placed type, each with [caption].
Map<String, PlacedWidget> _items(String? caption) => {
      'agent': _agent('agent')..caption = caption,
      'view cone agent': PlacedViewConeAgent(
        id: 'cone',
        type: AgentType.sova,
        position: const Offset(400, 300),
        presetType: UtilityType.viewCone90,
        length: 60,
        rotation: 0.75,
      )..caption = caption,
      'circle agent': PlacedCircleAgent(
        id: 'circle',
        type: AgentType.viper,
        position: const Offset(600, 300),
        diameterMeters: 12,
      )..caption = caption,
      'ability': _ability('ability')..caption = caption,
      'text': PlacedText(position: const Offset(10, 20), id: 'text')
        ..text = 'Fake A first'
        ..caption = caption,
      'image': PlacedImage(
        position: const Offset(50, 60),
        id: 'image',
        aspectRatio: 1.5,
        scale: 200,
        fileExtension: '.png',
      )..caption = caption,
      'utility': PlacedUtility(
        type: UtilityType.spike,
        position: const Offset(70, 80),
        id: 'spike',
      )..caption = caption,
    };

PlacedWidget _copyWith(PlacedWidget item) => switch (item) {
      PlacedAgent() => item.copyWith(),
      PlacedViewConeAgent() => item.copyWith(),
      PlacedCircleAgent() => item.copyWith(),
      PlacedAbility() => item.copyWith(),
      PlacedText() => item.copyWith(),
      PlacedImage() => item.copyWith(),
      PlacedUtility() => item.copyWith(),
      _ => throw StateError('A placed type this test does not know'),
    };

HiveImpl _registry() {
  final registry = HiveImpl();
  registerIcarusAdapters(registry);
  return registry;
}

HiveImpl _desktop463Registry() {
  final previous = Logger.level;
  Logger.level = LoggerLevel.error;
  try {
    return _registry()
      ..registerAdapter(Desktop463PlacedAgentAdapter(), override: true)
      ..registerAdapter(Desktop463PlacedAbilityAdapter(), override: true);
  } finally {
    Logger.level = previous;
  }
}

T _across<T extends Object>(HiveImpl from, HiveImpl to, T value) {
  final writer = BinaryWriterImpl(from)..write(value);
  return BinaryReaderImpl(Uint8List.fromList(writer.toBytes()), to).read() as T;
}

StrategyData _strategy() {
  final items = _items(_note);
  return StrategyData(
    id: 'caption-strategy',
    name: 'Captions',
    mapData: MapValue.ascent,
    versionNumber: Settings.versionNumber,
    lastEdited: DateTime.utc(2026, 11, 1),
    folderID: null,
    pages: [
      StrategyPage(
        id: 'page',
        name: 'Page 1',
        sortIndex: 0,
        isAttack: true,
        drawingData: const [],
        agentData: items.values.whereType<PlacedAgentNode>().toList(),
        abilityData: items.values.whereType<PlacedAbility>().toList(),
        textData: items.values.whereType<PlacedText>().toList(),
        imageData: const [],
        utilityData: items.values.whereType<PlacedUtility>().toList(),
        settings: StrategySettings(),
      ),
    ],
  );
}

void _expectCaptions(StrategyData strategy) {
  final page = strategy.pages.single;
  final items = <PlacedWidget>[
    ...page.agentData,
    ...page.abilityData,
    ...page.textData,
    ...page.utilityData,
  ];
  expect(items, hasLength(6));
  for (final item in items) {
    expect(item.caption, _note, reason: item.runtimeType.toString());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerIcarusAdapters(Hive);
    appProviderContainer = ProviderContainer();
  });
  tearDownAll(() => appProviderContainer.dispose());
  setUp(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  for (final MapEntry(key: name, value: item) in _items(_note).entries) {
    group('a captioned $name', () {
      test('keeps it through copyWith and deepCopy', () {
        expect(_copyWith(item).caption, _note);
        expect(item.deepCopy<PlacedWidget>().caption, _note);
      });

      test('keeps it through its JSON, as a cloud payload carries it', () {
        final json = jsonDecode(jsonEncode(item.toJson()));
        expect(json['caption'], _note);
      });

      test('keeps it through Hive', () {
        final registry = _registry();
        expect(_across(registry, registry, item).caption, _note);
      });
    });
  }

  test('agents and utilities keep it through an undo snapshot', () {
    final items = _items(_note);
    for (final name in [
      'agent',
      'view cone agent',
      'circle agent',
      'utility'
    ]) {
      expect(items[name]!.snapshotCopy<PlacedWidget>().caption, _note,
          reason: name);
    }
  });

  group('an emptied caption stays written', () {
    for (final MapEntry(key: name, value: item) in _items('').entries) {
      test(name, () {
        final registry = _registry();
        expect(item.toJson()['caption'], '');
        expect(_across(registry, registry, item).caption, '');
        expect(_copyWith(item).caption, '');
      });
    }
  });

  group('an item that never had a caption', () {
    for (final MapEntry(key: name, value: item) in _items(null).entries) {
      test('$name has no key in its JSON, so its payload is unchanged', () {
        expect(item.toJson().containsKey('caption'), isFalse);
      });
    }

    test('saved by desktop 4.6.3, opens with none', () {
      final registry = _registry();
      final desktop463 = _desktop463Registry();
      expect(_across(desktop463, registry, _agent('a')).caption, isNull);
      expect(_across(desktop463, registry, _ability('b')).caption, isNull);
    });

    test('from a payload written before captions, opens with none', () {
      for (final item in _items(null).values) {
        expect(item.deepCopy<PlacedWidget>().caption, isNull);
      }
    });
  });

  test('desktop 4.6.3 opens a captioned agent and ability, whole', () {
    final current = _registry();
    final desktop463 = _desktop463Registry();
    final agent = _agent('a')..caption = _note;
    final ability = _ability('b')..caption = _note;

    final openedAgent = _across(current, desktop463, agent);
    final openedAbility = _across(current, desktop463, ability);

    expect(openedAgent.id, 'a');
    expect(openedAgent.position, agent.position);
    expect(openedAbility.id, 'b');
    expect(openedAbility.position, ability.position);
  });

  test('turning an agent into a cone or a circle and back keeps it', () {
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_TestStrategyProvider.new),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(agentProvider.notifier);
    notifier.fromHive([_agent('plain')..caption = _note]);

    notifier.convertPlainAgentToViewCone(
      id: 'plain',
      presetType: UtilityType.viewCone90,
      rotation: 0.5,
      length: 60,
    );
    expect(container.read(agentProvider).first.caption, _note);
    notifier.convertViewConeAgentToPlain(id: 'plain');
    expect(container.read(agentProvider).first.caption, _note);
    notifier.convertPlainAgentToCircle(
      id: 'plain',
      diameterMeters: 10,
      colorValue: 0xFFFFFFFF,
      opacityPercent: 60,
    );
    expect(container.read(agentProvider).first.caption, _note);
  });

  test('an agent and ability made into a lineup leave their caption behind',
      () {
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_TestStrategyProvider.new),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(lineUpProvider.notifier);
    notifier.startFresh();
    notifier.setDraftAgent(
      PlacedAgent(
        id: 'origin-agent',
        type: AgentType.breach,
        position: const Offset(200, 300),
      )..caption = _note,
    );
    notifier.setDraftAbility(_ability('landing-ability')..caption = _note);

    final link = notifier.commitPlacement()!;

    final state = container.read(lineUpProvider);
    final origin = state.origins.singleWhere((o) => o.id == link.originId);
    final landing = state.landings.singleWhere((l) => l.id == link.landingId);
    expect(origin.agent.caption, isNull);
    expect(landing.ability.caption, isNull);
  });

  test("an image's cloud payload keeps its caption, not its link", () {
    final image = _items(_note)['image']! as PlacedImage;
    image.link = 'https://example.test';

    final payload = cloudImagePayloadFromPlacedImage(image);

    expect(payload['caption'], _note);
    expect(payload.containsKey('link'), isFalse);
  });

  // Images are left out: a real export needs the picture's file. An image's
  // caption is held by the JSON and Hive tests above, which export reads.
  test('Hive reopen, a real .ica and a library backup round-trip it', () async {
    final directory = await Directory.systemTemp.createTemp('icarus-caption-');
    Hive.init(directory.path);
    final container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    addTearDown(() async {
      container.dispose();
      await Hive.close();
      await directory.delete(recursive: true);
    });
    var box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    await MapThemeProfilesProvider.bootstrap();
    await box.put('caption-strategy', _strategy());
    await box.close();
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    _expectCaptions(box.get('caption-strategy')!);

    final service = StrategyImportExportService(container);
    final exported = await service.zipStrategy(
      id: 'caption-strategy',
      saveDir: directory,
    );
    final result = await service.loadFromFileDrop([XFile(exported)]);

    expect(result.issues, isEmpty);
    expect(result.strategiesImported, 1);
    expect(box.length, 2);
    box.values.forEach(_expectCaptions);

    final backup = await service.buildLibraryExportDirectoryForTest();
    addTearDown(() => backup.delete(recursive: true));
    final backupFile = '${directory.path}/library.zip';
    final encoder = ZipFileEncoder()..create(backupFile);
    await encoder.addDirectory(backup, includeDirName: false);
    await encoder.close();
    final imported = await service.loadFromFileDrop([XFile(backupFile)]);

    expect(imported.issues, isEmpty);
    expect(imported.strategiesImported, 2);
    expect(box.length, 4);
    box.values.forEach(_expectCaptions);
  });
}
