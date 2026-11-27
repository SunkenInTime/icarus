import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';
import 'package:icarus/config/drive_build.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus_library/icarus_library.dart' show Account, LibraryStore;
import 'package:uuid/uuid.dart';

typedef AuthChanges = ({int changes, bool authenticated, String? subject});

final authChangesProvider = Provider<AuthChanges Function()>(
  (ref) => () => (
        changes: ConvexClient.instance.authChanges,
        authenticated: ConvexClient.instance.isAuthenticated,
        subject: ref.read(authProvider).user?.id,
      ),
);

final cloudSenderTimingProvider = Provider<SenderTiming>(
  (ref) => const SenderTiming(),
);

final cloudSenderClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final convexSignInsProvider = Provider<Stream<bool>>(
  (ref) => ConvexClient.instance.authState,
);

final storeTransportProvider = Provider<StampedConvexTransport>(
  (ref) => StampedPlatformTransport(ConvexClient.instance),
);

final storeRepositoryProvider = Provider<ConvexStrategyRepository>(
  (ref) => ConvexStrategyRepository.stamped(ref.read(storeTransportProvider)),
);

final storeBatchSendProvider = Provider<StoreBatchSend>(
  (ref) => storeBatchSenderOver(ref.read(storeRepositoryProvider)),
);

final storeReadsProvider = Provider<StoreReads>(
  (ref) => storeReadsOver(
    ref.read(storeRepositoryProvider),
    canRead: appCanRead,
  ),
);

final storeGenerationProvider =
    Provider<Future<({int client, int connection})> Function()>(
  (ref) => ref.read(storeTransportProvider).generation,
);

final senderEditorShowsProvider = Provider<String?>(
  (ref) => ref.watch(
    strategyProvider.select(
      (state) => state.isOpen && state.source == StrategySource.cloud
          ? state.strategyId
          : null,
    ),
  ),
);

final _senderOpenInEditorProvider = Provider<String?>(
  (ref) => switch (ref.watch(strategyOpeningProvider)) {
    StrategyOpening(:final strategyId, source: StrategySource.cloud) =>
      strategyId,
    _ => ref.watch(senderEditorShowsProvider),
  },
);

final senderEditorProvider = Provider<ProviderListenable<String?>>(
  (ref) => _senderOpenInEditorProvider,
);

final senderSignInWatchProvider = Provider<ProviderListenable<Object?>>(
  (ref) => authProvider,
);

final senderConnectionProvider = Provider<int? Function()>(
  (ref) {
    final queue = ref.read(strategyOpQueueProvider.notifier);
    return () => queue.liveStamp;
  },
);

final cloudSenderProvider = NotifierProvider<CloudSenderNotifier, CloudSender?>(
  CloudSenderNotifier.new,
);

class CloudSenderNotifier extends Notifier<CloudSender?> {
  var _signOuts = 0;
  Account? _lastAccount;

  LibraryStoreOpened? opened;

  Object? openingThrew;

  @override
  CloudSender? build() => null;

  Future<void> beginOn(
    Future<LibraryStoreOpened> opening, {
    required String build,
  }) async {
    final LibraryStoreOpened ready;
    try {
      ready = opened = await opening;
    } catch (error) {
      openingThrew = error;
      return;
    }
    if (ready case LibraryStoreReady(:final store)) begin(store, build: build);
  }

  CloudSender begin(LibraryStore store, {required String build}) {
    if (state case final running?) return running;
    final sender = CloudSender(
      store: SenderStore(store, keepsAllReports: driveBuild),
      send: ref.read(storeBatchSendProvider),
      reads: ref.read(storeReadsProvider),
      generation: ref.read(storeGenerationProvider),
      build: build,
      clientId: const Uuid().v4(),
      inputs: _inputs(),
      timing: ref.read(cloudSenderTimingProvider),
      clock: ref.read(cloudSenderClockProvider),
      editorShows: () => ref.read(ref.read(senderEditorProvider)),
    );
    state = sender;
    final editor = ref.read(senderEditorProvider);
    void adoptOpen() {
      if (ref.read(editor) case final open?) sender.adopt(open);
    }

    void refresh() {
      sender.inputs = _inputs();
      adoptOpen();
    }

    final signIns = ref.read(convexSignInsProvider).listen((_) => refresh());
    ref.listen(ref.read(senderSignInWatchProvider), (_, __) => refresh());
    ref.listen<bool>(convexConnectionSnapshotProvider, (_, __) => refresh());
    ref.listen<String?>(
      editor,
      (_, open) {
        sender.editorOpened(open);
        adoptOpen();
      },
      fireImmediately: true,
    );
    ref.onDispose(() {
      unawaited(signIns.cancel());
      sender.dispose();
    });
    sender.start();
    return sender;
  }

  Snapshot _inputs() {
    final auth = ref.read(authChangesProvider)();
    final account = switch (auth) {
      (authenticated: true, subject: final named?, changes: _) =>
        Account(named),
      _ => null,
    };
    if (_lastAccount != null && account == null) _signOuts++;
    _lastAccount = account;
    return (
      account: account,
      connection: ref.read(senderConnectionProvider)(),
      signIns: auth.changes,
      signOuts: _signOuts,
    );
  }
}
