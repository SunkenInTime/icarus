import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';

class _TestActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    poppedItems = [];
    state = [...state, action];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('PlacedAbility visual state serialization', () {
    test('old json defaults to all-visible visual state', () {
      final ability = PlacedAbility(
        id: 'legacy-ability',
        data: AgentData.agents[AgentType.breach]!.abilities.first,
        position: const Offset(10, 20),
      );

      final legacyJson = Map<String, dynamic>.from(ability.toJson())
        ..remove('visualState');

      final decoded = PlacedAbility.fromJson(legacyJson);

      expect(decoded.visualState.showRangeOutline, isTrue);
      expect(decoded.visualState.showRangeFill, isTrue);
      expect(decoded.visualState.showInnerOutline, isTrue);
      expect(decoded.visualState.showInnerFill, isTrue);
    });

    test('visual state round-trips through json', () {
      final ability = PlacedAbility(
        id: 'roundtrip-ability',
        data: AgentData.agents[AgentType.brimstone]!.abilities[1],
        position: const Offset(50, 60),
        visualState: const AbilityVisualState(
          showRangeOutline: false,
          showRangeFill: false,
          showInnerOutline: false,
          showInnerFill: false,
        ),
      );

      final decoded = PlacedAbility.fromJson(ability.toJson());

      expect(decoded.visualState.showRangeOutline, isFalse);
      expect(decoded.visualState.showRangeFill, isFalse);
      expect(decoded.visualState.showInnerOutline, isFalse);
      expect(decoded.visualState.showInnerFill, isFalse);
    });
  });

  group('Ability visibility undo/redo', () {
    test('map ability visibility participates in existing undo/redo', () {
      final container = ProviderContainer(
        overrides: [
          actionProvider.overrideWith(_TestActionProvider.new),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(abilityProvider.notifier);
      final initialAbility = PlacedAbility(
        id: 'map-ability',
        data: AgentData.agents[AgentType.breach]!.abilities.first,
        position: const Offset(100, 200),
      );

      notifier.fromHive([initialAbility]);
      notifier.updateVisualState(
        0,
        const AbilityVisualState(
          showRangeFill: false,
        ),
      );

      expect(
        container.read(abilityProvider).single.visualState.showRangeFill,
        isFalse,
      );

      container.read(actionProvider.notifier).undoAction();
      expect(
        container.read(abilityProvider).single.visualState.showRangeFill,
        isTrue,
      );

      container.read(actionProvider.notifier).redoAction();
      expect(
        container.read(abilityProvider).single.visualState.showRangeFill,
        isFalse,
      );
    });

    test('lineup visibility participates in transaction undo/redo', () {
      final container = ProviderContainer(
        overrides: [
          actionProvider.overrideWith(_TestActionProvider.new),
        ],
      );
      addTearDown(container.dispose);

      final lineUp = LineUp(
        id: 'lineup-1',
        agent: PlacedAgent(
          id: 'lineup-agent',
          type: AgentType.breach,
          position: const Offset(20, 20),
        ),
        ability: PlacedAbility(
          id: 'lineup-ability',
          data: AgentData.agents[AgentType.breach]!.abilities.first,
          position: const Offset(40, 40),
        ),
        youtubeLink: '',
        images: const [],
        notes: '',
      );

      container.read(lineUpProvider.notifier).fromHive([lineUp]);
      container.read(actionProvider.notifier).performTransaction(
        groups: const [ActionGroup.lineUp],
        mutation: () {
              container.read(lineUpProvider.notifier).updateAbilityVisualState(
                lineUp.id,
                const AbilityVisualState(
                  showRangeFill: false,
                ),
              );
        },
      );

      expect(
        container
            .read(lineUpProvider)
            .lineUps
            .single
            .ability
            .visualState
            .showRangeFill,
        isFalse,
      );

      container.read(actionProvider.notifier).undoAction();
      expect(
        container
            .read(lineUpProvider)
            .lineUps
            .single
            .ability
            .visualState
            .showRangeFill,
        isTrue,
      );

      container.read(actionProvider.notifier).redoAction();
      expect(
        container
            .read(lineUpProvider)
            .lineUps
            .single
            .ability
            .visualState
            .showRangeFill,
        isFalse,
      );
    });
  });
}
