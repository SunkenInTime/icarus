import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/placed_view_cone_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'vision_geometry_test_support.dart';

class _Map extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final ability in [false, true]) {
    testWidgets(
        '${ability ? 'ability' : 'free utility'} drag feedback queries its moving apex',
        (tester) async {
      final coordinates =
          CoordinateSystem(playAreaSize: const Size(1920, 1080));
      final container = ProviderContainer(overrides: [
        mapProvider.overrideWith(_Map.new),
        viewConeGeometryProvider
            .overrideWith((ref, map) async => twoLayerAscentGeometry()),
      ]);
      addTearDown(container.dispose);
      final utility = PlacedUtility(
          id: 'free',
          type: UtilityType.viewCone90,
          position: Offset.zero,
          angle: 90);
      final turret = PlacedAbility(
          id: 'turret',
          data: AgentData.agents[AgentType.killjoy]!.abilities[2],
          position: const Offset(200, 250));
      container.read(utilityProvider.notifier).fromHive([utility]);
      container.read(abilityProvider.notifier).fromHive([turret]);
      final child = ability
          ? PlacedAbilityWidget(
              ability: turret,
              onDragEnd: (_, __) {},
              id: turret.id,
              data: turret,
              rotation: 0,
              length: 50)
          : PlacedViewConeWidget(
              utility: utility,
              onDragEnd: (_) {},
              id: utility.id,
              rotation: 0,
              length: 50,
              isAttack: true);
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: ShadApp(home: Scaffold(body: Stack(children: [child])))));
      await tester.pump();
      final pivot = tester.getTopLeft(find.byType(ViewConeWidget)) +
          ViewConeWidget.anchorPointVirtual * coordinates.scaleFactor;
      final gesture = await tester.startGesture(pivot);
      await gesture.moveBy(const Offset(30, 10));
      await tester.pump();
      final first = tester
          .widget<ViewConeWidget>(find.byType(ViewConeWidget))
          .worldOrigin!;
      await gesture.moveBy(const Offset(20, -30));
      await tester.pump();
      final second = tester
          .widget<ViewConeWidget>(find.byType(ViewConeWidget))
          .worldOrigin!;
      expect(second.dx - first.dx,
          closeTo(coordinates.screenWidthToWorld(20), 1e-9));
      expect(second.dy - first.dy,
          closeTo(coordinates.screenHeightToWorld(-30), 1e-9));
      expect(container.read(abilityProvider).single.position, turret.position);
      expect(container.read(utilityProvider).single.position, utility.position);
      await gesture.up();
      await tester.pump();
    });
  }
}
