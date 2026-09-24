import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

// Desktop 4.6.2+102 shipped these numbers to users. They must never move:
// a renumbered adapter silently misreads every library written before it.

void _ensureAdaptersRegistered() {
  if (!Hive.isAdapterRegistered(strategyPageAdapterTypeId)) {
    registerIcarusAdapters(Hive);
  }
}

Uint8List _write<T>(TypeAdapter<T> adapter, T value) {
  _ensureAdaptersRegistered();
  final writer = BinaryWriterImpl(Hive);
  adapter.write(writer, value);
  return Uint8List.fromList(writer.toBytes());
}

Map<int, dynamic> _fields(Uint8List bytes) {
  final reader = BinaryReaderImpl(bytes, Hive);
  final count = reader.readByte();
  return <int, dynamic>{
    for (var i = 0; i < count; i++) reader.readByte(): reader.read(),
  };
}

/// Encodes a field map exactly as a generated Hive adapter lays it out.
Uint8List _encodeFields(Map<int, dynamic> fields) {
  _ensureAdaptersRegistered();
  final writer = BinaryWriterImpl(Hive)..writeByte(fields.length);
  for (final entry in fields.entries) {
    writer
      ..writeByte(entry.key)
      ..write(entry.value);
  }
  return Uint8List.fromList(writer.toBytes());
}

StrategyPage _read(Uint8List bytes) =>
    StrategyPageAdapter().read(BinaryReaderImpl(bytes, Hive));

PlacedAbility _ability(String id, Offset position) => PlacedAbility(
      id: id,
      data: AgentData.agents[AgentType.sova]!.abilities.first,
      position: position,
    );

/// Two origins share one landing (fan-in), and the second origin also fans
/// out to a second landing.
LineUpGraph _fanInGraph() {
  return LineUpGraph(
    origins: [
      LineUpOrigin(
        id: 'origin-a',
        agent: PlacedAgent(
          id: 'origin-a',
          type: AgentType.sova,
          position: const Offset(100, 200),
          lineUpID: 'origin-a',
          weapon: WeaponType.vandal,
        ),
      ),
      LineUpOrigin(
        id: 'origin-b',
        agent: PlacedAgent(
          id: 'origin-b',
          type: AgentType.sova,
          position: const Offset(300, 400),
          lineUpID: 'origin-b',
          weapon: WeaponType.operator,
        ),
      ),
    ],
    landings: [
      LineUpLanding(
        id: 'landing-shared',
        ability: _ability('landing-shared', const Offset(500, 500)),
      ),
      LineUpLanding(
        id: 'landing-solo',
        ability: _ability('landing-solo', const Offset(600, 650)),
      ),
    ],
    links: [
      LineUpLink(
        id: 'link-a',
        originId: 'origin-a',
        landingId: 'landing-shared',
        name: 'A main dart',
        youtubeLink: 'https://youtu.be/a',
        notes: 'jump throw',
        images: [SimpleImageData(id: 'image-a', fileExtension: '.png')],
      ),
      LineUpLink(
        id: 'link-b',
        originId: 'origin-b',
        landingId: 'landing-shared',
        name: 'B long dart',
      ),
      LineUpLink(
        id: 'link-c',
        originId: 'origin-b',
        landingId: 'landing-solo',
      ),
    ],
  );
}

List<DrawingElement> _drawings() => [
      Line(
        id: 'line-1',
        lineStart: const Offset(1, 2),
        lineEnd: const Offset(3, 4),
        colorValue: 0xFFFFFFFF,
        isDotted: false,
        hasArrow: true,
        boundingBox:
            BoundingBox(min: const Offset(1, 2), max: const Offset(3, 4)),
      ),
      EllipseDrawing(
        id: 'ellipse-1',
        start: const Offset(5, 6),
        end: const Offset(7, 8),
        colorValue: 0xFF22C55E,
        isDotted: true,
        hasArrow: false,
        boundingBox:
            BoundingBox(min: const Offset(5, 6), max: const Offset(7, 8)),
      ),
    ];

