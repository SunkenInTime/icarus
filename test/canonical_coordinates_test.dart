import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/placed_media_geometry.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/canonical_positioned.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';

class _NoopActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {}
}

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.bind, isAttack: true);
}

class _FixedStorageStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => StrategyState(
        isSaved: false,
        stratName: null,
        id: 'canonical-coordinate-test',
        storageDirectory: Directory.systemTemp.path,
      );
}

void _expectOffset(Offset actual, Offset expected, {String? reason}) {
  expect(actual.dx, closeTo(expected.dx, 0.0001), reason: reason);
  expect(actual.dy, closeTo(expected.dy, 0.0001), reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('canonical side projection', () {
    test('position and rotation projections are reversible', () {
      final coordinates = CoordinateSystem.instance;
      const position = Offset(321.25, 456.75);
      const anchor = Offset(40, 80);
      const rotation = 0.73;

      final defense = coordinates.positionForSide(
        canonicalPosition: position,
        reflectionOffset: anchor * 2,
        isAttack: false,
      );
      _expectOffset(
        coordinates.positionFromSide(
          sidePosition: defense,
          reflectionOffset: anchor * 2,
          isAttack: false,
        ),
        position,
      );
      expect(
        coordinates.rotationFromSide(
          coordinates.rotationForSide(rotation, isAttack: false),
          isAttack: false,
        ),
        closeTo(rotation, 0.0001),
      );
    });

    test('ability anchors reflect exactly and defense drags round-trip', () {
      final coordinates = CoordinateSystem.instance;
      const mapScale = 0.835;
      const abilitySize = 57.0;

      final representativeAbilities = <PlacedAbility>[
        PlacedAbility(
          id: 'base',
          data: AgentData.agents[AgentType.sova]!.abilities.first,
          position: const Offset(210, 320),
        ),
        PlacedAbility(
          id: 'wall',
          data: AgentData.agents[AgentType.harbor]!.abilities[1],
          position: const Offset(430, 180),
          rotation: 0.9,
        ),
        PlacedAbility(
          id: 'deadlock',
          data: AgentData.agents[AgentType.deadlock]!.abilities[2],
          position: const Offset(610, 510),
          rotation: 1.2,
        ),
      ];

      for (final ability in representativeAbilities) {
        final renderedAnchor = ability.data.abilityData!
            .getAnchorPoint(
              mapScale: mapScale,
              abilitySize: abilitySize,
            )
            .scale(coordinates.scaleFactor, coordinates.scaleFactor);
        final attackTopLeft = screenPositionForWidget(
          widget: ability,
          coordinateSystem: coordinates,
          mapScale: mapScale,
          abilitySize: abilitySize,
        );
        final defenseTopLeft = screenPositionForWidget(
          widget: ability,
          coordinateSystem: coordinates,
          mapScale: mapScale,
          abilitySize: abilitySize,
          isAttack: false,
        );
        final attackAnchor = attackTopLeft + renderedAnchor;
        final defenseAnchor = defenseTopLeft + renderedAnchor;

        _expectOffset(
          defenseAnchor,
          Offset(
            coordinates.effectiveSize.width - attackAnchor.dx,
            coordinates.effectiveSize.height - attackAnchor.dy,
          ),
          reason: ability.data.abilityData.runtimeType.toString(),
        );
        _expectOffset(
          storedAbilityPositionForRenderedScreenPosition(
            ability: ability.data.abilityData!,
            coordinateSystem: coordinates,
            renderedScreenPosition: defenseTopLeft,
            mapScale: mapScale,
            abilitySize: abilitySize,
            isAttack: false,
          ),
          ability.position,
          reason: ability.data.abilityData.runtimeType.toString(),
        );
      }
    });

    test('agent and utility defense drags round-trip canonical positions', () {
      final coordinates = CoordinateSystem.instance;
      const mapScale = 1.12;
      const agentSize = 54.0;
      const abilitySize = 31.0;
      final agent = PlacedViewConeAgent(
        id: 'agent',
        type: AgentType.fade,
        presetType: UtilityType.viewCone90,
        position: const Offset(240, 360),
      );
      final utility = PlacedUtility(
        id: 'utility',
        type: UtilityType.customRectangle,
        position: const Offset(700, 120),
        customWidth: 8,
        customLength: 17,
      );

      final agentTopLeft = screenPositionForWidget(
        widget: agent,
        coordinateSystem: coordinates,
        agentSize: agentSize,
        isAttack: false,
      );
      _expectOffset(
        storedAgentPositionForRenderedScreenPosition(
          coordinateSystem: coordinates,
          renderedScreenPosition: agentTopLeft,
          agentSize: agentSize,
          isAttack: false,
        ),
        agent.position,
      );

      final utilityTopLeft = screenPositionForWidget(
        widget: utility,
        coordinateSystem: coordinates,
        mapScale: mapScale,
        agentSize: agentSize,
        abilitySize: abilitySize,
        isAttack: false,
      );
      _expectOffset(
        storedUtilityPositionForRenderedScreenPosition(
          utility: utility,
          coordinateSystem: coordinates,
          renderedScreenPosition: utilityTopLeft,
          mapScale: mapScale,
          agentSize: agentSize,
          abilitySize: abilitySize,
          isAttack: false,
        ),
        utility.position,
      );
    });
  });

  test('switching sides does not mutate any placed data', () {
    final container = ProviderContainer(
      overrides: [
        actionProvider.overrideWith(_NoopActionProvider.new),
        mapProvider.overrideWith(_FixedMapProvider.new),
      ],
    );
    addTearDown(container.dispose);

    final agent = PlacedViewConeAgent(
      id: 'agent',
      type: AgentType.sova,
      presetType: UtilityType.viewCone90,
      position: const Offset(100, 200),
      rotation: 0.4,
    );
    final ability = PlacedAbility(
      id: 'ability',
      data: AgentData.agents[AgentType.deadlock]!.abilities[2],
      position: const Offset(300, 400),
      rotation: 0.8,
    );
    final utility = PlacedUtility(
      id: 'utility',
      type: UtilityType.viewCone40,
      position: const Offset(500, 600),
    )..rotation = 1.1;
    final text = PlacedText(
      id: 'text',
      position: const Offset(70, 80),
      sizeVersion: worldSizedMediaVersion,
    )..text = 'Hold this angle';
    final image = PlacedImage(
      id: 'image',
      position: const Offset(900, 100),
      aspectRatio: 1.5,
      scale: 185,
      fileExtension: null,
      sizeVersion: worldSizedMediaVersion,
    );
    final group = LineUpGroup(
      id: 'group',
      agent: PlacedAgent(
        id: 'lineup-agent',
        type: AgentType.sova,
        position: const Offset(110, 210),
      ),
      items: [
        LineUpItem(
          id: 'item',
          ability: ability.copyWith(
            id: 'lineup-ability',
            position: const Offset(310, 410),
          ),
        ),
      ],
    );

    container.read(agentProvider.notifier).fromHive([agent]);
    container.read(abilityProvider.notifier).fromHive([ability]);
    container.read(utilityProvider.notifier).fromHive([utility]);
    container.read(textProvider.notifier).fromHive([text]);
    container.read(placedImageProvider.notifier).fromHive([image]);
    container.read(lineUpProvider.notifier).fromHive([group]);

    String snapshot() => jsonEncode({
          'agents':
              container.read(agentProvider).map((e) => e.toJson()).toList(),
          'abilities':
              container.read(abilityProvider).map((e) => e.toJson()).toList(),
          'utilities':
              container.read(utilityProvider).map((e) => e.toJson()).toList(),
          'texts': container.read(textProvider).map((e) => e.toJson()).toList(),
          'images': container
              .read(placedImageProvider)
              .images
              .map((e) => e.toJson())
              .toList(),
          'lineups': container
              .read(lineUpProvider)
              .groups
              .map((e) => e.toJson())
              .toList(),
        });

    final before = snapshot();
    container.read(mapProvider.notifier).switchSide();

    expect(container.read(mapProvider).isAttack, isFalse);
    expect(snapshot(), before);
  });

  testWidgets('dynamic boxes reflect their measured bounds and stay upright',
      (tester) async {
    Future<void> pump({required bool isAttack, required Size childSize}) {
      return tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 800,
              height: 450,
              child: Stack(
                children: [
                  CanonicalPositionedBox(
                    attackScreenPosition: const Offset(100, 80),
                    isAttack: isAttack,
                    child: SizedBox(
                      key: const ValueKey('dynamic-child'),
                      width: childSize.width,
                      height: childSize.height,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    await pump(isAttack: true, childSize: const Size(120, 70));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('dynamic-child'))),
      const Offset(100, 80),
    );

    await pump(isAttack: false, childSize: const Size(120, 70));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('dynamic-child'))),
      const Offset(580, 300),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('dynamic-child'))),
      const Size(120, 70),
    );

    await pump(isAttack: false, childSize: const Size(180, 105));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('dynamic-child'))),
      const Offset(520, 265),
    );
  });

  testWidgets('legacy text footprint matches the rendered text card',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    CoordinateSystem(playAreaSize: const Size(1920, 1080));

    final text = PlacedText(
      id: 'measured-text',
      position: Offset.zero,
      size: 220,
      fontSize: 16,
      sizeVersion: worldSizedMediaVersion,
    )..text = 'Hold A main\nthen swing on contact';

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                TextWidget(
                  key: const ValueKey('text-card'),
                  id: text.id,
                  text: text.text,
                  size: text.size,
                  fontSize: text.fontSize,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final expectedWorld = PlacedMediaGeometry.legacyTextFootprintInWorld(text);
    final expectedScreen = CoordinateSystem.instance.worldSizeToScreen(
      expectedWorld,
    );
    final actual = tester.getSize(find.byKey(const ValueKey('text-card')));
    expect(actual.width, closeTo(expectedScreen.width, 0.01));
    expect(actual.height, closeTo(expectedScreen.height, 0.01));
  });

  testWidgets('legacy image footprint matches the rendered image card',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    CoordinateSystem(playAreaSize: const Size(1920, 1080));

    final image = PlacedImage(
      id: 'measured-image',
      position: Offset.zero,
      aspectRatio: 16 / 9,
      scale: 320,
      fileExtension: null,
      sizeVersion: worldSizedMediaVersion,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          strategyProvider.overrideWith(_FixedStorageStrategyProvider.new),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ImageWidget(
                  key: const ValueKey('image-card'),
                  id: image.id,
                  link: null,
                  aspectRatio: image.aspectRatio,
                  scale: image.scale,
                  fileExtension: image.fileExtension,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final expectedScreen = CoordinateSystem.instance.worldSizeToScreen(
      PlacedMediaGeometry.legacyImageFootprintInWorld(image),
    );
    final actual = tester.getSize(find.byKey(const ValueKey('image-card')));
    expect(actual.width, closeTo(expectedScreen.width, 0.01));
    expect(actual.height, closeTo(expectedScreen.height, 0.01));
  });

  test('defense rotation is a half-turn without changing canonical rotation',
      () {
    const canonical = 0.42;
    final displayed = CoordinateSystem.instance.rotationForSide(
      canonical,
      isAttack: false,
    );
    expect(displayed, closeTo(canonical + math.pi, 0.0001));
    expect(canonical, 0.42);
  });
}
