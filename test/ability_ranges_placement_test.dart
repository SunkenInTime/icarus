import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _Strategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        isSaved: true,
        stratName: null,
        id: 'ability-ranges',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

class _Map extends MapProvider {
  _Map(this.isAttack);

  final bool isAttack;

  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: isAttack);
}

class _Settings extends StrategySettingsProvider {
  _Settings(this.abilitySize);

  final double abilitySize;

  @override
  StrategySettings build() => StrategySettings(abilitySize: abilitySize);
}

const _canvas = Size(1920, 1080);
const _saved = Offset(600, 400);
const _rangeOn = AbilityVisualState(showInnerOutline: false);

/// Every ability this change drew a range on, as it was defined before.
final Map<String, (AbilityInfo, Ability)> _changed = {
  for (final (agent, index) in const [
    (AgentType.raze, 3),
    (AgentType.gekko, 3),
    (AgentType.vyse, 2),
  ])
    AgentData.agents[agent]!.abilities[index].name: (
      AgentData.agents[agent]!.abilities[index],
      BaseAbility(iconPath: AgentData.agents[agent]!.abilities[index].iconPath),
    ),
  'Chokehold': (
    AgentData.agents[AgentType.veto]!.abilities[1],
    CircleAbility(
      iconPath: AgentData.agents[AgentType.veto]!.abilities[1].iconPath,
      size: 6.58,
      rangeOutlineColor: Colors.lightBlueAccent,
      hasCenterDot: true,
    ),
  ),
};

Future<void> _pump(
  WidgetTester tester,
  AbilityInfo info, {
  required bool isAttack,
  required double abilitySize,
  AbilityVisualState visualState = const AbilityVisualState(),
}) async {
  final container = ProviderContainer(overrides: [
    strategyProvider.overrideWith(_Strategy.new),
    mapProvider.overrideWith(() => _Map(isAttack)),
    strategySettingsProvider.overrideWith(() => _Settings(abilitySize)),
  ]);
  addTearDown(container.dispose);
  container.read(abilityProvider.notifier).fromHive([
    PlacedAbility(
      id: 'saved',
      data: info,
      position: _saved,
      visualState: visualState,
    ),
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
}

Future<Offset> _iconCenter(
  WidgetTester tester,
  AbilityInfo info, {
  required bool isAttack,
  required double abilitySize,
}) async {
  await _pump(tester, info, isAttack: isAttack, abilitySize: abilitySize);
  final center = tester.getCenter(find.byType(AbilityWidget));
  // Each render needs its own container, so tear this one down first.
  await tester.pumpWidget(const SizedBox.shrink());
  return center;
}

double _meters(double radius) =>
    radius *
    AgentData.inGameMetersDiameter *
    Maps.mapScale[MapValue.ascent]! *
    CoordinateSystem.instance.scaleFactor;

void main() {
  setUp(() => CoordinateSystem(playAreaSize: _canvas));

  for (final MapEntry(key: name, value: (info, old)) in _changed.entries) {
    testWidgets('$name stays where it was saved', (tester) async {
      tester.view.physicalSize = _canvas;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final before = info.copyWith(abilityData: old);
      for (final isAttack in const [true, false]) {
        for (final abilitySize in const [
          Settings.abilitySize,
          Settings.abilitySizeMax,
        ]) {
          expect(
            await _iconCenter(
              tester,
              info,
              isAttack: isAttack,
              abilitySize: abilitySize,
            ),
            await _iconCenter(
              tester,
              before,
              isAttack: isAttack,
              abilitySize: abilitySize,
            ),
            reason: 'attack: $isAttack, icon size: $abilitySize',
          );
        }
      }
    });

    test('$name keeps the anchor saves and migrations read', () {
      for (final mapScale in Maps.mapScale.values) {
        expect(
          storedAbilityAnchor(ability: info.abilityData!, mapScale: mapScale),
          storedAbilityAnchor(ability: old, mapScale: mapScale),
        );
      }
    });
  }

  testWidgets('a saved item draws no range until it is turned on',
      (tester) async {
    tester.view.physicalSize = _canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    for (final index in const [(AgentType.raze, 3), (AgentType.vyse, 2)]) {
      await _pump(
        tester,
        AgentData.agents[index.$1]!.abilities[index.$2],
        isAttack: true,
        abilitySize: Settings.abilitySize,
      );
      for (final key in const [
        'circle-range-outline-layer',
        'circle-range-fill-layer',
      ]) {
        expect(tester.widget<Opacity>(find.byKey(ValueKey(key))).opacity, 0);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }

    await _pump(
      tester,
      AgentData.agents[AgentType.veto]!.abilities[1],
      isAttack: true,
      abilitySize: Settings.abilitySize,
    );
    expect(
      find.byKey(const ValueKey('circle-optional-range-layer')),
      findsNothing,
    );
  });

  testWidgets('a range turned on draws around the icon, past the box',
      (tester) async {
    tester.view.physicalSize = _canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      AgentData.agents[AgentType.raze]!.abilities[3],
      isAttack: true,
      abilitySize: Settings.abilitySize,
      visualState: _rangeOn,
    );

    final outline = find.byKey(const ValueKey('circle-range-outline-layer'));
    expect(tester.widget<Opacity>(outline).opacity, 1);
    expect(tester.getSize(outline).width, closeTo(_meters(7), 0.001));
    expect(
      tester.getCenter(outline),
      offsetMoreOrLessEquals(tester.getCenter(find.byType(AbilityWidget))),
    );
  });

  testWidgets('Chokehold draws its stealth ring past its saved box',
      (tester) async {
    tester.view.physicalSize = _canvas;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      AgentData.agents[AgentType.veto]!.abilities[1],
      isAttack: true,
      abilitySize: Settings.abilitySize,
      visualState: _rangeOn,
    );

    final icon = tester.getCenter(find.byType(AbilityWidget));
    final ring = find.byKey(const ValueKey('circle-optional-range-layer'));
    expect(tester.getSize(ring).width, closeTo(_meters(9), 0.001));
    expect(tester.getCenter(ring), offsetMoreOrLessEquals(icon));
    final trigger = find.byKey(const ValueKey('circle-range-outline-layer'));
    expect(tester.getSize(trigger).width, closeTo(_meters(6.58), 0.001));
  });

  test('a turned plain icon keeps turning once it has a range', () {
    expect(
      drawsGlyphRotation(PlacedAbility(
        id: 'turned',
        data: AgentData.agents[AgentType.raze]!.abilities[3],
        position: _saved,
        rotation: 1,
      )),
      isTrue,
    );
  });
}
