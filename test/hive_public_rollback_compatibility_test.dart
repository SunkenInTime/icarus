import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:hive_ce/src/hive_impl.dart';
import 'package:hive_ce/src/util/logger.dart';
import 'package:hive_ce_flutter/adapters.dart'
    show ColorAdapter, TimeOfDayAdapter;
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

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

/// Any record 3.2.3 decodes: its class adapters all read a field bag.
class _PublicRecord {
  const _PublicRecord(this.typeId, this.fields);

  final int typeId;
  final Map<int, dynamic> fields;
}

class _PublicRecordAdapter extends TypeAdapter<_PublicRecord> {
  const _PublicRecordAdapter(this.typeId);

  @override
  final int typeId;

  @override
  _PublicRecord read(BinaryReader reader) {
    final count = reader.readByte();
    return _PublicRecord(typeId, {
      for (var i = 0; i < count; i++) reader.readByte(): reader.read(),
    });
  }

  @override
  void write(BinaryWriter writer, _PublicRecord obj) =>
      throw UnsupportedError('read only');
}

/// 3.2.3's generated enum adapters read one byte and default unknown values.
class _PublicEnumAdapter extends TypeAdapter<int> {
  const _PublicEnumAdapter(this.typeId);

  @override
  final int typeId;

  @override
  int read(BinaryReader reader) => reader.readByte();

  @override
  void write(BinaryWriter writer, int obj) =>
      throw UnsupportedError('read only');
}

/// 3.2.3's AgentType adapter, from the tag: bytes 0-27 in this order, and
/// every other byte decodes as Jett.
const _publicAgentOrder = [
  'jett', 'raze', 'pheonix', 'astra', 'clove', 'breach', 'iso', 'viper', //
  'deadlock', 'yoru', 'sova', 'skye', 'kayo', 'killjoy', 'brimstone',
  'cypher', 'chamber', 'fade', 'gekko', 'harbor', 'neon', 'omen', 'reyna',
  'sage', 'vyse', 'tejo', 'waylay', 'veto',
];

/// Ability list lengths in 3.2.3's AgentData table: four per agent, plus
/// Astra's Astral Form star at index 4.
int _publicAbilityCount(String agent) => agent == 'astra' ? 5 : 4;

class _PublicAgentTypeAdapter extends TypeAdapter<String> {
  const _PublicAgentTypeAdapter();

  @override
  final int typeId = 7;

  @override
  String read(BinaryReader reader) {
    final byte = reader.readByte();
    return byte < _publicAgentOrder.length ? _publicAgentOrder[byte] : 'jett';
  }

  @override
  void write(BinaryWriter writer, String obj) =>
      throw UnsupportedError('read only');
}

/// An ability as 3.2.3 resolved it.
class _PublicAbility {
  const _PublicAbility(this.agent, this.index);

  final String agent;
  final int index;
}

/// 3.2.3's AbilityInfoAdapter: `AgentData.agents[agentType]?.abilities[index]`
/// followed by `ability!`. An index past the agent's list throws RangeError
/// and fails the whole strategy record.
class _PublicAbilityInfoAdapter extends TypeAdapter<_PublicAbility> {
  const _PublicAbilityInfoAdapter();

  @override
  final int typeId = 9;

  @override
  _PublicAbility read(BinaryReader reader) {
    final count = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < count; i++) reader.readByte(): reader.read(),
    };
    final agent = fields[0] as String;
    final index = fields[1] as int;
    final abilities = List.generate(_publicAbilityCount(agent), (i) => i);
    return _PublicAbility(agent, abilities[index]);
  }

  @override
  void write(BinaryWriter writer, _PublicAbility obj) =>
      throw UnsupportedError('read only');
}

/// A registry holding exactly the adapters the public 3.2.3 build registers:
/// its generated types (0-8, 11-28), AbilityInfo (9) with its real lookup,
/// the real AgentType decode, and the Color (200)
/// and TimeOfDay (201) adapters hive_ce_flutter 2.3.4 adds in initFlutter.
/// Decoding with it throws on any typeId that build cannot read.
HiveImpl _publicBuildRegistry() {
  const enumTypeIds = {6, 16, 19, 23, 25};
  const recordTypeIds = {
    0, 1, 2, 3, 4, 5, 8, 11, 12, 13, 14, 15, 17, 18, 20, 21, 22, //
    24, 26, 27, 28,
  };
  final registry = HiveImpl();
  // Many typeIds share one Dart type here; hive_ce warns about that on
  // registration, which is expected for a read-only emulation.
  final previousLevel = Logger.level;
  Logger.level = LoggerLevel.error;
  try {
    for (final typeId in enumTypeIds) {
      registry.registerAdapter(_PublicEnumAdapter(typeId));
    }
    for (final typeId in recordTypeIds) {
      registry.registerAdapter(_PublicRecordAdapter(typeId));
    }
    registry
      ..registerAdapter(const _PublicAgentTypeAdapter())
      ..registerAdapter(const _PublicAbilityInfoAdapter())
      ..registerAdapter(ColorAdapter(typeId: 200))
      ..registerAdapter(const TimeOfDayAdapter(typeId: 201));
  } finally {
    Logger.level = previousLevel;
  }
  return registry;
}

