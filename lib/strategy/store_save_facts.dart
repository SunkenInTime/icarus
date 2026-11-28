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

StoreAheadOfServer storeAheadOfServerOf(SummarySync sync, SignedIn signedIn) =>
    switch (sync) {
      KeptInCloud(:final owner, :final tally) => switch (syncStateOf(
          owner,
          tally,
          network: Network.online,
          signedIn: signedIn,
        )) {
          AllSaved() => const StoreMatchesServer(),
          Outstanding(:final face, :final tally) => switch (face) {
              Face.offline ||
              Face.answerUnknown ||
              Face.sending ||
              Face.awaitingResult =>
                StoreSending(tally.unsentWork),
              Face.ownerUnreadable ||
              Face.signedOut ||
              Face.heldForAnotherAccount ||
              Face.notThisAccount ||
              Face.deletedOnServer ||
              Face.editAccessLost ||
              Face.unreadableWork ||
              Face.strategyReplaced ||
              Face.needsYou ||
              Face.upgradeRequired =>
                StoreNeedsUser(tally.unsentWork),
            },
        },
      CloudUnverified() || KeptHere() => const StoreUnverified(),
    };

StreamSubscription<StoreChange> feedStoreAheadOfServer(
  LibraryStore store,
  String strategyPublicId,
  SignedIn signedIn,
  void Function(StoreAheadOfServer ahead) note,
) {
  if (store.library case LibraryOpen(:final list)) {
    for (final summary in list.strategies) {
      if (summary.publicId == strategyPublicId) {
        note(storeAheadOfServerOf(summary.sync, signedIn));
      }
    }
  }
  return store.changes.listen((change) {
    switch (change) {
      case StrategyEdited(:final summary) || StrategyRefreshed(:final summary)
          when summary.publicId == strategyPublicId:
        note(storeAheadOfServerOf(summary.sync, signedIn));
      case LibraryEdited(:final summaries):
        for (final summary in summaries) {
          if (summary.publicId == strategyPublicId) {
            note(storeAheadOfServerOf(summary.sync, signedIn));
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
