import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/resizable_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ResizableSquareAbility.resolveLength', () {
    const minLength = 5.0;
    const maxLength = 20.0;

    test('defaults to min when max-default is disabled', () {
      final ability = ResizableSquareAbility(
        width: 3,
        height: maxLength,
        iconPath: 'assets/agents/Cypher/1.webp',
        color: Colors.white,
        minLength: minLength,
      );

      expect(ability.resolveLength(0), minLength);
    });

    test('defaults to max when max-default is enabled', () {
      final ability = ResizableSquareAbility(
        width: 3,
        height: maxLength,
        iconPath: 'assets/agents/Cypher/1.webp',
        color: Colors.white,
        minLength: minLength,
        defaultToMaxLength: true,
      );

      expect(ability.resolveLength(0), maxLength);
    });

    test('clamps values outside the supported range', () {
      final ability = ResizableSquareAbility(
        width: 3,
        height: maxLength,
        iconPath: 'assets/agents/Cypher/1.webp',
        color: Colors.white,
        minLength: minLength,
      );

      expect(ability.resolveLength(2), minLength);
      expect(ability.resolveLength(25), maxLength);
      expect(ability.resolveLength(12), 12);
    });
  });

  group('Neon/Cypher/Harbor defaults', () {
    test('Neon first ability is a wall resizable square that defaults to max',
        () {
      final ability = AgentData.agents[AgentType.neon]!.abilities.first
          .abilityData! as ResizableSquareAbility;

      expect(ability.isWall, isTrue);
      expect(ability.defaultToMaxLength, isTrue);
      expect(ability.minLength, AgentData.inGameMeters);

      final widget = ability.createWidget(
        id: 'neon',
        isAlly: true,
        mapScale: 1,
        length: 0,
      ) as ResizableSquareWidget;

      expect(widget.length, ability.height);
      expect(widget.maxLength, ability.height);
    });

    test('Cypher first ability defaults to max', () {
      final ability = AgentData.agents[AgentType.cypher]!.abilities.first
          .abilityData! as ResizableSquareAbility;

      expect(ability.isWall, isTrue);
      expect(ability.defaultToMaxLength, isTrue);

      final widget = ability.createWidget(
        id: 'cypher',
        isAlly: true,
        mapScale: 1,
        length: 0,
      ) as ResizableSquareWidget;

      expect(widget.length, ability.height);
      expect(widget.maxLength, ability.height);
    });

    test('Harbor last ability defaults to max and has a top border', () {
      final ability = AgentData.agents[AgentType.harbor]!.abilities.last
          .abilityData! as ResizableSquareAbility;

      expect(ability.defaultToMaxLength, isTrue);
      expect(ability.minLength, AgentData.inGameMeters);
      expect(ability.hasTopborder, isTrue);

      final widget = ability.createWidget(
        id: 'harbor',
        isAlly: true,
        mapScale: 1,
        length: 0,
      ) as ResizableSquareWidget;

      expect(widget.length, ability.height);
      expect(widget.maxLength, ability.height);
    });
  });

  testWidgets(
      'PlacedAbilityWidget uses the resolved max length for the initial handle position',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));

    final abilityInfo = AgentData.agents[AgentType.neon]!.abilities.first;
    final placedAbility = PlacedAbility(
      id: 'neon-placed',
      data: abilityInfo,
      position: const Offset(100, 100),
      length: 0,
    );

    final container = ProviderContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
    container.read(abilityProvider.notifier).fromHive([placedAbility]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Stack(
            children: [
              PlacedAbilityWidget(
                ability: placedAbility,
                onDragEnd: (_) {},
                id: placedAbility.id,
                data: placedAbility,
                rotation: placedAbility.rotation,
                length: placedAbility.length,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pump();

    final rotatableWidget =
        tester.widget<RotatableWidget>(find.byType(RotatableWidget));
    expect(rotatableWidget.buttonTop, 0);
  });
}
