import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/widgets/draggable_widgets/ability/resizable_square_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('PlacedAbility default length', () {
    test('Neon first ability defaults to max length for new placements', () {
      final abilityInfo = AgentData.agents[AgentType.neon]!.abilities.first;
      final abilityData = abilityInfo.abilityData! as ResizableSquareAbility;

      final placedAbility = PlacedAbility(
        id: 'neon-1',
        data: abilityInfo,
        position: const Offset(100, 120),
      );

      expect(placedAbility.length, abilityData.height);
    });

    test('Cypher first ability defaults to max length for new placements', () {
      final abilityInfo = AgentData.agents[AgentType.cypher]!.abilities.first;
      final abilityData = abilityInfo.abilityData! as ResizableSquareAbility;

      final placedAbility = PlacedAbility(
        id: 'cypher-1',
        data: abilityInfo,
        position: const Offset(100, 120),
      );

      expect(placedAbility.length, abilityData.height);
    });

    test('Breach resizable ability still defaults to zero length', () {
      final abilityInfo = AgentData.agents[AgentType.breach]!.abilities[2];

      final placedAbility = PlacedAbility(
        id: 'breach-1',
        data: abilityInfo,
        position: const Offset(100, 120),
      );

      expect(placedAbility.length, 0);
    });

    test(
      'explicit zero length remains zero for flagged resizable abilities',
      () {
        final abilityInfo = AgentData.agents[AgentType.neon]!.abilities.first;

        final placedAbility = PlacedAbility(
          id: 'neon-explicit-zero',
          data: abilityInfo,
          position: const Offset(100, 120),
          length: 0,
        );

        expect(placedAbility.length, 0);
      },
    );
  });

  group('ResizableSquareAbility widget defaults', () {
    test('null length resolves to max and explicit zero remains explicit', () {
      final ability = ResizableSquareAbility(
        width: 10,
        height: 20,
        minLength: 4,
        iconPath: 'assets/agents/Neon/1.webp',
        color: Colors.blueAccent,
        defaultToMaxLengthWhenUnspecified: true,
      );

      final defaultWidget = ability.createWidget(
        id: 'test',
        isAlly: true,
        mapScale: 2,
      ) as ResizableSquareWidget;

      expect(defaultWidget.length, 40);
      expect(defaultWidget.maxLength, 40);
      expect(defaultWidget.minLength, 8);

      final explicitZeroWidget = ability.createWidget(
        id: 'test',
        isAlly: true,
        mapScale: 2,
        length: 0,
      ) as ResizableSquareWidget;

      expect(explicitZeroWidget.length, 0);
      expect(explicitZeroWidget.minLength, 8);
    });
  });
}
