import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus_library/icarus_library.dart' show Account;

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

typedef AuthChanges = ({int changes, bool authenticated, String? subject});

final authChangesProvider = Provider<AuthChanges Function()>(
  (ref) => () => (
        changes: ConvexClient.instance.authChanges,
        authenticated: ConvexClient.instance.isAuthenticated,
        subject: ref.read(authProvider).user?.id,
      ),
);

typedef Drained = ({int watchesOpen, bool idle});

final cloudShadowBreatheProvider = Provider<Future<void> Function()>(
  (ref) => betweenAnimations,
);

final cloudShadowProvider =
    NotifierProvider<CloudShadowNotifier, CloudShadowState>(
  CloudShadowNotifier.new,
);

class CloudShadowNotifier extends Notifier<CloudShadowState>
    implements ResultTap {
  final notTaken = <String, int>{};
  var handed = 0;
  final _closing = <Future<void>>{};
  CloudShadow? _shadow;
  ConvexStrategyRepository? _repository;
  StreamSubscription<RemotePageList>? _list;
  String? _listed;
  int? _account;
  String? subject;
  var _cutoff = false;

  @override
  CloudShadowState build() {
    ref.onDispose(() {
      cutoff();
      detach();
    });
    return const CloudShadowIdle();
  }

  Future<void> begin({
    required Future<LibraryStoreOpened> opening,
    required String build,
    bool sends = false,
  }) async {
    final LibraryStoreOpened opened;
    try {
      opened = await opening;
    } catch (error) {
      state = CloudShadowFailed('$error');
      return;
    }
    if (_cutoff) {
      state = const CloudShadowFailed('the run ended while the store opened');
      return;
    }
    switch (opened) {
      case LibraryStoreReady(:final store, :final file):
        final shadow = _shadow = CloudShadow(
          store,
          build: build,
          canRead: appCanRead,
          breathe: ref.read(cloudShadowBreatheProvider),
          intake: sends
              ? ref
                  .read(cloudSenderProvider.notifier)
                  .begin(store, build: build)
              : null,
        );
        state = CloudShadowRunning(shadow, file);
        _guarded(() {
          ref.listen<bool>(
            convexConnectionSnapshotProvider,
            (previous, next) => _guarded(() {
              if (_cutoff) return;
              if (previous == true && !next) shadow.connectionLost();
            }),
          );
          ref.listen<AsyncValue<RemoteEditorSnapshot?>>(
            remoteEditorSnapshotProvider,
            (_, next) => _guarded(
              () => _editorOpened(next.valueOrNull?.shell.header.publicId),
            ),
            fireImmediately: true,
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

  bool _serving() {
    final shadow = _shadow;
    if (shadow == null || _cutoff || shadow.ended != null) return false;
    final auth = ref.read(authChangesProvider)();
    switch (_account) {
      case null:
        if (auth.changes == 0 || !auth.authenticated) return false;
        final named = auth.subject;
        if (named == null) return false;
        _account = auth.changes;
        subject = named;
        shadow.serve(Account(named));
        shadow.intake?.resultsFrom(auth.changes);
        return true;
      case final account when account != auth.changes && shadow.intake == null:
        shadow.end('the account changed');
        _closeList();
        return false;
      case _:
        return true;
    }
  }

  void _close(Future<void> closing) {
    final tracked = closing.then<void>(
      (_) {},
      onError: (Object error) => _shadow?.stop('$error'),
    );
    _closing.add(tracked);
    unawaited(tracked.whenComplete(() => _closing.remove(tracked)));
  }

  void _closeList() {
    final list = _list;
    _list = null;
    _listed = null;
    if (list != null) _close(Future.sync(list.cancel));
  }

  void _editorOpened(String? strategyId) {
    if (strategyId == _listed) return;
    _closeList();
    if (strategyId == null) return;
    _listed = strategyId;
    final shadow = _shadow!;
    unawaited(
      ref.read(cloudShadowBreatheProvider)().then(
            (_) => _guarded(() => _watchList(shadow, strategyId)),
            onError: (Object error) => shadow.stop('$error'),
          ),
    );
  }

  void _watchList(CloudShadow shadow, String strategyId) {
    if (_listed != strategyId || _list != null || !_serving()) return;
    final named = subject!;
    _list = ref
        .read(convexStrategyRepositoryProvider)
        .watchPageList(strategyId, accountSubject: named)
        .listen(
          (list) => _guarded(() {
            if (!_serving()) return;
            final now = _stamp();
            final stamp = (
              account: Account(named),
              connection: now.connection,
              signIns: now.signIns,
            );
            shadow.pageList(strategyId, list, stamp.connection, stamp: stamp);
          }),
          onError: (Object _) => _notTaken('a page list read failed'),
        );
  }

  int? _connection() => ref.read(strategyOpQueueProvider.notifier).liveStamp;

  void _notTaken(String why) => notTaken[why] = (notTaken[why] ?? 0) + 1;

  @override
  Object? heard() => _stamp();

  Snapshot _stamp() {
    final auth = ref.read(authChangesProvider)();
    return (
      account: switch (auth) {
        (authenticated: true, subject: final named?, changes: _) =>
          Account(named),
        _ => null,
      },
      connection: _connection(),
      signIns: auth.changes,
    );
  }

  @override
  void pageArrived(
    String strategyId,
    RemotePageSnapshot page,
    Object? heard, {
    required bool throughShareLink,
  }) {
    final shadow = _shadow;
    if (shadow == null) return;
    handed++;
    if (throughShareLink) {
      _notTaken('read through a share link');
    } else if (!_serving()) {
      _notTaken(shadow.ended == null && !_cutoff
          ? 'handed over before the first sign-in'
          : 'handed over after the shadow stopped taking results');
    } else {
      final stamp = heard as Snapshot?;
      shadow.page(strategyId, page, stamp?.connection, stamp: stamp);
    }
  }

  @override
  void tapFailed(Object error) => _shadow?.stop('$error');

  void cutoff() {
    if (_cutoff) return;
    _serving();
    _cutoff = true;
    _closeList();
  }

  Future<Drained> drained(DateTime deadline) async {
    final shadow = _shadow;
    final closing = Future.wait([..._closing]);
    await closing.timeout(_left(deadline), onTimeout: () => const []);
    final idle = shadow == null
        ? true
        : await shadow.idle
            .then((_) => true)
            .timeout(_left(deadline), onTimeout: () => false);
    return (watchesOpen: _closing.length, idle: idle);
  }

  Duration _left(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void detach() {
    if (_repository case final repository?
        when identical(repository.tap, this)) {
      repository.tap = null;
    }
  }
}
