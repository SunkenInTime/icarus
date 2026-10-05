import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:hive_ce/src/hive_impl.dart';
import 'package:hive_ce/src/util/logger.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

import 'desktop_4_6_3_adapters_test_support.dart';

/// This build's adapters.
HiveImpl _currentRegistry() {
  final registry = HiveImpl();
  registerIcarusAdapters(registry);
  return registry;
}

/// What desktop 4.6.3 registers: this build's adapters, which are unchanged
/// since that release, except the eight this build writes by hand.
HiveImpl _desktop463Registry() {
  final registry = _currentRegistry();
  // hive_ce warns on every override, which is the point here.
  final previousLevel = Logger.level;
  Logger.level = LoggerLevel.error;
  try {
    return registry
      ..registerAdapter(Desktop463PlacedAgentAdapter(), override: true)
      ..registerAdapter(Desktop463PlacedAbilityAdapter(), override: true)
      ..registerAdapter(Desktop463StrategyPageAdapter(), override: true)
      ..registerAdapter(Desktop463FolderAdapter(), override: true)
      ..registerAdapter(Desktop463FreeDrawingAdapter(), override: true)
      ..registerAdapter(Desktop463LineAdapter(), override: true)
      ..registerAdapter(Desktop463RectangleDrawingAdapter(), override: true)
      ..registerAdapter(Desktop463EllipseDrawingAdapter(), override: true);
  } finally {
    Logger.level = previousLevel;
  }
}

Uint8List _write(HiveImpl registry, Object value) {
  final writer = BinaryWriterImpl(registry)..write(value);
  return Uint8List.fromList(writer.toBytes());
}

T _read<T>(HiveImpl registry, Uint8List bytes) =>
    BinaryReaderImpl(bytes, registry).read() as T;

/// Saved by one build, opened by the other.
T _across<T extends Object>(HiveImpl from, HiveImpl to, T value) =>
    _read<T>(to, _write(from, value));

PlacedAbility _ability(
  String id, {
  AbilityVisualState visualState = const AbilityVisualState(),
}) {
  return PlacedAbility(
    id: id,
    data: AgentData.agents[AgentType.breach]!.abilities.first,
    position: const Offset(30, 40),
    visualState: visualState,
  );
}

StrategyPage _richPage() {
  const hidden = AbilityVisualState(showRangeFill: false);
  return StrategyPage(
    id: 'page-1',
    name: 'Page 1',
    drawingData: [
      Line(
        id: 'line-1',
        lineStart: const Offset(1, 2),
        lineEnd: const Offset(3, 4),
        colorValue: 0xFFFFFFFF,
        isDotted: false,
        hasArrow: false,
      ),
      EllipseDrawing(
        id: 'ellipse-1',
        start: const Offset(5, 6),
        end: const Offset(7, 8),
        colorValue: 0xFF22C55E,
        isDotted: true,
        hasArrow: false,
      ),
    ],
    agentData: [
      PlacedAgent(
        id: 'agent-plain',
        type: AgentType.breach,
        position: const Offset(10, 20),
        weapon: WeaponType.vandal,
      ),
      PlacedViewConeAgent(
        id: 'agent-cone',
        type: AgentType.killjoy,
        position: const Offset(30, 40),
        presetType: UtilityType.viewCone90,
        rotation: 1.2,
        length: 50,
        visionElevation: 1,
        weapon: WeaponType.operator,
      ),
      PlacedCircleAgent(
        id: 'agent-circle',
        type: AgentType.viper,
        position: const Offset(50, 60),
        diameterMeters: 12,
        colorValue: 0xFF3B82F6,
        opacityPercent: 45,
      ),
    ],
    abilityData: [_ability('ability-map', visualState: hidden)],
    textData: const [],
    imageData: const [],
    utilityData: const [],
    sortIndex: 0,
    isAttack: true,
    settings: StrategySettings(),
    lineUpGroups: [
      LineUpGroup(
        id: 'group-1',
        agent: PlacedAgent(
          id: 'lineup-agent',
          type: AgentType.breach,
          position: const Offset(70, 80),
          weapon: WeaponType.sheriff,
        ),
        items: [
          LineUpItem(
            id: 'item-1',
            ability: _ability('lineup-ability-1', visualState: hidden),
          ),
          LineUpItem(
            id: 'item-2',
            ability: _ability('lineup-ability-2'),
          ),
        ],
      ),
    ],
  );
}

Object? _plain(Object? json) => jsonDecode(jsonEncode(json));

