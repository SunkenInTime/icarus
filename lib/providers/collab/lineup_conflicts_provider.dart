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

  /// The user's waiting version, against the version it was made from.
  final List<LineupChange> yours;

  /// The cloud's version, against the same one.
  final List<LineupChange> cloud;
}

/// What the active strategy's refused work does to its lineup groups, when
/// that work is all lineup groups on the page on screen: the case Keep both
/// covers. Null otherwise, and the sync popover offers Keep mine and Use
/// cloud alone.
///
/// Every version is read from what this device already has: the user's
/// newest waiting change, the server's version the canvas was drawn from,
/// and the live copy of the page. When one of them cannot be read, there is
/// nothing trustworthy to show, so this is null too.
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
  final conflicts = <LineupGroupConflict>[];
  for (final MapEntry(:key, value: refused) in attention.entries) {
    final basePayload = liveSync.hydratedBasePayload(key);
    final newest = (queue.successorByEntityKey[key] ?? refused).pending.op;
    final yoursPayload = switch (newest) {
      LineupAddOp(:final payload) => payload,
      LineupPatchOp(:final payload?) => payload,
      LineupDeleteOp() => null,
      _ => basePayload,
    };
    final cloudRow = cloudRows[key.entityId];
    final base = _groupGraph(key, basePayload);
    final yours = _groupGraph(key, yoursPayload);
    final cloud = _groupGraph(
      key,
      cloudRow == null || cloudRow.deleted ? null : cloudRow.payload,
    );
    if (base == null || yours == null || cloud == null) return null;
    conflicts.add(
      LineupGroupConflict(
        key: key,
        yours: lineupChanges(from: base, to: yours),
        cloud: lineupChanges(from: base, to: cloud),
      ),
    );
  }
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
