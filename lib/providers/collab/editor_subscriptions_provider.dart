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
  const StampedSubscriptions(
    super.repository, {
    required this.accountSubject,
    required this.live,
    required this.canRead,
  });

  final String? Function() accountSubject;
  final LiveResults live;
  final CanRead canRead;

  @override
  Future<RemoteStrategyShell> readShell(
    String strategyPublicId, {
    String? shareToken,
  }) =>
      repository.fetchShellOfPageList(
        strategyPublicId,
        shareToken: shareToken,
        accountSubject: accountSubject(),
      );

  @override
  Future<RemotePageSnapshot> readPage({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) =>
      repository.fetchPageSnapshotAs(
        strategyPublicId: strategyPublicId,
        pagePublicId: pagePublicId,
        shareToken: shareToken,
        accountSubject: accountSubject(),
      );

  @override
  Stream<RemoteStrategyShell> shell(
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
            outcomeOf: (answer) => pageListOutcomeOf(switch (answer) {
              StampedValue(:final value, :final stamp) =>
                StampedValue(value.list, stamp),
              StampedError(:final error, :final stamp) =>
                StampedError(error, stamp),
            }),
            lostOf: (error) => storeReadOutcomeOfError(
              error,
              gone: const StrategyGone(),
              point: null,
            ),
          );
    return asPlainWatch(told).map((both) => both.shell);
  }

  @override
  Stream<RemotePageSnapshot> page({
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
        outcomeOf: (answer) => pageOutcomeOf(
          answer,
          pagePublicId: pagePublicId,
          canRead: canRead,
        ),
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
    required StoreReadOutcome Function(Stamped<T> answer) outcomeOf,
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
            tellStore(
              () => live.liveArrived(
                strategyPublicId,
                subject,
                account,
                outcomeOf(answer),
              ),
            );
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
