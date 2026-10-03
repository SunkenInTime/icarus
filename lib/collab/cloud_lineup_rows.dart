import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:uuid/uuid.dart';

/// One cloud row per lineup group: lineups that share a standing spot or a
/// landing spot, stored together with those spots.
///
/// A shared spot lives in its group's row, so it cannot disagree with
/// itself, and the row's one revision guards every lineup on it: two
/// clients changing the same group meet as an ordinary conflict. A row never
/// names anything outside itself.
///
/// A lineup stays in the group it was first written to: deleting the lineup
/// that joined two halves leaves both halves in the row, and groups never
/// merge. That keeps every edit a write to exactly the row the user's
/// lineups already live in, and no row is ever deleted except by deleting
/// its last lineup.
///
/// No two live rows of a page hold the same lineup or spot: the server
/// refuses a write that would make them (see assertLineupGroupAlone in
/// convex/ops.ts), so the work waits in attention rather than two rows
/// disagreeing about one spot.
class CloudLineupRow {
  const CloudLineupRow({required this.publicId, required this.payload});

  CloudLineupRow.remote(RemoteLineup lineup)
      : this(publicId: lineup.publicId, payload: lineup.payload);

  /// The group's id, as in `payload.data.id`.
  final String publicId;
  final CloudPayload payload;
}

/// A page's lineups as cloud rows describe them, and the group each lineup
/// and spot was drawn from (lineup, origin or landing id to group id).
class CloudLineups {
  const CloudLineups({required this.graph, this.groupOf = const {}});

  final LineUpGraph graph;
  final Map<String, String> groupOf;
}

/// The rows that store a page's lineups, and the group each lineup and spot
/// went into.
class CloudLineupRows {
  const CloudLineupRows({required this.rows, required this.groupOf});

  final List<CloudLineupRow> rows;
  final Map<String, String> groupOf;
}

/// A page's lineups as its live [rows] describe them, rows in order.
///
/// Ids are unique within a row and, as the server keeps them, across the
/// page's rows. Should two rows name one anyway, the first draws it, and a
/// lineup in a later row aimed at that spot is drawn to it too.
///
/// Throws a [FormatException] naming the row when one cannot be read.
CloudLineups lineUpGraphFromCloudRows(Iterable<CloudLineupRow> rows) {
  final origins = <String, LineUpOrigin>{};
  final landings = <String, LineUpLanding>{};
  final links = <String, LineUpLink>{};
  final groupOf = <String, String>{};
  for (final row in rows) {
    final group = _readGroupRow(row);
    for (final origin in group.origins) {
      if (origins.containsKey(origin.id)) continue;
      origins[origin.id] = origin;
      groupOf[origin.id] = row.publicId;
    }
    for (final landing in group.landings) {
      if (landings.containsKey(landing.id)) continue;
      landings[landing.id] = landing;
      groupOf[landing.id] = row.publicId;
    }
    for (final link in group.links) {
      if (links.containsKey(link.id)) continue;
      links[link.id] = link;
      groupOf[link.id] = row.publicId;
    }
  }
  return CloudLineups(
    graph: LineUpGraph(
      origins: origins.values.toList(),
      landings: landings.values.toList(),
      links: links.values.toList(),
    ),
    groupOf: groupOf,
  );
}

