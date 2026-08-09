import 'package:icarus/const/line_provider.dart';
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
          lineUpGroups: [
            for (final group in page.lineUpGroups) _migrateLineUpGroup(group),
          ],
        ),
    ];
  }

  static LineUpGroup _migrateLineUpGroup(LineUpGroup group) {
    return group.copyWith(
      items: [
        for (final item in group.items)
          item.copyWith(ability: _migrateAbility(item.ability)),
      ],
    );
  }

  static PlacedAbility _migrateAbility(PlacedAbility ability) {
    final migrated = ability.copyWith(
      visualState: ability.visualState.copyWith(showVisionCone: true),
    );
    migrated.isDeleted = ability.isDeleted;
    return migrated;
  }
}
