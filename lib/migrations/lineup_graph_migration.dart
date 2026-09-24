import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/strategy_page.dart';

/// Moves a page's lineups onto the origin / landing spot / link graph.
///
/// Legacy groups are upgraded by [StrategyPage] as soon as a page is built
/// (see [LineUpGraph.fromLegacyGroups]); this migration makes the result
/// hold the graph invariants so every reader can rely on them:
/// every link resolves both ends, no node is left without a link, and each
/// node's placed widget carries the node id as its `lineUpID`.
class LineUpGraphMigration {
  static const int version = 99;

  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
  }) {
    return [
      for (final page in pages) _migratePage(page),
    ];
  }

  static StrategyPage _migratePage(StrategyPage page) {
    final normalized = normalize(page.lineUpGraph);
    if (_sameGraph(normalized, page.lineUpGraph)) {
      return page;
    }
    return page.copyWith(lineUpGraph: normalized);
  }

  static LineUpGraph normalize(LineUpGraph graph) {
    final originIds = graph.origins.map((origin) => origin.id).toSet();
    final landingIds = graph.landings.map((landing) => landing.id).toSet();
    final links = [
      for (final link in graph.links)
        if (originIds.contains(link.originId) &&
            landingIds.contains(link.landingId))
          link,
    ];
    final linkedOriginIds = links.map((link) => link.originId).toSet();
    final linkedLandingIds = links.map((link) => link.landingId).toSet();

    return LineUpGraph(
      origins: [
        for (final origin in graph.origins)
          if (linkedOriginIds.contains(origin.id))
            origin.agent.lineUpID == origin.id
                ? origin
                : origin.copyWith(
                    agent: origin.agent.copyWith(lineUpID: origin.id),
                  ),
      ],
      landings: [
        for (final landing in graph.landings)
          if (linkedLandingIds.contains(landing.id))
            landing.ability.lineUpID == landing.id
                ? landing
                : landing.copyWith(
                    ability: landing.ability.copyWith(lineUpID: landing.id),
                  ),
      ],
      links: links,
    );
  }

  static bool _sameGraph(LineUpGraph a, LineUpGraph b) {
    if (a.origins.length != b.origins.length ||
        a.landings.length != b.landings.length ||
        a.links.length != b.links.length) {
      return false;
    }
    for (var i = 0; i < a.origins.length; i++) {
      if (!identical(a.origins[i], b.origins[i])) return false;
    }
    for (var i = 0; i < a.landings.length; i++) {
      if (!identical(a.landings[i], b.landings[i])) return false;
    }
    for (var i = 0; i < a.links.length; i++) {
      if (!identical(a.links[i], b.links[i])) return false;
    }
    return true;
  }
}
