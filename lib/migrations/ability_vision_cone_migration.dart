import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/strategy_page.dart';

class AbilityVisionConeMigration {
  static const int version = 95;

  static List<StrategyPage> migratePages({required List<StrategyPage> pages}) {
    return [
      for (final page in pages)
        page.copyWith(
          abilityData: [
            for (final ability in page.abilityData) _migrateAbility(ability),
          ],
          lineUpGraph: page.lineUpGraph.mapNodes(ability: _migrateAbility),
        ),
    ];
  }

  static PlacedAbility _migrateAbility(PlacedAbility ability) {
    final migrated = ability.copyWith(
      visualState: ability.visualState.copyWith(showVisionCone: true),
    );
    migrated.isDeleted = ability.isDeleted;
    return migrated;
  }
}
