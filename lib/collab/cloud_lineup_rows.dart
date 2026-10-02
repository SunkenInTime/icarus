import 'dart:convert';

import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/line_provider.dart';

/// One cloud row per lineup (a [LineUpLink]): its name, video, notes and
/// images, and whole copies of its origin and landing.
///
/// Lineups that share a spot (several lineups from one origin, or into one
/// landing) each carry their own copy of it, under the spot's id. The server
/// never joins rows, so every row can be drawn on its own, and a lineup's
/// row only ever changes when the user changes that lineup or its spot.
class CloudLineupRow {
  const CloudLineupRow({required this.publicId, required this.payload});

  CloudLineupRow.remote(RemoteLineup lineup)
      : this(publicId: lineup.publicId, payload: lineup.payload);

  /// The lineup's id, as on the canvas and in `payload.data.id`.
  final String publicId;
  final CloudPayload payload;
}

/// Local ids standing for real origin and landing ids, alias to real id.
/// They exist only on the canvas (see [lineUpGraphFromCloudRows]); rows are
/// always written under the real id.
class CloudLineupAliases {
  const CloudLineupAliases({this.origins = const {}, this.landings = const {}});

  static const none = CloudLineupAliases();

  final Map<String, String> origins;
  final Map<String, String> landings;

  bool get isEmpty => origins.isEmpty && landings.isEmpty;

  CloudLineupAliases followedBy(CloudLineupAliases other) {
    if (other.isEmpty) return this;
    return CloudLineupAliases(
      origins: {...origins, ...other.origins},
      landings: {...landings, ...other.landings},
    );
  }
}

/// A page's lineups as cloud rows describe them, and the aliases drawing
/// them took.
class CloudLineups {
  const CloudLineups({
    required this.graph,
    this.aliases = CloudLineupAliases.none,
  });

  final LineUpGraph graph;
  final CloudLineupAliases aliases;
}

/// A page's lineups as its live [rows] describe them.
///
/// Links come from the rows, in their order. The copies the rows carry of
/// one origin (or landing) id are grouped by value. Copies that agree, as
/// they do unless a change reached only some of a spot's lineups, are drawn
/// as one spot under the real id. Copies that disagree are drawn apart, one
/// spot per value: the value the row with the smallest lineup id carries
/// keeps the real id, and every other value is drawn under the alias
/// `<real id>@<smallest lineup id carrying it>`. Every client draws the same
/// spots from the same rows, and nothing is written for it: each lineup
/// keeps its own copy until the user changes it. Spots appear in the order
/// the rows first carry them.
///
/// Throws a [FormatException] naming the row when one cannot be read.
CloudLineups lineUpGraphFromCloudRows(Iterable<CloudLineupRow> rows) {
  final read = [for (final row in rows) _readLineupRow(row)];
  final originIds = _spotIds([
    for (final (link, origin, _) in read) (link.id, origin.id, origin.toJson()),
  ]);
  final landingIds = _spotIds([
    for (final (link, _, landing) in read)
      (link.id, landing.id, landing.toJson()),
  ]);

  final origins = <String, LineUpOrigin>{};
  final landings = <String, LineUpLanding>{};
  final links = <LineUpLink>[];
  for (final (link, origin, landing) in read) {
    final originId = originIds.byLineup[link.id]!;
    final landingId = landingIds.byLineup[link.id]!;
    origins.putIfAbsent(originId, () => _originAs(origin, originId));
    landings.putIfAbsent(landingId, () => _landingAs(landing, landingId));
    links.add(link.copyWith(originId: originId, landingId: landingId));
  }
  return CloudLineups(
    graph: LineUpGraph(
      origins: origins.values.toList(),
      landings: landings.values.toList(),
      links: links,
    ),
    aliases: CloudLineupAliases(
      origins: originIds.aliases,
      landings: landingIds.aliases,
    ),
  );
}

/// The rows that store [graph]: one per link, in link order, each carrying
/// its origin and landing as they are now, under their real ids ([aliases]
/// maps the canvas's aliases back). A link whose origin or landing is
/// missing draws nothing on the canvas, so it has no row either.
List<CloudLineupRow> cloudLineupRows(
  LineUpGraph graph, {
  CloudLineupAliases aliases = CloudLineupAliases.none,
}) {
  final origins = {
    for (final origin in graph.origins)
      origin.id: _originAs(origin, aliases.origins[origin.id] ?? origin.id),
  };
  final landings = {
    for (final landing in graph.landings)
      landing.id:
          _landingAs(landing, aliases.landings[landing.id] ?? landing.id),
  };
  return [
    for (final link in graph.links)
      if ((origins[link.originId], landings[link.landingId])
          case (final origin?, final landing?))
        CloudLineupRow(
          publicId: link.id,
          payload: cloudLineupPayload({
            ...link.toJson()
              ..remove('originId')
              ..remove('landingId'),
            'origin': origin.toJson(),
            'landing': landing.toJson(),
          }),
        ),
  ];
}

