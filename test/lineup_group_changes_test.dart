import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/strategy/lineup_group_changes.dart';

LineUpOrigin _origin(String id, {Offset position = const Offset(10, 20)}) =>
    LineUpOrigin(
      id: id,
      agent: PlacedAgent(
        id: 'agent-$id',
        type: AgentType.brimstone,
        position: position,
        lineUpID: id,
      ),
    );

LineUpLanding _landing(String id, {Offset position = const Offset(30, 40)}) =>
    LineUpLanding(
      id: id,
      ability: PlacedAbility(
        id: 'ability-$id',
        data: AgentData.agents[AgentType.brimstone]!.abilities[2],
        position: position,
        lineUpID: id,
      ),
    );

/// Three smokes from o1, o2, o3 onto one landing; k3 has no name.
LineUpGraph _group({
  Offset landingAt = const Offset(30, 40),
  String k1Notes = '',
  List<LineUpLink> extra = const [],
  bool withoutK2 = false,
}) =>
    LineUpGraph(
      origins: [_origin('o1'), _origin('o2'), _origin('o3')],
      landings: [_landing('l1', position: landingAt)],
      links: [
        LineUpLink(
          id: 'k1',
          originId: 'o1',
          landingId: 'l1',
          name: 'B Main 1',
          notes: k1Notes,
        ),
        if (!withoutK2)
          LineUpLink(
              id: 'k2', originId: 'o2', landingId: 'l1', name: 'B Main 2'),
        LineUpLink(id: 'k3', originId: 'o3', landingId: 'l1'),
        ...extra,
      ],
    );

Map<String, String> _described(List<LineupChange> changes) => {
      for (final change in changes) change.label: change.description,
    };

void main() {
  test('nothing changed lists nothing', () {
    expect(lineupChanges(from: _group(), to: _group()), isEmpty);
  });

  test('each changed lineup is listed once, with everything that changed', () {
    final changes = lineupChanges(
      from: _group(),
      to: _group(landingAt: const Offset(99, 99), k1Notes: 'jump throw'),
    );

    // Moving the shared landing moves every lineup on it.
    expect(_described(changes), {
      'B Main 1': 'notes edited, landing moved',
      'B Main 2': 'landing moved',
      'Brimstone lineup': 'landing moved',
    });
  });

  test('added and deleted lineups are named as such', () {
    final changes = lineupChanges(
      from: _group(),
      to: _group(
        withoutK2: true,
        extra: [
          LineUpLink(id: 'k4', originId: 'o1', landingId: 'l1', name: 'New'),
        ],
      ),
    );

    expect(_described(changes), {'New': 'added', 'B Main 2': 'deleted'});
    expect(changes.last.label, 'B Main 2', reason: 'deletions come last');
  });

  test('a deleted group lists every lineup as deleted', () {
    final changes = lineupChanges(from: _group(), to: LineUpGraph.empty);

    expect(changes.map((change) => change.description).toSet(), {'deleted'});
    expect(changes, hasLength(3));
  });

  test('a fork has fresh ids everywhere and the same lineups', () {
    final original = _group(k1Notes: 'jump throw');
    final fork = forkLineUpGraph(original);

    final originalIds = {
      for (final origin in original.origins) ...[origin.id, origin.agent.id],
      for (final landing in original.landings) ...[
        landing.id,
        landing.ability.id,
      ],
      for (final link in original.links) link.id,
    };
    final forkIds = {
      for (final origin in fork.origins) ...[origin.id, origin.agent.id],
      for (final landing in fork.landings) ...[landing.id, landing.ability.id],
      for (final link in fork.links) link.id,
    };
    expect(forkIds.intersection(originalIds), isEmpty);
    expect(forkIds, hasLength(originalIds.length));

    // The fork is wired like the original: three lineups on one landing,
    // each marker naming its own spot.
    expect(fork.links.map((link) => link.landingId).toSet(), {
      fork.landings.single.id,
    });
    for (final origin in fork.origins) {
      expect(origin.agent.lineUpID, origin.id);
    }
    expect(fork.landings.single.ability.lineUpID, fork.landings.single.id);

    // And otherwise the same: nothing a user sees differs.
    String described(LineUpGraph graph) => [
          for (final link in graph.links)
            '${link.name}|${link.notes}|'
                '${graph.origins.firstWhere((o) => o.id == link.originId).agent.position}|'
                '${graph.landings.firstWhere((l) => l.id == link.landingId).ability.position}',
        ].join(';');
    expect(described(fork), described(original));
  });
}
