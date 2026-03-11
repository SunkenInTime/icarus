import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/deadlock_barrier_mesh_widget.dart';

class _NoopActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    state = [...state, action];
  }
}

class _FixedMapProvider extends MapProvider {
  _FixedMapProvider({
    required this.mapValue,
  });

  final MapValue mapValue;

  @override
  MapState build() => MapState(currentMap: mapValue, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

ProviderContainer _createContainer(MapValue mapValue) {
  final container = ProviderContainer(
    overrides: [
      actionProvider.overrideWith(_NoopActionProvider.new),
      mapProvider.overrideWith(() => _FixedMapProvider(mapValue: mapValue)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Deadlock barrier side-switch geometry', () {
    late DeadlockBarrierMeshAbility abilityData;
    late AbilityInfo abilityInfo;

    const explicitMapScale = 1.15;
    const explicitAbilitySize = 42.0;

    setUp(() {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      abilityInfo = AgentData.agents[AgentType.deadlock]!.abilities[2];
      abilityData = abilityInfo.abilityData! as DeadlockBarrierMeshAbility;
    });

    test('getSize matches the rendered outer extent', () {
      final extent = deadlockBarrierMeshMaxExtent(
        mapScale: explicitMapScale,
        abilitySize: explicitAbilitySize,
      );

      final size = abilityData.getSize(
        mapScale: explicitMapScale,
        abilitySize: explicitAbilitySize,
      );

      expect(size.dx, extent);
      expect(size.dy, extent);
    });

    test('getAnchorPoint matches half the rendered outer extent', () {
      final extent = deadlockBarrierMeshMaxExtent(
        mapScale: explicitMapScale,
        abilitySize: explicitAbilitySize,
      );

      final anchor = abilityData.getAnchorPoint(
        mapScale: explicitMapScale,
        abilitySize: explicitAbilitySize,
      );

      expect(anchor.dx, extent / 2);
      expect(anchor.dy, extent / 2);
    });

    test(
        'PlacedAbility.switchSides mirrors deadlock using the full rendered size',
        () {
      const initialPosition = Offset(123.4, 234.5);
      const initialRotation = math.pi / 3;

      final placedAbility = PlacedAbility(
        id: 'deadlock-barrier',
        data: abilityInfo,
        position: initialPosition,
        rotation: initialRotation,
      );

      final fullSize = abilityData
          .getSize(
            mapScale: explicitMapScale,
            abilitySize: explicitAbilitySize,
          )
          .scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          );

      final expectedPosition = getFlippedPosition(
        position: initialPosition,
        scaledSize: fullSize,
      );

      placedAbility.switchSides(
        mapScale: explicitMapScale,
        abilitySize: explicitAbilitySize,
      );

      expect(placedAbility.position.dx, closeTo(expectedPosition.dx, 0.0001));
      expect(placedAbility.position.dy, closeTo(expectedPosition.dy, 0.0001));
      expect(
        placedAbility.rotation,
        closeTo(initialRotation + math.pi, 0.0001),
      );
    });

    test('AbilityProvider.switchSides uses current map scale for deadlock', () {
      final container = _createContainer(MapValue.bind);
      final notifier = container.read(abilityProvider.notifier);
      final actualMapScale = Maps.mapScale[MapValue.bind]!;
      final abilitySize = container.read(strategySettingsProvider).abilitySize;

      const initialPosition = Offset(123.4, 234.5);
      const initialRotation = math.pi / 3;

      final placedAbility = PlacedAbility(
        id: 'deadlock-provider-switch',
        data: abilityInfo,
        position: initialPosition,
        rotation: initialRotation,
      );

      notifier.fromHive([placedAbility]);

      final fullSize = abilityData
          .getSize(
            mapScale: actualMapScale,
            abilitySize: abilitySize,
          )
          .scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          );
      final expectedPosition = getFlippedPosition(
        position: initialPosition,
        scaledSize: fullSize,
      );

      notifier.switchSides();

      final flippedAbility = container.read(abilityProvider).single;
      expect(flippedAbility.position.dx, closeTo(expectedPosition.dx, 0.0001));
      expect(flippedAbility.position.dy, closeTo(expectedPosition.dy, 0.0001));
      expect(
        flippedAbility.rotation,
        closeTo(initialRotation + math.pi, 0.0001),
      );
    });

    test('deleted deadlock ability is flipped while stored in poppedAbility',
        () {
      final container = _createContainer(MapValue.bind);
      final notifier = container.read(abilityProvider.notifier);
      final actualMapScale = Maps.mapScale[MapValue.bind]!;
      final abilitySize = container.read(strategySettingsProvider).abilitySize;

      const initialPosition = Offset(123.4, 234.5);
      const initialRotation = math.pi / 3;

      final placedAbility = PlacedAbility(
        id: 'deadlock-popped-switch',
        data: abilityInfo,
        position: initialPosition,
        rotation: initialRotation,
      );

      notifier.fromHive([placedAbility]);
      notifier.removeAbility(placedAbility.id);

      final fullSize = abilityData
          .getSize(
            mapScale: actualMapScale,
            abilitySize: abilitySize,
          )
          .scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          );
      final expectedPosition = getFlippedPosition(
        position: initialPosition,
        scaledSize: fullSize,
      );

      notifier.switchSides();
      notifier.undoAction(
        UserAction(
          type: ActionType.deletion,
          id: placedAbility.id,
          group: ActionGroup.ability,
        ),
      );

      final restoredAbility = container.read(abilityProvider).single;
      expect(restoredAbility.position.dx, closeTo(expectedPosition.dx, 0.0001));
      expect(restoredAbility.position.dy, closeTo(expectedPosition.dy, 0.0001));
      expect(
        restoredAbility.rotation,
        closeTo(initialRotation + math.pi, 0.0001),
      );
    });

    test('switchSides still flips deleted abilities when live state is empty',
        () {
      final container = _createContainer(MapValue.bind);
      final notifier = container.read(abilityProvider.notifier);
      final actualMapScale = Maps.mapScale[MapValue.bind]!;
      final abilitySize = container.read(strategySettingsProvider).abilitySize;

      const initialPosition = Offset(300.0, 450.0);

      final placedAbility = PlacedAbility(
        id: 'deadlock-empty-state-switch',
        data: abilityInfo,
        position: initialPosition,
      );

      notifier.fromHive([placedAbility]);
      notifier.removeAbility(placedAbility.id);
      expect(container.read(abilityProvider), isEmpty);

      final fullSize = abilityData
          .getSize(
            mapScale: actualMapScale,
            abilitySize: abilitySize,
          )
          .scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          );
      final expectedPosition = getFlippedPosition(
        position: initialPosition,
        scaledSize: fullSize,
      );

      notifier.switchSides();
      notifier.undoAction(
        UserAction(
          type: ActionType.deletion,
          id: placedAbility.id,
          group: ActionGroup.ability,
        ),
      );

      final restoredAbility = container.read(abilityProvider).single;
      expect(restoredAbility.position.dx, closeTo(expectedPosition.dx, 0.0001));
      expect(restoredAbility.position.dy, closeTo(expectedPosition.dy, 0.0001));
    });

    test('switchSides flips both live and deleted deadlock abilities', () {
      final container = _createContainer(MapValue.bind);
      final notifier = container.read(abilityProvider.notifier);
      final actualMapScale = Maps.mapScale[MapValue.bind]!;
      final abilitySize = container.read(strategySettingsProvider).abilitySize;

      const livePosition = Offset(100.0, 150.0);
      const deletedPosition = Offset(200.0, 250.0);

      final liveAbility = PlacedAbility(
        id: 'deadlock-live-switch',
        data: abilityInfo,
        position: livePosition,
      );
      final deletedAbility = PlacedAbility(
        id: 'deadlock-deleted-switch',
        data: abilityInfo,
        position: deletedPosition,
      );

      notifier.fromHive([liveAbility, deletedAbility]);
      notifier.removeAbility(deletedAbility.id);

      final fullSize = abilityData
          .getSize(
            mapScale: actualMapScale,
            abilitySize: abilitySize,
          )
          .scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          );
      final expectedLivePosition = getFlippedPosition(
        position: livePosition,
        scaledSize: fullSize,
      );
      final expectedDeletedPosition = getFlippedPosition(
        position: deletedPosition,
        scaledSize: fullSize,
      );

      notifier.switchSides();

      final flippedLiveAbility = container.read(abilityProvider).single;
      expect(
        flippedLiveAbility.position.dx,
        closeTo(expectedLivePosition.dx, 0.0001),
      );
      expect(
        flippedLiveAbility.position.dy,
        closeTo(expectedLivePosition.dy, 0.0001),
      );

      notifier.undoAction(
        UserAction(
          type: ActionType.deletion,
          id: deletedAbility.id,
          group: ActionGroup.ability,
        ),
      );

      final abilities = container.read(abilityProvider);
      final restoredAbility =
          abilities.firstWhere((ability) => ability.id == deletedAbility.id);
      expect(
        restoredAbility.position.dx,
        closeTo(expectedDeletedPosition.dx, 0.0001),
      );
      expect(
        restoredAbility.position.dy,
        closeTo(expectedDeletedPosition.dy, 0.0001),
      );
    });

