import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/line_provider.dart';

/// One cloud row per lineup (a [LineUpLink]): its name, video, notes and
/// images, and whole copies of its origin and landing.
///
/// Lineups that share a spot (several lineups from one origin, or into one
/// landing) each carry their own copy of it, under the spot's id. The server
/// never joins rows, so every row can be drawn on its own. The client draws
/// the copies of one id as one spot again ([lineUpGraphFromCloudRows]), and
/// changing a shared spot changes every row that carries it
/// ([cloudLineupRows]).
class CloudLineupRow {
  const CloudLineupRow({
    required this.publicId,
    required this.payload,
    this.revision = 0,
  });

  CloudLineupRow.remote(RemoteLineup lineup)
      : this(
          publicId: lineup.publicId,
          payload: lineup.payload,
          revision: lineup.revision,
        );

  /// The lineup's id, as on the canvas and in `payload.data.id`.
  final String publicId;
  final CloudPayload payload;

  /// The row's server revision, which picks the copy drawn when the copies
  /// of a shared spot disagree. Zero for a row the server does not have.
  final int revision;
}

/// The revision a lineup still waiting to be sent ranks at: above any the
/// server holds, so the user's own change to a shared spot is the copy drawn
/// until it lands.
const pendingCloudLineupRevision = 1 << 52;

/// The rows that store [graph]: one per link, in link order, each carrying
/// its origin and landing as they are now. A link whose origin or landing is
/// missing draws nothing on the canvas, so it has no row either.
List<CloudLineupRow> cloudLineupRows(LineUpGraph graph) {
  final origins = {for (final origin in graph.origins) origin.id: origin};
  final landings = {for (final landing in graph.landings) landing.id: landing};
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

/// A page's lineups as its live [rows] describe them.
///
/// Links come from the rows, in their order. Origins and landings are the
/// rows' copies, one per id, in the order the rows first carry them. Copies
/// of one spot disagree only after teammates changed it at the same time;
/// every client then draws the copy from the row with the highest revision,
/// a tie going to the greatest publicId, so all of them show the same spot.
///
/// Throws a [FormatException] naming the row when one cannot be read.
LineUpGraph lineUpGraphFromCloudRows(Iterable<CloudLineupRow> rows) {
  final origins = <String, (LineUpOrigin, CloudLineupRow)>{};
  final landings = <String, (LineUpLanding, CloudLineupRow)>{};
  final links = <LineUpLink>[];
  bool outranks(CloudLineupRow row, CloudLineupRow? drawn) =>
      drawn == null ||
      row.revision > drawn.revision ||
      (row.revision == drawn.revision &&
          row.publicId.compareTo(drawn.publicId) > 0);

  for (final row in rows) {
    final (link, origin, landing) = _readLineupRow(row);
    links.add(link);
    if (outranks(row, origins[origin.id]?.$2)) {
      origins[origin.id] = (origin, row);
    }
    if (outranks(row, landings[landing.id]?.$2)) {
      landings[landing.id] = (landing, row);
    }
  }
  return LineUpGraph(
    origins: [for (final (origin, _) in origins.values) origin],
    landings: [for (final (landing, _) in landings.values) landing],
    links: links,
  );
}

/// A page's lineups as its [lineups] on the server describe them. Deleted
/// rows draw nothing.
LineUpGraph lineUpGraphFromRemoteLineups(Iterable<RemoteLineup> lineups) {
  return lineUpGraphFromCloudRows([
    for (final lineup in lineups)
      if (!lineup.deleted) CloudLineupRow.remote(lineup),
  ]);
}

/// The payloads of [rows] as the canvas draws them, by publicId: each row
/// rebuilt from [lineUpGraphFromCloudRows], so a row whose copy of a shared
/// spot is not the one drawn carries the drawn copy. Comparing these with
/// the canvas never mistakes the copy hydration chose for a local edit.
Map<String, CloudPayload> drawnCloudLineupPayloads(
  Iterable<CloudLineupRow> rows,
) {
  return {
    for (final row in cloudLineupRows(lineUpGraphFromCloudRows(rows)))
      row.publicId: row.payload,
  };
}

/// Whether [op] is a lineup change in the cloud format before one row per
/// lineup: an origin, landing or link row keyed `<kind>:<id>`. An outbox
/// written by such a build can still hold one; no server takes it.
bool isRetiredCloudLineupOp(StrategyOp op) {
  if (op.entityType != StrategyOpEntityType.lineup) return false;
  final payload = op.payload;
  return (payload is Map && payload['kind'] != cloudLineupPayloadKind) ||
      _retiredLineupKey.hasMatch(op.entityPublicId ?? '');
}

final _retiredLineupKey = RegExp(r'^lineup(Origin|Landing|Link):');

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
