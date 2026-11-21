import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  final omen = AgentData.agents[AgentType.omen]!;
  final sova = AgentData.agents[AgentType.sova]!;

  void use(InteractionState tool) =>
      container.read(interactionStateProvider.notifier).update(tool);
  void act(ActionGroup group) =>
      container.read(actionProvider.notifier).addAction(
            UserAction(type: ActionType.addition, id: 'item', group: group),
          );
  void show(AgentData? agent) =>
      container.read(abilityBarProvider.notifier).updateData(agent);
  AgentData? shown() => container.read(abilityBarProvider);

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  test('drawing hides the bar and the select tool brings it back', () {
    show(omen);
    use(InteractionState.drawing);
    expect(shown(), omen, reason: 'opening a tool alone hides nothing');

    act(ActionGroup.drawing);
    act(ActionGroup.drawing);
    expect(shown(), isNull);

    use(InteractionState.navigation);
    expect(shown(), omen);
  });

  test('placing an ability keeps the bar', () {
    show(omen);
    act(ActionGroup.ability);
    expect(shown(), omen);
  });

  test('a bar closed on purpose stays closed', () {
    show(omen);
    use(InteractionState.drawing);
    act(ActionGroup.drawing);
    show(null);

    use(InteractionState.navigation);
    expect(shown(), isNull);
  });

  test('an agent picked meanwhile is the one shown', () {
    show(omen);
    use(InteractionState.drawing);
    act(ActionGroup.drawing);
    show(sova);

    use(InteractionState.navigation);
    expect(shown(), sova);
  });

  test('leaving lineup placement closes the bar as before', () {
    show(omen);
    use(InteractionState.drawing);
    act(ActionGroup.drawing);
    use(InteractionState.lineUpPlacing);

    use(InteractionState.navigation);
    expect(shown(), isNull);
  });
}
