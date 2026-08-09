import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/migrations/ability_vision_cone_migration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

void main() {
  group('AbilityVisionConeMigration', () {
    test('initializes map and lineup ability state and bumps the version', () {
      final strategy =
          _strategy(version: AbilityVisionConeMigration.version - 1);

      final migrated = StrategyProvider.migrateAbilityVisionCones(strategy);
      final page = migrated.pages.single;

      expect(migrated.versionNumber, Settings.versionNumber);
      expect(page.abilityData.single.visualState.showVisionCone, isTrue);
      expect(
        page.lineUpGroups.single.items.single.ability.visualState
            .showVisionCone,
        isTrue,
      );
      expect(page.abilityData.single.isDeleted, isTrue);
    });

    test('does not rewrite a strategy already at the migration version', () {
      final strategy = _strategy(version: AbilityVisionConeMigration.version);

      expect(
        identical(
          StrategyProvider.migrateAbilityVisionCones(strategy),
          strategy,
        ),
        isTrue,
      );
    });

    test('runs through the current-version migration pipeline', () {
      final strategy =
          _strategy(version: AbilityVisionConeMigration.version - 1);

      final migrated = StrategyProvider.migrateToCurrentVersion(strategy);

      expect(migrated.versionNumber, Settings.versionNumber);
      expect(
        migrated.pages.single.abilityData.single.visualState.showVisionCone,
        isTrue,
      );
      expect(
        migrated.pages.single.lineUpGroups.single.items.single.ability
            .visualState.showVisionCone,
        isTrue,
      );
    });
  });
}

StrategyData _strategy({required int version}) {
  PlacedAbility hiddenAbility(String id) {
    return PlacedAbility(
      id: id,
      data: AgentData.agents[AgentType.killjoy]!.abilities[2],
      position: Offset.zero,
      visualState: const AbilityVisualState(showVisionCone: false),
    );
  }

  final mapAbility = hiddenAbility('map-turret')..isDeleted = true;
  final lineUpAbility = hiddenAbility('lineup-turret');

  return StrategyData(
    id: 'strategy-id',
    name: 'Vision cone migration test',
    mapData: MapValue.ascent,
    versionNumber: version,
    lastEdited: DateTime.utc(2026, 1, 1),
    folderID: null,
    pages: [
      StrategyPage(
        id: 'page-1',
        sortIndex: 0,
        name: 'Page 1',
        drawingData: const [],
        agentData: const [],
        abilityData: [mapAbility],
        textData: const [],
        imageData: const [],
        utilityData: const [],
        isAttack: true,
        settings: StrategySettings(),
        lineUpGroups: [
          LineUpGroup(
            id: 'lineup-group',
            agent: PlacedAgent(
              id: 'lineup-agent',
              type: AgentType.killjoy,
              position: Offset.zero,
            ),
            items: [
              LineUpItem(id: 'lineup-item', ability: lineUpAbility),
            ],
          ),
        ],
      ),
    ],
  );
}
