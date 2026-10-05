import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/strategy/remote_page_merge.dart';

LineUpOrigin _origin(String id, double x) => LineUpOrigin(
      id: id,
      agent: PlacedAgent(
        id: 'agent-$id',
        type: AgentType.sova,
        position: Offset(x, 0),
        lineUpID: id,
      ),
    );

LineUpLanding _landing(String id, double x) => LineUpLanding(
      id: id,
      ability: PlacedAbility(
        id: 'ability-$id',
        data: AgentData.agents[AgentType.sova]!.abilities[2],
        position: Offset(x, 0),
        lineUpID: id,
      ),
    );

LineUpLink _link(String id, String originId, String landingId,
        [String? name]) =>
    LineUpLink(
      id: id,
      originId: originId,
      landingId: landingId,
      name: name ?? id,
    );

void main() {
  List<String> merge(
          List<String> current, List<String> incoming, Set<String> held) =>
      mergeRemoteItems(
        current: current,
        incoming: incoming,
        idOf: (id) => id.split(':').first,
        keep: held.contains,
      );

  test('takes the server copy of everything not held, in server order', () {
    expect(merge(['a:1', 'b:1'], ['b:2', 'c:1', 'a:2'], {}),
        ['b:2', 'c:1', 'a:2']);
  });

  test('a held item keeps its screen copy', () {
    expect(merge(['a:1', 'b:1'], ['a:2', 'b:2'], {'a'}), ['a:1', 'b:2']);
  });

  test('a held item the server removed stays in its place', () {
    expect(merge(['a:1', 'b:1', 'c:1'], ['b:1', 'c:1'], {'a'}),
        ['a:1', 'b:1', 'c:1']);
    expect(merge(['a:1', 'b:1', 'c:1'], ['a:1', 'c:1'], {'b'}),
        ['a:1', 'b:1', 'c:1']);
  });

  test('an unheld item the server removed goes', () {
    expect(merge(['a:1', 'b:1'], ['b:1'], {'b'}), ['b:1']);
  });

  group('held lineups', () {
    // On screen: k1 (o1 → shared) and k2 (o2 → shared) share a landing; k3
    // (o3 → l3) stands apart. The server moved every spot to 9 and renamed
    // every lineup.
    final local = LineUpGraph(
      origins: [_origin('o1', 1), _origin('o2', 1), _origin('o3', 1)],
      landings: [_landing('shared', 1), _landing('l3', 1)],
      links: [
        _link('k1', 'o1', 'shared'),
        _link('k2', 'o2', 'shared'),
        _link('k3', 'o3', 'l3'),
      ],
    );
    final remote = LineUpGraph(
      origins: [_origin('o1', 9), _origin('o2', 9), _origin('o3', 9)],
      landings: [_landing('shared', 9), _landing('l3', 9)],
      links: [
        _link('k1', 'o1', 'shared', 'k1 renamed'),
        _link('k2', 'o2', 'shared', 'k2 renamed'),
        _link('k3', 'o3', 'l3', 'k3 renamed'),
      ],
    );
    // The group rows: g1 holds k1 and k2 with their spots, g3 holds k3 (and
    // a teammate's k4, when there is one).
    const groups = {
      'k1': 'g1',
      'o1': 'g1',
      'k2': 'g1',
      'o2': 'g1',
      'shared': 'g1',
      'k3': 'g3',
      'o3': 'g3',
      'l3': 'g3',
      'k4': 'g3',
      'o4': 'g3',
    };
    String? groupOf(String id) => groups[id];
    Map<String, String> names(LineUpGraph graph) =>
        {for (final link in graph.links) link.id: link.name};
    Map<String, double> spots(LineUpGraph graph) => {
          for (final origin in graph.origins)
            origin.id: origin.agent.position.dx,
          for (final landing in graph.landings)
            landing.id: landing.ability.position.dx,
        };

    test('nothing held takes the server copy whole', () {
      final (graph, held) = mergeHeldLineups(
        local: local,
        remote: remote,
        holding: {'x'},
        groupOf: groupOf,
      );

      expect(held, isEmpty);
      expect(identical(graph, remote), isTrue);
    });

    test('holding a spot holds its whole group, and only that', () {
      final (graph, held) = mergeHeldLineups(
        local: local,
        remote: remote,
        holding: {'o1'},
        groupOf: groupOf,
      );

      // o1 holds group g1, so k2 waits with k1.
      expect(held, {'g1'});
      expect(names(graph), {'k1': 'k1', 'k2': 'k2', 'k3': 'k3 renamed'});
      expect(spots(graph), {
        'o1': 1,
        'o2': 1,
        'o3': 9,
        'shared': 1,
        'l3': 9,
      });
      // Held objects stay the ones on screen.
      expect(identical(graph.origins.first, local.origins.first), isTrue);
    });

    test('a teammate lineup new on a held spot waits off the canvas', () {
      final withNew = LineUpGraph(
        origins: [...remote.origins, _origin('o4', 9)],
        landings: remote.landings,
        links: [...remote.links, _link('k4', 'o4', 'l3')],
      );

      final (graph, held) = mergeHeldLineups(
        local: local,
        remote: withNew,
        holding: {'l3'},
        groupOf: groupOf,
      );

      expect(held, {'g3'});
      expect(graph.links.map((link) => link.id), ['k1', 'k2', 'k3']);
      expect(graph.origins.map((origin) => origin.id), ['o1', 'o2', 'o3']);
      expect(spots(graph)['l3'], 1);
    });

    test('a held lineup the server removed stays in its place', () {
      final without = LineUpGraph(
        origins: [remote.origins[1], remote.origins[2]],
        landings: remote.landings,
        links: [remote.links[1], remote.links[2]],
      );

      final (graph, held) = mergeHeldLineups(
        local: local,
        remote: without,
        holding: {'k1'},
        groupOf: groupOf,
      );

      expect(held, {'g1'});
      expect(graph.links.map((link) => link.id), ['k1', 'k2', 'k3']);
      expect(spots(graph)['o1'], 1);
    });

    test('a group holds lineups no spot connects any more', () {
      // k3 is in g1 too: the lineup that joined it to k1 was deleted, and
      // a group never splits.
      String? oneGroup(String id) => id == 'x' ? null : 'g1';

      final (graph, held) = mergeHeldLineups(
        local: local,
        remote: remote,
        holding: {'k1'},
        groupOf: oneGroup,
      );

      expect(held, {'g1'});
      expect(names(graph), {'k1': 'k1', 'k2': 'k2', 'k3': 'k3'});
    });

    test('a lineup in no group yet holds what shares its spots', () {
      final (graph, held) = mergeHeldLineups(
        local: local,
        remote: remote,
        holding: {'o1'},
        groupOf: (_) => null,
      );

      expect(held, isEmpty);
      expect(names(graph), {'k1': 'k1', 'k2': 'k2', 'k3': 'k3 renamed'});
    });
  });
}
