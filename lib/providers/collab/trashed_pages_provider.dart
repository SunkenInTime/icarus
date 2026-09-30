import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';

/// How long after a failed read the trash is read again.
const trashRecheckDelay = Duration(seconds: 15);

/// Whether the open cloud strategy has pages in its trash, so Recently
/// deleted is worth offering. Read again whenever the strategy's revision
/// moves: deleting and restoring a page both move it, element edits do not.
/// A read that fails (offline, say) counts as none and is tried again after
/// [trashRecheckDelay], so the button comes back once the connection does.
final hasTrashedPagesProvider = FutureProvider.autoDispose<bool>((ref) async {
  final (strategyId, _) = ref.watch(
    remoteEditorSnapshotProvider.select(
      (snapshot) => (
        snapshot.valueOrNull?.header.publicId,
        snapshot.valueOrNull?.header.revision,
      ),
    ),
  );
  if (strategyId == null) return false;
  try {
    final pages = await ref
        .read(convexStrategyRepositoryProvider)
        .listTrashedPages(strategyId);
    return pages.isNotEmpty;
  } catch (_) {
    final recheck = Timer(trashRecheckDelay, ref.invalidateSelf);
    ref.onDispose(recheck.cancel);
    return false;
  }
});
