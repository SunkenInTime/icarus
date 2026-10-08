import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _Strategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        isSaved: true,
        stratName: null,
        id: 'steel-garden',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

class _Map extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

const _canvas = Size(1920, 1080);

/// Where a saved Steel Garden's icon lands and how wide its circle is
/// drawn, both in screen pixels.
Future<({Offset icon, double diameter})> _render(WidgetTester tester) async {
  final container = ProviderContainer(overrides: [
    strategyProvider.overrideWith(_Strategy.new),
    mapProvider.overrideWith(_Map.new),
  ]);
  addTearDown(container.dispose);
  final info = AgentData.agents[AgentType.vyse]!.abilities[3];
  container.read(abilityProvider.notifier).fromHive([
    PlacedAbility(id: 'ult', data: info, position: const Offset(600, 400)),
  ]);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: ShadApp(
      home: Material(
        child: SizedBox.fromSize(
          size: _canvas,
          child: const PlacedWidgetBuilder(),
        ),
      ),
    ),
  ));
  await tester.pump();
  final result = (
    icon: tester.getCenter(find.byType(AbilityWidget)),
    diameter: tester
        .getSize(find.byKey(const ValueKey('circle-range-outline-layer')))
        .width,
  );
  await tester.pumpWidget(const SizedBox.shrink());
  return result;
}

void main() {
  testWidgets(
      'a saved Steel Garden keeps its center and draws at 28 m, not 32.5 m',
      (tester) async {
    tester.view
      ..physicalSize = _canvas
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    CoordinateSystem(playAreaSize: _canvas);

    final info = AgentData.agents[AgentType.vyse]!.abilities[3];
    final steelGarden = info.abilityData! as CircleAbility;
    addTearDown(() => info.abilityData = steelGarden);

    final now = await _render(tester);

    // The Steel Garden every saved position was placed with.
    info.abilityData = CircleAbility(
      iconPath: steelGarden.iconPath,
      size: 32.5,
      rangeOutlineColor: steelGarden.rangeOutlineColor,
      hasCenterDot: true,
    );
    final before = await _render(tester);

    expect(now.icon, before.icon);
    expect(now.diameter / before.diameter, closeTo(28 / 32.5, 1e-9));
  });
}
