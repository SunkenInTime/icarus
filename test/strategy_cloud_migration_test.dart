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
LineUpGraph _hydrate(List<LineupAddOp> adds) {
  return lineUpGraphFromCloudRows([
    for (final add in adds)
      CloudLineupRow(
        publicId: add.lineupPublicId,
        payload: jsonDecode(jsonEncode(add.payload)) as Map<String, dynamic>,
      ),
  ]).graph;
}

String _canonical(Object? value) =>
    canonicalCloudJsonEncode(jsonDecode(jsonEncode(value)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a lineup is uploaded as one row per origin, landing and link', () {
    final adds = _upload(_sharedIdLineup());

    expect(adds.map((add) => add.lineupPublicId), [
      'lineupOrigin:origin-1',
      'lineupLanding:link-1',
      'lineupLink:link-1',
    ]);
    expect(adds.map((add) => add.payload['kind']), [
      'lineupOrigin',
      'lineupLanding',
      'lineupLink',
    ]);
    expect(adds.map((add) => add.sortIndex), [0, 1, 2]);
    // Hydrating the upload gives back the page's graph, ids and all, so the
    // page never authors a patch for a lineup nobody touched.
    expect(
      _canonical(_hydrate(adds).toJson()),
      _canonical(_sharedIdLineup().toJson()),
    );
  });

  test('an id another page already took is reassigned with its references', () {
    final adds = _upload(
      _sharedIdLineup(),
      // A page duplicated from page 1 already uploaded this origin.
      usedLineupIds: {'lineupOrigin:origin-1'},
    );

    final origin = cloudPayloadData(adds[0].payload);
    final newOriginId = origin['id'] as String;
    expect(newOriginId, isNot('origin-1'));
    expect(adds[0].lineupPublicId, 'lineupOrigin:$newOriginId');
    expect((origin['agent'] as Map)['lineUpID'], newOriginId);
    // The landing and link ids were free, so they stay.
    expect(adds[1].lineupPublicId, 'lineupLanding:link-1');
    expect(adds[2].lineupPublicId, 'lineupLink:link-1');
    expect(cloudPayloadData(adds[2].payload)['originId'], newOriginId);

    // And the rows reproduce exactly when the hydrated graph is sent again.
    final resent = cloudLineupRows(_hydrate(adds));
    expect(
      _canonical([for (final row in resent) row.payload]),
      _canonical([for (final add in adds) add.payload]),
    );
  });

  test('a fan-in lineup uploads with its shared landing and link names', () {
    final fanIn = LineUpGraph(
      origins: [
        _origin('origin-a', const Offset(10, 20)),
        _origin('origin-b', const Offset(50, 60)),
      ],
      landings: [_landing('shared')],
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
      ],
    );

    final adds = _upload(fanIn);

    expect(adds, hasLength(5));
    final hydrated = _hydrate(adds);
    expect(hydrated.landings.single.id, 'shared');
    expect(
      [for (final link in hydrated.links) (link.landingId, link.name)],
      [('shared', 'From heaven'), ('shared', 'From mid')],
    );
    expect(hydrated.links.first.images.single.id, 'image-a');
    expect(_canonical(hydrated.toJson()), _canonical(fanIn.toJson()));
  });
}
