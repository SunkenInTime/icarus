import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';

sealed class CloudShadowState {
  const CloudShadowState();
}

final class CloudShadowIdle extends CloudShadowState {
  const CloudShadowIdle();
}

final class CloudShadowNotOpened extends CloudShadowState {
  const CloudShadowNotOpened(this.opened);

  final LibraryStoreOpened opened;
}

final class CloudShadowFailed extends CloudShadowState {
  const CloudShadowFailed(this.reason);

  final String reason;
}

final class CloudShadowRunning extends CloudShadowState {
  const CloudShadowRunning(this.shadow, this.file);

  final CloudShadow shadow;
  final File file;
}

typedef AuthChanges = ({int changes, bool settled});

final authChangesProvider = Provider<AuthChanges Function()>(
  (ref) => () => (
        changes: ConvexClient.instance.authChanges,
        settled: ConvexClient.instance.authSettled,
      ),
);

final cloudShadowProvider =
    NotifierProvider<CloudShadowNotifier, CloudShadowState>(
  CloudShadowNotifier.new,
);

class CloudShadowNotifier extends Notifier<CloudShadowState>
    implements ResultTap {
  final _lists = <String, StreamSubscription<RemotePageList>>{};
  final _listsStarting = <String>{};
  CloudShadow? _shadow;
  ConvexStrategyRepository? _repository;
  ProviderSubscription<bool>? _connection;
  var _stopped = false;

  @override
  CloudShadowState build() {
    ref.onDispose(stopSubscriptions);
    return const CloudShadowIdle();
  }

  Future<void> begin({
    required Future<LibraryStoreOpened> opening,
    required String build,
  }) async {
    final LibraryStoreOpened opened;
    try {
      opened = await opening;
    } catch (error) {
      state = CloudShadowFailed('$error');
      return;
    }
    switch (opened) {
      case LibraryStoreReady(:final store, :final file):
        final shadow = _shadow = CloudShadow(
          store,
          build: build,
          canRead: appCanRead,
          breathe: betweenAnimations,
        );
        state = CloudShadowRunning(shadow, file);
        _guarded(() {
          _connection = ref.listen<bool>(
            convexConnectionSnapshotProvider,
            (previous, next) => _guarded(() {
              if (previous == true && !next) shadow.connectionLost();
            }),
          );
          final repository = ref.read(convexStrategyRepositoryProvider);
          _repository = repository;
          repository.tap = this;
        });
      case LibraryStoreHeldElsewhere() ||
            LibraryStoreRefused() ||
            LibraryStoreTooSmall():
        state = CloudShadowNotOpened(opened);
    }
  }

  void _guarded(void Function() work) {
    try {
      work();
    } catch (error) {
      _shadow?.stop('$error');
    }
  }

  Future<void> stopSubscriptions() async {
    _stopped = true;
    if (_repository case final repository?
        when identical(repository.tap, this)) {
      repository.tap = null;
    }
    _connection?.close();
    _connection = null;
    final lists = [..._lists.values];
    _lists.clear();
    for (final list in lists) {
      try {
        await list.cancel();
      } catch (error) {
        _shadow?.stop('$error');
      }
    }
  }

  @override
  Object issued() {
    final auth = ref.read(authChangesProvider)();
    return auth;
  }

  ResultTag _tag(Object issue) {
    final issuedUnder = issue as AuthChanges;
    final now = ref.read(authChangesProvider)();
    final attributable =
        issuedUnder.settled && now.changes == issuedUnder.changes;
    return (
      connection: ref.read(strategyOpQueueProvider.notifier).liveStamp,
      account: attributable ? issuedUnder.changes : null,
    );
  }

  @override
  void pageArrived(String strategyId, RemotePageSnapshot page, Object issue) =>
      _guarded(() {
        final shadow = _shadow;
        if (shadow == null || _stopped) return;
        shadow.page(strategyId, page, _tag(issue));
        _watchListLater(shadow, strategyId);
      });

  @override
  void readFailed(String strategyId, String what, Object error, Object issue) =>
      _guarded(() {
        final shadow = _shadow;
        if (shadow == null || _stopped) return;
        shadow.readFailed(
          strategyId,
          what,
          error,
          _tag(issue),
          refusedByServer: isConvexFunctionError(error),
        );
      });

  void _watchListLater(CloudShadow shadow, String strategyId) {
    if (_lists.containsKey(strategyId) || !_listsStarting.add(strategyId)) {
      return;
    }
    unawaited(
      betweenAnimations().then(
        (_) => _guarded(() => _watchList(shadow, strategyId)),
        onError: (Object error) => shadow.stop('$error'),
      ),
    );
  }

  void _watchList(CloudShadow shadow, String strategyId) {
    _listsStarting.remove(strategyId);
    if (_stopped || _lists.containsKey(strategyId)) return;
    final issue = issued();
    _lists[strategyId] = ref
        .read(convexStrategyRepositoryProvider)
        .watchPageList(strategyId)
        .listen(
          (list) => _guarded(() {
            if (_stopped) return;
            final tag = _tag(issue);
            shadow.pageList(strategyId, list, tag);
            if (tag.account == null) _rewatch(shadow, strategyId);
          }),
          onError: (Object error) => _guarded(() {
            if (_stopped) return;
            final tag = _tag(issue);
            shadow.readFailed(
              strategyId,
              'the page list',
              error,
              tag,
              refusedByServer: isConvexFunctionError(error),
            );
            if (tag.account == null) _rewatch(shadow, strategyId);
          }),
        );
  }

  void _rewatch(CloudShadow shadow, String strategyId) {
    final previous = _lists.remove(strategyId);
    if (previous != null) {
      unawaited(
        previous.cancel().then<void>(
              (_) {},
              onError: (Object error) => shadow.stop('$error'),
            ),
      );
    }
    _watchListLater(shadow, strategyId);
  }
}
