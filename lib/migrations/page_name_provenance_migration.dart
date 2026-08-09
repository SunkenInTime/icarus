import 'package:icarus/providers/strategy_page.dart';

class PageNameProvenanceMigration {
  static const int version = 95;

  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
  }) {
    // Historical pages have no trusted signal that distinguishes an automatic
    // "Page N" from a custom name with the same text. Preserve null provenance
    // so structural changes never rewrite a name based on a guess.
    return [
      for (final page in pages) page.copyWith(),
    ];
  }
}
