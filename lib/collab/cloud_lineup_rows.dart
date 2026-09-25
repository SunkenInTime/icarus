import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/line_provider.dart';

/// The payload kinds of the cloud rows that store a page's lineups.
///
/// A page's lineups are a graph, and the cloud stores it one row per entity
/// so that teammates editing different links, origins or landings never
/// touch the same row.
abstract final class CloudLineupKind {
  static const origin = 'lineupOrigin';
  static const landing = 'lineupLanding';
  static const link = 'lineupLink';

  /// The shape clients wrote before the graph synced: one group per origin,
  /// one item per link. Still read; never written.
  static const legacyGroup = 'lineupGroup';
}

/// One lineup row: an origin, a landing or a link (or a legacy group).
class CloudLineupRow {
  const CloudLineupRow({required this.publicId, required this.payload});

  /// `<payload kind>:<entity id>` for a graph row. Entity ids repeat across
  /// kinds (a landing made with its link shares the link's id, and lineups
  /// from 3.x used one id for all three), so the kind is part of the key.
  /// The entity's own id is `payload.data.id`, exactly as on the canvas.
  final String publicId;
  final CloudPayload payload;
}

String cloudLineupRowId(String kind, String entityId) => '$kind:$entityId';

/// The rows that store [graph]: its origins, then its landings, then its
/// links.
List<CloudLineupRow> cloudLineupRows(LineUpGraph graph) {
  CloudLineupRow row(String kind, String id, Map<String, dynamic> data) {
    return CloudLineupRow(
      publicId: cloudLineupRowId(kind, id),
      payload: cloudLineupPayload(kind: kind, data: data),
    );
  }

  return [
    for (final origin in graph.origins)
      row(CloudLineupKind.origin, origin.id, origin.toJson()),
    for (final landing in graph.landings)
      row(CloudLineupKind.landing, landing.id, landing.toJson()),
    for (final link in graph.links)
      row(CloudLineupKind.link, link.id, link.toJson()),
  ];
}

/// A page's lineup graph as its cloud rows describe it.
class CloudLineupGraph {
  const CloudLineupGraph({required this.graph, required this.drawnRowIds});

  final LineUpGraph graph;

  /// The rows [graph] was built from. Hydration draws only whole lineups: a
  /// link whose origin and landing both exist, and the nodes such links use.
  /// A row outside that (a link that arrived before its landing, an origin a
  /// teammate's delete left without links) is never shown, so a client must
  /// never author a change to it from what it hydrated.
  final Set<String> drawnRowIds;
}

/// Reads a page's live lineup rows, in their stored order, into the graph.
///
/// Legacy group rows are read through [LineUpGraph.fromLegacyGroups]; when a
/// graph row stores the same entity, the graph row wins. Throws a
/// [FormatException] naming the row when one cannot be read.
CloudLineupGraph lineUpGraphFromCloudRows(Iterable<CloudLineupRow> rows) {
  final origins = <String, (LineUpOrigin, String)>{};
  final landings = <String, (LineUpLanding, String)>{};
  final links = <String, (LineUpLink, String)>{};
  final legacyGroups = <(LineUpGroup, String)>[];

  for (final row in rows) {
    final data = cloudPayloadData(row.payload);
    try {
      switch (row.payload['kind']) {
        case CloudLineupKind.origin:
          final origin = LineUpOrigin.fromJson(data);
          origins[origin.id] = (origin, row.publicId);
        case CloudLineupKind.landing:
          final landing = LineUpLanding.fromJson(data);
          landings[landing.id] = (landing, row.publicId);
        case CloudLineupKind.link:
          final link = LineUpLink.fromJson(data);
          links[link.id] = (link, row.publicId);
        case CloudLineupKind.legacyGroup:
          legacyGroups.add((LineUpGroup.fromJson(data), row.publicId));
        case final kind:
          throw FormatException('unknown lineup kind $kind');
      }
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(
        FormatException('Cloud lineup ${row.publicId} could not be read: '
            '$error'),
        stackTrace,
      );
    }
  }

  for (final (group, rowId) in legacyGroups) {
    final legacy = LineUpGraph.fromLegacyGroups([group]);
    for (final origin in legacy.origins) {
      origins.putIfAbsent(origin.id, () => (origin, rowId));
    }
    for (final landing in legacy.landings) {
      landings.putIfAbsent(landing.id, () => (landing, rowId));
    }
    for (final link in legacy.links) {
      links.putIfAbsent(link.id, () => (link, rowId));
    }
  }

  final drawnLinks = [
    for (final entry in links.values)
      if (origins.containsKey(entry.$1.originId) &&
          landings.containsKey(entry.$1.landingId))
        entry,
  ];
  final usedOrigins = {for (final (link, _) in drawnLinks) link.originId};
  final usedLandings = {for (final (link, _) in drawnLinks) link.landingId};
  final drawnOrigins = [
    for (final entry in origins.values)
      if (usedOrigins.contains(entry.$1.id)) entry,
  ];
  final drawnLandings = [
    for (final entry in landings.values)
      if (usedLandings.contains(entry.$1.id)) entry,
  ];

  return CloudLineupGraph(
    graph: LineUpGraph(
      origins: [for (final (origin, _) in drawnOrigins) origin],
      landings: [for (final (landing, _) in drawnLandings) landing],
      links: [for (final (link, _) in drawnLinks) link],
    ),
    drawnRowIds: {
      for (final (_, rowId) in drawnOrigins) rowId,
      for (final (_, rowId) in drawnLandings) rowId,
      for (final (_, rowId) in drawnLinks) rowId,
    },
  );
}

/// [graph] with every origin, landing and link id passed through [newId],
/// and every reference to them (a link's ends, the `lineUpID` of the agent
/// and ability) following along. Used where a copy must not collide with
/// the rows it came from.
LineUpGraph lineUpGraphWithIds(
  LineUpGraph graph,
  String Function(String kind, String id) newId,
) {
  final originIds = {
    for (final origin in graph.origins)
      origin.id: newId(CloudLineupKind.origin, origin.id),
  };
  final landingIds = {
    for (final landing in graph.landings)
      landing.id: newId(CloudLineupKind.landing, landing.id),
  };
  return LineUpGraph(
    origins: [
      for (final origin in graph.origins)
        LineUpOrigin(
          id: originIds[origin.id]!,
          agent: origin.agent.copyWith(lineUpID: originIds[origin.id]!)
            ..isDeleted = origin.agent.isDeleted,
        ),
    ],
    landings: [
      for (final landing in graph.landings)
        LineUpLanding(
          id: landingIds[landing.id]!,
          ability: landing.ability.copyWith(lineUpID: landingIds[landing.id]!)
            ..isDeleted = landing.ability.isDeleted,
        ),
    ],
    links: [
      for (final link in graph.links)
        link.copyWith(
          id: newId(CloudLineupKind.link, link.id),
          originId: originIds[link.originId] ?? link.originId,
          landingId: landingIds[link.landingId] ?? link.landingId,
        ),
    ],
  );
}
