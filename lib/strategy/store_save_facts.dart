import 'dart:async';

import 'package:icarus_library/icarus_library.dart';

sealed class StoreAheadOfServer {
  const StoreAheadOfServer();
}

final class StoreMatchesServer extends StoreAheadOfServer {
  const StoreMatchesServer();
}

final class StoreSending extends StoreAheadOfServer {
  const StoreSending(this.ops);

  final int ops;
}

final class StoreNeedsUser extends StoreAheadOfServer {
  const StoreNeedsUser(this.ops);

  final int ops;
}

final class StoreUnverified extends StoreAheadOfServer {
  const StoreUnverified();
}

final class StoreOwnedSave {
  const StoreOwnedSave({
    required this.canvasAheadOfStore,
    required this.storeAheadOfServer,
  });

  final bool canvasAheadOfStore;
  final StoreAheadOfServer storeAheadOfServer;

  StoreOwnedSave copyWith({
    bool? canvasAheadOfStore,
    StoreAheadOfServer? storeAheadOfServer,
  }) =>
      StoreOwnedSave(
        canvasAheadOfStore: canvasAheadOfStore ?? this.canvasAheadOfStore,
        storeAheadOfServer: storeAheadOfServer ?? this.storeAheadOfServer,
      );
}

StoreAheadOfServer storeAheadOfServerOf(SummarySync sync) => switch (sync) {
      KeptInCloud(:final tally) => _aheadBy(tally),
      CloudUnverified() || KeptHere() => const StoreUnverified(),
    };

StoreAheadOfServer _aheadBy(Tally tally) {
  int total(Iterable<int> counts) => counts.fold(0, (sum, n) => sum + n);
  final waiting = total(tally.waiting.values);
  final stuck = total(tally.attention.values) + tally.unreadable;
  if (stuck > 0 || (waiting > 0 && tally.standing != Standing.good)) {
    return StoreNeedsUser(stuck + waiting);
  }
  if (waiting > 0) return StoreSending(waiting);
  return const StoreMatchesServer();
}

StreamSubscription<StoreChange> feedStoreAheadOfServer(
  LibraryStore store,
  String strategyPublicId,
  void Function(StoreAheadOfServer ahead) note,
) {
  if (store.library case LibraryOpen(:final list)) {
    for (final summary in list.strategies) {
      if (summary.publicId == strategyPublicId) {
        note(storeAheadOfServerOf(summary.sync));
      }
    }
  }
  return store.changes.listen((change) {
    switch (change) {
      case StrategyEdited(:final summary) || StrategyRefreshed(:final summary)
          when summary.publicId == strategyPublicId:
        note(storeAheadOfServerOf(summary.sync));
      case LibraryEdited(:final summaries):
        for (final summary in summaries) {
          if (summary.publicId == strategyPublicId) {
            note(storeAheadOfServerOf(summary.sync));
          }
        }
      case StrategyRefused(strategyPublicId: final refused)
          when refused == strategyPublicId:
        note(const StoreUnverified());
      case StrategyEdited() ||
            StrategyRefreshed() ||
            StrategyRefused() ||
            StoredResultsDropped():
        break;
    }
  });
}