void _expectSamePage(StrategyPage actual, StrategyPage expected) {
  expect(
    _plain(actual.toJson('strategy')),
    _plain(expected.toJson('strategy')),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final current = _currentRegistry();
  final desktop463 = _desktop463Registry();

  test('a page is saved byte for byte as desktop 4.6.3 saves it', () {
    final page = _richPage();
    expect(_write(current, page), _write(desktop463, page));
  });

  test('desktop 4.6.3 opens a page this build saved, whole', () {
    final page = _richPage();
    final opened = _across(current, desktop463, page);

    _expectSamePage(opened, page);
    expect(opened.drawingData.last, isA<EllipseDrawing>());
    expect(opened.agentData[1], isA<PlacedViewConeAgent>());
    expect(opened.agentData[2], isA<PlacedCircleAgent>());
    expect(
      opened.agentData.map((agent) => agent.weapon),
      [WeaponType.vandal, WeaponType.operator, WeaponType.none],
    );
    expect(opened.abilityData.single.visualState.showRangeFill, isFalse);
    expect(opened.lineUpOrigins.single.agent.weapon, WeaponType.sheriff);
  });

  test('what desktop 4.6.3 saves back, this build opens whole', () {
    final page = _richPage();
    final rolledBack = _across(current, desktop463, page);
    _expectSamePage(_across(desktop463, current, rolledBack), page);
  });

  test('every agent and ability survives a rollback', () {
    final page = StrategyPage(
      id: 'page-roster',
      name: 'Roster',
      drawingData: const [],
      agentData: [
        for (final type in AgentType.values)
          PlacedAgent(
            id: 'agent-${type.name}',
            type: type,
            position: const Offset(1, 1),
          ),
      ],
      abilityData: [
        for (final agent in AgentData.agents.values)
          for (var i = 0; i < agent.abilities.length; i++)
            PlacedAbility(
              id: 'ability-${agent.type.name}-$i',
              data: agent.abilities[i],
              position: const Offset(5, 5),
            ),
      ],
      textData: const [],
      imageData: const [],
      utilityData: const [],
      sortIndex: 0,
      isAttack: true,
      settings: StrategySettings(),
    );

    _expectSamePage(_across(current, desktop463, page), page);
  });

  test('folders keep their exact icon and color through a rollback', () {
    for (final iconId in [
      FolderIconRegistry.defaultId,
      FolderIconRegistry.sentinelRoleId,
      FolderIconRegistry.premierModeId,
    ]) {
      final folder = Folder(
        id: 'folder-$iconId',
        name: 'Execs',
        dateCreated: DateTime.utc(2026, 8, 30),
        iconId: iconId,
        color: FolderColor.custom,
        customColor: const Color(0xFF22C55E),
      );
      expect(_write(current, folder), _write(desktop463, folder));
      final opened = _across(current, desktop463, folder);
      expect(opened.iconId, iconId);
      expect(opened.customColor, const Color(0xFF22C55E));
    }
  });

  group('records earlier cloud builds wrote', () {
    BinaryReaderImpl fieldBag(Map<int, Object?> fields) {
      final writer = BinaryWriterImpl(current)..writeByte(fields.length);
      for (final MapEntry(:key, :value) in fields.entries) {
        writer
          ..writeByte(key)
          ..write(value);
      }
      return BinaryReaderImpl(Uint8List.fromList(writer.toBytes()), current);
    }

    test('ability visual state as primitives in fields 10-14', () {
      final ability = _ability('ability-old-cloud');
      final restored = PlacedAbilityAdapter().read(
        fieldBag({
          0: ability.data,
          1: ability.isAlly,
          2: ability.rotation,
          3: ability.id,
          4: false,
          5: ability.position,
          6: ability.length,
          7: ability.lineUpID,
          8: ability.armLengthsMeters,
          10: false,
          11: false,
          12: true,
          13: false,
          14: false,
        }),
      );

      expect(restored.visualState.showRangeOutline, isFalse);
      expect(restored.visualState.showRangeFill, isFalse);
      expect(restored.visualState.showInnerOutline, isTrue);
      expect(restored.visualState.showInnerFill, isFalse);
      expect(restored.visualState.showVisionCone, isFalse);
    });

    test('folders with the exact icon at 7 and the color at 8', () {
      final restored = FolderAdapter().read(
        fieldBag({
          0: 'Execs',
          1: 'folder-old-cloud',
          2: null,
          3: DateTime.utc(2026, 8, 30),
          4: Icons.folder,
          5: FolderColor.custom,
          6: const Color(0xFF22C55E),
          7: FolderIconRegistry.sentinelRoleId,
          8: 0xFF22C55E,
        }),
      );

      expect(restored.iconId, FolderIconRegistry.sentinelRoleId);
      expect(restored.customColor, const Color(0xFF22C55E));
    });
  });
}
