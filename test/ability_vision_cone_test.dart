import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_vision_cone_composite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

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

    test('fixed-range cones persist map-independent lengths', () {
      final ability = AgentData.agents[AgentType.raze]!.abilities.first;
      final spec = AbilityVisionConeSpec.forAbility(ability)!;
      const mapScale = 0.5;
      final renderedMaximum = spec.maximumLength(mapScale);
      final stored = spec.storedLengthFromRendered(
        renderedLength: renderedMaximum,
        mapScale: mapScale,
      );

      expect(stored, renderedMaximum / mapScale);
      expect(
        spec.resolveLength(storedLength: stored, mapScale: mapScale),
        renderedMaximum,
      );
      const otherMapScale = 1.0;
      expect(
        spec.resolveLength(storedLength: stored, mapScale: otherMapScale),
        spec.maximumLength(otherMapScale),
      );
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

    testWidgets('counter-rotation keeps the drag correction rotation-invariant',
        (tester) async {
      final turret = PlacedAbility(
        id: 'turret',
        data: AgentData.agents[AgentType.killjoy]!.abilities[2],
        position: Offset.zero,
      );
      final spec = AbilityVisionConeSpec.forAbility(turret.data)!;

      Future<Offset> renderedChildTopLeft(double rotation) async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Stack(
                children: [
                  Positioned(
                    left: 20,
                    top: 30,
                    child: AbilityVisionConeComposite(
                      ability: turret,
                      spec: spec,
                      rotation: rotation,
                      length: 50,
                      mapScale: 1,
                      abilitySize: 40,
                      clipToGeometry: false,
                      child: const SizedBox(
                        key: ValueKey('ability-child'),
                        width: 40,
                        height: 40,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        return tester.getTopLeft(
          find.byKey(const ValueKey('ability-child')),
        );
      }

      final unrotated = await renderedChildTopLeft(0);
      final quarterTurn = await renderedChildTopLeft(math.pi / 2);
      final arbitraryRotation = await renderedChildTopLeft(1.234);

      for (final rotated in [quarterTurn, arbitraryRotation]) {
        expect(rotated.dx, closeTo(unrotated.dx, 0.000001));
        expect(rotated.dy, closeTo(unrotated.dy, 0.000001));
      }
    });
  });
}
