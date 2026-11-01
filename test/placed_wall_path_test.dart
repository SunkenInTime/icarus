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
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';

import 'desktop_4_6_3_adapters_test_support.dart';

const _wall = [Offset(40, -30), Offset(90, -35.5), Offset(120, -80)];

class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

class _TestActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    poppedItems = [];
    state = [...state, action];
  }
}

class _TestStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => StrategyState(
        isSaved: true,
        stratName: null,
        id: 'wall-test',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

PlacedAbility _tide(String id, {List<Offset>? wallPath}) => PlacedAbility(
      id: id,
      data: AgentData.agents[AgentType.harbor]!.abilities[1],
      position: const Offset(30, 40),
      wallPath: wallPath,
    );

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
      ..registerAdapter(Desktop463PlacedAbilityAdapter(), override: true);
  } finally {
    Logger.level = previous;
  }
}

Uint8List _bytes(HiveImpl registry, Object value) =>
    Uint8List.fromList((BinaryWriterImpl(registry)..write(value)).toBytes());

T _across<T extends Object>(HiveImpl from, HiveImpl to, T value) =>
    BinaryReaderImpl(_bytes(from, value), to).read() as T;

/// One High Tide with a wall and one that never had one.
StrategyData _strategy() => StrategyData(
      id: 'wall-strategy',
      name: 'Walls',
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
          agentData: const [],
          abilityData: [_tide('walled', wallPath: _wall), _tide('icon')],
          textData: const [],
          imageData: const [],
          utilityData: const [],
          settings: StrategySettings(),
        ),
      ],
    );

