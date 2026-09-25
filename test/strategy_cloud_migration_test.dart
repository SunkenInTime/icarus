import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_cloud_migration.dart';

StrategyPage _pageWithLineup(String pageId) {
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
    lineUpOrigins: [
      LineUpOrigin(
        id: 'origin-1',
        agent: PlacedAgent(
          id: 'agent-1',
          type: AgentType.sova,
          position: const Offset(10, 20),
          lineUpID: 'origin-1',
        ),
      ),
    ],
    lineUpLandings: [
      LineUpLanding(
        id: 'link-1',
        ability: PlacedAbility(
          id: 'ability-1',
          data: AgentData.agents[AgentType.sova]!.abilities[2],
          position: const Offset(30, 40),
          lineUpID: 'link-1',
        ),
      ),
    ],
    lineUpLinks: [
      LineUpLink(id: 'link-1', originId: 'origin-1', landingId: 'link-1'),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a reassigned lineup id is written into its nested references', () {
    final ops = <StrategyOp>[];
    appendMigratedPageOps(
      ops,
      _pageWithLineup('page-2'),
      usedElementIds: <String>{},
      // A page duplicated from page 1 already used the group id.
      usedLineupIds: {'origin-1'},
    );

    final add = ops.whereType<LineupAddOp>().single;
    expect(add.lineupPublicId, isNot('origin-1'));
    final data = cloudPayloadData(add.payload);
    expect(data['id'], add.lineupPublicId);
    expect((data['agent'] as Map)['lineUpID'], add.lineupPublicId);
    for (final item in data['items'] as List) {
      expect(((item as Map)['ability'] as Map)['lineUpID'], add.lineupPublicId);
    }

    // Hydrating the uploaded payload and projecting it again reproduces it,
    // so the page never authors a patch for a lineup nobody touched.
    final hydrated = LineUpGraph.fromLegacyGroups([
      LineUpGroup.fromJson(
          jsonDecode(jsonEncode(data)) as Map<String, dynamic>),
    ]);
    String canonical(Object? value) =>
        canonicalCloudJsonEncode(jsonDecode(jsonEncode(value)));
    expect(
      canonical(hydrated.toLegacyGroups().single.toJson()),
      canonical(data),
    );
  });

  test('a lineup keeping its id is uploaded unchanged', () {
    final ops = <StrategyOp>[];
    appendMigratedPageOps(
      ops,
      _pageWithLineup('page-1'),
      usedElementIds: <String>{},
      usedLineupIds: <String>{},
    );

    final add = ops.whereType<LineupAddOp>().single;
    expect(add.lineupPublicId, 'origin-1');
    expect((cloudPayloadData(add.payload)['agent'] as Map)['lineUpID'],
        'origin-1');
  });
}