/// Reads a record's field bag the way 3.2.3 would.
Map<int, dynamic> _readAsPublicBuild(Uint8List bytes) {
  final reader = BinaryReaderImpl(bytes, _publicBuildRegistry());
  final count = reader.readByte();
  return <int, dynamic>{
    for (var i = 0; i < count; i++) reader.readByte(): reader.read(),
  };
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
    final page = _richPage();
    final adapter = StrategyPageAdapter();
    final bytes = _writeAdapter(adapter, page);
    final fields = _readFields(bytes);

    expect((fields[3] as List).map((drawing) => drawing.id), ['line-1']);
    expect((fields[4] as List).map((agent) => agent.id), ['agent-plain']);
    expect(fields[12], isNull);
    expect(fields[13], isA<String>());
    // 15-17 hold the lineup graph for desktop 4.x readers; 3.2.3 cannot
    // decode those types, so the mirrors live above them.
    expect(fields[15], isNull);
    expect(fields[16], isNull);
    expect(fields[17], isNull);
    expect(fields[18], isA<String>());
    expect(fields[19], isA<String>());
    expect(fields[20], isA<String>());

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

  test('agents without a firearm write exactly the 3.2.3 record', () {
    final plain = PlacedAgent(
      id: 'agent-plain',
      type: AgentType.jett,
      position: const Offset(1, 2),
    );
    final plainFields = _readFields(_writeAdapter(PlacedAgentAdapter(), plain));
    expect(plainFields.keys, [0, 1, 2, 3, 4, 5, 6]);

    final armed = plain.copyWith(weapon: WeaponType.ghost);
    final armedBytes = _writeAdapter(PlacedAgentAdapter(), armed);
    expect(_readFields(armedBytes)[7], WeaponType.ghost);
    expect(
      PlacedAgentAdapter().read(BinaryReaderImpl(armedBytes, Hive)).weapon,
      WeaponType.ghost,
      reason: 'desktop 4.6 libraries always carry field 7',
    );
  });

  test('the 3.2.3 registry rejects types that build never had', () {
    final armed = PlacedAgent(
      id: 'agent-armed',
      type: AgentType.jett,
      position: const Offset(1, 2),
      weapon: WeaponType.ghost,
    );
    expect(
      () => _readAsPublicBuild(_writeAdapter(PlacedAgentAdapter(), armed)),
      throwsA(isA<HiveError>()),
    );
  });

  test('3.2.3 can decode every field of a page written by this build', () {
    final page = _richPage();
    final fields = _readAsPublicBuild(
      _writeAdapter(StrategyPageAdapter(), page),
    );

    expect(fields.keys.toSet(), {
      0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 18, 19, 20, //
    });
    final legacyAgents = (fields[4] as List).cast<_PublicRecord>();
    expect(legacyAgents.map((agent) => agent.fields[2]), ['agent-plain']);
    expect(legacyAgents.single.fields.containsKey(7), isFalse);
    final legacyLineUps = (fields[11] as List).cast<_PublicRecord>();
    expect(legacyLineUps, isNotEmpty);
    for (final lineUp in legacyLineUps) {
      final agent = lineUp.fields[1] as _PublicRecord;
      expect(agent.fields.containsKey(7), isFalse);
    }
  });

  test('3.2.3 can decode a whole strategy written by this build', () {
    final strategy = StrategyData(
      id: 'strategy-1',
      name: 'Rollback',
      mapData: MapValue.ascent,
      versionNumber: 100,
      lastEdited: DateTime.utc(2026, 9, 24),
      folderID: null,
      pages: [_richPage()],
    );
    final fields = _readAsPublicBuild(
      _writeAdapter(StrategyDataAdapter(), strategy),
    );
    final pages = (fields.values.whereType<List>())
        .expand((list) => list)
        .whereType<_PublicRecord>()
        .where((record) => record.typeId == strategyPageAdapterTypeId);
    expect(pages, hasLength(1));
  });

  test('this build restores weapons that the legacy slots dropped', () {
    final page = _richPage();
    final restored = StrategyPageAdapter().read(
      BinaryReaderImpl(_writeAdapter(StrategyPageAdapter(), page), Hive),
    );
    expect(
      restored.agentData.map((agent) => agent.weapon),
      [WeaponType.vandal, WeaponType.operator, WeaponType.none],
    );
    expect(
      restored.lineUpOrigins.single.agent.weapon,
      WeaponType.sheriff,
    );
  });

  group('agents and abilities newer than 3.2.3', () {
    PlacedAbility abilityOf(AgentType type, int index) => PlacedAbility(
          id: 'ability-${type.name}-$index',
          data: AgentData.agents[type]!.abilities[index],
          position: const Offset(5, 5),
        );

    test('the 3.2.3 lookup crashes on a Miks ultimate written raw', () {
      final ult = abilityOf(AgentType.miks, 4);
      expect(
        () => _readAsPublicBuild(_writeAdapter(PlacedAbilityAdapter(), ult)),
        throwsA(isA<RangeError>()),
      );
    });

    test('every legacy slot resolves to the right agent or is left out', () {
      final abilities = [
        for (final agent in AgentData.agents.values)
          for (var i = 0; i < agent.abilities.length; i++)
            abilityOf(agent.type, i),
      ];
      final agents = [
        for (final type in AgentType.values)
          PlacedAgent(
            id: 'agent-${type.name}',
            type: type,
            position: const Offset(1, 1),
          ),
      ];
      final graph = LineUpGraph(
        origins: [
          for (final agent in agents)
            LineUpOrigin(id: 'origin-${agent.type.name}', agent: agent),
        ],
        landings: [
          for (final ability in abilities)
            LineUpLanding(id: 'landing-${ability.id}', ability: ability),
        ],
        links: [
          for (final ability in abilities)
            LineUpLink(
              id: 'link-${ability.id}',
              originId: 'origin-${ability.data.type.name}',
              landingId: 'landing-${ability.id}',
            ),
        ],
      );
      final page = StrategyPage(
        id: 'page-roster',
        name: 'Roster',
        drawingData: const [],
        agentData: agents,
        abilityData: abilities,
        textData: const [],
        imageData: const [],
        utilityData: const [],
        sortIndex: 0,
        isAttack: true,
        settings: StrategySettings(),
        lineUpOrigins: graph.origins,
        lineUpLandings: graph.landings,
        lineUpLinks: graph.links,
      );
      final bytes = _writeAdapter(StrategyPageAdapter(), page);

      final fields = _readAsPublicBuild(bytes);

      String sourceAgentOf(String id) => id.split('-')[1];
      final legacyAgents = (fields[4] as List).cast<_PublicRecord>();
      for (final agent in legacyAgents) {
        final id = agent.fields[2] as String;
        expect(agent.fields[0], sourceAgentOf(id), reason: id);
      }
      expect(
        legacyAgents.map((agent) => agent.fields[0]).toSet(),
        _publicAgentOrder.toSet(),
      );
      final legacyAbilities = (fields[5] as List).cast<_PublicRecord>();
      for (final ability in legacyAbilities) {
        final id = ability.fields[3] as String;
        final resolved = ability.fields[0] as _PublicAbility;
        expect(resolved.agent, sourceAgentOf(id), reason: id);
      }
      expect(
        legacyAbilities.length,
        _publicAgentOrder.map(_publicAbilityCount).reduce((a, b) => a + b),
      );
      final legacyLineUps = (fields[11] as List).cast<_PublicRecord>();
      expect(legacyLineUps, hasLength(legacyAbilities.length));
      for (final lineUp in legacyLineUps) {
        final agent = lineUp.fields[1] as _PublicRecord;
        final ability = lineUp.fields[2] as _PublicRecord;
        final resolved = ability.fields[0] as _PublicAbility;
        expect(agent.fields[0], resolved.agent);
      }

      // This build keeps every agent, ability and lineup through the mirrors.
      final restored =
          StrategyPageAdapter().read(BinaryReaderImpl(bytes, Hive));
      expect(
        restored.agentData.map((agent) => agent.id),
        agents.map((agent) => agent.id),
      );
      expect(
        restored.abilityData.map((ability) => ability.id),
        abilities.map((ability) => ability.id),
      );
      expect(
        restored.abilityData
            .firstWhere((ability) => ability.id == 'ability-miks-4')
            .data
            .index,
        4,
      );
      expect(restored.lineUpLinks, hasLength(abilities.length));
    });
  });
}
