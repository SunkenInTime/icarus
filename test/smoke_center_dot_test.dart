import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_range_opacity.dart';

const _dotKey = ValueKey('image-ability-center-dot');

void main() {
  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  final smokes = [
    for (final agent in AgentData.agents.values)
      for (final ability in agent.abilities)
        if (ability.abilityData is ImageAbility) ability,
  ];

  Future<void> pumpSmoke(
    WidgetTester tester,
    ImageAbility smoke, {
    double rangeOpacity = 1,
    VoidCallback? onTapSmoke,
  }) {
    return tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Center(
            child: AbilityRangeOpacity(
              opacity: rangeOpacity,
              child: GestureDetector(
                key: const ValueKey('smoke'),
                onTap: onTapSmoke,
                child: smoke.createWidget(
                  id: 'smoke',
                  isAlly: true,
                  mapScale: 1,
                  rotation: 0.7,
                  watchMouse: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  test('every smoke is drawn by an ImageAbility', () {
    final names = smokes.map((s) => s.name).toSet();
    expect(
      names,
      containsAll([
        'Cloudburst',
        'Nebula/Dissipate',
        'Poison Cloud',
        'Sky Smoke',
        'Dark Cover',
        'Ruse',
        'Cove',
        'Waveform',
      ]),
    );
  });

  testWidgets('each smoke marks its exact center, even when turned',
      (tester) async {
    for (final smoke in smokes) {
      await pumpSmoke(tester, smoke.abilityData! as ImageAbility);
      expect(
        tester.getCenter(find.byKey(_dotKey)),
        offsetMoreOrLessEquals(
            tester.getCenter(find.byKey(const ValueKey('smoke')))),
        reason: smoke.name,
      );
    }
  });

  testWidgets('a click on the dot reaches the smoke under it', (tester) async {
    var taps = 0;
    await pumpSmoke(
      tester,
      smokes.first.abilityData! as ImageAbility,
      onTapSmoke: () => taps++,
    );
    await tester.tapAt(tester.getCenter(find.byKey(_dotKey)));
    expect(taps, 1);
  });

  testWidgets('the dot fades with the smoke in a replay', (tester) async {
    await pumpSmoke(
      tester,
      smokes.first.abilityData! as ImageAbility,
      rangeOpacity: 0.3,
    );
    expect(tester.widget<Opacity>(find.byKey(_dotKey)).opacity, 0.3);
  });
}
