import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
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

final class CloudShadowRunning extends CloudShadowState {
  const CloudShadowRunning(this.shadow);

  final CloudShadow shadow;
}

final cloudShadowProvider =
    NotifierProvider<CloudShadowNotifier, CloudShadowState>(
  CloudShadowNotifier.new,
);

class CloudShadowNotifier extends Notifier<CloudShadowState> {
  StreamSubscription<RemotePageList>? _pageList;
  String? _watched;
  RemotePageSnapshot? _lastPage;

  @override
  CloudShadowState build() {
    ref.onDispose(() => _pageList?.cancel());
    return const CloudShadowIdle();
  }

  Future<void> begin({
    required Future<LibraryStoreOpened> opening,
    required String build,
  }) async {
    final opened = await opening;
    switch (opened) {
      case LibraryStoreReady(:final store):
        final shadow = CloudShadow(store, build: build, canRead: appCanRead);
        state = CloudShadowRunning(shadow);
        _follow(shadow);
      case LibraryStoreHeldElsewhere() ||
            LibraryStoreRefused() ||
            LibraryStoreTooSmall():
        state = CloudShadowNotOpened(opened);
    }
  }

  int? get _stamp => ref.read(strategyOpQueueProvider.notifier).liveStamp;

  void _follow(CloudShadow shadow) {
    shadow.account(ref.read(strategyOutboxSessionProvider).accountId);
    shadow.connection(_stamp);
    ref.listen<StrategyOutboxSession>(
      strategyOutboxSessionProvider,
      (_, next) => shadow.account(next.accountId),
    );
    ref.listen<bool>(
      convexConnectionSnapshotProvider,
      (_, __) => scheduleMicrotask(() => shadow.connection(_stamp)),
    );
    ref.listen<AsyncValue<RemoteEditorSnapshot?>>(
      remoteEditorSnapshotProvider,
      (_, next) => _snapshot(shadow, next.valueOrNull),
      fireImmediately: true,
    );
  }

  void _snapshot(CloudShadow shadow, RemoteEditorSnapshot? snapshot) {
    final strategyId = snapshot?.shell.header.publicId;
    if (strategyId != _watched) {
      unawaited(_pageList?.cancel());
      _pageList = null;
      _lastPage = null;
      _watched = strategyId;
      shadow.strategyClosed();
      if (strategyId != null) _watchPageList(shadow, strategyId);
    }
    final page = snapshot?.activePage;
    if (strategyId == null || page == null || identical(page, _lastPage)) {
      return;
    }
    _lastPage = page;
    if (page.fromCopy || page.madeHere) return;
    final remote = ref.read(remoteEditorSnapshotProvider.notifier);
    shadow.page(
      strategyId,
      page,
      stamp: remote.answeredOnCurrentConnection(page) ? _stamp : null,
    );
  }

  void _watchPageList(CloudShadow shadow, String strategyId) {
    _pageList = ref
        .read(convexStrategyRepositoryProvider)
        .watchPageList(strategyId)
        .listen(
          (list) => shadow.pageList(strategyId, list, stamp: _stamp),
          onError: (Object error) => shadow.reports.add(
            ShadowSkipped(
                strategyId, 'the page list', 'the read failed: $error'),
          ),
        );
  }
}
