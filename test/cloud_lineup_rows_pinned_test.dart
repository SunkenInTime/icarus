import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';

const _pinned = 'test/fixtures/cloud_lineup_rows/rows-as-main-writes-them.json';

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

LineUpLink _link(String id, String originId, String landingId) =>
    LineUpLink(id: id, originId: originId, landingId: landingId, name: id);

typedef _Case = ({
  String shape,
  LineUpGraph graph,
  Map<String, String> groupOf,
  Set<String> takenGroupIds,
});

List<_Case> _cases() {
  final cases = <_Case>[];
  void add(String shape, LineUpGraph graph,
          {Map<String, String> groupOf = const {},
          Set<String> takenGroupIds = const {}}) =>
      cases.add((
        shape: shape,
        graph: graph,
        groupOf: groupOf,
        takenGroupIds: takenGroupIds,
      ));

  add(
    'a dangling lineup repeats a whole lineup id',
    LineUpGraph(
      origins: [_origin('o1')],
      landings: [_landing('l1')],
      links: [_link('k1', 'o1', 'l1'), _link('k1', 'o1', 'gone')],
    ),
  );
  add(
    'a dangling lineup before the whole one with its id',
    LineUpGraph(
      origins: [_origin('o1')],
      landings: [_landing('l1')],
      links: [_link('k1', 'gone', 'l1'), _link('k1', 'o1', 'l1')],
    ),
  );
  add(
    'a lineup whose standing spot is missing',
    LineUpGraph(
      origins: [_origin('o1')],
      landings: [_landing('l1'), _landing('l2')],
      links: [_link('k1', 'o1', 'l1'), _link('k2', 'o9', 'l2')],
    ),
  );
  add(
    'a lineup whose landing is missing',
    LineUpGraph(
      origins: [_origin('o1'), _origin('o2')],
      landings: [_landing('l1')],
      links: [_link('k1', 'o1', 'l1'), _link('k2', 'o2', 'l9')],
    ),
  );
  add(
    'two whole lineups with one id',
    LineUpGraph(
      origins: [_origin('o1'), _origin('o2')],
      landings: [_landing('l1'), _landing('l2')],
      links: [_link('k1', 'o1', 'l1'), _link('k1', 'o2', 'l2')],
    ),
  );
  add(
    'two standing spots with one id',
    LineUpGraph(
      origins: [_origin('o1'), _origin('o1')],
      landings: [_landing('l1'), _landing('l2')],
      links: [_link('k1', 'o1', 'l1'), _link('k2', 'o1', 'l2')],
    ),
  );
  add(
    'two landings with one id',
    LineUpGraph(
      origins: [_origin('o1'), _origin('o2')],
      landings: [_landing('l1'), _landing('l1')],
      links: [_link('k1', 'o1', 'l1'), _link('k2', 'o2', 'l1')],
    ),
  );
  add(
    'a standing spot and a landing with one id',
    LineUpGraph(
      origins: [_origin('x')],
      landings: [_landing('x'), _landing('l2')],
      links: [_link('x', 'x', 'x'), _link('k2', 'x', 'l2')],
    ),
  );
  add(
    'spots no lineup aims at',
    LineUpGraph(
      origins: [_origin('o1'), _origin('lonely')],
      landings: [_landing('l1'), _landing('unused')],
      links: [_link('k1', 'o1', 'l1')],
    ),
  );

  final random = Random(685);
  for (var index = 0; index < 400; index++) {
    final originIds = [
      for (var i = 0; i < 1 + random.nextInt(5); i++) 'o${random.nextInt(6)}',
    ];
    final landingIds = [
      for (var i = 0; i < 1 + random.nextInt(5); i++) 'l${random.nextInt(6)}',
    ];
    final links = [
      for (var i = 0; i < 1 + random.nextInt(8); i++)
        _link(
          'k${random.nextInt(8)}',
          random.nextInt(8) == 0
              ? 'o-gone'
              : originIds[random.nextInt(originIds.length)],
          random.nextInt(8) == 0
              ? 'l-gone'
              : landingIds[random.nextInt(landingIds.length)],
        ),
    ];
    final everyId = [
      ...originIds,
      ...landingIds,
      for (final link in links) link.id,
    ];
    add(
      'generated $index',
      LineUpGraph(
        origins: [for (final id in originIds) _origin(id)],
        landings: [for (final id in landingIds) _landing(id)],
        links: links,
      ),
      groupOf: {
        for (final id in everyId)
          if (random.nextInt(4) == 0) id: 'g${random.nextInt(3)}',
      },
      takenGroupIds: {
        for (final link in links)
          if (random.nextInt(4) == 0) link.id,
      },
    );
  }
  return cases;
}

Object? _written(_Case written) {
  final made = cloudLineupRows(
    written.graph,
    groupOf: written.groupOf,
    takenGroupIds: written.takenGroupIds,
  );
  final known = {
    for (final origin in written.graph.origins) origin.id,
    for (final landing in written.graph.landings) landing.id,
    for (final link in written.graph.links) link.id,
    ...written.groupOf.values,
  };
  String named(String id) => known.contains(id) ? id : 'fresh';
  return jsonDecode(canonicalCloudJsonEncode({
    'shape': written.shape,
    'rows': [
      for (final row in made.rows)
        {
          'id': named(row.publicId),
          'payload': jsonDecode(
            jsonEncode(row.payload)
                .replaceAll(row.publicId, named(row.publicId)),
          ),
        },
    ],
    'groupOf': {
      for (final MapEntry(:key, :value) in made.groupOf.entries)
        key: named(value),
    },
  }));
}

Map<String, String> _pinnedForm(_Case written) {
  final rows = _written(written);
  return {
    'shape': written.shape,
    'rows':
        sha256.convert(utf8.encode(canonicalCloudJsonEncode(rows))).toString(),
  };
}

void main() {
  test('rows come out as main writes them, malformed graphs included', () {
    final written = [for (final graph in _cases()) _pinnedForm(graph)];
    final file = File(_pinned);
    if (Platform.environment['ICARUS_PIN_LINEUP_ROWS'] == '1') {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '${const JsonEncoder.withIndent(' ').convert(written)}\n',
        );
    }
    final pinned = jsonDecode(file.readAsStringSync()) as List;
    expect(written, hasLength(pinned.length));
    for (final (index, rows) in written.indexed) {
      expect(rows, pinned[index]);
    }
  });
}
