import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/migrations/lineup_group_migration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

StrategyData _buildStrategyWithGroup({
  required String? agentLineUpId,
  required String? abilityLineUpId,
}) {
  const groupId = 'group-1';
  final group = LineUpGroup(
    id: groupId,
    agent: PlacedAgent(
      id: 'group-agent',
      type: AgentType.sova,
      position: const Offset(10, 20),
      lineUpID: agentLineUpId,
    ),
    items: [
      LineUpItem(
        id: 'group-item',
        ability: PlacedAbility(
          id: 'group-ability',
          data: AgentData.agents[AgentType.sova]!.abilities.first,
          position: const Offset(30, 40),
          lineUpID: abilityLineUpId,
        ),
      ),
    ],
  );

  return StrategyData(
    id: 'strategy-id',
    name: 'LineUp migration test',
    mapData: MapValue.ascent,
    versionNumber: LineUpGroupMigration.version - 1,
    lastEdited: DateTime.utc(2026, 1, 1),
    folderID: null,
    pages: [
      StrategyPage(
        id: 'page-1',
        sortIndex: 0,
        name: 'Page 1',
        drawingData: const [],
        agentData: const [],
        abilityData: const [],
        textData: const [],
        imageData: const [],
        utilityData: const [],
        isAttack: true,
        settings: StrategySettings(),
        lineUpGroups: [group],
      ),
    ],
  );
}

void main() {
  group('LineUpGroupMigration', () {
    test('does not rewrite strategy when lineup ids are already normalized', () {
      final strategy = _buildStrategyWithGroup(
        agentLineUpId: 'group-1',
        abilityLineUpId: 'group-1',
      );

      final migrated = StrategyProvider.migrateLineUpGroups(strategy);

      expect(identical(migrated, strategy), isTrue);
    });

    test('normalizes missing lineup ids and bumps strategy version', () {
      final strategy = _buildStrategyWithGroup(
        agentLineUpId: null,
        abilityLineUpId: null,
      );

      final migrated = StrategyProvider.migrateLineUpGroups(strategy);
      final group = migrated.pages.single.lineUpGroups.single;

      expect(identical(migrated, strategy), isFalse);
      expect(migrated.versionNumber, Settings.versionNumber);
      expect(group.agent.lineUpID, group.id);
      expect(group.items.single.ability.lineUpID, group.id);
    });
  });
}
