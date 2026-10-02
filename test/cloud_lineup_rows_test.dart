import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';

LineUpOrigin _origin(String id, {Offset position = const Offset(10, 20)}) =>
    LineUpOrigin(
      id: id,
      agent: PlacedAgent(
        id: 'agent-$id',
        type: AgentType.sova,
        position: position,
        lineUpID: id,
      ),
    );

LineUpLanding _landing(String id, {Offset position = const Offset(30, 40)}) =>
    LineUpLanding(
      id: id,
      ability: PlacedAbility(
        id: 'ability-$id',
        data: AgentData.agents[AgentType.sova]!.abilities[2],
        position: position,
        lineUpID: id,
      ),
    );

LineUpLink _link(String id, String originId, String landingId) =>
    LineUpLink(id: id, originId: originId, landingId: landingId, name: id);

/// One group: two origins into landing `shared` (fan-in), and a second
/// lineup out of origin a (fan-out). And a second group, k9 alone.
LineUpGraph _page() => LineUpGraph(
      origins: [_origin('a'), _origin('b'), _origin('z')],
      landings: [_landing('shared'), _landing('other'), _landing('far')],
      links: [
        LineUpLink(
          id: 'k1',
          originId: 'a',
          landingId: 'shared',
          name: 'A',
          notes: 'jump throw',
          images: [SimpleImageData(id: 'img-1', fileExtension: '.png')],
        ),
        _link('k2', 'b', 'shared'),
        _link('k9', 'z', 'far'),
        _link('k3', 'a', 'other'),
      ],
    );

String _json(LineUpGraph graph) => jsonEncode(graph.toJson());

/// [rows] as canonical JSON, to compare them exactly.
String _canonical(Iterable<CloudLineupRow> rows) =>
    canonicalCloudJsonEncode(jsonDecode(jsonEncode([
      for (final row in rows)
        {'publicId': row.publicId, 'payload': row.payload},
    ])));

Map<String, dynamic> _data(CloudLineupRow row) =>
    Map<String, dynamic>.from(row.payload['data'] as Map);

List<String> _ids(Object? entries) => [
      for (final entry in entries as List) (entry as Map)['id'] as String,
    ];

