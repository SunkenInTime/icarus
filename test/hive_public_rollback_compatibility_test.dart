import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

void _ensureAdaptersRegistered() {
  if (!Hive.isAdapterRegistered(strategyPageAdapterTypeId)) {
    registerIcarusAdapters(Hive);
  }
}

Uint8List _writeAdapter<T>(TypeAdapter<T> adapter, T value) {
  _ensureAdaptersRegistered();
  final writer = BinaryWriterImpl(Hive);
  adapter.write(writer, value);
  return Uint8List.fromList(writer.toBytes());
}

Map<int, dynamic> _readFields(Uint8List bytes) {
  final reader = BinaryReaderImpl(bytes, Hive);
  final numOfFields = reader.readByte();
  return <int, dynamic>{
    for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
  };
}

BinaryReaderImpl _fieldReader(Map<int, dynamic> fields) {
  _ensureAdaptersRegistered();
  final writer = BinaryWriterImpl(Hive)..writeByte(fields.length);
  for (final entry in fields.entries) {
    writer
      ..writeByte(entry.key)
      ..write(entry.value);
  }
  return BinaryReaderImpl(Uint8List.fromList(writer.toBytes()), Hive);
}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('placed abilities persist visual state as rollback-safe booleans', () {
    const hidden = AbilityVisualState(
      showRangeOutline: false,
      showRangeFill: false,
      showInnerOutline: false,
      showInnerFill: false,
      showVisionCone: false,
    );
    final ability = _ability('ability-current', visualState: hidden);
    final fields = _readFields(
      _writeAdapter(PlacedAbilityAdapter(), ability),
    );

    expect(fields[9], isNull);
    expect(fields[10], isFalse);
    expect(fields[11], isFalse);
    expect(fields[12], isFalse);
    expect(fields[13], isFalse);
    expect(fields[14], isFalse);
    expect(fields.values.whereType<AbilityVisualState>(), isEmpty);

    final restored = PlacedAbilityAdapter().read(
      _fieldReader(<int, dynamic>{
        0: ability.data,
        1: ability.isAlly,
        2: ability.rotation,
        3: 'ability-old-cloud',
        4: false,
        5: ability.position,
        6: ability.length,
        7: ability.lineUpID,
        8: ability.armLengthsMeters,
        9: hidden,
      }),
    );

    expect(restored.visualState.showRangeOutline, isFalse);
    expect(restored.visualState.showRangeFill, isFalse);
    expect(restored.visualState.showInnerOutline, isFalse);
    expect(restored.visualState.showInnerFill, isFalse);
    expect(restored.visualState.showVisionCone, isFalse);
  });

  test('folders retain legacy icon and color fields', () {
    final folder = Folder(
      id: 'folder-1',
      name: 'Execs',
      dateCreated: DateTime.utc(2026, 8, 30),
      iconId: FolderIconRegistry.defaultId,
      color: FolderColor.custom,
      customColor: const Color(0xFF22C55E),
    );
    final adapter = FolderAdapter();
    final bytes = _writeAdapter(adapter, folder);
    final fields = _readFields(bytes);

    expect(fields[4], isA<IconData>());
    expect(fields[6], const Color(0xFF22C55E));
    expect(fields[7], FolderIconRegistry.defaultId);
    expect(fields[8], 0xFF22C55E);

    final restored = adapter.read(BinaryReaderImpl(bytes, Hive));
    expect(restored.iconId, FolderIconRegistry.defaultId);
    expect(restored.customColor, const Color(0xFF22C55E));
  });

  test('strategy pages expose only 3.2.3 types in legacy fields', () {
    const hidden = AbilityVisualState(showRangeFill: false);
    final page = StrategyPage(
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
        ),
        PlacedViewConeAgent(
          id: 'agent-cone',
          type: AgentType.killjoy,
          position: const Offset(30, 40),
          presetType: UtilityType.viewCone90,
          rotation: 1.2,
          length: 50,
          visionElevation: 1,
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
    final adapter = StrategyPageAdapter();
    final bytes = _writeAdapter(adapter, page);
    final fields = _readFields(bytes);

    expect((fields[3] as List).map((drawing) => drawing.id), ['line-1']);
    expect((fields[4] as List).map((agent) => agent.id), ['agent-plain']);
    expect(fields[12], isNull);
    expect(fields[13], isA<String>());
    expect(fields[15], isA<String>());
    expect(fields[16], isA<String>());

    final restored = adapter.read(BinaryReaderImpl(bytes, Hive));
    expect(restored.drawingData.map((drawing) => drawing.id),
        ['line-1', 'ellipse-1']);
    expect(restored.drawingData.last, isA<EllipseDrawing>());
    expect(restored.agentData.map((agent) => agent.id),
        ['agent-plain', 'agent-cone', 'agent-circle']);
    expect(restored.agentData[1], isA<PlacedViewConeAgent>());
    expect(restored.agentData[2], isA<PlacedCircleAgent>());
    expect(restored.abilityData.single.visualState.showRangeFill, isFalse);
    expect(restored.lineUpGroups, hasLength(1));
    expect(
      restored.lineUpGroups.single.items.map((item) => item.id),
      ['item-1', 'item-2'],
    );
    expect(
      restored
          .lineUpGroups.single.items.first.ability.visualState.showRangeFill,
      isFalse,
    );
  });
}
