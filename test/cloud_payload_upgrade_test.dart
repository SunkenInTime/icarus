import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/migrations/paranoia_range_migration.dart';

const _map = MapValue.haven;

final _omen = AgentData.agents[AgentType.omen]!;

PlacedAbility _placed(String id, int index) => PlacedAbility(
      id: id,
      data: _omen.abilities[index],
      position: const Offset(610, 340),
      rotation: 0.7,
      isAlly: false,
    );

/// A payload as a 4.6.3-era client wrote it: version 1, old Paranoia size.
CloudPayload _v1(String kind, Map<String, dynamic> data) {
  final payload = cloudElementPayload(kind: kind, data: data);
  return {...payload, 'payloadVersion': 1};
}

RemotePageSnapshot _page(
    List<CloudPayload> elements, List<CloudPayload> lineups) {
  final now = DateTime.utc(2026, 10, 1);
  return RemotePageSnapshot(
    page: RemotePage(
      publicId: 'page',
      strategyPublicId: 'strategy',
      name: 'Garage retake',
      sortIndex: 0,
      isAttack: true,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    ),
    content: RemotePageContent(
      settings: const {},
      revision: 1,
      createdAt: now,
      updatedAt: now,
    ),
    elements: [
      for (final (i, payload) in elements.indexed)
        RemoteElement(
          publicId: 'element-$i',
          strategyPublicId: 'strategy',
          pagePublicId: 'page',
          elementType: payload['kind'] as String,
          payload: payload,
          sortIndex: i,
          revision: 1,
          deleted: false,
        ),
    ],
    lineups: [
      for (final (i, payload) in lineups.indexed)
        RemoteLineup(
          publicId: 'lineup-$i',
          strategyPublicId: 'strategy',
          pagePublicId: 'page',
          payload: payload,
          sortIndex: i,
          revision: 1,
          deleted: false,
        ),
    ],
    assetsById: const {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a version 1 Paranoia moves exactly as the local migration moves it',
      () {
    final paranoia = _placed('paranoia', 1);
    final upgraded = upgradeCloudPayload(
      _v1('ability', paranoia.toJson()),
      _map,
    );

    expect(upgraded['payloadVersion'], paranoiaCloudPayloadVersion);
    final expected = ParanoiaRangeMigration.migrateAbility(paranoia, _map);
    expect(PlacedAbility.fromJson(cloudPayloadData(upgraded)).position,
        expected.position);
    expect(expected.position, isNot(paranoia.position));
  });

  test('a lineup carrying a Paranoia is never moved', () {
    // Every lineup row was written at the in-game size: correcting one would
    // move its Paranoia twice.
    final lineup = cloudLineupRows(LineUpGraph(
      origins: [
        LineUpOrigin(
          id: 'origin',
          agent: PlacedAgent(
            id: 'omen',
            type: AgentType.omen,
            position: const Offset(340, 210),
            lineUpID: 'origin',
          ),
        ),
      ],
      landings: [LineUpLanding(id: 'landing', ability: _placed('l', 1))],
      links: [
        LineUpLink(id: 'lineup', originId: 'origin', landingId: 'landing'),
      ],
    )).single.payload;

    expect(lineup['payloadVersion'], currentCloudPayloadVersion);
    expect(identical(upgradeCloudPayload(lineup, _map), lineup), isTrue);
    final page = upgradeRemotePageSnapshot(
      _page([_v1('ability', _placed('paranoia', 1).toJson())], [lineup]),
      Maps.mapNames[_map]!,
    );
    expect(identical(page.lineups.single.payload, lineup), isTrue);
  });

  test('rows without a Paranoia are left exactly as the server holds them', () {
    final darkCover = _v1('ability', _placed('dark-cover', 2).toJson());
    final agent = cloudElementPayload(
      kind: 'agent',
      data: PlacedAgent(
        id: 'omen',
        type: AgentType.omen,
        position: const Offset(340, 210),
      ).toJson(),
    );

    expect(identical(upgradeCloudPayload(darkCover, _map), darkCover), isTrue);
    expect(identical(upgradeCloudPayload(agent, _map), agent), isTrue);
    expect(agent['payloadVersion'], currentCloudPayloadVersion);
  });

  test(
      'what this build writes reads back unchanged, so it is never moved twice',
      () {
    final written = cloudElementPayload(
      kind: 'ability',
      data: _placed('paranoia', 1).toJson(),
    );

    expect(written['payloadVersion'], paranoiaCloudPayloadVersion);
    expect(identical(upgradeCloudPayload(written, _map), written), isTrue);
  });

  test('a page snapshot is upgraded row by row', () {
    final paranoia = _v1('ability', _placed('paranoia', 1).toJson());
    final darkCover = _v1('ability', _placed('dark-cover', 2).toJson());
    final page = upgradeRemotePageSnapshot(
      _page([paranoia, darkCover], const []),
      Maps.mapNames[_map]!,
    );

    expect(
      page.elements[0].payload['payloadVersion'],
      paranoiaCloudPayloadVersion,
    );
    expect(identical(page.elements[1].payload, darkCover), isTrue);
  });

  test('a map this build does not know leaves the page as it is', () {
    final source = _page(
      [_v1('ability', _placed('paranoia', 1).toJson())],
      const [],
    );
    expect(
      identical(upgradeRemotePageSnapshot(source, 'not-a-map-yet'), source),
      isTrue,
    );
  });
}