void main() {
  test('lineups connected through a spot share one row with their spots', () {
    final written = cloudLineupRows(_page());

    expect(written.rows.map((row) => row.publicId), ['k1', 'k9']);
    final group = written.rows.first;
    expect(group.payload['kind'], cloudLineupsPayloadKind);
    expect(group.payload['payloadVersion'], currentCloudPayloadVersion);
    final data = _data(group);
    expect(data['id'], 'k1');
    expect(_ids(data['origins']), ['a', 'b']);
    expect(_ids(data['landings']), ['shared', 'other']);
    expect(_ids(data['links']), ['k1', 'k2', 'k3']);
    expect(
      (data['links'] as List).first,
      jsonDecode(jsonEncode(_page().links.first.toJson())),
      reason: 'a lineup is stored as the canvas has it',
    );
    expect(_ids(_data(written.rows.last)['links']), ['k9']);
    expect(written.groupOf, {
      for (final id in ['a', 'b', 'shared', 'other', 'k1', 'k2', 'k3'])
        id: 'k1',
      for (final id in ['z', 'far', 'k9']) id: 'k9',
    });
  });

  test('rows draw back the page exactly, and write back the same rows', () {
    final written = cloudLineupRows(_page());
    final read = lineUpGraphFromCloudRows(written.rows);

    expect(read.groupOf, written.groupOf);
    final rewritten = cloudLineupRows(read.graph, groupOf: read.groupOf);
    expect(_canonical(rewritten.rows), _canonical(written.rows));
    // Graph order is rows' order: the round trip keeps every lineup, spot
    // and field.
    expect(
      _json(read.graph),
      _json(LineUpGraph(
        origins: [_origin('a'), _origin('b'), _origin('z')],
        landings: [_landing('shared'), _landing('other'), _landing('far')],
        links: [_page().links[0], _page().links[1], _page().links[3]] +
            [_page().links[2]],
      )),
    );
  });

  test('a group keeps its id when the lineup it was named after goes', () {
    final read = lineUpGraphFromCloudRows(cloudLineupRows(_page()).rows);
    final withoutK1 = LineUpGraph(
      origins: read.graph.origins,
      landings: read.graph.landings,
      links: [
        for (final link in read.graph.links)
          if (link.id != 'k1') link,
      ],
    );

    final rows = cloudLineupRows(withoutK1, groupOf: read.groupOf).rows;
    expect(rows.map((row) => row.publicId), ['k1', 'k9']);
    expect(_ids(_data(rows.first)['links']), ['k2', 'k3']);
  });

  test('a group never splits: halves stay in its row', () {
    // k1 (a -> shared) and k3 (b -> l2) connect only through k2
    // (b -> shared).
    final graph = LineUpGraph(
      origins: [_origin('a'), _origin('b')],
      landings: [_landing('shared'), _landing('l2')],
      links: [
        _link('k1', 'a', 'shared'),
        _link('k2', 'b', 'shared'),
        _link('k3', 'b', 'l2'),
      ],
    );
    final read = lineUpGraphFromCloudRows(cloudLineupRows(graph).rows);

    // Deleting k2 leaves {k1} and {k3} unconnected.
    final split = LineUpGraph(
      origins: graph.origins,
      landings: graph.landings,
      links: [graph.links[0], graph.links[2]],
    );
    final rows = cloudLineupRows(split, groupOf: read.groupOf).rows;
    expect(rows.map((row) => row.publicId), ['k1']);
    expect(_ids(_data(rows.single)['links']), ['k1', 'k3']);

    // Without what the rows said, the halves would be two new groups.
    expect(
      cloudLineupRows(split).rows.map((row) => row.publicId),
      ['k1', 'k3'],
    );
  });

  test('a new lineup on a spot joins that spot\'s group', () {
    final read = lineUpGraphFromCloudRows(cloudLineupRows(_page()).rows);
    final added = LineUpGraph(
      origins: [...read.graph.origins, _origin('c')],
      landings: read.graph.landings,
      links: [...read.graph.links, _link('k0', 'c', 'far')],
    );

    final written = cloudLineupRows(added, groupOf: read.groupOf);
    expect(written.rows.map((row) => row.publicId), ['k1', 'k9']);
    expect(_ids(_data(written.rows.last)['links']), ['k9', 'k0']);
    expect(written.groupOf['k0'], 'k9');
    expect(written.groupOf['c'], 'k9');
  });

  test('a lineup joining two groups goes to one, and neither row goes', () {
    final read = lineUpGraphFromCloudRows(cloudLineupRows(_page()).rows);
    final bridged = LineUpGraph(
      origins: read.graph.origins,
      landings: read.graph.landings,
      links: [...read.graph.links, _link('k5', 'z', 'shared')],
    );

    final written = cloudLineupRows(bridged, groupOf: read.groupOf);
    // k5 joins the smaller group, k1, and carries origin z with it; k9's
    // row keeps z too, and nothing is deleted.
    expect(written.rows.map((row) => row.publicId), ['k1', 'k9']);
    expect(_ids(_data(written.rows.first)['links']), ['k1', 'k2', 'k3', 'k5']);
    expect(_ids(_data(written.rows.first)['origins']), ['a', 'b', 'z']);
    expect(_ids(_data(written.rows.last)['links']), ['k9']);
    expect(_ids(_data(written.rows.last)['origins']), ['z']);
    expect(written.groupOf['z'], 'k9', reason: 'a spot stays in its group');
    expect(written.groupOf['k5'], 'k1');
  });

  test('a lineup two rows name is drawn from the first, and kept there', () {
    // A build that merged groups wrote k9 into k1's row, and was refused
    // deleting k9's row; a teammate has edited k9 there since. Live sync
    // writes k9's row back as stored while k9 is drawn (see
    // _normalizedLocalEntities); the codec only draws one k9.
    CloudLineupRow row(String id, LineUpGraph graph) => CloudLineupRow(
          publicId: id,
          payload: cloudLineupsPayload({
            'id': id,
            'origins': [for (final origin in graph.origins) origin.toJson()],
            'landings': [
              for (final landing in graph.landings) landing.toJson(),
            ],
            'links': [for (final link in graph.links) link.toJson()],
          }),
        );
    final merged = row(
      'k1',
      LineUpGraph(
        origins: [_origin('a'), _origin('z')],
        landings: [_landing('shared'), _landing('far')],
        links: [
          _link('k1', 'a', 'shared'),
          _link('k9', 'z', 'far').copyWith(notes: 'old'),
        ],
      ),
    );
    final teammates = row(
      'k9',
      LineUpGraph(
        origins: [_origin('z')],
        landings: [_landing('far')],
        links: [_link('k9', 'z', 'far').copyWith(notes: 'newer')],
      ),
    );

    final read = lineUpGraphFromCloudRows([merged, teammates]);
    expect(read.graph.links.map((link) => link.id), ['k1', 'k9']);
    expect(read.graph.links.last.notes, 'old');
    expect(read.groupOf['k9'], 'k1');
    expect(
      cloudLineupRows(read.graph, groupOf: read.groupOf)
          .rows
          .map((row) => row.publicId),
      ['k1'],
    );
  });

  test('a new group never takes a group id already in use', () {
    final graph = LineUpGraph(
      origins: [_origin('a')],
      landings: [_landing('l')],
      links: [_link('k1', 'a', 'l'), _link('k2', 'a', 'l')],
    );

    expect(
      cloudLineupRows(graph, takenGroupIds: {'k1'}).rows.single.publicId,
      'k2',
    );
    // A group id remembered for a lineup elsewhere is in use too.
    expect(
      cloudLineupRows(graph, groupOf: {'gone': 'k1'}).rows.single.publicId,
      'k2',
    );
    // Every lineup id taken: a fresh id.
    final fresh = cloudLineupRows(graph, takenGroupIds: {'k1', 'k2'});
    expect(fresh.rows.single.publicId, isNot(anyOf('k1', 'k2')));
    expect(fresh.groupOf['k1'], fresh.rows.single.publicId);
  });

  test('a lineup missing a spot, and a spot no lineup uses, are not written',
      () {
    final rows = cloudLineupRows(LineUpGraph(
      origins: [_origin('a'), _origin('lonely')],
      landings: [_landing('l')],
      links: [
        _link('k1', 'a', 'l'),
        _link('dangling', 'a', 'missing'),
      ],
    )).rows;

    expect(rows.map((row) => row.publicId), ['k1']);
    expect(_ids(_data(rows.single)['origins']), ['a']);
    expect(_ids(_data(rows.single)['links']), ['k1']);
  });

  test('the first row naming a spot or lineup draws it', () {
    // Two clients put lineups on spot `shared` into different groups.
    final first = cloudLineupRows(LineUpGraph(
      origins: [_origin('a')],
      landings: [_landing('shared')],
      links: [_link('k1', 'a', 'shared')],
    )).rows.single;
    final second = cloudLineupRows(LineUpGraph(
      origins: [_origin('b')],
      landings: [_landing('shared', position: const Offset(99, 99))],
      links: [_link('k2', 'b', 'shared')],
    )).rows.single;

    final read = lineUpGraphFromCloudRows([first, second]);
    expect(read.graph.landings.map((l) => l.id), ['shared']);
    expect(read.graph.landings.single.ability.position, const Offset(30, 40));
    expect(read.graph.links.map((l) => l.landingId), ['shared', 'shared']);
    expect(read.groupOf['shared'], 'k1');

    // Written back, both rows stay, each carrying the spot as drawn: no
    // lineup moves rows and no row is deleted.
    final rows = cloudLineupRows(read.graph, groupOf: read.groupOf).rows;
    expect(rows.map((row) => row.publicId), ['k1', 'k2']);
    expect(_ids(_data(rows.last)['links']), ['k2']);
    expect(_ids(_data(rows.last)['landings']), ['shared']);
  });

  test('a row of any other shape fails loudly, naming the row', () {
    final valid = cloudLineupRows(_page()).rows.first.payload;
    final data = Map<String, dynamic>.from(valid['data'] as Map);
    final broken = <String, CloudPayload>{
      // Protocol 4's graph rows, the legacy group, and the per-lineup row
      // this replaced are not groups.
      'lineupLink': {...valid, 'kind': 'lineupLink'},
      'lineupGroup': {...valid, 'kind': 'lineupGroup'},
      'lineup': {...valid, 'kind': 'lineup'},
      'no origins': {
        ...valid,
        'data': {...data}..remove('origins'),
      },
      'no links': {
        ...valid,
        'data': {...data}..remove('links'),
      },
      'a lineup aimed outside the row': {
        ...valid,
        'data': {
          ...data,
          'landings': [
            for (final landing in data['landings'] as List)
              if ((landing as Map)['id'] != 'other') landing,
          ],
        },
      },
      'not objects': {
        ...valid,
        'data': {
          ...data,
          'origins': ['a'],
        },
      },
    };
    for (final MapEntry(key: reason, value: payload) in broken.entries) {
      expect(
        () => lineUpGraphFromCloudRows([
          CloudLineupRow(publicId: 'k1', payload: payload),
        ]),
        throwsA(isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Cloud lineup group k1 could not be read'),
        )),
        reason: reason,
      );
    }
    expect(
      () => lineUpGraphFromCloudRows([
        CloudLineupRow(publicId: 'someone-else', payload: valid),
      ]),
      throwsA(isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains('Cloud lineup group someone-else could not be read'),
      )),
      reason: 'a row keyed apart from its group',
    );
  });

  test('ops in a cloud format before lineup group rows are retired', () {
    final payload = cloudLineupRows(_page()).rows.first.payload;
    expect(
      isRetiredCloudLineupOp(LineupAddOp(
        opId: 'op',
        lineupPublicId: 'k1',
        pagePublicId: 'p',
        payload: payload,
        sortIndex: 0,
      )),
      isFalse,
    );
    for (final kind in ['lineupLink', 'lineup']) {
      expect(
        isRetiredCloudLineupOp(LineupAddOp(
          opId: 'op',
          lineupPublicId: 'k1',
          pagePublicId: 'p',
          payload: {...payload, 'kind': kind},
          sortIndex: 0,
        )),
        isTrue,
        reason: kind,
      );
    }
    for (final key in ['lineupOrigin:a', 'lineupLanding:l', 'lineupLink:k']) {
      expect(
        isRetiredCloudLineupOp(LineupDeleteOp(
          opId: 'op',
          lineupPublicId: key,
          pagePublicId: 'p',
          expectedLineupRevision: 1,
        )),
        isTrue,
        reason: key,
      );
    }
    expect(
      isRetiredCloudLineupOp(const ElementDeleteOp(
        opId: 'op',
        elementPublicId: 'lineupLink:not-a-lineup',
        pagePublicId: 'p',
        expectedElementRevision: 1,
      )),
      isFalse,
    );
  });
}
