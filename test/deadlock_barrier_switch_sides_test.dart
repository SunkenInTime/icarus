import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/widgets/draggable_widgets/ability/deadlock_barrier_mesh_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Deadlock barrier canonical geometry', () {
    late DeadlockBarrierMeshAbility abilityData;
    late PlacedAbility placedAbility;
    const mapScale = 1.15;
    const abilitySize = 42.0;

    setUp(() {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      final abilityInfo = AgentData.agents[AgentType.deadlock]!.abilities[2];
      abilityData = abilityInfo.abilityData! as DeadlockBarrierMeshAbility;
      placedAbility = PlacedAbility(
        id: 'deadlock-barrier',
        data: abilityInfo,
        position: const Offset(123.4, 234.5),
        rotation: 0.7,
      );
    });

    test('modeled size and anchor match the rendered outer extent', () {
      final extent = deadlockBarrierMeshMaxExtent(
        mapScale: mapScale,
        abilitySize: abilitySize,
      );
      final size = abilityData.getSize(
        mapScale: mapScale,
        abilitySize: abilitySize,
      );
      final anchor = abilityData.getAnchorPoint(
        mapScale: mapScale,
        abilitySize: abilitySize,
      );

      expect(size, Offset(extent, extent));
      expect(anchor, Offset(extent / 2, extent / 2));
    });

    test('defense projection preserves stored position and anchor symmetry',
        () {
      final coordinateSystem = CoordinateSystem.instance;
      final anchor = abilityData
          .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
          .scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);
      final attackTopLeft = screenPositionForWidget(
        widget: placedAbility,
        coordinateSystem: coordinateSystem,
        mapScale: mapScale,
        abilitySize: abilitySize,
      );
      final defenseTopLeft = screenPositionForWidget(
        widget: placedAbility,
        coordinateSystem: coordinateSystem,
        mapScale: mapScale,
        abilitySize: abilitySize,
        isAttack: false,
      );

      expect(
        defenseTopLeft + anchor,
        Offset(
          coordinateSystem.effectiveSize.width - attackTopLeft.dx - anchor.dx,
          coordinateSystem.effectiveSize.height - attackTopLeft.dy - anchor.dy,
        ),
      );
      expect(placedAbility.position, const Offset(123.4, 234.5));
      expect(placedAbility.rotation, 0.7);
      expect(
        coordinateSystem.rotationForSide(
          placedAbility.rotation,
          isAttack: false,
        ),
        closeTo(0.7 + 3.141592653589793, 0.0001),
      );
    });

    test('stored default footprint remains independent of runtime size', () {
      final coordinateSystem = CoordinateSystem.instance;
      final atMinimum = screenAnchorForAbility(
        ability: placedAbility,
        coordinateSystem: coordinateSystem,
        mapScale: mapScale,
        isAttack: false,
      );
      final restored = storedAbilityPositionForRenderedScreenPosition(
        ability: abilityData,
        coordinateSystem: coordinateSystem,
        renderedScreenPosition: screenPositionForWidget(
          widget: placedAbility,
          coordinateSystem: coordinateSystem,
          mapScale: mapScale,
          abilitySize: Settings.abilitySizeMax,
          isAttack: false,
        ),
        mapScale: mapScale,
        abilitySize: Settings.abilitySizeMax,
        isAttack: false,
      );

      expect(atMinimum, isNot(Offset.zero));
      expect(restored.dx, closeTo(placedAbility.position.dx, 0.0001));
      expect(restored.dy, closeTo(placedAbility.position.dy, 0.0001));
    });
  });
}