void _expectWalls(StrategyData strategy) {
  final abilities = strategy.pages.single.abilityData;
  expect(abilities, hasLength(2));
  final walled = abilities.singleWhere((a) => a.wallPath != null);
  expect(walled.wallPath, _wall);
  expect(walled.position, const Offset(30, 40));
  final icon = abilities.singleWhere((a) => a.wallPath == null);
  expect(icon.position, const Offset(30, 40));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerIcarusAdapters(Hive);
    appProviderContainer = ProviderContainer();
  });
  tearDownAll(() => appProviderContainer.dispose());
  setUp(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  group('a High Tide with a wall', () {
    test('keeps it through its JSON, as a cloud payload carries it', () {
      final item = _tide('a', wallPath: _wall);
      final json = jsonDecode(jsonEncode(item.toJson()));

      expect(json['wallPath'], [
        {'dx': 40.0, 'dy': -30.0},
        {'dx': 90.0, 'dy': -35.5},
        {'dx': 120.0, 'dy': -80.0},
      ]);
      expect(
        PlacedAbility.fromJson(json as Map<String, dynamic>).wallPath,
        _wall,
      );
    });

    test('keeps it through Hive', () {
      final registry = _registry();
      expect(
        _across(registry, registry, _tide('a', wallPath: _wall)).wallPath,
        _wall,
      );
    });

    test('keeps it beside a caption in Hive', () {
      final registry = _registry();
      final opened = _across(
        registry,
        registry,
        _tide('a', wallPath: _wall)..caption = 'Cross here',
      );
      expect(opened.wallPath, _wall);
      expect(opened.caption, 'Cross here');
    });

    test('copies share no list with the original', () {
      final item = _tide('a', wallPath: _wall.toList());
      final copies = [
        item.copyWith(id: 'b'),
        clonePlacedAbility(item),
        item.deepCopy<PlacedAbility>(),
      ];

      item.wallPath![0] = Offset.zero;

      for (final copy in copies) {
        expect(copy.wallPath, _wall);
      }
    });

    test('a removed wall stays written, as empty', () {
      final registry = _registry();
      final removed = _tide('a', wallPath: const []);

      expect(removed.toJson()['wallPath'], isEmpty);
      expect(_across(registry, registry, removed).wallPath, isEmpty);
      expect(removed.copyWith().wallPath, isEmpty);
    });

    test('a lineup keeps it, since it is where the ability lands', () {
      final container = ProviderContainer(overrides: [
        strategyProvider.overrideWith(_TestStrategyProvider.new),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(lineUpProvider.notifier);
      notifier.startFresh();
      notifier.setDraftAgent(
        PlacedAgent(
          id: 'origin-agent',
          type: AgentType.harbor,
          position: const Offset(200, 300),
        ),
      );
      notifier.setDraftAbility(_tide('landing', wallPath: _wall));

      final link = notifier.commitPlacement()!;

      final landing = container
          .read(lineUpProvider)
          .landings
          .singleWhere((l) => l.id == link.landingId);
      expect(landing.ability.wallPath, _wall);
    });

    test('its old undo history restores the wall', () {
      final item = _tide('a', wallPath: _wall);
      item.updateGeometryHistory();
      item.updateGeometry(newWallPath: const [Offset(1, 1)]);

      item.undoAction();
      expect(item.wallPath, _wall);

      item.redoAction();
      expect(item.wallPath, const [Offset(1, 1)]);
    });
  });

  group('an ability that never had a wall', () {
    test('has no key in its JSON, so its payload is unchanged', () {
      expect(_tide('a').toJson().containsKey('wallPath'), isFalse);
    });

    test('opens with none from a payload written before walls', () {
      final json = _tide('a').toJson();
      expect(PlacedAbility.fromJson(json).wallPath, isNull);
    });

    test('is byte for byte the record desktop 4.6.3 writes', () {
      expect(
        _bytes(_registry(), _tide('a')),
        _bytes(_desktop463Registry(), _tide('a')),
      );
    });

    test('saved by desktop 4.6.3, opens with none', () {
      final opened = _across(_desktop463Registry(), _registry(), _tide('a'));
      expect(opened.wallPath, isNull);
      expect(opened.position, const Offset(30, 40));
    });
  });

  group('an older build', () {
    test('opens a High Tide with a wall as its icon, whole', () {
      final opened = _across(
        _registry(),
        _desktop463Registry(),
        _tide('a', wallPath: _wall),
      );

      expect(opened.id, 'a');
      expect(opened.position, const Offset(30, 40));
      expect(opened.data.name, 'High Tide');
    });

    // The cost of a rollback that the design accepts: the page's next save
    // by the old build drops the wall and keeps the icon.
    test('saving it keeps the icon and loses the wall', () {
      final desktop463 = _desktop463Registry();
      final current = _registry();

      final opened = _across(current, desktop463, _tide('a', wallPath: _wall));
      final reopened = _across(desktop463, current, opened);

      expect(reopened.position, const Offset(30, 40));
      expect(reopened.wallPath, isNull);
    });
  });

  group('in the cloud', () {
    Map<String, Object?> payload(PlacedAbility item) => {
          'kind': 'ability',
          'payloadVersion': 1,
          'data': jsonDecode(jsonEncode(item.toJson())),
        };

    test('a wall edit merges as that one field', () {
      expect(
        elementMergeFields(
          payload(_tide('a', wallPath: _wall)),
          payload(_tide('a', wallPath: const [Offset(1, 1)])),
        ),
        ['wallPath'],
      );
    });

    test('a first wall and a removed wall each merge as that field', () {
      expect(
        elementMergeFields(
          payload(_tide('a')),
          payload(_tide('a', wallPath: _wall)),
        ),
        ['wallPath'],
      );
      expect(
        elementMergeFields(
          payload(_tide('a', wallPath: _wall)),
          payload(_tide('a', wallPath: const [])),
        ),
        ['wallPath'],
      );
    });

    test('moving the icon leaves the wall out of the merge', () {
      expect(
        elementMergeFields(
          payload(_tide('a', wallPath: _wall)),
          payload(_tide('a', wallPath: _wall).copyWith(
            position: const Offset(300, 400),
          )),
        ),
        ['position'],
      );
    });
  });

  group('setting a wall', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(overrides: [
        actionProvider.overrideWith(_TestActionProvider.new),
        strategyProvider.overrideWith(_TestStrategyProvider.new),
      ]);
      addTearDown(container.dispose);
    });

    PlacedAbility tide() => container.read(abilityProvider).single;

    test('a first wall undoes to empty, so the server drops it', () {
      container.read(abilityProvider.notifier).fromHive([_tide('a')]);

      container.read(abilityProvider.notifier).setWallPath('a', _wall);
      expect(tide().wallPath, _wall);

      container.read(actionProvider.notifier).undoAction();
      expect(tide().wallPath, isEmpty);
      expect(tide().toJson()['wallPath'], isEmpty);

      container.read(actionProvider.notifier).redoAction();
      expect(tide().wallPath, _wall);
    });

    test('an unchanged wall is no edit', () {
      container
          .read(abilityProvider.notifier)
          .fromHive([_tide('a', wallPath: _wall)]);

      container.read(abilityProvider.notifier).setWallPath('a', _wall.toList());

      expect(container.read(actionProvider), isEmpty);
    });

    test('nothing happens for an empty wall on an ability without one', () {
      container.read(abilityProvider.notifier).fromHive([_tide('a')]);

      container.read(abilityProvider.notifier).setWallPath('a', const []);

      expect(container.read(actionProvider), isEmpty);
      expect(tide().wallPath, isNull);
    });
  });

  test('Hive reopen, a real .ica and a library backup round-trip it', () async {
    final directory = await Directory.systemTemp.createTemp('icarus-wall-');
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
    await box.put('wall-strategy', _strategy());
    await box.close();
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    _expectWalls(box.get('wall-strategy')!);

    final service = StrategyImportExportService(container);
    final exported = await service.zipStrategy(
      id: 'wall-strategy',
      saveDir: directory,
    );
    final result = await service.loadFromFileDrop([XFile(exported)]);

    expect(result.issues, isEmpty);
    expect(result.strategiesImported, 1);
    expect(box.length, 2);
    box.values.forEach(_expectWalls);

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
    box.values.forEach(_expectWalls);
  });
}