/// The rows that store [graph], given the group each lineup and spot was in
/// before ([groupOf], from the rows the canvas was drawn from and earlier
/// calls).
///
/// A lineup stays in the group it was first written to, so a group never
/// splits, and no row is ever deleted to tidy groups up: a group's row goes
/// only when its last lineup does. New lineups that share a spot form one
/// component, which joins the group one of its spots is already in (the
/// smallest such group's id, when spots of two groups meet in it), or else
/// is a new group. A new group takes its smallest lineup id that is not
/// already a group's id, here, in [groupOf] or in [takenGroupIds] (or a
/// fresh id, when every one of them is).
///
/// A row holds its lineups and every spot they aim at. The app only ever
/// aims a new lineup at one existing spot, so a spot is in one row. A
/// lineup aimed at spots of two groups would put a spot in two rows; the
/// server refuses that write, and the work waits in attention.
///
/// A lineup whose origin or landing is missing draws nothing on the canvas,
/// so it is not written; neither is a spot no lineup is aimed at. Rows come
/// in the order of their first lineup, their contents in [graph]'s order.
CloudLineupRows cloudLineupRows(
  LineUpGraph graph, {
  Map<String, String> groupOf = const {},
  Set<String> takenGroupIds = const {},
}) {
  final originIds = {for (final origin in graph.origins) origin.id};
  final landingIds = {for (final landing in graph.landings) landing.id};
  final links = [
    for (final link in graph.links)
      if (originIds.contains(link.originId) &&
          landingIds.contains(link.landingId))
        link,
  ];

  // The group of each lineup already in one, and so of the spots they aim
  // at, as far as [groupOf] does not already say.
  final linkGroup = <String, String>{
    for (final link in links)
      if (groupOf[link.id] case final group?) link.id: group,
  };
  final spotGroup = <String, String>{};
  for (final link in links) {
    for (final spot in ['o:${link.originId}', 'l:${link.landingId}']) {
      final group = groupOf[spot.substring(2)] ?? linkGroup[link.id];
      if (group != null) spotGroup.putIfAbsent(spot, () => group);
    }
  }

  // New lineups, joined through the spots they share: each kind of id in
  // its own namespace, so an origin and a landing with one id stay apart.
  final parent = <String, String>{};
  String find(String node) {
    final up = parent[node] ?? node;
    if (up == node) return node;
    return parent[node] = find(up);
  }

  void union(String a, String b) {
    final rootA = find(a);
    final rootB = find(b);
    if (rootA != rootB) parent[rootA] = rootB;
  }

  final newLinks = [
    for (final link in links)
      if (!linkGroup.containsKey(link.id)) link,
  ];
  for (final link in newLinks) {
    union('k:${link.id}', 'o:${link.originId}');
    union('k:${link.id}', 'l:${link.landingId}');
  }
  final componentLinks = <String, List<LineUpLink>>{};
  final componentGroups = <String, Set<String>>{};
  for (final link in newLinks) {
    final root = find('k:${link.id}');
    (componentLinks[root] ??= []).add(link);
    for (final spot in ['o:${link.originId}', 'l:${link.landingId}']) {
      if (spotGroup[spot] case final group?) {
        (componentGroups[root] ??= {}).add(group);
      }
    }
  }

  String smallest(Iterable<String> ids) =>
      ids.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
  final used = <String>{
    ...takenGroupIds,
    ...groupOf.values,
    ...linkGroup.values,
  };
  for (final MapEntry(key: root, value: component) in componentLinks.entries) {
    final String group;
    if (componentGroups[root] case final groups?) {
      group = smallest(groups);
    } else {
      final candidates = [for (final link in component) link.id]..sort();
      group = candidates.firstWhere(
        (candidate) => !used.contains(candidate),
        orElse: () => const Uuid().v4(),
      );
      used.add(group);
    }
    for (final link in component) {
      linkGroup[link.id] = group;
    }
  }

  final linksByGroup = <String, List<LineUpLink>>{};
  for (final link in links) {
    (linksByGroup[linkGroup[link.id]!] ??= []).add(link);
  }
  final assigned = <String, String>{};
  final rows = <CloudLineupRow>[];
  for (final MapEntry(key: id, value: groupLinks) in linksByGroup.entries) {
    final usedOrigins = {for (final link in groupLinks) link.originId};
    final usedLandings = {for (final link in groupLinks) link.landingId};
    final origins = [
      for (final origin in graph.origins)
        if (usedOrigins.contains(origin.id)) origin,
    ];
    final landings = [
      for (final landing in graph.landings)
        if (usedLandings.contains(landing.id)) landing,
    ];
    for (final link in groupLinks) {
      assigned[link.id] = id;
    }
    // A spot carried by two rows stays with the group it was in.
    for (final spot in [...usedOrigins, ...usedLandings]) {
      assigned.putIfAbsent(spot, () => groupOf[spot] ?? id);
    }
    rows.add(
      CloudLineupRow(
        publicId: id,
        payload: cloudLineupsPayload({
          'id': id,
          'origins': [for (final origin in origins) origin.toJson()],
          'landings': [for (final landing in landings) landing.toJson()],
          'links': [for (final link in groupLinks) link.toJson()],
        }),
      ),
    );
  }
  return CloudLineupRows(rows: rows, groupOf: assigned);
}

/// A page's lineups as its [lineups] on the server describe them. Deleted
/// rows draw nothing.
LineUpGraph lineUpGraphFromRemoteLineups(Iterable<RemoteLineup> lineups) {
  return lineUpGraphFromCloudRows([
    for (final lineup in lineups)
      if (!lineup.deleted) CloudLineupRow.remote(lineup),
  ]).graph;
}

/// Whether [op] is a lineup change in a cloud format before one row per
/// lineup group: an origin, landing or link row keyed `<kind>:<id>`. An
/// outbox written by such a build can still hold one; it is never sent.
bool isRetiredCloudLineupOp(StrategyOp op) {
  if (op.entityType != StrategyOpEntityType.lineup) return false;
  final payload = op.payload;
  return (payload is Map && payload['kind'] != cloudLineupsPayloadKind) ||
      _retiredLineupKey.hasMatch(op.entityPublicId ?? '');
}

final _retiredLineupKey = RegExp(r'^lineup(Origin|Landing|Link):');

({
  List<LineUpOrigin> origins,
  List<LineUpLanding> landings,
  List<LineUpLink> links,
}) _readGroupRow(CloudLineupRow row) {
  try {
    final kind = row.payload['kind'];
    if (kind != cloudLineupsPayloadKind) {
      throw FormatException('unknown lineup kind $kind');
    }
    final data = cloudPayloadData(row.payload);
    if (data['id'] != row.publicId) {
      throw FormatException('it holds group ${data['id']}');
    }
    final group = (
      origins: [
        for (final json in _objects(data['origins'], 'origins'))
          LineUpOrigin.fromJson(json),
      ],
      landings: [
        for (final json in _objects(data['landings'], 'landings'))
          LineUpLanding.fromJson(json),
      ],
      links: [
        for (final json in _objects(data['links'], 'links'))
          LineUpLink.fromJson(json),
      ],
    );
    final originIds = {for (final origin in group.origins) origin.id};
    final landingIds = {for (final landing in group.landings) landing.id};
    for (final link in group.links) {
      if (!originIds.contains(link.originId) ||
          !landingIds.contains(link.landingId)) {
        throw FormatException('lineup ${link.id} is aimed outside the row');
      }
    }
    return group;
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(
      FormatException('Cloud lineup group ${row.publicId} could not be read: '
          '$error'),
      stackTrace,
    );
  }
}

List<Map<String, dynamic>> _objects(Object? value, String name) {
  if (value is! List) throw FormatException('it has no $name');
  return [
    for (final entry in value)
      if (entry is Map)
        Map<String, dynamic>.from(entry)
      else
        throw FormatException('its $name hold something other than objects'),
  ];
}