List<PlacedAgentNode> _agents() => [
      PlacedAgent(
        id: 'agent-plain',
        type: AgentType.jett,
        position: const Offset(10, 20),
        weapon: WeaponType.sheriff,
      ),
      PlacedViewConeAgent(
        id: 'agent-cone',
        type: AgentType.killjoy,
        position: const Offset(30, 40),
        presetType: UtilityType.viewCone90,
        rotation: 1.2,
        length: 50,
        visionElevation: 1,
        weapon: WeaponType.phantom,
      ),
      PlacedCircleAgent(
        id: 'agent-circle',
        type: AgentType.viper,
        position: const Offset(50, 60),
        diameterMeters: 12,
        colorValue: 0xFF3B82F6,
        opacityPercent: 45,
        weapon: WeaponType.judge,
      ),
    ];

StrategyPage _page({LineUpGraph? graph}) {
  final lineUps = graph ?? _fanInGraph();
  return StrategyPage(
    id: 'page-1',
    name: 'Page 1',
    isAutoNamed: false,
    drawingData: _drawings(),
    agentData: _agents(),
    abilityData: [_ability('ability-map', const Offset(70, 80))],
    textData: const [],
    imageData: const [],
    utilityData: const [],
    sortIndex: 2,
    isAttack: false,
    settings: StrategySettings(),
    lineUpOrigins: lineUps.origins,
    lineUpLandings: lineUps.landings,
    lineUpLinks: lineUps.links,
  );
}

String _json(Object? value) => jsonEncode(value);

void _expectSameGraph(LineUpGraph actual, LineUpGraph expected) {
  expect(_json(actual.toJson()), _json(expected.toJson()));
}

