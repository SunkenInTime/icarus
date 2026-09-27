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

  test('a row of any other kind fails loudly, naming the row', () {
    // Legacy lineup groups included: they are not part of the cloud format.
    for (final kind in ['lineupSomething', 'lineupGroup']) {
      expect(
        () => lineUpGraphFromCloudRows([
          CloudLineupRow(
            publicId: 'odd',
            payload: {'kind': kind, 'payloadVersion': 1, 'data': {}},
          ),
        ]),
        throwsA(isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Cloud lineup odd could not be read'),
        )),
      );
    }
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
