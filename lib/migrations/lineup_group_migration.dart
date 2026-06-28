import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/strategy_page.dart';

class LineUpGroupMigration {
  static const int version = 61;

  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
  }) {
    return [
      for (final page in pages) _migratePage(page),
    ];
  }

  static StrategyPage _migratePage(StrategyPage page) {
    bool groupNeedsMigration(LineUpGroup group) {
      if (group.agent.lineUpID != group.id) {
        return true;
      }
      for (final item in group.items) {
        if (item.ability.lineUpID != group.id) {
          return true;
        }
      }
      return false;
    }

    final hasChanged = page.lineUpGroups.any(groupNeedsMigration);
    if (!hasChanged) {
      return page;
    }

    final migratedGroups = [
      for (final group in page.lineUpGroups)
        group.copyWith(
          agent: group.agent.copyWith(lineUpID: group.id),
          items: [
            for (final item in group.items)
              item.copyWith(
                ability: item.ability.copyWith(lineUpID: group.id),
              ),
          ],
        ),
    ];

    return page.copyWith(lineUpGroups: migratedGroups);
  }
}
