import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/strategy/lineup_group_changes.dart';

/// A lineup group whose change the server refused, and what each side did
/// to it since the version both started from.
class LineupGroupConflict {
  const LineupGroupConflict({
    required this.key,
    required this.yours,
    required this.cloud,
  });

  final EntitySyncKey key;

  /// The user's waiting version against the version it was made from, or,
  /// when [cloud] is null, against the cloud's version.
  final List<LineupChange> yours;

  /// The cloud's version against the one the user's was made from. Null
  /// when that version is no longer on this device (the page was drawn
  /// again since): then who changed what cannot be told apart.
  final List<LineupChange>? cloud;
}

/// What the active strategy's refused work does to its lineup groups, when
/// that work is all lineup groups on the page on screen: the case Keep both
/// covers. Null otherwise, and the sync popover offers Keep mine and Use
/// cloud alone.
///
/// Every version is read from what this device already has: the user's
/// newest waiting change, the server's version the canvas was drawn from,
/// and the live copy of the page. The version drawn from tells the sides'
/// changes apart only while it is the one the refused change was made
/// against; once the page is drawn again it is the cloud's, so every
/// conflict then lists only how the user's version differs from the
/// cloud's. When a version cannot be read, there is nothing trustworthy to
/// show, so this is null too.
final lineupConflictsProvider = Provider<List<LineupGroupConflict>?>((ref) {
  final queue = ref.watch(strategyOpQueueProvider);
  final attention = queue.attentionByEntityKey;
  final page = ref.watch(remoteEditorSnapshotProvider).valueOrNull?.activePage;
  if (attention.isEmpty || page == null) return null;
  final pageId = page.page.publicId;
  if (attention.keys.any(
    (key) => key.kind != EntitySyncKeyKind.lineup || key.pageId != pageId,
  )) {
    return null;
  }

  final liveSync = ref.read(activePageLiveSyncProvider.notifier);
  final cloudRows = {for (final row in page.lineups) row.publicId: row};
  final versions = <(EntitySyncKey, LineUpGraph, LineUpGraph, LineUpGraph)>[];
  var basesHold = true;
  for (final MapEntry(:key, value: refused) in attention.entries) {
    final base = liveSync.hydratedBase(key);
    final refusedOp = refused.pending.op;
    final madeAgainst = switch (refusedOp) {
      LineupAddOp(:final expectedLineupRevision) => expectedLineupRevision,
      LineupPatchOp(:final expectedLineupRevision) => expectedLineupRevision,
      LineupDeleteOp(:final expectedLineupRevision) => expectedLineupRevision,
      LineupReorderOp(:final expectedLineupRevision) => expectedLineupRevision,
      _ => null,
    };
    if (base?.revision != madeAgainst) basesHold = false;
    final newest = (queue.successorByEntityKey[key] ?? refused).pending.op;
    final yoursPayload = switch (newest) {
      LineupAddOp(:final payload) => payload,
      LineupPatchOp(:final payload?) => payload,
      LineupDeleteOp() => null,
      _ => base?.payload,
    };
    final cloudRow = cloudRows[key.entityId];
    final yours = _groupGraph(key, yoursPayload);
    final cloud = _groupGraph(
      key,
      cloudRow == null || cloudRow.deleted ? null : cloudRow.payload,
    );
    final from =
        base == null ? LineUpGraph.empty : _groupGraph(key, base.payload);
    if (yours == null || cloud == null || from == null) return null;
    versions.add((key, yours, cloud, from));
  }
  final conflicts = [
    for (final (key, yours, cloud, from) in versions)
      basesHold
          ? LineupGroupConflict(
              key: key,
              yours: lineupChanges(from: from, to: yours),
              cloud: lineupChanges(from: from, to: cloud),
            )
          : LineupGroupConflict(
              key: key,
              yours: lineupChanges(from: cloud, to: yours),
              cloud: null,
            ),
  ];
  return conflicts;
});

/// The lineups one group row's [payload] holds; empty for no row, null when
/// the row cannot be read.
LineUpGraph? _groupGraph(EntitySyncKey key, Object? payload) {
  if (payload == null) return LineUpGraph.empty;
  try {
    return lineUpGraphFromCloudRows([
      CloudLineupRow(
        publicId: key.entityId!,
        payload: cloudObjectPayload(payload),
      ),
    ]).graph;
  } on FormatException {
    return null;
  }
}
