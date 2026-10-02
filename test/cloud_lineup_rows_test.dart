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

/// Two origins into one landing, and a second lineup out of origin a.
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

String _json(LineUpGraph graph) => jsonEncode(graph.toJson());

/// [rows] as canonical JSON, to compare them exactly.
String _canonical(Iterable<CloudLineupRow> rows) =>
    canonicalCloudJsonEncode(jsonDecode(jsonEncode([
      for (final row in rows)
        {'publicId': row.publicId, 'payload': row.payload},
    ])));

/// [json], as JSON, with a version, as a row carries a spot.
Map<String, dynamic> _versioned(Object json, int version) => {
      ...jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      'version': version,
    };

/// The [end] (`origin` or `landing`) [row] carries.
Map<String, dynamic> _end(CloudLineupRow row, String end) =>
    Map<String, dynamic>.from((row.payload['data'] as Map)[end] as Map);

/// [row] with its ends' versions set to [origin] and [landing] (or removed,
/// for [_noVersion]), as another client may have written it.
CloudLineupRow _atVersions(
  CloudLineupRow row, {
  Object? origin,
  Object? landing,
}) {
  Map<String, dynamic> withVersion(String end, Object? version) {
    final json = _end(row, end);
    if (version == null) return json;
    if (identical(version, _noVersion)) return json..remove('version');
    return json..['version'] = version;
  }

  return CloudLineupRow(
    publicId: row.publicId,
    payload: {
      ...row.payload,
      'data': {
        ...Map<String, dynamic>.from(row.payload['data'] as Map),
        'origin': withVersion('origin', origin),
        'landing': withVersion('landing', landing),
      },
    },
  );
}

const _noVersion = Object();

/// [_shared] with landing `shared` moved.
LineUpGraph _sharedMoved() => LineUpGraph(
      origins: _shared().origins,
      landings: [
        _landing('shared', position: const Offset(99, 99)),
        _landing('other'),
      ],
      links: _shared().links,
    );

