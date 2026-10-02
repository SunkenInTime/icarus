import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:uuid/uuid.dart';

/// One cloud row per lineup group: lineups that share a standing spot or a
/// landing spot, stored together with those spots.
///
/// A shared spot lives in exactly one row, so it can never disagree with
/// itself, and the row's one revision guards every lineup on it: two
/// clients changing the same group meet as an ordinary conflict. A row never
/// names anything outside itself.
///
/// A group only grows or merges, never splits: deleting the lineup that
/// joined two halves leaves both halves in the row. That keeps every edit a
/// write to exactly the row the user's lineups already live in.
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
/// Ids are unique within a row but nothing stops two rows naming the same
/// one (two clients merging groups at once, say). The first row to name a
/// spot or lineup draws it; a lineup in a later row aimed at that spot is
/// drawn to it too.
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
/// Lineups connected through a spot share a row, and so do lineups that
/// shared one before, so a group never splits. A group connected to two
/// groups (only a merge from two clients makes one) takes the smaller id
/// and the other row is no longer written. A group with no lineup that was
/// in one before is new: it takes its smallest lineup id that is not
/// already a group's id, here, in [groupOf] or in [takenGroupIds] (or a
/// fresh id, when every one of them is).
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

  // Union-find over lineups, spots and earlier groups, each kind in its own
  // namespace so equal ids of different kinds stay apart.
  final parent = <String, String>{};
  String find(String node) {
    final up = parent[node] ?? node;
    if (up == node) return node;
    return parent[node] = find(up);
  }

  void union(String a, String b) {
    parent.putIfAbsent(a, () => a);
    parent.putIfAbsent(b, () => b);
    final rootA = find(a);
    final rootB = find(b);
    if (rootA != rootB) parent[rootA] = rootB;
  }

  void joinEarlierGroup(String node, String id) {
    if (groupOf[id] case final group?) union(node, 'g:$group');
  }

  for (final link in links) {
    final node = 'k:${link.id}';
    union(node, 'o:${link.originId}');
    union(node, 'l:${link.landingId}');
    joinEarlierGroup(node, link.id);
    joinEarlierGroup('o:${link.originId}', link.originId);
    joinEarlierGroup('l:${link.landingId}', link.landingId);
  }

  // Each component's links in graph order, and the earlier groups in it.
  final linksByRoot = <String, List<LineUpLink>>{};
  for (final link in links) {
    (linksByRoot[find('k:${link.id}')] ??= []).add(link);
  }
  final earlierByRoot = <String, List<String>>{};
  for (final node in parent.keys) {
    if (node.startsWith('g:')) {
      (earlierByRoot[find(node)] ??= []).add(node.substring(2));
    }
  }

  String smallest(Iterable<String> ids) =>
      ids.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);

  final idByRoot = <String, String>{};
  final used = <String>{...takenGroupIds, ...groupOf.values};
  for (final MapEntry(key: root, value: earlier) in earlierByRoot.entries) {
    if (!linksByRoot.containsKey(root)) continue;
    final id = smallest(earlier);
    idByRoot[root] = id;
    used.addAll(earlier);
  }
  for (final MapEntry(key: root, value: groupLinks) in linksByRoot.entries) {
    if (idByRoot.containsKey(root)) continue;
    final candidates = [for (final link in groupLinks) link.id]..sort();
    final id = candidates.firstWhere(
      (candidate) => !used.contains(candidate),
      orElse: () => const Uuid().v4(),
    );
    idByRoot[root] = id;
    used.add(id);
  }

  final originsById = {for (final origin in graph.origins) origin.id: origin};
  final landingsById = {
    for (final landing in graph.landings) landing.id: landing,
  };
  final assigned = <String, String>{};
  final rows = <CloudLineupRow>[];
  for (final MapEntry(key: root, value: groupLinks) in linksByRoot.entries) {
    final id = idByRoot[root]!;
    final usedOrigins = {for (final link in groupLinks) link.originId};
    final usedLandings = {for (final link in groupLinks) link.landingId};
    final origins = [
      for (final origin in graph.origins)
        if (usedOrigins.contains(origin.id)) originsById[origin.id]!,
    ];
    final landings = [
      for (final landing in graph.landings)
        if (usedLandings.contains(landing.id)) landingsById[landing.id]!,
    ];
    for (final itemId in [...usedOrigins, ...usedLandings]) {
      assigned[itemId] = id;
    }
    for (final link in groupLinks) {
      assigned[link.id] = id;
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
