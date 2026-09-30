import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';

/// Whether the open cloud strategy has pages in its trash, so Recently
/// deleted is worth offering. Read again whenever the strategy's revision
/// moves: deleting and restoring a page both move it, element edits do not.
/// Unknown (loading, offline) counts as none.
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
  final pages = await ref
      .read(convexStrategyRepositoryProvider)
      .listTrashedPages(strategyId);
  return pages.isNotEmpty;
});
