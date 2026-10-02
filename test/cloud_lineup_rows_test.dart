import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';

LineUpOrigin _origin(
  String id, {
  Offset position = const Offset(10, 20),
  String? lineUpID,
}) =>
    LineUpOrigin(
      id: id,
      agent: PlacedAgent(
        id: 'agent-$id',
        type: AgentType.sova,
        position: position,
        lineUpID: lineUpID ?? id,
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

/// Two origins into one landing (fan-in), and a second lineup out of
/// origin a (fan-out).
LineUpGraph _shared() => LineUpGraph(
      origins: [_origin('a'), _origin('b')],
      landings: [_landing('shared'), _landing('other')],
      links: [
        LineUpLink(
          id: 'k1',
          originId: 'a',
          landingId: 'shared',
          name: 'A',
          notes: 'jump throw',
          images: [SimpleImageData(id: 'img-1', fileExtension: '.png')],
        ),
        LineUpLink(id: 'k2', originId: 'b', landingId: 'shared', name: 'B'),
        LineUpLink(id: 'k3', originId: 'a', landingId: 'other', name: 'C'),
      ],
    );

/// The row of lineup [id] from [origin] into [landing], as a client that
/// saw that copy of each wrote it.
CloudLineupRow _row(String id, LineUpOrigin origin, LineUpLanding landing) =>
    cloudLineupRows(LineUpGraph(
      origins: [origin],
      landings: [landing],
      links: [
        LineUpLink(id: id, originId: origin.id, landingId: landing.id),
      ],
    )).single;

const _here = Offset(30, 40);
const _moved = Offset(99, 99);
const _elsewhere = Offset(55, 55);

/// Lineups k1, k2 and k3 into landing `shared`: k1 carries it [_here], k2
/// and k3 a copy [_moved] that never reached k1.
List<CloudLineupRow> _splitLanding() => [
      _row('k1', _origin('o1'), _landing('shared')),
      _row('k2', _origin('o2'), _landing('shared', position: _moved)),
      _row('k3', _origin('o3'), _landing('shared', position: _moved)),
    ];

String _json(LineUpGraph graph) => jsonEncode(graph.toJson());

/// [value] as plain JSON.
Object? _plain(Object? value) => jsonDecode(jsonEncode(value));

/// [rows] as canonical JSON, to compare them exactly.
String _canonical(Iterable<CloudLineupRow> rows) =>
    canonicalCloudJsonEncode(_plain([
      for (final row in rows)
        {'publicId': row.publicId, 'payload': row.payload},
    ]));

/// The [end] (`origin` or `landing`) [row] carries.
Map<String, dynamic> _end(CloudLineupRow row, String end) =>
    Map<String, dynamic>.from((row.payload['data'] as Map)[end] as Map);

/// Each lineup's origin and landing ids as [read] draws them.
Map<String, (String, String)> _ends(CloudLineups read) => {
      for (final link in read.graph.links)
        link.id: (link.originId, link.landingId),
    };

Offset _originAt(CloudLineups read, String id) =>
    read.graph.origins.firstWhere((o) => o.id == id).agent.position;

Offset _landingAt(CloudLineups read, String id) =>
    read.graph.landings.firstWhere((l) => l.id == id).ability.position;

/// Every order of [items].
List<List<T>> _orders<T>(List<T> items) => items.length <= 1
    ? [items]
    : [
        for (final (i, first) in items.indexed)
          for (final rest in _orders([...items]..removeAt(i))) [first, ...rest],
      ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('each lineup is one row, carrying its whole origin and landing', () {
    final rows = cloudLineupRows(_shared());

    expect(rows.map((row) => row.publicId), ['k1', 'k2', 'k3']);
    final first = rows.first.payload;
    expect(first['kind'], cloudLineupPayloadKind);
    expect(first['payloadVersion'], currentCloudPayloadVersion);
    final data = first['data'] as Map<String, dynamic>;
    expect(data.keys.toSet(), {
      'id',
      'name',
      'youtubeLink',
      'notes',
      'images',
      'origin',
      'landing',
    });
    // An end is the spot itself, nothing added.
    expect(_plain(data['origin']), _plain(_origin('a').toJson()));
    expect(_plain(data['landing']), _plain(_landing('shared').toJson()));
    expect(data['images'], [
      {'id': 'img-1', 'fileExtension': '.png'},
    ]);
  });

  test('copies that agree draw one shared spot under its real id', () {
    final rows = cloudLineupRows(_shared());

    for (final order in _orders(rows)) {
      final read = lineUpGraphFromCloudRows(order);
      expect(read.aliases.isEmpty, isTrue);
      expect(read.graph.origins.map((o) => o.id).toSet(), {'a', 'b'});
      expect(read.graph.landings.map((l) => l.id).toSet(), {'shared', 'other'});
      expect(_ends(read), {
        'k1': ('a', 'shared'),
        'k2': ('b', 'shared'),
        'k3': ('a', 'other'),
      });
    }

    // Fan-in and fan-out round-trip: the page drawn is the page written,
    // and writing it again gives back the same rows.
    final read = lineUpGraphFromCloudRows(rows);
    expect(_json(read.graph), _json(_shared()));
    final written = cloudLineupRows(read.graph, aliases: read.aliases);
    expect(_canonical(written), _canonical(rows));
  });

  test('copies that disagree draw apart, the smallest lineup id keeping the id',
      () {
    for (final order in _orders(_splitLanding())) {
      final read = lineUpGraphFromCloudRows(order);

      expect(_ends(read), {
        'k1': ('o1', 'shared'),
        'k2': ('o2', 'shared@k2'),
        'k3': ('o3', 'shared@k2'),
      });
      expect(_landingAt(read, 'shared'), _here);
      expect(_landingAt(read, 'shared@k2'), _moved);
      expect(read.graph.landings, hasLength(2));
      expect(read.aliases.landings, {'shared@k2': 'shared'});
      expect(read.aliases.origins, isEmpty);
    }

    // Which copy keeps the id follows the lineup ids, not which copy is
    // newer: here the moved copy is k1's.
    final read = lineUpGraphFromCloudRows([
      _row('k2', _origin('o2'), _landing('shared')),
      _row('k1', _origin('o1'), _landing('shared', position: _moved)),
    ]);
    expect(_ends(read), {
      'k2': ('o2', 'shared@k2'),
      'k1': ('o1', 'shared'),
    });
    expect(_landingAt(read, 'shared'), _moved);
    expect(_landingAt(read, 'shared@k2'), _here);
  });

  test('spots appear in the order the rows first carry them', () {
    final read = lineUpGraphFromCloudRows(_splitLanding().reversed);

    expect(read.graph.origins.map((o) => o.id), ['o3', 'o2', 'o1']);
    expect(read.graph.landings.map((l) => l.id), ['shared@k2', 'shared']);
    expect(read.graph.links.map((l) => l.id), ['k3', 'k2', 'k1']);
  });

  test('three copies that disagree draw three spots', () {
    final rows = [
      _row('k1', _origin('o1'), _landing('shared')),
      _row('k2', _origin('o2'), _landing('shared', position: _moved)),
      _row('k3', _origin('o3'), _landing('shared', position: _elsewhere)),
      _row('k4', _origin('o4'), _landing('shared', position: _moved)),
    ];

    for (final order in _orders(rows)) {
      final read = lineUpGraphFromCloudRows(order);

      expect(_ends(read), {
        'k1': ('o1', 'shared'),
        'k2': ('o2', 'shared@k2'),
        'k3': ('o3', 'shared@k3'),
        'k4': ('o4', 'shared@k2'),
      });
      expect(_landingAt(read, 'shared'), _here);
      expect(_landingAt(read, 'shared@k2'), _moved);
      expect(_landingAt(read, 'shared@k3'), _elsewhere);
      expect(read.aliases.landings, {
        'shared@k2': 'shared',
        'shared@k3': 'shared',
      });
    }
  });

  test('an origin and a landing split on their own', () {
    const far = Offset(70, 80);
    final read = lineUpGraphFromCloudRows([
      _row('k1', _origin('a'), _landing('l')),
      // Only the origin disagrees.
      _row('k2', _origin('a', position: far), _landing('l')),
      // Only the landing disagrees.
      _row('k3', _origin('a'), _landing('l', position: _moved)),
    ]);

    expect(_ends(read), {
      'k1': ('a', 'l'),
      'k2': ('a@k2', 'l'),
      'k3': ('a', 'l@k3'),
    });
    expect(_originAt(read, 'a'), const Offset(10, 20));
    expect(_originAt(read, 'a@k2'), far);
    expect(_landingAt(read, 'l'), _here);
    expect(_landingAt(read, 'l@k3'), _moved);
    expect(read.aliases.origins, {'a@k2': 'a'});
    expect(read.aliases.landings, {'l@k3': 'l'});
  });

  test('an unchanged page writes back every row exactly', () {
    final pages = {
      'agreeing': cloudLineupRows(_shared()),
      'split landing': _splitLanding(),
      'split origin and landing': [
        _row('k1', _origin('a'), _landing('l')),
        _row('k2', _origin('a', position: _elsewhere), _landing('l')),
        _row('k3', _origin('a'), _landing('l', position: _moved)),
        _row('k4', _origin('a', position: _elsewhere), _landing('l')),
      ],
    };

    for (final MapEntry(key: page, value: rows) in pages.entries) {
      // Rows as the server returns them.
      final stored = [
        for (final row in rows)
          CloudLineupRow(
            publicId: row.publicId,
            payload: _plain(row.payload) as Map<String, dynamic>,
          ),
      ];
      final hydrated = lineUpGraphFromCloudRows(stored);

      final written = cloudLineupRows(
        hydrated.graph,
        aliases: hydrated.aliases,
      );

      expect(_canonical(written), _canonical(stored), reason: page);
    }
  });

  test('moving a spot drawn apart changes only the rows carrying it', () {
    final rows = _splitLanding();
    final hydrated = lineUpGraphFromCloudRows(rows);
    LineUpGraph moving(String id, Offset to) => LineUpGraph(
          origins: hydrated.graph.origins,
          landings: [
            for (final landing in hydrated.graph.landings)
              landing.id == id
                  ? LineUpLanding(
                      id: id,
                      ability: landing.ability.copyWith(position: to),
                    )
                  : landing,
          ],
          links: hydrated.graph.links,
        );

    // The aliased spot: k2 and k3 change, under the real id.
    final aliasMoved = cloudLineupRows(
      moving('shared@k2', _elsewhere),
      aliases: hydrated.aliases,
    );
    expect(_canonical([aliasMoved[0]]), _canonical([rows[0]]));
    for (final row in aliasMoved.skip(1)) {
      final landing = _end(row, 'landing');
      expect(landing['id'], 'shared');
      expect((landing['ability'] as Map)['lineUpID'], 'shared');
      expect(
        _plain(landing),
        _plain(_landing('shared', position: _elsewhere).toJson()),
      );
    }
    expect(_end(aliasMoved[1], 'landing'), _end(aliasMoved[2], 'landing'));

    // The spot that kept the id: only k1 changes.
    final realMoved = cloudLineupRows(
      moving('shared', _elsewhere),
      aliases: hydrated.aliases,
    );
    expect(
      _plain(_end(realMoved[0], 'landing')),
      _plain(_landing('shared', position: _elsewhere).toJson()),
    );
    expect(_canonical(realMoved.skip(1)), _canonical(rows.skip(1)));
  });

  test("a marker's lineUpID follows its spot's alias, and back", () {
    final rows = [
      _row('k1', _origin('a'), _landing('l')),
      _row('k2', _origin('a', position: _moved),
          _landing('l', position: _moved)),
      // A marker that never named its spot keeps what it named.
      _row(
        'k3',
        _origin('a', position: _elsewhere, lineUpID: 'unrelated'),
        _landing('l'),
      ),
    ];
    final hydrated = lineUpGraphFromCloudRows(rows);

    final origins = {
      for (final origin in hydrated.graph.origins)
        origin.id: origin.agent.lineUpID,
    };
    expect(origins, {'a': 'a', 'a@k2': 'a@k2', 'a@k3': 'unrelated'});
    expect(
      hydrated.graph.landings
          .firstWhere((l) => l.id == 'l@k2')
          .ability
          .lineUpID,
      'l@k2',
    );

    final written = cloudLineupRows(hydrated.graph, aliases: hydrated.aliases);
    expect((_end(written[1], 'origin')['agent'] as Map)['lineUpID'], 'a');
    expect((_end(written[1], 'landing')['ability'] as Map)['lineUpID'], 'l');
    expect(
      (_end(written[2], 'origin')['agent'] as Map)['lineUpID'],
      'unrelated',
    );
    expect(_canonical(written), _canonical(rows));
  });

  test('a lineup added to a spot drawn apart is written under the real id', () {
    final rows = _splitLanding();
    final hydrated = lineUpGraphFromCloudRows(rows);
    final added = LineUpGraph(
      origins: [...hydrated.graph.origins, _origin('o4')],
      landings: hydrated.graph.landings,
      links: [
        ...hydrated.graph.links,
        LineUpLink(id: 'k4', originId: 'o4', landingId: 'shared@k2'),
      ],
    );

    final written = cloudLineupRows(added, aliases: hydrated.aliases);

    expect(_canonical(written.take(3)), _canonical(rows));
    expect(
        _plain(_end(written[3], 'landing')), _plain(_end(rows[1], 'landing')));
    expect(_end(written[3], 'landing')['id'], 'shared');
    // And it is drawn again on the spot it was added to.
    expect(_ends(lineUpGraphFromCloudRows(written))['k4'], ('o4', 'shared@k2'));
  });

  test('aliases followed by more aliases keep both', () {
    const first = CloudLineupAliases(
      origins: {'a@k2': 'a'},
      landings: {'l@k3': 'l'},
    );
    const second = CloudLineupAliases(origins: {'b@k5': 'b'});

    final both = first.followedBy(second);

    expect(both.origins, {'a@k2': 'a', 'b@k5': 'b'});
    expect(both.landings, {'l@k3': 'l'});
    expect(identical(first.followedBy(CloudLineupAliases.none), first), isTrue);
    expect(CloudLineupAliases.none.isEmpty, isTrue);
  });

  test('a link missing its origin or landing has no row', () {
    final rows = cloudLineupRows(LineUpGraph(
      origins: [_origin('a')],
      landings: [_landing('l')],
      links: [
        LineUpLink(id: 'k1', originId: 'a', landingId: 'l'),
        LineUpLink(id: 'dangling', originId: 'a', landingId: 'missing'),
      ],
    ));

    expect(rows.map((row) => row.publicId), ['k1']);
  });

  test('a row of any other shape fails loudly, naming the row', () {
    final valid = cloudLineupRows(_shared()).first.payload;
    final data = valid['data'] as Map<String, dynamic>;
    final broken = <String, CloudPayload>{
      // The graph rows of protocol 4 and the legacy group are not lineups.
      'lineupLink': {...valid, 'kind': 'lineupLink'},
      'lineupGroup': {...valid, 'kind': 'lineupGroup'},
      'no origin': {
        ...valid,
        'data': {...data}..remove('origin'),
      },
      'no landing': {
        ...valid,
        'data': {...data}..remove('landing'),
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
          contains('Cloud lineup k1 could not be read'),
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
        contains('Cloud lineup someone-else could not be read'),
      )),
      reason: 'a row keyed apart from its lineup',
    );
  });

  test('ops in the cloud format before one row per lineup are retired', () {
    final payload = cloudLineupRows(_shared()).first.payload;
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
    expect(
      isRetiredCloudLineupOp(LineupAddOp(
        opId: 'op',
        lineupPublicId: 'lineupLink:k1',
        pagePublicId: 'p',
        payload: {...payload, 'kind': 'lineupLink'},
        sortIndex: 0,
      )),
      isTrue,
    );
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