void _expectSameContent(StrategyPage actual, StrategyPage expected) {
  expect(actual.id, expected.id);
  expect(actual.name, expected.name);
  expect(actual.isAutoNamed, expected.isAutoNamed);
  expect(actual.sortIndex, expected.sortIndex);
  expect(actual.isAttack, expected.isAttack);
  expect(
    DrawingProvider.objectToJson(actual.drawingData),
    DrawingProvider.objectToJson(expected.drawingData),
  );
  expect(
    AgentProvider.objectToJson(actual.agentData),
    AgentProvider.objectToJson(expected.agentData),
  );
  expect(
    actual.abilityData.map((ability) => ability.id),
    expected.abilityData.map((ability) => ability.id),
  );
  _expectSameGraph(actual.lineUpGraph, expected.lineUpGraph);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shipped Hive typeIds are fixed', () {
    expect(PlacedAgentAdapter().typeId, 2);
    expect(PlacedAbilityAdapter().typeId, 3);
    expect(StrategyPageAdapter().typeId, 20);
    expect(LineUpAdapter().typeId, 21);
    expect(SimpleImageDataAdapter().typeId, 22);
    expect(PlacedViewConeAgentAdapter().typeId, 29);
    expect(PlacedCircleAgentAdapter().typeId, 30);
    expect(AbilityVisualStateAdapter().typeId, 32);
    expect(LineUpGroupAdapter().typeId, 33);
    expect(LineUpItemAdapter().typeId, 34);
    expect(LineUpOriginAdapter().typeId, 35);
    expect(LineUpLandingAdapter().typeId, 36);
    expect(LineUpLinkAdapter().typeId, 37);
    expect(WeaponTypeAdapter().typeId, 38);
  });

  test('cloud-only adapters sit above the shipped range', () {
    expect(CloudMediaJobStateAdapter().typeId, 39);
  });

  test('agent weapons use the shipped field slots', () {
    final agents = _agents();
    expect(
      _fields(_write(PlacedAgentAdapter(), agents[0] as PlacedAgent))[7],
      WeaponType.sheriff,
    );
    expect(
      _fields(
        _write(PlacedViewConeAgentAdapter(), agents[1] as PlacedViewConeAgent),
      )[10],
      WeaponType.phantom,
    );
    expect(
      _fields(
        _write(PlacedCircleAgentAdapter(), agents[2] as PlacedCircleAgent),
      )[9],
      WeaponType.judge,
    );
  });

  test('lineup graph types use the shipped field slots', () {
    final graph = _fanInGraph();
    final origin = _fields(_write(LineUpOriginAdapter(), graph.origins.first));
    expect(origin[0], 'origin-a');
    expect(origin[1], isA<PlacedAgent>());
    final landing =
        _fields(_write(LineUpLandingAdapter(), graph.landings.first));
    expect(landing[0], 'landing-shared');
    expect(landing[1], isA<PlacedAbility>());
    final link = _fields(_write(LineUpLinkAdapter(), graph.links.first));
    expect(link[0], 'link-a');
    expect(link[1], 'origin-a');
    expect(link[2], 'landing-shared');
    expect(link[3], 'A main dart');
    expect(link[4], 'https://youtu.be/a');
    expect(link[5], 'jump throw');
    expect(link[6], isA<List>());
  });

  group('StrategyPage adapter', () {
    test('writes the graph into a JSON mirror and round-trips losslessly', () {
      final page = _page();
      final bytes = _write(StrategyPageAdapter(), page);
      final fields = _fields(bytes);

      // Slots older readers decode must only hold types they know.
      expect(fields.keys.toSet(), {
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 18, 19, //
      });
      expect(fields[13], isA<String>());
      expect(fields[18], isA<String>());
      expect(fields[19], isA<String>());
      expect(
        _json(jsonDecode(fields[19] as String)),
        _json(page.lineUpGraph.toJson()),
      );

      final restored = _read(bytes);
      _expectSameContent(restored, page);
      final shared = restored.lineUpGraph.links
          .where((link) => link.landingId == 'landing-shared')
          .map((link) => link.originId);
      expect(shared, ['origin-a', 'origin-b']);
      expect(
        restored.lineUpOrigins.map((origin) => origin.agent.weapon),
        [WeaponType.vandal, WeaponType.operator],
      );
      expect(restored.agentData[1], isA<PlacedViewConeAgent>());
      expect(restored.drawingData.last, isA<EllipseDrawing>());
    });

    test('reads pages written by desktop 4.6 (graph at 15-17, no mirrors)', () {
      final page = _page();
      // Field layout of the generated StrategyPageAdapter that shipped in
      // desktop-stable-v4.6.2+102.
      final bytes = _encodeFields({
        0: page.id,
        1: page.sortIndex,
        2: page.name,
        3: page.drawingData,
        4: page.agentData,
        5: page.abilityData,
        6: page.textData,
        7: page.imageData,
        8: page.utilityData,
        9: page.isAttack,
        10: page.settings,
        // ignore: deprecated_member_use_from_same_package
        11: page.lineUps,
        // ignore: deprecated_member_use_from_same_package
        12: page.lineUpGroups,
        14: page.isAutoNamed,
        15: page.lineUpOrigins,
        16: page.lineUpLandings,
        17: page.lineUpLinks,
      });

      final restored = _read(bytes);
      _expectSameContent(restored, page);

      // Saving it again through the merged adapter loses nothing either.
      _expectSameContent(_read(_write(StrategyPageAdapter(), restored)), page);
    });

    test('reads pages written by cloud builds before the main merge', () {
      final page = _page(
        graph: LineUpGraph.fromLegacyGroups(_fanInGraph().toLegacyGroups()),
      );
      final bytes = _encodeFields({
        0: page.id,
        1: page.sortIndex,
        2: page.name,
        3: const <DrawingElement>[],
        4: const <PlacedAgent>[],
        5: page.abilityData,
        6: page.textData,
        7: page.imageData,
        8: page.utilityData,
        9: page.isAttack,
        10: page.settings,
        11: const <LineUp>[],
        13: AgentProvider.objectToJson(page.agentData),
        14: page.isAutoNamed,
        15: DrawingProvider.objectToJson(page.drawingData),
        16: jsonEncode(
          page.lineUpGraph
              .toLegacyGroups()
              .map((group) => cloudLineupPayload(group))
              .toList(),
        ),
      });

      _expectSameContent(_read(bytes), page);
    });
  });
}