Offset _landingAt(CloudLineups read, String id) =>
    read.graph.landings.firstWhere((l) => l.id == id).ability.position;

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
    // A spot nothing was drawn from yet starts at version 1.
    expect(data['origin'], _versioned(_origin('a').toJson(), 1));
    expect(data['landing'], _versioned(_landing('shared').toJson(), 1));
    expect(data['images'], [
      {'id': 'img-1', 'fileExtension': '.png'},
    ]);
  });

  test('shared spots read back as one spot, sharing intact', () {
    final read = lineUpGraphFromCloudRows(cloudLineupRows(_shared()));

    expect(_json(read.graph), _json(_shared()));
    expect(read.originVersions, {'a': 1, 'b': 1});
    expect(read.landingVersions, {'shared': 1, 'other': 1});
  });

  test('fan-in and fan-out round-trip through rows drawn and written again',
      () {
    // Rows another client left at versions past 1.
    final rows = [
      for (final row in cloudLineupRows(_shared()))
        _atVersions(row, origin: 2, landing: 4),
    ];

    final read = lineUpGraphFromCloudRows(rows);
    expect(_json(read.graph), _json(_shared()));
    expect(read.originVersions, {'a': 2, 'b': 2});
    expect(read.landingVersions, {'shared': 4, 'other': 4});

    // Nothing changed, so writing what was drawn gives back the same rows,
    // versions and all.
    final written = cloudLineupRows(read.graph, drawn: read);
    expect(_canonical(written), _canonical(rows));
    expect(_json(lineUpGraphFromCloudRows(written).graph), _json(_shared()));
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

  test('a spot keeps its version while unchanged and goes one past it changed',
      () {
    final drawn = lineUpGraphFromCloudRows([
      for (final row in cloudLineupRows(_shared()))
        _atVersions(row, origin: 3, landing: 5),
    ]);
    // Landing `shared` moved, lineup k1 renamed, and a new lineup from a new
    // origin into a new landing.
    final edited = LineUpGraph(
      origins: [..._sharedMoved().origins, _origin('c')],
      landings: [..._sharedMoved().landings, _landing('fresh')],
      links: [
        for (final link in _sharedMoved().links)
          link.id == 'k1'
              ? LineUpLink(
                  id: 'k1',
                  originId: 'a',
                  landingId: 'shared',
                  name: 'A, renamed',
                )
              : link,
        LineUpLink(id: 'k4', originId: 'c', landingId: 'fresh'),
      ],
    );

    final rows = cloudLineupRows(edited, drawn: drawn);

    expect(
      {
        for (final row in rows)
          row.publicId: (
            _end(row, 'origin')['version'],
            _end(row, 'landing')['version'],
          ),
      },
      {
        // A lineup's own fields are not its spots: renaming k1 leaves
        // origin a at 3. Every row carrying the moved landing carries it
        // one past the version drawn.
        'k1': (3, 6),
        'k2': (3, 6),
        'k3': (3, 5),
        // Spots nothing was drawn from start at 1.
        'k4': (1, 1),
      },
    );
    expect(_end(rows[1], 'landing'), _end(rows[0], 'landing'));
  });

  test('a change that reached only some rows outranks the copies it missed',
      () {
    final before = [
      for (final row in cloudLineupRows(_shared()))
        _atVersions(row, origin: 1, landing: 5),
    ];
    final drawn = lineUpGraphFromCloudRows(before);
    final moved = cloudLineupRows(_sharedMoved(), drawn: drawn);
    expect(_end(moved[0], 'landing')['version'], 6);

    // Only k1's write landed. k2 still holds the old copy and, at an equal
    // version, would win on its greater lineup id.
    final partial = lineUpGraphFromCloudRows([moved[0], before[1], before[2]]);

    expect(_landingAt(partial, 'shared'), const Offset(99, 99));
    expect(partial.landingVersions['shared'], 6);

    // Writing what is drawn brings k2's copy back in line, at the same
    // version, since the drawn spot itself did not change.
    final healed = cloudLineupRows(partial.graph, drawn: partial);
    expect(_end(healed[1], 'landing'), _end(moved[0], 'landing'));
    expect(_canonical(healed), _canonical(moved));
  });

  test('disagreeing copies draw the highest version, then the greatest id', () {
    final original = cloudLineupRows(_shared());
    final moved = cloudLineupRows(_sharedMoved());
    // Every order the rows can arrive in draws the same spot.
    void expectDrawn(
      List<CloudLineupRow> rows,
      Offset position,
      int version,
    ) {
      for (final order in [rows, rows.reversed.toList()]) {
        final read = lineUpGraphFromCloudRows(order);
        expect(_landingAt(read, 'shared'), position);
        expect(read.landingVersions['shared'], version);
      }
    }

    // k2 carries the moved copy at a higher version than k1.
    expectDrawn(
      [
        _atVersions(original[0], landing: 3),
        _atVersions(moved[1], landing: 4),
      ],
      const Offset(99, 99),
      4,
    );
    // The original copy ahead wins though its lineup id is lower.
    expectDrawn(
      [
        _atVersions(original[0], landing: 3),
        _atVersions(moved[1], landing: 2),
      ],
      const Offset(30, 40),
      3,
    );
    // A tie goes to the greatest lineup id (k2 over k1).
    expectDrawn(
      [
        _atVersions(original[0], landing: 5),
        _atVersions(moved[1], landing: 5),
      ],
      const Offset(99, 99),
      5,
    );

    // Each spot is ranked on its own: origin a is drawn from k3, landing
    // shared from k1.
    final movedOrigin = cloudLineupRows(LineUpGraph(
      origins: [_origin('a', position: const Offset(77, 77)), _origin('b')],
      landings: _shared().landings,
      links: _shared().links,
    ));
    final read = lineUpGraphFromCloudRows([
      _atVersions(moved[0], origin: 1, landing: 2),
      _atVersions(original[1], origin: 1, landing: 1),
      _atVersions(movedOrigin[2], origin: 2, landing: 1),
    ]);
    expect(
      read.graph.origins.firstWhere((o) => o.id == 'a').agent.position,
      const Offset(77, 77),
    );
    expect(_landingAt(read, 'shared'), const Offset(99, 99));
    expect(read.originVersions, {'a': 2, 'b': 1});
    expect(read.landingVersions, {'shared': 2, 'other': 1});
    // A spot keeps the place its first row gave it, whichever row's copy is
    // drawn.
    expect(read.graph.origins.map((o) => o.id), ['a', 'b']);
    expect(read.graph.landings.map((l) => l.id), ['shared', 'other']);
  });

  test('an end without a whole positive version fails loudly, naming the row',
      () {
    final valid = cloudLineupRows(_shared()).first;
    for (final end in ['origin', 'landing']) {
      for (final version in <Object?>[_noVersion, 0, -1, 1.5, '2', true]) {
        final row = end == 'origin'
            ? _atVersions(valid, origin: version)
            : _atVersions(valid, landing: version);
        expect(
          () => lineUpGraphFromCloudRows([row]),
          throwsA(isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Cloud lineup k1 could not be read'),
              contains('its $end has no version'),
            ),
          )),
          reason: '$end at $version',
        );
      }
    }
    // A version the server returns as a float64 integer reads as that
    // integer.
    final read = lineUpGraphFromCloudRows([
      _atVersions(valid, origin: 2.0, landing: 3.0),
    ]);
    expect(read.originVersions, {'a': 2});
    expect(read.landingVersions, {'shared': 3});
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
      throwsA(isA<FormatException>()),
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
