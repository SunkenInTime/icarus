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

    final hasChanged = migratedGroups.length != page.lineUpGroups.length ||
        migratedGroups.asMap().entries.any((entry) {
          final index = entry.key;
          return entry.value != page.lineUpGroups[index];
        });

    if (!hasChanged) {
      return page;
    }

    return page.copyWith(lineUpGroups: migratedGroups);
  }
}
