import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_cloud_migration.dart';

LineUpOrigin _origin(String id, Offset position) => LineUpOrigin(
      id: id,
      agent: PlacedAgent(
        id: 'agent-$id',
        type: AgentType.sova,
        position: position,
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

StrategyPage _page(String pageId, LineUpGraph graph) {
  return StrategyPage(
    id: pageId,
    name: pageId,
    drawingData: const [],
    agentData: const [],
    abilityData: const [],
    textData: const [],
    imageData: const [],
    utilityData: const [],
    sortIndex: 0,
    isAttack: true,
    settings: StrategySettings(),
    lineUpOrigins: graph.origins,
    lineUpLandings: graph.landings,
    lineUpLinks: graph.links,
  );
}

/// One lineup whose landing shares its link's id, as the editor made them
/// before the graph synced natively.
LineUpGraph _sharedIdLineup() => LineUpGraph(
      origins: [_origin('origin-1', const Offset(10, 20))],
      landings: [_landing('link-1')],
      links: [
        LineUpLink(id: 'link-1', originId: 'origin-1', landingId: 'link-1'),
      ],
    );

List<LineupAddOp> _upload(
  LineUpGraph graph, {
  Set<String>? usedLineupIds,
}) {
  final ops = <StrategyOp>[];
  appendMigratedPageOps(
    ops,
    _page('page-1', graph),
    usedElementIds: <String>{},
    usedLineupIds: usedLineupIds ?? <String>{},
  );
  return ops.whereType<LineupAddOp>().toList();
}

/// What a client hydrates from the uploaded rows, JSON round-tripped as the
/// server returns them.
LineUpGraph _hydrate(List<LineupAddOp> adds) => _hydrated(adds).graph;

/// [_hydrate], with the version of each spot drawn.
CloudLineups _hydrated(List<LineupAddOp> adds) {
  return lineUpGraphFromCloudRows([
    for (final add in adds)
      CloudLineupRow(
        publicId: add.lineupPublicId,
        payload: jsonDecode(jsonEncode(add.payload)) as Map<String, dynamic>,
      ),
  ]);
}

String _canonical(Object? value) =>
    canonicalCloudJsonEncode(jsonDecode(jsonEncode(value)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a lineup is uploaded as one row carrying its origin and landing', () {
    final adds = _upload(_sharedIdLineup());

    expect(adds.map((add) => add.lineupPublicId), ['link-1']);
    expect(adds.single.payload['kind'], cloudLineupPayloadKind);
    expect(adds.single.sortIndex, 0);
    final data = cloudPayloadData(adds.single.payload);
    expect((data['origin'] as Map)['id'], 'origin-1');
    expect((data['landing'] as Map)['id'], 'link-1');
    // An upload is the spots' first cloud copy.
    expect((data['origin'] as Map)['version'], 1);
    expect((data['landing'] as Map)['version'], 1);
    // Hydrating the upload gives back the page's graph, ids and all, so the
    // page never authors a patch for a lineup nobody touched.
    expect(
      _canonical(_hydrate(adds).toJson()),
      _canonical(_sharedIdLineup().toJson()),
    );
  });

  test('a lineup id another page already took is reassigned', () {
    final adds = _upload(
      _sharedIdLineup(),
      // A page duplicated from page 1 already uploaded this lineup.
      usedLineupIds: {'link-1'},
    );

    final newId = adds.single.lineupPublicId;
    expect(newId, isNot('link-1'));
    final data = cloudPayloadData(adds.single.payload);
    expect(data['id'], newId);
    // Spots are shared within a page only, so its ends keep their ids.
    expect((data['origin'] as Map)['id'], 'origin-1');
    expect((data['landing'] as Map)['id'], 'link-1');

    // And the rows reproduce exactly when the hydrated graph is sent again.
    final hydrated = _hydrated(adds);
    final resent = cloudLineupRows(hydrated.graph, drawn: hydrated);
    expect(
      _canonical([for (final row in resent) row.payload]),
      _canonical([for (final add in adds) add.payload]),
    );
  });

  test('fan-in and fan-out upload with their shared spots and names', () {
    final fanIn = LineUpGraph(
      origins: [
        _origin('origin-a', const Offset(10, 20)),
        _origin('origin-b', const Offset(50, 60)),
      ],
      landings: [_landing('shared'), _landing('other')],
      links: [
        LineUpLink(
          id: 'link-a',
          originId: 'origin-a',
          landingId: 'shared',
          name: 'From heaven',
          images: [SimpleImageData(id: 'image-a', fileExtension: '.png')],
        ),
        LineUpLink(
          id: 'link-b',
          originId: 'origin-b',
          landingId: 'shared',
          name: 'From mid',
        ),
        LineUpLink(
          id: 'link-c',
          originId: 'origin-a',
          landingId: 'other',
          name: 'From heaven, long',
        ),
      ],
    );

    final adds = _upload(fanIn);

    expect(adds.map((add) => add.lineupPublicId), [
      'link-a',
      'link-b',
      'link-c',
    ]);
    final hydrated = _hydrate(adds);
    expect(hydrated.landings.map((landing) => landing.id), [
      'shared',
      'other',
    ]);
    expect(
      [
        for (final link in hydrated.links)
          (link.originId, link.landingId, link.name),
      ],
      [
        ('origin-a', 'shared', 'From heaven'),
        ('origin-b', 'shared', 'From mid'),
        ('origin-a', 'other', 'From heaven, long'),
      ],
    );
    expect(hydrated.links.first.images.single.id, 'image-a');
    expect(_canonical(hydrated.toJson()), _canonical(fanIn.toJson()));
  });
}
