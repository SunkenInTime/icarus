import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/agent_provider.dart';

void main() {
  group('PlacedAgentNode serialization', () {
    test('round-trips plain, view-cone, and circle agents', () {
      final plain = PlacedAgent(
        id: 'plain-agent',
        type: AgentType.jett,
        position: const Offset(10, 20),
        isAlly: false,
        lineUpID: 'lineup-1',
        state: AgentState.dead,
      )..isDeleted = true;
      final viewCone = PlacedViewConeAgent(
        id: 'viewcone-agent',
        type: AgentType.sova,
        position: const Offset(30, 40),
        presetType: UtilityType.viewCone90,
        rotation: 1.25,
        length: 42,
        state: AgentState.dead,
      );
      final circle = PlacedCircleAgent(
        id: 'circle-agent',
        type: AgentType.viper,
        position: const Offset(50, 60),
        diameterMeters: 12.5,
        colorValue: 0xFF00FF00,
        opacityPercent: 35,
      );

      final encoded = AgentProvider.objectToJson([plain, viewCone, circle]);
      final decoded = jsonDecode(encoded) as List<dynamic>;
      final restored = AgentProvider.fromJson(encoded);

      expect(decoded[0]['kind'], PlacedAgentNode.plainKind);
      expect(decoded[1]['kind'], PlacedAgentNode.viewConeKind);
      expect(decoded[2]['kind'], PlacedAgentNode.circleKind);

      expect(restored[0], isA<PlacedAgent>());
      expect(restored[1], isA<PlacedViewConeAgent>());
      expect(restored[2], isA<PlacedCircleAgent>());

      final restoredPlain = restored[0] as PlacedAgent;
      expect(restoredPlain.lineUpID, 'lineup-1');
      expect(restoredPlain.state, AgentState.dead);
      expect(restoredPlain.isDeleted, isTrue);

      final restoredViewCone = restored[1] as PlacedViewConeAgent;
      expect(restoredViewCone.presetType, UtilityType.viewCone90);
      expect(restoredViewCone.rotation, 1.25);
      expect(restoredViewCone.length, 42);

      final restoredCircle = restored[2] as PlacedCircleAgent;
      expect(restoredCircle.diameterMeters, 12.5);
      expect(restoredCircle.colorValue, 0xFF00FF00);
      expect(restoredCircle.opacityPercent, 35);
    });

    test('missing kind defaults to plain agent and accepts legacy enum ints', () {
      final restored = PlacedAgentNode.fromJson({
        'id': 'legacy-agent',
        'type': AgentType.fade.index,
        'position': {'dx': 100, 'dy': 200},
        'isAlly': false,
        'state': AgentState.dead.index,
        'lineUpID': 'legacy-lineup',
      });

      expect(restored, isA<PlacedAgent>());

      final agent = restored as PlacedAgent;
      expect(agent.type, AgentType.fade);
      expect(agent.position, const Offset(100, 200));
      expect(agent.isAlly, isFalse);
      expect(agent.state, AgentState.dead);
      expect(agent.lineUpID, 'legacy-lineup');
    });

    test('legacy view-cone payload accepts numeric enums', () {
      final restored = PlacedAgentNode.fromJson({
        'kind': PlacedAgentNode.viewConeKind,
        'id': 'legacy-viewcone',
        'type': AgentType.sova.index,
        'position': {'dx': 12, 'dy': 34},
        'presetType': UtilityType.viewCone180.index,
        'rotation': 0.75,
        'length': 55,
        'state': AgentState.none.index,
      });

      expect(restored, isA<PlacedViewConeAgent>());

      final agent = restored as PlacedViewConeAgent;
      expect(agent.type, AgentType.sova);
      expect(agent.presetType, UtilityType.viewCone180);
      expect(agent.rotation, 0.75);
      expect(agent.length, 55);
      expect(agent.state, AgentState.none);
    });
  });

  test('LineUp serialization remains plain-agent-only', () {
    final lineUp = LineUp(
      id: 'lineup-1',
      agent: PlacedAgent(
        id: 'lineup-agent',
        type: AgentType.jett,
        position: const Offset(5, 6),
      ),
      ability: PlacedAbility(
        id: 'lineup-ability',
        data: AgentData.agents[AgentType.jett]!.abilities.first,
        position: const Offset(7, 8),
      ),
      youtubeLink: 'https://example.com',
      images: const [],
      notes: 'test',
    );

    final encoded = LineUpProvider.objectToJson([lineUp]);
    final decoded = jsonDecode(encoded) as List<dynamic>;
    final restored = LineUpProvider.fromJson(encoded).single;

    expect(decoded.single['agent']['kind'], PlacedAgentNode.plainKind);
    expect(restored.agent, isA<PlacedAgent>());
    expect(restored.agent.lineUpID, isNull);
  });
}
