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

final class CloudShadowFailed extends CloudShadowState {
  const CloudShadowFailed(this.reason);

  final String reason;
}

final class CloudShadowRunning extends CloudShadowState {
  const CloudShadowRunning(this.shadow, this.file);

  final CloudShadow shadow;
  final File file;
}

typedef AuthChanges = ({int changes, bool settled, bool authenticated});

final authChangesProvider = Provider<AuthChanges Function()>(
  (ref) => () => (
        changes: ConvexClient.instance.authChanges,
        settled: ConvexClient.instance.authSettled,
        authenticated: ConvexClient.instance.isAuthenticated,
      ),
);

final class _Issue {
  _Issue({required this.throughShareLink});

  final bool throughShareLink;
}

typedef Drained = ({int readsOpen, int watchesOpen, bool idle});

final cloudShadowBreatheProvider = Provider<Future<void> Function()>(
  (ref) => betweenAnimations,
);

final cloudShadowProvider =
    NotifierProvider<CloudShadowNotifier, CloudShadowState>(
  CloudShadowNotifier.new,
);

class CloudShadowNotifier extends Notifier<CloudShadowState>
    implements ResultTap {
  final _taken = <_Issue>{};
  final _unanswered = <_Issue>{};
  final _closing = <Future<void>>{};
  CloudShadow? _shadow;
  ConvexStrategyRepository? _repository;
  StreamSubscription<RemotePageList>? _list;
  String? _listed;
  int? _account;
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
        );
        state = CloudShadowRunning(shadow, file);
        _guarded(() {
          ref.listen<bool>(
            convexConnectionSnapshotProvider,
            (previous, next) => _guarded(() {
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
        if (!auth.settled || auth.changes == 0 || !auth.authenticated) {
          return false;
        }
        _account = auth.changes;
        return true;
      case final account when account != auth.changes:
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
    _list = ref
        .read(convexStrategyRepositoryProvider)
        .watchPageList(strategyId)
        .listen(
          (list) => _guarded(() {
            if (!_serving()) return;
            shadow.pageList(strategyId, list, _connection());
          }),
          onError: (Object error) => _guarded(() {
            if (!_serving()) return;
            shadow.readFailed(
              strategyId,
              'the page list',
              error,
              _connection(),
            );
          }),
        );
  }

  int? _connection() => ref.read(strategyOpQueueProvider.notifier).liveStamp;

  @override
  Object issued({required bool throughShareLink}) {
    final issue = _Issue(throughShareLink: throughShareLink);
    if (_serving()) {
      _taken.add(issue);
      _unanswered.add(issue);
    }
    return issue;
  }

  bool _answered(Object issue) {
    if (!_taken.contains(issue)) return false;
    final first = _unanswered.remove(issue);
    if (_cutoff && !first) return false;
    final shadow = _shadow;
    if (shadow == null || shadow.ended != null) return false;
    final auth = ref.read(authChangesProvider)();
    if (auth.changes != _account) {
      shadow.end('the account changed');
      _closeList();
      return false;
    }
    return true;
  }

  @override
  void pageArrived(String strategyId, RemotePageSnapshot page, Object issue) {
    final shadow = _shadow;
    if (shadow == null || !_answered(issue)) return;
    if ((issue as _Issue).throughShareLink) {
      shadow.skipped(
        strategyId,
        'page ${page.page.publicId}',
        SkipReason.throughShareLink,
      );
      return;
    }
    shadow.page(strategyId, page, _connection());
  }

  @override
  void readFailed(String strategyId, String what, Object error, Object issue) {
    final shadow = _shadow;
    if (shadow == null || !_answered(issue)) return;
    if ((issue as _Issue).throughShareLink) {
      shadow.skipped(
          strategyId, 'a read of $what', SkipReason.throughShareLink);
      return;
    }
    shadow.readFailed(strategyId, what, error, _connection());
  }

  @override
  void readClosed(Object issue) {
    _taken.remove(issue);
    _unanswered.remove(issue);
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
    bool waiting() => _unanswered.isNotEmpty && shadow?.ended == null;
    while (waiting() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final closing = Future.wait([..._closing]);
    await closing.timeout(_left(deadline), onTimeout: () => const []);
    final idle = shadow == null
        ? true
        : await shadow.idle
            .then((_) => true)
            .timeout(_left(deadline), onTimeout: () => false);
    return (
      readsOpen: shadow?.ended == null ? _unanswered.length : 0,
      watchesOpen: _closing.length,
      idle: idle,
    );
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
    _taken.clear();
    _unanswered.clear();
  }
}
