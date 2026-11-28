import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/live_results.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus_library/icarus_library.dart'
    show Account, CanRead, PageGone, StrategyGone;

final editorSubscriptionsProvider = Provider<EditorSubscriptions>(
  (ref) => switch (ref.watch(cloudStoreSwitchProvider)) {
    CloudStoreOff() =>
      TodaysSubscriptions(ref.watch(convexStrategyRepositoryProvider)),
    CloudStoreSend() => StampedSubscriptions(
        ref.watch(storeRepositoryProvider),
        accountSubject: () => ref.read(authProvider).user?.id,
        live: ref.watch(storeLiveResultsProvider),
        canRead: appCanRead,
      ),
  },
);

sealed class EditorSubscriptions {
  const EditorSubscriptions(this.repository);

  final ConvexStrategyRepository repository;

  Future<RemoteStrategyShell> readShell(
    String strategyPublicId, {
    String? shareToken,
  });

  Stream<RemoteStrategyShell> shell(
    String strategyPublicId, {
    String? shareToken,
  });

  Future<RemotePageSnapshot> readPage({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  });

  Stream<RemotePageSnapshot> page({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  });
}

final class TodaysSubscriptions extends EditorSubscriptions {
  const TodaysSubscriptions(super.repository);

  @override
  Future<RemoteStrategyShell> readShell(
    String strategyPublicId, {
    String? shareToken,
  }) =>
      repository.fetchShell(strategyPublicId, shareToken: shareToken);

