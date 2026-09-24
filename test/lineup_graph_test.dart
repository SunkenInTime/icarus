import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/migrations/lineup_graph_migration.dart';
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

ProviderContainer _createContainer() {
  final container = ProviderContainer(
    overrides: [actionProvider.overrideWith(_TestActionProvider.new)],
  );
  addTearDown(container.dispose);
  return container;
}

PlacedAgent _sova(String id, Offset position) => PlacedAgent(
      id: id,
      type: AgentType.sova,
      position: position,
      isAlly: true,
    );

PlacedAbility _sovaAbility(String id, Offset position) => PlacedAbility(
      id: id,
      data: AgentData.agents[AgentType.sova]!.abilities.first,
      position: position,
      isAlly: true,
    );

LineUpLink _placeFresh(
  LineUpProvider notifier, {
  required String agentId,
  required String abilityId,
  Offset agentPosition = const Offset(100, 100),
  Offset abilityPosition = const Offset(400, 400),
}) {
  notifier.startFresh();
  notifier.setDraftAgent(_sova(agentId, agentPosition));
  notifier.setDraftAbility(_sovaAbility(abilityId, abilityPosition));
  return notifier.commitPlacement()!;
}

void main() {
  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('placement', () {
    test('fresh placement creates an origin, a landing and one link', () {
      final container = _createContainer();
      final notifier = container.read(lineUpProvider.notifier);

      final link = _placeFresh(notifier, agentId: 'a', abilityId: 'b');
      final state = container.read(lineUpProvider);

      expect(state.origins.single.id, link.originId);
      expect(state.landings.single.id, link.landingId);
      expect(state.origins.single.agent.lineUpID, link.originId);
      expect(state.landings.single.ability.lineUpID, link.landingId);
      expect(link.name, '');
      expect(state.placement, isNull);
    });

    test('pinned landing fans in a second origin without a new landing', () {
      final container = _createContainer();
      final notifier = container.read(lineUpProvider.notifier);
      final first = _placeFresh(notifier, agentId: 'a1', abilityId: 'b1');

      notifier.startToLanding(first.landingId);
      notifier.setDraftAgent(_sova('a2', const Offset(900, 100)));
      final second = notifier.commitPlacement()!;

      final state = container.read(lineUpProvider);
      expect(state.landings, hasLength(1));
      expect(state.origins, hasLength(2));
      expect(second.landingId, first.landingId);
      expect(second.originId, isNot(first.originId));
      expect(state.linksToLanding(first.landingId), hasLength(2));
    });

  });

  group('deletion and undo', () {
    test('deleting the last link through a node removes the node', () {
      final container = _createContainer();
      final notifier = container.read(lineUpProvider.notifier);
      final first = _placeFresh(notifier, agentId: 'a1', abilityId: 'b1');
      notifier.startToLanding(first.landingId);
      notifier.setDraftAgent(_sova('a2', const Offset(900, 100)));
      final second = notifier.commitPlacement()!;

      notifier.deleteLink(second.id);

      final state = container.read(lineUpProvider);
      expect(state.links.map((link) => link.id), [first.id]);
      expect(state.origins.map((origin) => origin.id), [first.originId]);
      expect(state.landings, hasLength(1));
    });

    test('deleting a shared landing removes every link and orphaned origin',
        () {
      final container = _createContainer();
      final notifier = container.read(lineUpProvider.notifier);
      final first = _placeFresh(notifier, agentId: 'a1', abilityId: 'b1');
      notifier.startToLanding(first.landingId);
      notifier.setDraftAgent(_sova('a2', const Offset(900, 100)));
      notifier.commitPlacement();

      notifier.deleteLanding(first.landingId);

      final state = container.read(lineUpProvider);
      expect(state.links, isEmpty);
      expect(state.origins, isEmpty);
      expect(state.landings, isEmpty);
    });

    test('undoing an addition removes only its link and orphaned nodes', () {
      final container = _createContainer();
      final notifier = container.read(lineUpProvider.notifier);
      final first = _placeFresh(notifier, agentId: 'a1', abilityId: 'b1');
      notifier.startToLanding(first.landingId);
      notifier.setDraftAgent(_sova('a2', const Offset(900, 100)));
      final second = notifier.commitPlacement()!;
      final addSecond = container.read(actionProvider).last;
      expect(addSecond.id, second.id);

      notifier.undoAction(addSecond);
      var state = container.read(lineUpProvider);
      expect(state.links.map((link) => link.id), [first.id]);
      expect(state.origins.map((origin) => origin.id), [first.originId]);
      expect(state.landings.single.id, first.landingId);

      notifier.redoAction(addSecond);
      state = container.read(lineUpProvider);
      expect(state.links, hasLength(2));
      expect(state.origins, hasLength(2));
      expect(state.landings, hasLength(1));
    });

    test('undoing an origin deletion restores the origin and its links', () {
      final container = _createContainer();
      final notifier = container.read(lineUpProvider.notifier);
      final first = _placeFresh(notifier, agentId: 'a1', abilityId: 'b1');
      notifier.startFromOrigin(first.originId);
      notifier.setDraftAbility(_sovaAbility('b2', const Offset(500, 500)));
      final second = notifier.commitPlacement()!;

      notifier.deleteOrigin(first.originId);
      final deletion = container.read(actionProvider).last;
      expect(deletion.type, ActionType.deletion);
      expect(container.read(lineUpProvider).links, isEmpty);
      expect(container.read(lineUpProvider).landings, isEmpty);

      notifier.undoAction(deletion);
      final state = container.read(lineUpProvider);
      expect(state.links.map((link) => link.id), [first.id, second.id]);
      expect(state.origins.single.id, first.originId);
      expect(state.landings, hasLength(2));
    });
  });

  group('serialization', () {
    test('graph JSON round-trips a fan-in with media', () {
      final container = _createContainer();
      final notifier = container.read(lineUpProvider.notifier);
      final first = _placeFresh(notifier, agentId: 'a1', abilityId: 'b1');
      notifier.startToLanding(first.landingId);
      notifier.setDraftAgent(_sova('a2', const Offset(900, 100)));
      final second = notifier.commitPlacement()!;
      notifier.updateLink(
        second.copyWith(
          name: 'From B main',
          notes: 'aim higher',
          images: [SimpleImageData(id: 'img', fileExtension: 'png')],
        ),
      );

      final graph = container.read(lineUpProvider).graph;
      final encoded = LineUpProvider.objectToJson(graph);
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      expect(decoded.containsKey('lineUpGroups'), isFalse);

      final restored = LineUpProvider.fromJson(encoded);
      expect(
        LineUpProvider.objectToJson(restored),
        encoded,
      );
      expect(restored.links, hasLength(2));
      expect(restored.links.last.name, 'From B main');
      expect(restored.links.last.images.single.id, 'img');
    });

    test('legacy projection writes one group per origin with media', () {
      final container = _createContainer();
      final notifier = container.read(lineUpProvider.notifier);
      final first = _placeFresh(notifier, agentId: 'a1', abilityId: 'b1');
      notifier.startToLanding(first.landingId);
      notifier.setDraftAgent(_sova('a2', const Offset(900, 100)));
      final second = notifier.commitPlacement()!;
      notifier.updateLink(second.copyWith(notes: 'from B main'));

      final groups = container.read(lineUpProvider).graph.toLegacyGroups();

      expect(groups.map((group) => group.id), [first.originId, second.originId]);
      for (final group in groups) {
        expect(group.agent.lineUpID, group.id);
        expect(group.items.single.ability.id, 'b1');
        expect(group.items.single.ability.lineUpID, group.id);
      }
      expect(groups.last.items.single.notes, 'from B main');
    });

    test('legacy groups upgrade without merging stacked landings', () {
      final group = LineUpGroup(
        id: 'group-1',
        agent: _sova('a1', const Offset(100, 100)),
        items: [
          LineUpItem(
            id: 'item-1',
            ability: _sovaAbility('b1', const Offset(400, 400)),
            notes: 'one',
          ),
          LineUpItem(
            id: 'item-2',
            ability: _sovaAbility('b2', const Offset(400, 400)),
            notes: 'two',
          ),
        ],
      );

      final graph = LineUpGraph.fromLegacyGroups([
        group,
        LineUpGroup(id: 'empty', agent: _sova('a2', Offset.zero), items: []),
      ]);

      expect(graph.origins.single.id, 'group-1');
      expect(graph.origins.single.agent.lineUpID, 'group-1');
      expect(graph.landings.map((landing) => landing.id), ['item-1', 'item-2']);
      expect(graph.landings.first.ability.lineUpID, 'item-1');
      expect(graph.links.map((link) => link.id), ['item-1', 'item-2']);
      expect(graph.links.every((link) => link.originId == 'group-1'), isTrue);
      expect(graph.links.map((link) => link.notes), ['one', 'two']);
    });
  });

  group('LineUpGraphMigration', () {
    test('drops dangling links and orphaned nodes, restores lineUpIDs', () {
      final graph = LineUpGraph(
        origins: [
          LineUpOrigin(id: 'o1', agent: _sova('a1', Offset.zero)),
          LineUpOrigin(id: 'orphan', agent: _sova('a2', Offset.zero)),
        ],
        landings: [
          LineUpLanding(id: 'l1', ability: _sovaAbility('b1', Offset.zero)),
        ],
        links: [
          LineUpLink(id: 'k1', originId: 'o1', landingId: 'l1'),
          LineUpLink(id: 'dangling', originId: 'o1', landingId: 'missing'),
        ],
      );

      final normalized = LineUpGraphMigration.normalize(graph);

      expect(normalized.origins.single.id, 'o1');
      expect(normalized.origins.single.agent.lineUpID, 'o1');
      expect(normalized.landings.single.ability.lineUpID, 'l1');
      expect(normalized.links.single.id, 'k1');
    });

    test('is idempotent', () {
      final graph = LineUpGraph(
        origins: [
          LineUpOrigin(id: 'o1', agent: _sova('a1', Offset.zero)),
        ],
        landings: [
          LineUpLanding(id: 'l1', ability: _sovaAbility('b1', Offset.zero)),
        ],
        links: [LineUpLink(id: 'k1', originId: 'o1', landingId: 'l1')],
      );

      final once = LineUpGraphMigration.normalize(graph);
      final twice = LineUpGraphMigration.normalize(once);

      expect(jsonEncode(twice.toJson()), jsonEncode(once.toJson()));
      expect(identical(twice.origins.single, once.origins.single), isTrue);
      expect(identical(twice.landings.single, once.landings.single), isTrue);
    });
  });
}
