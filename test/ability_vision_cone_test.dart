import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/agents.dart';

void main() {
  group('AbilityVisionConeSpec', () {
    test('only the four directional abilities have vision cones', () {
      final expected = <(AgentType, int), double>{
        (AgentType.killjoy, 2): 100,
        (AgentType.cypher, 2): 103,
        (AgentType.raze, 0): 40,
        (AgentType.gekko, 1): 40,
      };

      for (final agent in AgentData.agents.values) {
        for (final ability in agent.abilities) {
          final spec = AbilityVisionConeSpec.forAbility(ability);
          final key = (ability.type, ability.index);
          expect(
            spec?.angleDegrees,
            expected[key],
            reason: '${agent.name} ${ability.name}',
          );
        }
      }
    });

    test('Boom Bot and Wingman default to and clamp at 15 meters', () {
      for (final (agentType, index) in [
        (AgentType.raze, 0),
        (AgentType.gekko, 1),
      ]) {
        final ability = AgentData.agents[agentType]!.abilities[index];
        final spec = AbilityVisionConeSpec.forAbility(ability)!;
        final maximum = spec.maximumLength(1);

        expect(spec.maxRangeMeters, 15);
        expect(spec.resolveLength(storedLength: 0, mapScale: 1), maximum);
        expect(spec.resolveLength(storedLength: 10000, mapScale: 1), maximum);
      }
    });

    test('Turret and Spycam retain adjustable line-of-sight range', () {
      for (final (agentType, index) in [
        (AgentType.killjoy, 2),
        (AgentType.cypher, 2),
      ]) {
        final ability = AgentData.agents[agentType]!.abilities[index];
        final spec = AbilityVisionConeSpec.forAbility(ability)!;

        expect(spec.maxRangeMeters, isNull);
        expect(spec.resolveLength(storedLength: 75, mapScale: 1), 75);
      }
    });
  });
}