    testWidgets('rendered deadlock wall size matches modeled size',
        (tester) async {
      final container = _createContainer(MapValue.bind);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
      });

      final mapScale = Maps.mapScale[MapValue.bind]!;
      final abilitySize = container.read(strategySettingsProvider).abilitySize;
      final expectedExtent =
          abilityData.getSize(mapScale: mapScale, abilitySize: abilitySize).dx *
              CoordinateSystem.instance.scaleFactor;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: DeadlockBarrierMeshWidget(
                iconPath: abilityInfo.iconPath,
                id: 'deadlock-render-size',
                isAlly: true,
                color: abilityData.color,
                mapScale: mapScale,
                armLengthsMeters:
                    DeadlockBarrierMeshAbility.defaultArmLengthsMeters,
                showCenterAbility: false,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      final renderedSize =
          tester.getSize(find.byType(DeadlockBarrierMeshWidget));
      expect(renderedSize.width, closeTo(expectedExtent, 0.0001));
      expect(renderedSize.height, closeTo(expectedExtent, 0.0001));
    });

    test('AbilityProvider.updatePosition uses current map scale for bounds',
        () {
      final container = _createContainer(MapValue.pearl);
      final notifier = container.read(abilityProvider.notifier);
      final actualMapScale = Maps.mapScale[MapValue.pearl]!;
      final abilitySize = container.read(strategySettingsProvider).abilitySize;
      final worldMaxX = CoordinateSystem.instance.worldNormalizedWidth - 10;
      final worldMaxY = CoordinateSystem.instance.normalizedHeight - 10;

      final placedAbility = PlacedAbility(
        id: 'deadlock-edge-bounds',
        data: abilityInfo,
        position: const Offset(100, 100),
      );
      notifier.fromHive([placedAbility]);

      final anchorWithActualScale = abilityData.getAnchorPoint(
        mapScale: actualMapScale,
        abilitySize: abilitySize,
      );
      final anchorWithFallbackScale = abilityData.getAnchorPoint(
        mapScale: 1.0,
        abilitySize: abilitySize,
      );
      final midpointX =
          (anchorWithActualScale.dx + anchorWithFallbackScale.dx) / 2;
      final midpointY =
          (anchorWithActualScale.dy + anchorWithFallbackScale.dy) / 2;
      final candidatePosition = Offset(
        worldMaxX - midpointX,
        worldMaxY - midpointY,
      );

      notifier.updatePosition(candidatePosition, placedAbility.id);

      expect(
        container.read(abilityProvider),
        isEmpty,
        reason: 'The real current-map scale should push the deadlock center '
            'out of bounds and remove the ability.',
      );
    });

    test('rendered extent matches projected arm span and handle diameter', () {
      const meterScale = AgentData.inGameMetersDiameter * explicitMapScale;
      const maxArmLengthVirtual =
          DeadlockBarrierMeshAbility.maxArmLengthMeters * meterScale;
      final projectedReachVirtual = maxArmLengthVirtual * math.cos(math.pi / 4);
      final expectedExtent =
          math.max(explicitAbilitySize, projectedReachVirtual * 2) +
              deadlockBarrierMeshHandleDiameterVirtual;
      final fullExtent = deadlockBarrierMeshMaxExtent(
        mapScale: explicitMapScale,
        abilitySize: explicitAbilitySize,
      );

      expect(fullExtent, greaterThan(explicitAbilitySize));
      expect(fullExtent, closeTo(expectedExtent, 0.0001));
    });
  });
}
