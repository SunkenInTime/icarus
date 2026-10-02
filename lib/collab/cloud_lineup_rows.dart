import 'dart:convert';

import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/line_provider.dart';

/// One cloud row per lineup (a [LineUpLink]): its name, video, notes and
/// images, and whole copies of its origin and landing.
///
/// Lineups that share a spot (several lineups from one origin, or into one
/// landing) each carry their own copy of it, under the spot's id, with the
/// spot's version. The server never joins rows, so every row can be drawn on
/// its own. The client draws the copies of one id as one spot again
/// ([lineUpGraphFromCloudRows]) and writes every row of a spot with the copy
/// it draws ([cloudLineupRows]), so copies that drifted apart (a change that
/// reached only some of the rows) come back together.
///
/// Versions live only here, in the cloud rows: the canvas, Hive and .ica
/// files never see them.
class CloudLineupRow {
  const CloudLineupRow({required this.publicId, required this.payload});

  CloudLineupRow.remote(RemoteLineup lineup)
      : this(publicId: lineup.publicId, payload: lineup.payload);

  /// The lineup's id, as on the canvas and in `payload.data.id`.
  final String publicId;
  final CloudPayload payload;
}

/// A page's lineups as cloud rows describe them, with the version of each
/// spot drawn.
class CloudLineups {
  const CloudLineups({
    required this.graph,
    this.originVersions = const {},
    this.landingVersions = const {},
  });

  static const empty = CloudLineups(graph: LineUpGraph.empty);

  final LineUpGraph graph;

  /// The version of each origin and landing drawn, by id.
  final Map<String, int> originVersions;
  final Map<String, int> landingVersions;
}

/// The rows that store [graph]: one per link, in link order, each carrying
/// its origin and landing as they are now. A link whose origin or landing is
/// missing draws nothing on the canvas, so it has no row either.
///
/// [drawn] is what the canvas was drawn from. A spot keeps the version it
/// was drawn at while it is unchanged, and goes one past it once changed,
/// so the change outranks every copy the rows hold. A spot [drawn] lacks
/// starts at version 1.
List<CloudLineupRow> cloudLineupRows(
  LineUpGraph graph, {
  CloudLineups drawn = CloudLineups.empty,
}) {
  final drawnOrigins = {
    for (final origin in drawn.graph.origins) origin.id: origin,
  };
  final drawnLandings = {
    for (final landing in drawn.graph.landings) landing.id: landing,
  };
  int versionOf(
    String id,
    Map<String, dynamic> now,
    Map<String, dynamic>? before,
    Map<String, int> versions,
  ) {
    final version = versions[id];
    if (version == null || before == null) return 1;
    return _sameJson(now, before) ? version : version + 1;
  }

  final origins = {for (final origin in graph.origins) origin.id: origin};
  final landings = {for (final landing in graph.landings) landing.id: landing};
  final originJson = <String, Map<String, dynamic>>{
    for (final origin in graph.origins)
      origin.id: {
        ...origin.toJson(),
        'version': versionOf(
          origin.id,
          origin.toJson(),
          drawnOrigins[origin.id]?.toJson(),
          drawn.originVersions,
        ),
      },
  };
  final landingJson = <String, Map<String, dynamic>>{
    for (final landing in graph.landings)
      landing.id: {
        ...landing.toJson(),
        'version': versionOf(
          landing.id,
          landing.toJson(),
          drawnLandings[landing.id]?.toJson(),
          drawn.landingVersions,
        ),
      },
  };
  return [
    for (final link in graph.links)
      if (origins.containsKey(link.originId) &&
          landings.containsKey(link.landingId))
        CloudLineupRow(
          publicId: link.id,
          payload: cloudLineupPayload({
            ...link.toJson()
              ..remove('originId')
              ..remove('landingId'),
            'origin': originJson[link.originId],
            'landing': landingJson[link.landingId],
          }),
        ),
  ];
}

/// A page's lineups as its live [rows] describe them.
///
/// Links come from the rows, in their order. Origins and landings are the
/// rows' copies, one per id, in the order the rows first carry them. When
/// copies of a spot disagree, every client draws the one with the highest
/// version, a tie going to the row with the greatest lineup id.
///
/// Throws a [FormatException] naming the row when one cannot be read.
CloudLineups lineUpGraphFromCloudRows(Iterable<CloudLineupRow> rows) {
  final origins = <String, (LineUpOrigin, int, String)>{};
  final landings = <String, (LineUpLanding, int, String)>{};
  final links = <LineUpLink>[];
  bool outranks(int version, String rowId, (Object, int, String)? drawn) =>
      drawn == null ||
      version > drawn.$2 ||
      (version == drawn.$2 && rowId.compareTo(drawn.$3) > 0);

  for (final row in rows) {
    final (link, origin, originVersion, landing, landingVersion) =
        _readLineupRow(row);
    links.add(link);
    if (outranks(originVersion, row.publicId, origins[origin.id])) {
      origins[origin.id] = (origin, originVersion, row.publicId);
    }
    if (outranks(landingVersion, row.publicId, landings[landing.id])) {
      landings[landing.id] = (landing, landingVersion, row.publicId);
    }
  }
  return CloudLineups(
    graph: LineUpGraph(
      origins: [for (final (origin, _, _) in origins.values) origin],
      landings: [for (final (landing, _, _) in landings.values) landing],
      links: links,
    ),
    originVersions: {
      for (final MapEntry(:key, value: (_, version, _)) in origins.entries)
        key: version,
    },
    landingVersions: {
      for (final MapEntry(:key, value: (_, version, _)) in landings.entries)
        key: version,
    },
  );
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

(LineUpLink, LineUpOrigin, int, LineUpLanding, int) _readLineupRow(
  CloudLineupRow row,
) {
  try {
    final kind = row.payload['kind'];
    if (kind != cloudLineupPayloadKind) {
      throw FormatException('unknown lineup kind $kind');
    }
    final data = cloudPayloadData(row.payload);
    final originJson = _object(data['origin'], 'origin');
    final landingJson = _object(data['landing'], 'landing');
    final origin = LineUpOrigin.fromJson(originJson);
    final landing = LineUpLanding.fromJson(landingJson);
    final link = LineUpLink.fromJson({
      ...data,
      'originId': origin.id,
      'landingId': landing.id,
    });
    if (link.id != row.publicId) {
      throw FormatException('it holds lineup ${link.id}');
    }
    return (
      link,
      origin,
      _version(originJson, 'origin'),
      landing,
      _version(landingJson, 'landing'),
    );
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

int _version(Map<String, dynamic> end, String name) {
  final version = end['version'];
  if (version is! num || version != version.roundToDouble() || version < 1) {
    throw FormatException('its $name has no version');
  }
  return version.toInt();
}

bool _sameJson(Map<String, dynamic> left, Map<String, dynamic> right) {
  return canonicalCloudJsonEncode(jsonDecode(jsonEncode(left))) ==
      canonicalCloudJsonEncode(jsonDecode(jsonEncode(right)));
}