/// A page's lineups as its [lineups] on the server describe them. Deleted
/// rows draw nothing.
LineUpGraph lineUpGraphFromRemoteLineups(Iterable<RemoteLineup> lineups) {
  return lineUpGraphFromCloudRows([
    for (final lineup in lineups)
      if (!lineup.deleted) CloudLineupRow.remote(lineup),
  ]).graph;
}

/// Whether [op] is a lineup change in the cloud format before one row per
/// lineup: an origin, landing or link row keyed `<kind>:<id>`. An outbox
/// written by such a build can still hold one; it is never sent.
bool isRetiredCloudLineupOp(StrategyOp op) {
  if (op.entityType != StrategyOpEntityType.lineup) return false;
  final payload = op.payload;
  return (payload is Map && payload['kind'] != cloudLineupPayloadKind) ||
      _retiredLineupKey.hasMatch(op.entityPublicId ?? '');
}

final _retiredLineupKey = RegExp(r'^lineup(Origin|Landing|Link):');

/// The spot id each lineup's copy of one kind of end is drawn under, and the
/// aliases among them; see [lineUpGraphFromCloudRows].
({Map<String, String> byLineup, Map<String, String> aliases}) _spotIds(
  List<(String lineupId, String endId, Map<String, dynamic> value)> copies,
) {
  // End id -> value -> the lineups carrying that value.
  final groups = <String, Map<String, List<String>>>{};
  for (final (lineupId, endId, value) in copies) {
    ((groups[endId] ??= {})[_valueKey(value)] ??= []).add(lineupId);
  }
  final byLineup = <String, String>{};
  final aliases = <String, String>{};
  String smallest(List<String> ids) => ids.reduce(
        (a, b) => a.compareTo(b) <= 0 ? a : b,
      );
  for (final MapEntry(key: endId, value: byValue) in groups.entries) {
    final firsts = {
      for (final MapEntry(:key, value: lineups) in byValue.entries)
        key: smallest(lineups),
    };
    final realValue = firsts.entries
        .reduce((a, b) => a.value.compareTo(b.value) <= 0 ? a : b)
        .key;
    for (final MapEntry(key: value, value: lineups) in byValue.entries) {
      final id = value == realValue ? endId : '$endId@${firsts[value]}';
      if (id != endId) aliases[id] = endId;
      for (final lineupId in lineups) {
        byLineup[lineupId] = id;
      }
    }
  }
  return (byLineup: byLineup, aliases: aliases);
}

String _valueKey(Map<String, dynamic> value) =>
    canonicalCloudJsonEncode(jsonDecode(jsonEncode(value)));

/// [origin] under [id], its agent's `lineUpID` following when it named the
/// origin's old id.
LineUpOrigin _originAs(LineUpOrigin origin, String id) {
  if (id == origin.id) return origin;
  final agent = origin.agent;
  return LineUpOrigin(
    id: id,
    agent: agent.lineUpID == origin.id
        ? (agent.copyWith(lineUpID: id)..isDeleted = agent.isDeleted)
        : agent,
  );
}

/// [landing] under [id], its ability's `lineUpID` following when it named
/// the landing's old id.
LineUpLanding _landingAs(LineUpLanding landing, String id) {
  if (id == landing.id) return landing;
  final ability = landing.ability;
  return LineUpLanding(
    id: id,
    ability: ability.lineUpID == landing.id
        ? (ability.copyWith(lineUpID: id)..isDeleted = ability.isDeleted)
        : ability,
  );
}

(LineUpLink, LineUpOrigin, LineUpLanding) _readLineupRow(CloudLineupRow row) {
  try {
    final kind = row.payload['kind'];
    if (kind != cloudLineupPayloadKind) {
      throw FormatException('unknown lineup kind $kind');
    }
    final data = cloudPayloadData(row.payload);
    final origin = LineUpOrigin.fromJson(_object(data['origin'], 'origin'));
    final landing = LineUpLanding.fromJson(_object(data['landing'], 'landing'));
    final link = LineUpLink.fromJson({
      ...data,
      'originId': origin.id,
      'landingId': landing.id,
    });
    if (link.id != row.publicId) {
      throw FormatException('it holds lineup ${link.id}');
    }
    return (link, origin, landing);
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(
      FormatException('Cloud lineup ${row.publicId} could not be read: '
          '$error'),
      stackTrace,
    );
  }
}

Map<String, dynamic> _object(Object? value, String name) {
  if (value is! Map) throw FormatException('it has no $name');
  return Map<String, dynamic>.from(value);
}
