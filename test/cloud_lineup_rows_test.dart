import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';

LineUpOrigin _origin(String id) => LineUpOrigin(
      id: id,
      agent: PlacedAgent(
        id: 'agent-$id',
        type: AgentType.sova,
        position: const Offset(10, 20),
        lineUpID: id,
      ),
    );

LineUpLanding _landing(String id) => LineUpLanding(
      id: id,
      ability: PlacedAbility(
        id: 'ability-$id',
        data: AgentData.agents[AgentType.sova]!.abilities[2],
        position: const Offset(30, 40),
        lineUpID: id,
      ),
    );

LineUpGraph _fanIn() => LineUpGraph(
      origins: [_origin('a'), _origin('b')],
      landings: [_landing('shared')],
      links: [
        LineUpLink(id: 'k1', originId: 'a', landingId: 'shared', name: 'A'),
        LineUpLink(id: 'k2', originId: 'b', landingId: 'shared', name: 'B'),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rows are keyed by kind and entity id and read back whole', () {
    final rows = cloudLineupRows(_fanIn());

    expect(rows.map((row) => row.publicId), [
      'lineupOrigin:a',
      'lineupOrigin:b',
      'lineupLanding:shared',
      'lineupLink:k1',
      'lineupLink:k2',
    ]);
    final read = lineUpGraphFromCloudRows(rows);
    expect(read.drawnRowIds, rows.map((row) => row.publicId).toSet());
    expect(jsonEncode(read.graph.toJson()), jsonEncode(_fanIn().toJson()));
  });

  test('only whole lineups are drawn', () {
    final rows = cloudLineupRows(LineUpGraph(
      origins: [_origin('a'), _origin('lonely')],
      landings: [_landing('l')],
      links: [
        LineUpLink(id: 'k1', originId: 'a', landingId: 'l'),
        LineUpLink(id: 'dangling', originId: 'a', landingId: 'missing'),
      ],
    ));

    final read = lineUpGraphFromCloudRows(rows);

    expect(read.drawnRowIds, {
      'lineupOrigin:a',
      'lineupLanding:l',
      'lineupLink:k1',
    });
    expect(read.graph.origins.map((origin) => origin.id), ['a']);
    expect(read.graph.links.map((link) => link.id), ['k1']);
  });

  test('a legacy group reads through its projection; graph rows win', () {
    final group = LineUpGroup(
      id: 'g',
      agent: PlacedAgent(
        id: 'agent-g',
        type: AgentType.sova,
        position: const Offset(1, 2),
      ),
      items: [
        LineUpItem(
          id: 'item',
          ability: _landing('item').ability,
          notes: 'from the group',
        ),
      ],
    );
    final groupRow = CloudLineupRow(
      publicId: 'g',
      payload: {
        'kind': CloudLineupKind.legacyGroup,
        'payloadVersion': 1,
        'data': group.toJson(),
      },
    );

    final legacyOnly = lineUpGraphFromCloudRows([groupRow]);
    expect(legacyOnly.graph.origins.single.id, 'g');
    expect(legacyOnly.graph.links.single.notes, 'from the group');
    expect(legacyOnly.drawnRowIds, {'g'});

    // The same link written again as a graph row by a new client.
    final linkRow = cloudLineupRows(LineUpGraph(links: [
      LineUpLink(
        id: 'item',
        originId: 'g',
        landingId: 'item',
        notes: 'from the graph',
      ),
    ])).single;
    final mixed = lineUpGraphFromCloudRows([groupRow, linkRow]);
    expect(mixed.graph.links.single.notes, 'from the graph');
    expect(mixed.drawnRowIds, {'g', 'lineupLink:item'});
  });

  test('an unknown row kind fails loudly, naming the row', () {
    expect(
      () => lineUpGraphFromCloudRows([
        const CloudLineupRow(
          publicId: 'odd',
          payload: {'kind': 'lineupSomething', 'payloadVersion': 1, 'data': {}},
        ),
      ]),
      throwsA(isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains('Cloud lineup odd could not be read'),
      )),
    );
  });

  test('new ids carry every reference with them', () {
    var next = 0;
    final copy = lineUpGraphWithIds(_fanIn(), (kind, id) => '$kind-${next++}');

    final originIds = copy.origins.map((origin) => origin.id).toSet();
    final landingId = copy.landings.single.id;
    expect(originIds.intersection({'a', 'b'}), isEmpty);
    for (final origin in copy.origins) {
      expect(origin.agent.lineUpID, origin.id);
    }
    expect(copy.landings.single.ability.lineUpID, landingId);
    for (final link in copy.links) {
      expect(originIds, contains(link.originId));
      expect(link.landingId, landingId);
    }
    expect(copy.links.map((link) => link.name), ['A', 'B']);
    expect(
      lineUpGraphFromCloudRows(cloudLineupRows(copy)).graph.links,
      hasLength(2),
    );
  });
}