  @override
  Future<RemotePageSnapshot> readPage({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) =>
      repository.fetchPageSnapshot(
        strategyPublicId: strategyPublicId,
        pagePublicId: pagePublicId,
        shareToken: shareToken,
      );

  @override
  Stream<RemoteStrategyShell> shell(
    String strategyPublicId, {
    String? shareToken,
  }) =>
      repository.watchShell(strategyPublicId, shareToken: shareToken);

  @override
  Stream<RemotePageSnapshot> page({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) =>
      repository.watchPageSnapshot(
        strategyPublicId: strategyPublicId,
        pagePublicId: pagePublicId,
        shareToken: shareToken,
      );
}

final class StampedSubscriptions extends EditorSubscriptions {
  StampedSubscriptions(
    super.repository, {
    required this.accountSubject,
    required this.live,
    required this.canRead,
  });

  final String? Function() accountSubject;
  final LiveResults live;
  final CanRead canRead;

  final _opening = <(String, String?, String?), FirstAnswerOfWatch<Object>>{};

  @override
  Future<RemoteStrategyShell> readShell(
    String strategyPublicId, {
    String? shareToken,
  }) async =>
      await _openedBy(
        (strategyPublicId, null, shareToken),
        () => _watchShell(strategyPublicId, shareToken: shareToken),
        orRead: () => repository.fetchShellOfPageList(
          strategyPublicId,
          shareToken: shareToken,
          accountSubject: accountSubject(),
        ),
      ) as RemoteStrategyShell;

  @override
  Future<RemotePageSnapshot> readPage({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) async =>
      await _openedBy(
        (strategyPublicId, pagePublicId, shareToken),
        () => _watchPage(
          strategyPublicId: strategyPublicId,
          pagePublicId: pagePublicId,
          shareToken: shareToken,
        ),
        orRead: () => repository.fetchPageSnapshotAs(
          strategyPublicId: strategyPublicId,
          pagePublicId: pagePublicId,
          shareToken: shareToken,
          accountSubject: accountSubject(),
        ),
      ) as RemotePageSnapshot;

  final _watched = <(String, String?, String?)>{};

  Future<Object> _openedBy(
    (String, String?, String?) subject,
    Stream<Object> Function() watch, {
    required Future<Object> Function() orRead,
  }) {
    if (_watched.contains(subject)) return orRead();
    _opening.remove(subject)?.cancel();
    _opening.removeWhere((held, opened) {
      if (held.$1 == subject.$1) return false;
      opened.cancel();
      return true;
    });
    final opened = FirstAnswerOfWatch<Object>(watch());
    _opening[subject] = opened;
    return opened.first.catchError((Object error) {
      if (identical(_opening[subject], opened)) _opening.remove(subject);
      throw error;
    });
  }

  Stream<T> _handedOver<T extends Object>(
    (String, String?, String?) subject,
    Stream<T> Function() watch,
  ) {
    final opened = _opening.remove(subject);
    final stream = opened == null ? watch() : opened.rest.cast<T>();
    late final StreamController<T> handed;
    StreamSubscription<T>? inner;
    handed = StreamController<T>(
      sync: true,
      onListen: () {
        _watched.add(subject);
        inner = stream.listen(
          handed.add,
          onError: handed.addError,
          onDone: handed.close,
        );
      },
      onPause: () => inner?.pause(),
      onResume: () => inner?.resume(),
      onCancel: () {
        _watched.remove(subject);
        return inner?.cancel();
      },
    );
    return handed.stream;
  }

  @override
  Stream<RemoteStrategyShell> shell(
    String strategyPublicId, {
    String? shareToken,
  }) =>
      _handedOver(
        (strategyPublicId, null, shareToken),
        () => _watchShell(strategyPublicId, shareToken: shareToken),
      );

  @override
  Stream<RemotePageSnapshot> page({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) =>
      _handedOver(
        (strategyPublicId, pagePublicId, shareToken),
        () => _watchPage(
          strategyPublicId: strategyPublicId,
          pagePublicId: pagePublicId,
          shareToken: shareToken,
        ),
      );

  Stream<RemoteStrategyShell> _watchShell(
    String strategyPublicId, {
    String? shareToken,
  }) {
    final subject = accountSubject();
    final watched = repository.watchPageListStamped(
      strategyPublicId,
      shareToken: shareToken,
      accountSubject: subject,
    );
    final told = subject == null || shareToken != null
        ? watched
        : _toldToTheStore(
            watched,
            strategyPublicId: strategyPublicId,
            subject: const ReadOfList(),
            account: Account(subject),
            answered: (answer) => live.liveArrived(
              strategyPublicId,
              const ReadOfList(),
              Account(subject),
              pageListOutcomeOf(switch (answer) {
                StampedValue(:final value, :final stamp) =>
                  StampedValue(value.list, stamp),
                StampedError(:final error, :final stamp) =>
                  StampedError(error, stamp),
              }),
            ),
            lostOf: (error) => storeReadOutcomeOfError(
              error,
              gone: const StrategyGone(),
              point: null,
            ),
          );
    return asPlainWatch(told).map((both) => both.shell);
  }

  Stream<RemotePageSnapshot> _watchPage({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) {
    final subject = accountSubject();
    final watched = repository.watchPageSnapshotStamped(
      strategyPublicId: strategyPublicId,
      pagePublicId: pagePublicId,
      shareToken: shareToken,
      accountSubject: subject,
    );
    if (subject == null || shareToken != null) return asPlainWatch(watched);
    return asPlainWatch(
      _toldToTheStore(
        watched,
        strategyPublicId: strategyPublicId,
        subject: ReadOfPage(pagePublicId),
        account: Account(subject),
        answered: (answer) => switch (answer) {
          StampedValue(:final value, :final stamp) => live.livePageArrived(
              strategyPublicId,
              ReadOfPage(pagePublicId),
              Account(subject),
              LivePageAnswer(
                value,
                pagePublicId: pagePublicId,
                point: pointOf(stamp),
              ),
            ),
          StampedError() => live.liveArrived(
              strategyPublicId,
              ReadOfPage(pagePublicId),
              Account(subject),
              pageOutcomeOf(
                answer,
                pagePublicId: pagePublicId,
                canRead: canRead,
              ),
            ),
        },
        lostOf: (error) => storeReadOutcomeOfError(
          error,
          gone: PageGone(pagePublicId),
          point: null,
        ),
      ),
    );
  }

  Stream<Stamped<T>> _toldToTheStore<T>(
    Stream<Stamped<T>> watched, {
    required String strategyPublicId,
    required ReadOf subject,
    required Account account,
    required void Function(Stamped<T> answer) answered,
    required StoreReadOutcome Function(Object error) lostOf,
  }) {
    void tellStore(void Function() hand) {
      try {
        hand();
      } catch (error, stackTrace) {
        AppErrorReporter.reportError(
          'The store did not take a live result of $subject',
          error: error,
          stackTrace: stackTrace,
          source: 'editor_subscriptions:live_results',
          promptUser: false,
        );
      }
    }

    StreamSubscription<Stamped<T>>? inner;
    late final StreamController<Stamped<T>> told;
    told = StreamController<Stamped<T>>(
      sync: true,
      onListen: () {
        tellStore(() => live.liveOpened(strategyPublicId, subject));
        inner = watched.listen(
          (answer) {
            told.add(answer);
            tellStore(() => answered(answer));
          },
          onError: (Object error, StackTrace stackTrace) {
            told.addError(error, stackTrace);
            tellStore(
              () => live.liveArrived(
                strategyPublicId,
                subject,
                account,
                lostOf(error),
              ),
            );
          },
          onDone: told.close,
        );
      },
      onPause: () => inner?.pause(),
      onResume: () => inner?.resume(),
      onCancel: () {
        tellStore(() => live.liveClosed(strategyPublicId, subject));
        return inner?.cancel();
      },
    );
    return told.stream;
  }
}

final class FirstAnswerOfWatch<T> {
  FirstAnswerOfWatch(Stream<T> watch) {
    _subscription = watch.listen(
      (value) {
        if (!_first.isCompleted) {
          _first.complete(value);
        } else {
          _later.add(value);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_first.isCompleted) {
          _first.completeError(error, stackTrace);
          unawaited(_subscription.cancel());
        } else {
          _later.addError(error, stackTrace);
        }
      },
      onDone: _later.close,
    );
  }

  late final StreamSubscription<T> _subscription;
  final _first = Completer<T>();
  final _later = StreamController<T>(sync: true);

  Future<T> get first => _first.future;

  Stream<T> get rest {
    _later.onCancel = _subscription.cancel;
    return _later.stream;
  }

  void cancel() => unawaited(_subscription.cancel());
}
