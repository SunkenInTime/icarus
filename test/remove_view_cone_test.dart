import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/page_transition/transition_planner.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';

class _NoopActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    state = [...state, action];
  }
}

void main() {
  test('removing a view cone preserves the underlying agent', () {
    final container = ProviderContainer(
      overrides: [
        actionProvider.overrideWith(_NoopActionProvider.new),
      ],
    );
    addTearDown(container.dispose);

    final original = PlacedViewConeAgent(
      id: 'view-cone-agent',
      type: AgentType.sova,
      position: const Offset(180, 220),
      isAlly: false,
      state: AgentState.dead,
      presetType: UtilityType.viewCone90,
      rotation: 0.75,
      length: 90,
      visionElevation: 2,
    )..isDeleted = true;
    final notifier = container.read(agentProvider.notifier);
    notifier.fromHive([original]);

    expect(notifier.convertViewConeAgentToPlain(id: original.id), isTrue);

    final converted = container.read(agentProvider).single;
    expect(converted, isA<PlacedAgent>());
    expect(converted.id, original.id);
    expect(converted.type, original.type);
    expect(converted.position, original.position);
    expect(converted.isAlly, original.isAlly);
    expect(converted.state, original.state);
    expect(converted.isDeleted, original.isDeleted);
  });

  test('removing a view cone ignores plain agents', () {
    final container = ProviderContainer(
      overrides: [
        actionProvider.overrideWith(_NoopActionProvider.new),
      ],
    );
    addTearDown(container.dispose);

    final original = PlacedAgent(
      id: 'plain-agent',
      type: AgentType.jett,
      position: const Offset(100, 120),
    );
    final notifier = container.read(agentProvider.notifier);
    notifier.fromHive([original]);

    expect(notifier.convertViewConeAgentToPlain(id: original.id), isFalse);
    expect(container.read(agentProvider).single, same(original));
    expect(container.read(actionProvider), isEmpty);
  });

  test('view-cone removal maps the same agent through page transitions', () {
    final withCone = PlacedViewConeAgent(
      id: 'transition-agent',
      type: AgentType.sova,
      position: const Offset(200, 300),
      presetType: UtilityType.viewCone90,
      rotation: 0.5,
      length: 75,
    );
    final withoutCone = PlacedAgent(
      id: withCone.id,
      type: withCone.type,
      position: withCone.position,
      isAlly: withCone.isAlly,
      state: withCone.state,
    );

    final removal = TransitionPlanner.diff(
      {withCone.id: withCone},
      {withoutCone.id: withoutCone},
    ).single;
    expect(removal.kind, TransitionKind.move);
    expect(removal.id, withCone.id);
    expect(removal.from, same(withCone));
    expect(removal.to, same(withoutCone));

    final attachment = TransitionPlanner.diff(
      {withoutCone.id: withoutCone},
      {withCone.id: withCone},
    ).single;
    expect(attachment.kind, TransitionKind.move);
    expect(attachment.id, withCone.id);
    expect(attachment.from, same(withoutCone));
    expect(attachment.to, same(withCone));
  });
}
