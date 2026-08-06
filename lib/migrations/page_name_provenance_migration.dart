import 'package:icarus/providers/strategy_page.dart';

class PageNameProvenanceMigration {
  static const int version = 95;

  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
  }) {
    return [
      for (final page in pages)
        page.copyWith(
          isAutoNamed: page.name == 'Page ${page.sortIndex + 1}',
        ),
    ];
  }
}
