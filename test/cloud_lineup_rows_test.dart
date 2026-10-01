import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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

CloudLineupRow _withRevision(CloudLineupRow row, int revision) =>
    CloudLineupRow(
        publicId: row.publicId, payload: row.payload, revision: revision);

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
    expect(data['origin'], jsonDecode(jsonEncode(_origin('a').toJson())));
    expect(
        data['landing'], jsonDecode(jsonEncode(_landing('shared').toJson())));
    expect(data['images'], [
      {'id': 'img-1', 'fileExtension': '.png'},
    ]);
  });

  test('shared spots read back as one spot, sharing intact', () {
    final read = lineUpGraphFromCloudRows(cloudLineupRows(_shared()));

    expect(_json(read), _json(_shared()));
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

  test('disagreeing copies of a spot draw the highest revision, then id', () {
    final moved = LineUpGraph(
      origins: [_origin('a'), _origin('b')],
      landings: [_landing('shared', position: const Offset(99, 99))],
      links: _shared().links.take(2).toList(),
    );
    final original = cloudLineupRows(_shared());
    final edited = cloudLineupRows(moved);
    Offset landingOf(LineUpGraph graph) =>
        graph.landings.firstWhere((l) => l.id == 'shared').ability.position;

    // k2 carries the moved copy at a higher revision than k1.
    var read = lineUpGraphFromCloudRows([
      _withRevision(original[0], 3),
      _withRevision(edited[1], 4),
    ]);
    expect(landingOf(read), const Offset(99, 99));

    // Same rows, the other copy ahead: the order rows arrive in never
    // decides.
    read = lineUpGraphFromCloudRows([
      _withRevision(edited[1], 2),
      _withRevision(original[0], 3),
    ]);
    expect(landingOf(read), const Offset(30, 40));

    // A tie goes to the greatest publicId (k2 over k1).
    read = lineUpGraphFromCloudRows([
      _withRevision(original[0], 5),
      _withRevision(edited[1], 5),
    ]);
    expect(landingOf(read), const Offset(99, 99));
    read = lineUpGraphFromCloudRows([
      _withRevision(edited[1], 5),
      _withRevision(original[0], 5),
    ]);
    expect(landingOf(read), const Offset(99, 99));
    // The spot keeps the place its first row gave it.
    expect(read.landings.map((landing) => landing.id), ['shared']);
  });

  test('drawn payloads carry the copy that is drawn', () {
    final moved = LineUpGraph(
      origins: [_origin('a'), _origin('b')],
      landings: [_landing('shared', position: const Offset(99, 99))],
      links: _shared().links.take(2).toList(),
    );
    final stale = _withRevision(cloudLineupRows(_shared())[0], 1);
    final fresh = _withRevision(cloudLineupRows(moved)[1], 2);

    final drawn = drawnCloudLineupPayloads([stale, fresh]);

    expect(drawn.keys, ['k1', 'k2']);
    expect(drawn['k2'], fresh.payload);
    expect(
      (drawn['k1']!['data'] as Map)['landing'],
      (fresh.payload['data'] as Map)['landing'],
    );
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
      isRetiredCloudLineupOp(ElementDeleteOp(
        opId: 'op',
        elementPublicId: 'lineupLink:not-a-lineup',
        pagePublicId: 'p',
        expectedElementRevision: 1,
      )),
      isFalse,
    );
  });
}
