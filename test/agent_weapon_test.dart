import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/migrations/agent_weapon_migration.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';

class _TestStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => StrategyState(
        isSaved: true,
        stratName: null,
        id: 'weapon-test',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

List<PlacedAgentNode> _agents(WeaponType weapon) => [
      PlacedAgent(
        id: 'plain',
        type: AgentType.sova,
        position: const Offset(200, 300),
        weapon: weapon,
      ),
      PlacedViewConeAgent(
        id: 'cone',
        type: AgentType.sova,
        position: const Offset(400, 300),
        presetType: UtilityType.viewCone90,
        length: 60,
        rotation: 0.75,
        weapon: weapon,
      ),
      PlacedCircleAgent(
        id: 'circle',
        type: AgentType.sova,
        position: const Offset(600, 300),
        diameterMeters: 12,
        weapon: weapon,
      ),
    ];

StrategyData _strategy({int version = 100}) => StrategyData(
      id: 'firearm-strategy',
      name: 'Firearms',
      mapData: MapValue.ascent,
      versionNumber: version,
      lastEdited: DateTime.utc(2026, 9, 13),
      folderID: null,
      pages: [
        StrategyPage(
          id: 'page',
          name: 'Armed agents',
          sortIndex: 0,
          isAttack: true,
          drawingData: const [],
          agentData: _agents(WeaponType.vandal),
          abilityData: const [],
          textData: const [],
          imageData: const [],
          utilityData: const [],
          settings: StrategySettings(),
          lineUpOrigins: [
            LineUpOrigin(
              id: 'origin',
              agent: (_agents(WeaponType.bandit).first as PlacedAgent)
                  .copyWith(id: 'lineup-agent', lineUpID: 'origin'),
            ),
          ],
          lineUpLandings: [
            LineUpLanding(
              id: 'landing',
              ability: PlacedAbility(
                id: 'lineup-ability',
                lineUpID: 'landing',
                data: AgentData.agents[AgentType.sova]!.abilities.first,
                position: const Offset(700, 500),
              ),
            ),
          ],
          lineUpLinks: [
            LineUpLink(id: 'link', originId: 'origin', landingId: 'landing'),
          ],
        ),
      ],
    );

void _expectWeapons(StrategyData strategy) {
  expect(strategy.pages.single.agentData.map((agent) => agent.weapon),
      everyElement(WeaponType.vandal));
  expect(strategy.pages.single.lineUpOrigins.single.agent.weapon,
      WeaponType.bandit);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerIcarusAdapters(Hive);
    appProviderContainer = ProviderContainer();
  });
  tearDownAll(() => appProviderContainer.dispose());
  setUp(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  test('every firearm round-trips through JSON and copies for every agent kind',
      () {
    for (final weapon in WeaponType.values) {
      for (final original in _agents(weapon)) {
        final json = original.toJson();
        expect(json['weapon'], weapon.name);
        final restored = PlacedAgentNode.fromJson(jsonDecode(jsonEncode(json)));
        expect(restored.weapon, weapon);
        expect(restored.toJson(), json);
        final copy = original.snapshotCopy<PlacedAgentNode>();
        expect(copy.weapon, weapon);
        copy.weapon = WeaponType.none;
        expect(original.weapon, weapon);
      }
    }
  });

  test('legacy JSON defaults to no firearm without changing agent geometry',
      () {
    for (final original in _agents(WeaponType.none)) {
      final legacy = original.toJson()..remove('weapon');
      final restored = PlacedAgentNode.fromJson(legacy);
      expect(restored.weapon, WeaponType.none);
      expect(restored.toJson()..remove('weapon'), legacy);
      expect(
        () => PlacedAgentNode.fromJson({...legacy, 'weapon': 'invalid-weapon'}),
        throwsArgumentError,
      );
    }
  });

  test('new Hive adapters read the old field layouts with no firearm', () {
    // Frozen pre-v100 field numbers, deliberately written without the new field.
    final oldRecords = <(TypeAdapter<PlacedAgentNode>, Map<int, dynamic>)>[
      (
        PlacedAgentAdapter(),
        {
          0: AgentType.sova,
          1: true,
          2: 'plain',
          3: false,
          4: const Offset(200, 300),
          5: null,
          6: AgentState.none,
        }
      ),
      (
        PlacedViewConeAgentAdapter(),
        {
          0: UtilityType.viewCone90,
          1: 0.75,
          2: 60.0,
          3: AgentType.sova,
          4: true,
          5: AgentState.none,
          6: 'cone',
          7: false,
          8: const Offset(400, 300),
          9: null,
        }
      ),
      (
        PlacedCircleAgentAdapter(),
        {
          0: 12.0,
          1: 0xFFFFFFFF,
          2: 100,
          3: AgentType.sova,
          4: true,
          5: AgentState.none,
          6: 'circle',
          7: false,
          8: const Offset(600, 300),
        }
      ),
    ];
    final expected = _agents(WeaponType.none);
    for (var i = 0; i < oldRecords.length; i++) {
      final (adapter, fields) = oldRecords[i];
      final writer = BinaryWriterImpl(Hive);
      writer.writeByte(fields.length);
      for (final field in fields.entries) {
        writer
          ..writeByte(field.key)
          ..write(field.value);
      }
      final restored = adapter.read(
        BinaryReaderImpl(writer.toBytes(), Hive),
      );
      expect(restored.toJson(), expected[i].toJson());
    }
  });

  test('selection, removal, movement and deletion undo independently', () {
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_TestStrategyProvider.new),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(agentProvider.notifier);
    final actions = container.read(actionProvider.notifier);
    for (final original in _agents(WeaponType.none)) {
      actions.resetActionState();
      notifier.fromHive([original]);
      notifier.setWeapon(original.id, WeaponType.phantom);
      expect(container.read(strategyProvider).isSaved, isFalse);
      notifier.updatePosition(const Offset(800, 500), original.id);
      notifier.setWeapon(original.id, WeaponType.none);
      actions.undoAction();
      expect(container.read(agentProvider).single.weapon, WeaponType.phantom);
      actions.undoAction();
      expect(
          container.read(agentProvider).single.position,
          _agents(WeaponType.none)
              .firstWhere((a) => a.id == original.id)
              .position);
      actions.undoAction();
      expect(container.read(agentProvider).single.weapon, WeaponType.none);
      actions.redoAction();
      actions.redoAction();
      expect(container.read(agentProvider).single.position,
          const Offset(800, 500));
      expect(container.read(agentProvider).single.weapon, WeaponType.phantom);
      notifier.removeAgentAsAction(original.id);
      actions.undoAction();
      expect(container.read(agentProvider).single.weapon, WeaponType.phantom);
      final actionCount = container.read(actionProvider).length;
      notifier.setWeapon(original.id, WeaponType.phantom);
      notifier.setWeapon('missing', WeaponType.odin);
      expect(container.read(actionProvider).length, actionCount);
    }
  });

  test('duplication and agent conversions preserve the firearm', () {
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_TestStrategyProvider.new),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(agentProvider.notifier);
    notifier.fromHive(_agents(WeaponType.operator));
    for (final original in _agents(WeaponType.operator)) {
      final id = notifier.duplicateAgentAt(
        sourceId: original.id,
        position: const Offset(900, 500),
      );
      expect(
          container.read(agentProvider).singleWhere((a) => a.id == id).weapon,
          WeaponType.operator);
    }
    notifier.convertPlainAgentToViewCone(
      id: 'plain',
      presetType: UtilityType.viewCone90,
      rotation: 0.5,
      length: 60,
    );
    expect(container.read(agentProvider).first.weapon, WeaponType.operator);
    notifier.convertViewConeAgentToPlain(id: 'plain');
    expect(container.read(agentProvider).first.weapon, WeaponType.operator);
    notifier.convertPlainAgentToCircle(
      id: 'plain',
      diameterMeters: 10,
      colorValue: 0xFFFFFFFF,
      opacityPercent: 60,
    );
    expect(container.read(agentProvider).first.weapon, WeaponType.operator);
  });

  test(
      'lineup origins keep weapons through creation, selection, undo and copies',
      () {
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_TestStrategyProvider.new),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(lineUpProvider.notifier);
    notifier.startFresh();
    notifier.setDraftAgent(_agents(WeaponType.guardian).first as PlacedAgent);
    notifier.setDraftAbility(
        _strategy().pages.single.lineUpLandings.single.ability);
    final link = notifier.commitPlacement()!;
    expect(
        notifier.originById(link.originId)!.agent.weapon, WeaponType.guardian);
    notifier.setOriginWeapon(link.originId, WeaponType.sheriff);
    expect(
        notifier.originById(link.originId)!.agent.weapon, WeaponType.sheriff);
    container.read(actionProvider.notifier).undoAction();
    expect(
        notifier.originById(link.originId)!.agent.weapon, WeaponType.guardian);
    container.read(actionProvider.notifier).redoAction();
    expect(
        notifier.originById(link.originId)!.agent.weapon, WeaponType.sheriff);
    notifier.setOriginWeapon(link.originId, WeaponType.none);
    expect(notifier.originById(link.originId)!.agent.weapon, WeaponType.none);
    container.read(actionProvider.notifier).undoAction();
    expect(
        notifier.originById(link.originId)!.agent.weapon, WeaponType.sheriff);
    // Deleting and recreating the graph must not lose a weapon edit's redo.
    notifier.deleteOrigin(link.originId);
    final actions = container.read(actionProvider.notifier);
    actions.undoAction();
    actions.undoAction();
    expect(
        notifier.originById(link.originId)!.agent.weapon, WeaponType.guardian);
    actions.redoAction();
    actions.redoAction();
    expect(notifier.originById(link.originId), isNull);
    actions.undoAction();
    expect(
        notifier.originById(link.originId)!.agent.weapon, WeaponType.sheriff);
    final copied = _strategy().pages.single.copyWith(id: 'copied-page');
    expect(
        copied.agentData.map((a) => a.weapon), everyElement(WeaponType.vandal));
    expect(copied.lineUpOrigins.single.agent.weapon, WeaponType.bandit);
  });

  test('v100 migration changes only the version and is idempotent', () {
    final original = _strategy(version: 99);
    final migrated = AgentWeaponMigration.migrate(original);
    expect(migrated.versionNumber, 100);
    expect(migrated.pages, same(original.pages));
    expect(migrated.lastEdited, original.lastEdited);
    expect(migrated.id, original.id);
    expect(AgentWeaponMigration.migrate(migrated), same(migrated));
    expect(StrategyProvider.migrateToCurrentVersion(original).versionNumber,
        Settings.versionNumber);
  });

  test('patch releases advance only the version and preserve newer strategies',
      () {
    for (final version in [100, Settings.versionNumber - 1]) {
      final original = _strategy(version: version);
      final migrated = StrategyProvider.migrateToCurrentVersion(original);
      expect(migrated.versionNumber, Settings.versionNumber);
      expect(migrated.pages, same(original.pages));
      expect(migrated.id, original.id);
      expect(migrated.name, original.name);
      expect(migrated.mapData, original.mapData);
      expect(migrated.createdAt, original.createdAt);
      expect(migrated.lastEdited, original.lastEdited);
      expect(migrated.folderID, original.folderID);
      expect(
          StrategyProvider.migrateToCurrentVersion(migrated), same(migrated));
    }
    final newer = _strategy(version: Settings.versionNumber + 1);
    expect(StrategyProvider.migrateToCurrentVersion(newer), same(newer));
  });

  test('Hive reopen, real .ica export/import and library backup retain weapons',
      () async {
    final directory = await Directory.systemTemp.createTemp('icarus-firearms-');
    Hive.init(directory.path);
    final container = ProviderContainer();
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
    await box.put('firearm-strategy', _strategy());
    await box.close();
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    _expectWeapons(box.get('firearm-strategy')!);

    final notifier = container.read(strategyProvider.notifier);
    final exported = await notifier.zipStrategy(
      id: 'firearm-strategy',
      saveDir: directory,
    );
    final result = await notifier.loadFromFileDrop([XFile(exported)]);
    expect(result.issues, isEmpty);
    expect(result.strategiesImported, 1);
    for (final strategy in box.values) {
      _expectWeapons(strategy);
    }

    final backup = await notifier.buildLibraryExportDirectoryForTest();
    addTearDown(() => backup.delete(recursive: true));
    final backupFile = '${directory.path}/library.zip';
    final encoder = ZipFileEncoder()..create(backupFile);
    await encoder.addDirectory(backup, includeDirName: false);
    await encoder.close();
    final imported = await notifier.loadFromFileDrop([XFile(backupFile)]);
    expect(imported.issues, isEmpty);
    expect(imported.strategiesImported, 2);
    expect(box.length, 4);
    for (final strategy in box.values) {
      _expectWeapons(strategy);
      expect(strategy.versionNumber,
          strategy.id == 'firearm-strategy' ? 100 : Settings.versionNumber);
    }
  });
}
