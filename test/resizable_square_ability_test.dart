import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/custom_square_widget.dart';
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

  group('Wall square geometry contracts', () {
    const mapScale = 1.25;
    const abilitySize = 42.0;

    test('wall square abilities report the full rendered width', () {
      final ability = AgentData
          .agents[AgentType.viper]!.abilities[2].abilityData! as SquareAbility;

      final size =
          ability.getSize(mapScale: mapScale, abilitySize: abilitySize);
      final anchor =
          ability.getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize);

      expect(size.dx, abilitySize * 2);
      expect(anchor.dx, abilitySize);
    });

    test('wall resizable abilities report the full rendered width', () {
      final neonAbility = AgentData.agents[AgentType.neon]!.abilities.first
          .abilityData! as ResizableSquareAbility;
      final cypherAbility = AgentData.agents[AgentType.cypher]!.abilities.first
          .abilityData! as ResizableSquareAbility;

      for (final ability in [neonAbility, cypherAbility]) {
        final size =
            ability.getSize(mapScale: mapScale, abilitySize: abilitySize);
        final anchor = ability.getAnchorPoint(
          mapScale: mapScale,
          abilitySize: abilitySize,
        );
        final lengthAnchor = ability.getLengthAnchor(mapScale, abilitySize);

        expect(size.dx, abilitySize * 2);
        expect(anchor.dx, abilitySize);
        expect(lengthAnchor.dx, abilitySize);
      }
    });

    test('non-wall squares keep width based on map scale', () {
      final ability = AgentData.agents[AgentType.breach]!.abilities.first
          .abilityData! as SquareAbility;

      final size =
          ability.getSize(mapScale: mapScale, abilitySize: abilitySize);

      expect(size.dx, ability.width * mapScale);
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

  testWidgets('wall resizable widget size matches modeled width',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));

    final ability = AgentData.agents[AgentType.neon]!.abilities.first
        .abilityData! as ResizableSquareAbility;
    final container = ProviderContainer();
    final abilitySize = container.read(strategySettingsProvider).abilitySize;

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ability.createWidget(
              id: 'neon-width',
              isAlly: true,
              mapScale: 1,
              length: 0,
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    final renderedSize = tester.getSize(find.byType(ResizableSquareWidget));
    final modeledSize =
        ability.getSize(mapScale: 1, abilitySize: abilitySize).scale(
              CoordinateSystem.instance.scaleFactor,
              CoordinateSystem.instance.scaleFactor,
            );

    expect(renderedSize.width, closeTo(modeledSize.dx, 0.0001));
  });

  testWidgets('wall square widget size matches modeled width', (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));

    final ability = AgentData.agents[AgentType.viper]!.abilities[2].abilityData!
        as SquareAbility;
    final container = ProviderContainer();
    final abilitySize = container.read(strategySettingsProvider).abilitySize;

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ability.createWidget(
              id: 'viper-width',
              isAlly: true,
              mapScale: 1,
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    final renderedSize = tester.getSize(find.byType(CustomSquareWidget));
    final modeledSize =
        ability.getSize(mapScale: 1, abilitySize: abilitySize).scale(
              CoordinateSystem.instance.scaleFactor,
              CoordinateSystem.instance.scaleFactor,
            );

    expect(renderedSize.width, closeTo(modeledSize.dx, 0.0001));
  });

  group('PlacedAbility.switchSides wall sizing', () {
    const mapScale = 1.2;
    const abilitySize = 42.0;

    test('square walls flip using the full rendered width', () {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));

      final abilityInfo = AgentData.agents[AgentType.viper]!.abilities[2];
      final initialPosition = const Offset(123.4, 234.5);
      const initialRotation = 0.5;

      final placedAbility = PlacedAbility(
        id: 'viper-wall-switch',
        data: abilityInfo,
        position: initialPosition,
        rotation: initialRotation,
      );

      final fullSize = abilityInfo.abilityData!
          .getSize(mapScale: mapScale, abilitySize: abilitySize)
          .scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          );
      final expectedPosition = getFlippedPosition(
        position: initialPosition,
        scaledSize: fullSize,
        isRotatable: true,
      );

      placedAbility.switchSides(mapScale: mapScale, abilitySize: abilitySize);

      expect(placedAbility.position.dx, closeTo(expectedPosition.dx, 0.0001));
      expect(placedAbility.position.dy, closeTo(expectedPosition.dy, 0.0001));
      expect(placedAbility.rotation, closeTo(initialRotation + pi, 0.0001));
    });

    test('resizable wall abilities flip using the full rendered width', () {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));

      final abilityInfo = AgentData.agents[AgentType.neon]!.abilities.first;
      final initialPosition = const Offset(210.0, 310.0);
      const initialRotation = 0.75;

      final placedAbility = PlacedAbility(
        id: 'neon-wall-switch',
        data: abilityInfo,
        position: initialPosition,
        rotation: initialRotation,
      );

      final fullSize = abilityInfo.abilityData!
          .getSize(mapScale: mapScale, abilitySize: abilitySize)
          .scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          );
      final expectedPosition = getFlippedPosition(
        position: initialPosition,
        scaledSize: fullSize,
        isRotatable: true,
      );

      placedAbility.switchSides(mapScale: mapScale, abilitySize: abilitySize);

      expect(placedAbility.position.dx, closeTo(expectedPosition.dx, 0.0001));
      expect(placedAbility.position.dy, closeTo(expectedPosition.dy, 0.0001));
      expect(placedAbility.rotation, closeTo(initialRotation + pi, 0.0001));
    });
  });
}
