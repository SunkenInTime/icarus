import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/shadow_store.dart';
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
  const CloudShadowRunning(this.shadow, this.file);

  final CloudShadow shadow;
  final File file;
}

final cloudShadowProvider =
    NotifierProvider<CloudShadowNotifier, CloudShadowState>(
  CloudShadowNotifier.new,
);

class CloudShadowNotifier extends Notifier<CloudShadowState> {
  StreamSubscription<RemotePageList>? _pageList;
  String? _watched;
  RemotePageSnapshot? _lastPage;
  String? _accountId;
  int _account = 0;

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
      case LibraryStoreReady(:final store, :final file):
        final shadow = CloudShadow(
          store,
          build: build,
          canRead: appCanRead,
          breathe: betweenAnimations,
        );
        state = CloudShadowRunning(shadow, file);
        _guarded(shadow, () => _follow(shadow));
      case LibraryStoreHeldElsewhere() ||
            LibraryStoreRefused() ||
            LibraryStoreTooSmall():
        state = CloudShadowNotOpened(opened);
    }
  }

  void _guarded(CloudShadow shadow, void Function() work) {
    try {
      work();
    } catch (error) {
      shadow.stop('$error');
    }
  }

  ResultTag _tag(int? connection) {
    final accountId = ref.read(strategyOutboxSessionProvider).accountId;
    if (accountId != _accountId) {
      _accountId = accountId;
      _account++;
    }
    return (connection: connection, account: _account);
  }

  void _follow(CloudShadow shadow) {
    _accountId = ref.read(strategyOutboxSessionProvider).accountId;
    ref.listen<bool>(
      convexConnectionSnapshotProvider,
      (previous, next) => _guarded(shadow, () {
        if (previous == true && !next) shadow.connectionLost();
      }),
    );
    ref.listen<AsyncValue<RemoteEditorSnapshot?>>(
      remoteEditorSnapshotProvider,
      (_, next) => _guarded(shadow, () => _snapshot(shadow, next.valueOrNull)),
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
      if (strategyId != null) {
        unawaited(
          betweenAnimations().then(
            (_) => _guarded(shadow, () => _watchPageList(shadow, strategyId)),
          ),
        );
      }
    }
    final page = snapshot?.activePage;
    if (strategyId == null || page == null || identical(page, _lastPage)) {
      return;
    }
    _lastPage = page;
    if (page.fromCopy || page.madeHere) return;
    final remote = ref.read(remoteEditorSnapshotProvider.notifier);
    shadow.page(strategyId, page, _tag(remote.connectionOf(page)));
  }

  void _watchPageList(CloudShadow shadow, String strategyId) {
    if (_watched != strategyId || _pageList != null) return;
    _pageList = ref
        .read(convexStrategyRepositoryProvider)
        .watchPageList(strategyId)
        .listen(
          (list) => _guarded(
            shadow,
            () => shadow.pageList(
              strategyId,
              list,
              _tag(ref.read(strategyOpQueueProvider.notifier).liveStamp),
            ),
          ),
          onError: (Object error) =>
              shadow.reports.add(ShadowReadFailed(strategyId, '$error')),
        );
  }
}
