import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/action_provider.dart';

class _NoopActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {}
}

LineUpGraph _breachGraph() {
  return LineUpGraph(
    origins: [
      LineUpOrigin(
        id: 'origin-1',
        agent: PlacedAgent(
          id: 'origin-agent',
          type: AgentType.breach,
          position: const Offset(120, 220),
          lineUpID: 'origin-1',
        ),
      ),
    ],
    landings: [
      LineUpLanding(
        id: 'landing-1',
        ability: PlacedAbility(
          id: 'landing-ability',
          data: AgentData.agents[AgentType.breach]!.abilities.first,
          position: const Offset(10, 20),
          lineUpID: 'landing-1',
        ),
      ),
    ],
    links: [
      LineUpLink(id: 'link-1', originId: 'origin-1', landingId: 'landing-1'),
    ],
  );
}

void main() {
  test('placing from a pinned origin keeps the origin agent canonical', () {
    final container = ProviderContainer(
      overrides: [actionProvider.overrideWith(_NoopActionProvider.new)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(lineUpProvider.notifier);

    notifier.fromHive(_breachGraph());
    notifier.startFromOrigin('origin-1');

    final placement = container.read(lineUpProvider).placement;
    expect(placement?.mode, LineUpPlacementMode.fromPinnedOrigin);
    expect(placement?.pinnedOriginId, 'origin-1');
    expect(placement?.lockedAgentType, AgentType.breach);
    expect(placement?.draftAgent, isNull);
    expect(
      container.read(lineUpProvider).originById('origin-1')?.agent.position,
      const Offset(120, 220),
    );
  });

  test('matching abilities retain canonical positions from a pinned origin',
      () {
    final container = ProviderContainer(
      overrides: [actionProvider.overrideWith(_NoopActionProvider.new)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(lineUpProvider.notifier);
    final ability = PlacedAbility(
      id: 'new-ability',
      data: AgentData.agents[AgentType.breach]!.abilities.first,
      position: const Offset(300, 400),
    );

    notifier.fromHive(_breachGraph());
    notifier.startFromOrigin('origin-1');
    notifier.setDraftAbility(ability);

    final draft = container.read(lineUpProvider).placement?.draftAbility;
    expect(draft?.position, const Offset(300, 400));

    final link = notifier.commitPlacement();
    expect(link?.originId, 'origin-1');
    final landing = container.read(lineUpProvider).landingById(link!.landingId);
    expect(landing?.ability.position, const Offset(300, 400));
    expect(landing?.ability.lineUpID, link.landingId);
  });
}
