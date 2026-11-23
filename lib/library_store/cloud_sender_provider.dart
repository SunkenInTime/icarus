import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/config/drive_build.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus_library/icarus_library.dart' show Account, LibraryStore;
import 'package:uuid/uuid.dart';

final cloudSenderTimingProvider = Provider<SenderTiming>(
  (ref) => const SenderTiming(),
);

final cloudSenderClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final convexSignInsProvider = Provider<Stream<bool>>(
  (ref) => ConvexClient.instance.authState,
);

final storeBatchSendProvider = Provider<StoreBatchSend>(
  (ref) => storeBatchSenderOver(ref.read(convexStrategyRepositoryProvider)),
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

  @override
  CloudSender? build() => null;

  CloudSender begin(LibraryStore store, {required String build}) {
    if (state case final running?) return running;
    final sender = CloudSender(
      store: SenderStore(store, keepsAllReports: driveBuild),
      send: ref.read(storeBatchSendProvider),
      build: build,
      clientId: const Uuid().v4(),
      inputs: _inputs(),
      timing: ref.read(cloudSenderTimingProvider),
      clock: ref.read(cloudSenderClockProvider),
    );
    state = sender;
    void refresh() => sender.inputs = _inputs();
    final signIns = ref.read(convexSignInsProvider).listen((_) => refresh());
    ref.listen(ref.read(senderSignInWatchProvider), (_, __) => refresh());
    ref.listen<bool>(convexConnectionSnapshotProvider, (_, __) => refresh());
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
