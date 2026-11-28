import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:icarus/strategy/autosave_before_exit.dart';
import 'package:icarus/strategy/store_save_facts.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:icarus/l10n/cloud_sync_error_text.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum UnsavedStrategyDecision {
  save,
  dontSave,
  cancel,
}

enum CloudExitDecision {
  stay,
  leaveAnyway,
  retrySync,
  retryAuth,
}

Future<UnsavedStrategyDecision> _showUnsavedStrategyDialog(
  BuildContext context,
  _ExitQuestion question,
) async {
  final result = await question.ask<UnsavedStrategyDecision>(
    context,
    (context, answer) {
      final l10n = context.l10n;
      return ShadDialog.alert(
        title: Text(l10n.unsavedGuardTitle),
        description: Text(l10n.unsavedGuardDescription),
        actions: [
          ShadButton.ghost(
            onPressed: () {
              answer(UnsavedStrategyDecision.cancel);
            },
            child: Text(l10n.commonCancel),
          ),
          ShadButton.destructive(
            onPressed: () {
              answer(UnsavedStrategyDecision.dontSave);
            },
            child: Text(l10n.unsavedGuardDontSave),
          ),
          ShadButton(
            onPressed: () {
              answer(UnsavedStrategyDecision.save);
            },
            child: Text(l10n.commonSave),
          ),
        ],
      );
    },
  );

  return result ?? UnsavedStrategyDecision.cancel;
}

Future<CloudExitDecision> _showCloudSyncBlockedDialog(
  BuildContext context,
  _ExitQuestion question, {
  required String message,
  required bool allowLeaveAnyway,
  required bool showRetryAuth,
}) async {
  final result = await question.ask<CloudExitDecision>(
    context,
    (context, answer) {
      final l10n = context.l10n;
      return ShadDialog.alert(
        title: Text(l10n.unsavedGuardCloudPendingTitle),
        description: Text(message),
        // One row that wraps when the labels need more room: the quiet way
        // out first, the command last.
        actions: [
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                ShadButton.ghost(
                  onPressed: () {
                    answer(CloudExitDecision.stay);
                  },
                  child: Text(l10n.unsavedGuardStayHere),
                ),
                if (showRetryAuth)
                  ShadButton.secondary(
                    onPressed: () {
                      answer(CloudExitDecision.retryAuth);
                    },
                    child: Text(l10n.unsavedGuardRetrySignIn),
                  ),
                if (allowLeaveAnyway)
                  ShadButton.secondary(
                    onPressed: () {
                      answer(CloudExitDecision.leaveAnyway);
                    },
                    child: Text(l10n.unsavedGuardLeaveAnyway),
                  ),
                ShadButton(
                  onPressed: () {
                    answer(CloudExitDecision.retrySync);
                  },
                  child: Text(l10n.unsavedGuardRetrySync),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  return result ?? CloudExitDecision.stay;
}

Future<bool> _waitForCloudSync(
  WidgetRef ref, {
  Duration timeout = const Duration(seconds: 8),
  Duration pollInterval = const Duration(milliseconds: 120),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final strategyId = ref.read(strategyProvider).strategyId;
    final saveState = ref.read(strategySaveStateProvider);
    final queueState = ref.read(strategyOpQueueProvider);
    final mediaQueueState = ref.read(cloudMediaUploadQueueProvider);
    final mediaJobs = mediaQueueState.jobsForStrategy(strategyId);
    if (!saveState.hasPendingCloudSync &&
        !saveState.hasPendingMediaSync &&
        mediaJobs.isEmpty &&
        queueState.pending.isEmpty &&
        !queueState.isFlushing &&
        !mediaQueueState.isProcessing &&
        saveState.cloudSyncError == null &&
        saveState.mediaSyncErrorCount == 0) {
      return true;
    }
    await Future<void>.delayed(pollInterval);
  }
  return false;
}

Future<LeaveAnswer> _guardCloudStrategyExit({
  required BuildContext context,
  required WidgetRef ref,
  required OpenSeen asked,
  required _ExitQuestion question,
}) async {
  if (ref.read(strategySaveStateProvider).storeOwned != null) {
    return _guardStoreOwnedExit(
      context: context,
      ref: ref,
      asked: asked,
      question: question,
    );
  }
  final l10n = context.l10n;
  final openingStrategy = ref.read(strategyProvider);
  final openingSaveState = ref.read(strategySaveStateProvider);
  if ((ref.read(textDraftProvider).isNotEmpty || openingSaveState.isDirty) &&
      openingStrategy.strategyId != null) {
    ref.read(textDraftProvider.notifier).commitAllDrafts();
    try {
      await ref
          .read(strategyProvider.notifier)
          .forceSaveNow(openingStrategy.strategyId!);
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        l10n.unsavedGuardTextEditSyncFailed,
        error: error,
        stackTrace: stackTrace,
        source: 'cloud_media.exit_guard',
      );
      return const Stay();
    }
  }

  // Set when the user chose Leave anyway. It is honoured only if the work
  // is still all in the durable outboxes when the state is read again:
  // something may have changed while the dialog was open.
  var leaveIfDurable = false;
  while (true) {
    final strategyState = ref.read(strategyProvider);
    final saveState = ref.read(strategySaveStateProvider);
    final queueState = ref.read(strategyOpQueueProvider);
    final authState = ref.read(authProvider);
    final mediaQueueState = ref.read(cloudMediaUploadQueueProvider);
    final mediaJobs = mediaQueueState.jobsForStrategy(strategyState.strategyId);
    final hasPendingMediaJobs = mediaJobs.isNotEmpty;
    final outboxError = !queueState.outboxIsReliable
        ? 'Icarus could not confirm that cloud edits are saved on this device.'
        : (!mediaQueueState.outboxIsReliable
            ? (mediaQueueState.durabilityError ??
                'Icarus could not confirm that media work is saved on this device.')
            : null);

    final hasPendingSync = saveState.hasPendingCloudSync ||
        saveState.hasPendingMediaSync ||
        hasPendingMediaJobs ||
        queueState.pending.isNotEmpty;
    final cloudError =
        saveState.cloudSyncError ?? queueState.lastError ?? outboxError;
    final hasDurablePendingWork =
        queueState.pending.isNotEmpty || hasPendingMediaJobs;
    final hasUncommittedMediaReferences = mediaJobs.any(
      (job) => !job.referenceDurable,
    );
    final hasUnstagedWork = ref.read(textDraftProvider).isNotEmpty ||
        hasUncommittedMediaReferences ||
        ref.read(strategySaveStateProvider.notifier).canvasHeld ||
        (saveState.isDirty && !hasDurablePendingWork);
    final hasUnreadableSavedWork = queueState.loadIssues.isNotEmpty ||
        mediaQueueState.loadIssues.isNotEmpty;
    final canLeaveWithDurableWork = !hasUnstagedWork &&
        queueState.durableLoaded &&
        mediaQueueState.durableLoaded &&
        !queueState.hasDurabilityFailure &&
        mediaQueueState.durabilityError == null &&
        ((hasDurablePendingWork &&
                queueState.outboxIsReliable &&
                mediaQueueState.outboxIsReliable) ||
            hasUnreadableSavedWork);
    if (leaveIfDurable) {
      leaveIfDurable = false;
      if (canLeaveWithDurableWork) {
        if (!context.mounted) return const Stay();
        return Leave(asked);
      }
    }
    final isConnected = ref.read(convexConnectionSnapshotProvider);
    AppErrorReporter.reportInfo(
      'Cloud exit guard check: strategy=${strategyState.strategyId} '
      'dirty=${saveState.isDirty} saving=${saveState.isSaving} '
      'pendingCloud=${saveState.hasPendingCloudSync} '
      'pendingMedia=${saveState.hasPendingMediaSync} '
      'mediaErrors=${saveState.mediaSyncErrorCount} '
      'opPending=${queueState.pending.length} '
      'opFlushing=${queueState.isFlushing} '
      'mediaJobs=${mediaQueueState.jobs.length} '
      'mediaProcessing=${mediaQueueState.isProcessing} '
      'auth=${authState.isAuthenticated} '
      'userReady=${authState.isConvexUserReady} '
      'authIncident=${authState.hasActiveAuthIncident} '
      'connected=$isConnected '
      'durablePending=$hasDurablePendingWork '
      'uncommittedMediaReferences=$hasUncommittedMediaReferences '
      'canLeaveWithDurableWork=$canLeaveWithDurableWork '
      'cloudError=${cloudError ?? 'none'}',
      source: 'cloud_media.exit_guard',
    );
    // Nothing pending and nothing new since the save on entry: a draft or
    // edit made during the wait would still be unstaged.
    if (!hasPendingSync && cloudError == null && !hasUnstagedWork) {
      if (!context.mounted) {
        return const Stay();
      }
      AppErrorReporter.reportInfo(
        'Cloud exit guard allowing leave: strategy=${strategyState.strategyId}',
        source: 'cloud_media.exit_guard',
      );
      return Leave(asked);
    }

    if ((queueState.isFlushing || mediaQueueState.isProcessing) &&
        cloudError == null) {
      AppErrorReporter.reportInfo(
        'Cloud exit guard waiting for active op flush: '
        'strategy=${strategyState.strategyId}',
        source: 'cloud_media.exit_guard',
      );
      final synced = await _waitForCloudSync(ref);
      if (synced) {
        AppErrorReporter.reportInfo(
          'Cloud exit guard wait completed; rechecking sync state.',
          source: 'cloud_media.exit_guard',
        );
        continue;
      }
      AppErrorReporter.reportInfo(
        'Cloud exit guard wait timed out; showing blocked dialog.',
        source: 'cloud_media.exit_guard',
      );
    }

    if (!context.mounted) return const Stay();

    final decision = await _showCloudSyncBlockedDialog(
      context,
      question,
      message: _cloudSyncBlockedMessage(
        l10n: context.l10n,
        isConnected: isConnected,
        cloudError: cloudError,
        mediaErrorCount: saveState.mediaSyncErrorCount,
        canLeaveWithDurableWork: canLeaveWithDurableWork,
        hasUnreadableSavedWork: hasUnreadableSavedWork,
        hasRefusedWork: queueState.attentionByEntityKey.isNotEmpty,
        hasPausedWork: queueState.pausedByEntityKey.isNotEmpty,
      ),
      allowLeaveAnyway: canLeaveWithDurableWork,
      showRetryAuth: authState.hasActiveAuthIncident,
    );

    switch (decision) {
      case CloudExitDecision.stay:
        AppErrorReporter.reportInfo(
          'Cloud exit guard user chose stay.',
          source: 'cloud_media.exit_guard',
        );
        return const Stay();
      case CloudExitDecision.retryAuth:
        AppErrorReporter.reportInfo(
          'Cloud exit guard retrying auth.',
          source: 'cloud_media.exit_guard',
        );
        await ref
            .read(authProvider.notifier)
            .reinitializeConvexAuth(source: 'cloud_exit_guard');
        break;
      case CloudExitDecision.leaveAnyway:
        AppErrorReporter.reportInfo(
          'Cloud exit guard leaving with work pending in durable outboxes.',
          source: 'cloud_media.exit_guard',
        );
        leaveIfDurable = true;
        break;
      case CloudExitDecision.retrySync:
        AppErrorReporter.reportInfo(
          'Cloud exit guard retrying sync.',
          source: 'cloud_media.exit_guard',
        );
        final strategyId = strategyState.strategyId;
        if (strategyId == null) {
          return const Stay();
        }
        await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
        break;
    }
  }
}

Future<LeaveAnswer> _guardStoreOwnedExit({
  required BuildContext context,
  required WidgetRef ref,
  required OpenSeen asked,
  required _ExitQuestion question,
}) async {
  final l10n = context.l10n;
  final strategyId = ref.read(strategyProvider).strategyId;
  final opening = ref.read(strategySaveStateProvider).storeOwned;
  if ((ref.read(textDraftProvider).isNotEmpty ||
          (opening?.canvasAheadOfStore ?? false)) &&
      strategyId != null) {
    ref.read(textDraftProvider.notifier).commitAllDrafts();
    try {
      await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        l10n.unsavedGuardTextEditSyncFailed,
        error: error,
        stackTrace: stackTrace,
        source: 'cloud_store.exit_guard',
      );
      return const Stay();
    }
  }
  var leaveIfKept = false;
  while (true) {
    final saveState = ref.read(strategySaveStateProvider);
    final owned = saveState.storeOwned;
    if (owned == null) return const Stay();
    final mediaJobs = ref
        .read(cloudMediaUploadQueueProvider)
        .jobsForStrategy(ref.read(strategyProvider).strategyId);
    final ahead = owned.storeAheadOfServer;
    final unstaged = ref.read(textDraftProvider).isNotEmpty ||
        owned.canvasAheadOfStore ||
        mediaJobs.any((job) => !job.referenceDurable);
    if (!unstaged &&
        ahead is StoreMatchesServer &&
        mediaJobs.isEmpty &&
        saveState.mediaSyncErrorCount == 0) {
      return Leave(asked);
    }
    if (leaveIfKept) {
      leaveIfKept = false;
      if (!unstaged) return Leave(asked);
    }
    if (!context.mounted) return const Stay();
    final decision = await _showCloudSyncBlockedDialog(
      context,
      question,
      message: _cloudSyncBlockedMessage(
        l10n: context.l10n,
        isConnected: ref.read(convexConnectionSnapshotProvider),
        cloudError: null,
        mediaErrorCount: saveState.mediaSyncErrorCount,
        canLeaveWithDurableWork: !unstaged,
        hasUnreadableSavedWork: false,
        hasRefusedWork: ahead is StoreNeedsUser,
        hasPausedWork: false,
      ),
      allowLeaveAnyway: !unstaged,
      showRetryAuth: ref.read(authProvider).hasActiveAuthIncident,
    );
    switch (decision) {
      case CloudExitDecision.stay:
        return const Stay();
      case CloudExitDecision.retryAuth:
        await ref
            .read(authProvider.notifier)
            .reinitializeConvexAuth(source: 'cloud_store_exit_guard');
      case CloudExitDecision.leaveAnyway:
        leaveIfKept = true;
      case CloudExitDecision.retrySync:
        final strategyId = ref.read(strategyProvider).strategyId;
        if (strategyId == null) return const Stay();
        await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
    }
  }
}

String _cloudSyncBlockedMessage({
  required AppLocalizations l10n,
  required bool isConnected,
  required String? cloudError,
  required int mediaErrorCount,
  required bool canLeaveWithDurableWork,
  required bool hasUnreadableSavedWork,
  required bool hasRefusedWork,
  required bool hasPausedWork,
}) {
  final base = !isConnected
      ? l10n.unsavedGuardOffline
      : (cloudError != null
          ? friendlyCloudSyncError(l10n, cloudError)
          : (mediaErrorCount > 0
              ? l10n.unsavedGuardImagesPending
              : l10n.unsavedGuardStillSending));
  if (canLeaveWithDurableWork) {
    if (hasUnreadableSavedWork) {
      return l10n.unsavedGuardLeaveKeepsUnreadable(base);
    }
    // Refused work waits for the user's choice; nothing retries it.
    if (hasRefusedWork) {
      return l10n.unsavedGuardLeaveChooseLater(base);
    }
    // Paused work is sent again only when the user retries it.
    if (hasPausedWork) {
      return l10n.unsavedGuardLeaveRetryFromButton(base);
    }
    return l10n.unsavedGuardLeaveRetriesLater(base);
  }
  return l10n.unsavedGuardStayAndRetry(base);
}

Future<AutosaveBeforeExit> _autosaveUntilItHoldsEditsMadeMeanwhile(
  StrategyProvider strategies,
  OpenSeen asked,
) async {
  var autosave = await strategies.flushPendingAutosaveBeforeExit();
  while (autosave is EditedDuringTheAutosave &&
      asked.isNow(strategies.askedByTheUserNow())) {
    autosave = await strategies.flushPendingAutosaveBeforeExit();
  }
  return autosave;
}

Future<void> _saveUntilItHoldsEditsMadeMeanwhile(
  WidgetRef ref,
  String strategyId,
  OpenSeen asked,
) async {
  final strategies = ref.read(strategyProvider.notifier);
  final edits = ref.read(strategySaveStateProvider.notifier);
  int marks;
  do {
    marks = edits.dirtyMarks;
    await strategies.forceSaveNow(strategyId);
  } while (edits.dirtyMarks != marks &&
      ref.read(strategySaveStateProvider).isDirty &&
      asked.isNow(strategies.askedByTheUserNow()));
}

final class _LeaveRequest {
  _LeaveRequest({required this.closesWindow});

  final bool closesWindow;
  final answer = Completer<LeaveAnswer>();
}

sealed class _QuestionState {
  const _QuestionState();
}

final class _Saving extends _QuestionState {
  const _Saving();
}

final class _Asking extends _QuestionState {
  _Asking(this.dialog, this.unanswered);

  final Route<dynamic> dialog;
  final void Function() unanswered;
  final stopWatching = <void Function()>[];
}

final class _Settled extends _QuestionState {
  const _Settled();
}

typedef _AnswerBuilder<T> = Widget Function(
  BuildContext context,
  void Function(T decision) answer,
);

final class _ExitQuestion {
  _ExitQuestion(this.asked, this._container);

  final OpenSeen asked;
  final ProviderContainer _container;
  final requests = <_LeaveRequest>[];
  _QuestionState _state = const _Saving();

  bool _mayAsk() =>
      asked.isNow(
          _container.read(strategyProvider.notifier).askedByTheUserNow()) &&
      StrategyView.onScreen.value > 0;

  bool takes(OpenSeen now) => _state is! _Settled && asked.isNow(now);

  Future<T?> ask<T>(BuildContext context, _AnswerBuilder<T> builder) {
    if (_state is _Settled) return Future.value();
    if (!_mayAsk()) {
      settle(const Superseded());
      return Future.value();
    }
    final answered = Completer<T?>();
    late final _Asking asking;
    bool end(T? decision) {
      if (!identical(_state, asking)) return false;
      if (!_mayAsk()) {
        settle(const Superseded());
        return false;
      }
      _stopAsking(asking);
      answered.complete(decision);
      return true;
    }

    final dialog = _dialogRoute<T>(
      context,
      (context) => identical(_state, asking)
          ? builder(context, (decision) {
              if (end(decision)) Navigator.of(context).pop();
            })
          : const SizedBox.shrink(),
    );
    asking = _Asking(dialog, () {
      if (!answered.isCompleted) answered.complete();
    });
    _state = asking;
    asking.stopWatching.addAll([
      _container.listen(strategyProvider, (_, __) => _recheck()).close,
      _container.listen(openCountProvider, (_, __) => _recheck()).close,
    ]);
    StrategyView.onScreen.addListener(_recheck);
    asking.stopWatching
        .add(() => StrategyView.onScreen.removeListener(_recheck));
    unawaited(Navigator.of(context, rootNavigator: true)
        .push(dialog)
        .then((_) => end(null)));
    return answered.future;
  }

  void _recheck() {
    if (_state is _Asking && !_mayAsk()) settle(const Superseded());
  }

  void _stopAsking(_Asking asking) {
    for (final stop in asking.stopWatching) {
      stop();
    }
    _state = const _Saving();
  }

  void settle(LeaveAnswer answer) {
    final ended = _state;
    if (ended is _Settled) return;
    if (ended is _Asking) _stopAsking(ended);
    _state = const _Settled();
    _questions.remove(this);
    final goes = switch (answer) {
      Stay() || Superseded() => null,
      Leave() => requests.lastWhere(
          (request) => request.closesWindow,
          orElse: () => requests.last,
        ),
    };
    for (final request in requests) {
      request.answer.complete(switch (answer) {
        Superseded() => answer,
        _ => identical(request, goes) ? answer : const Stay(),
      });
    }
    if (ended is _Asking) {
      ended.unanswered();
      _remove(ended.dialog);
    }
  }

  static void _remove(Route<dynamic> dialog) {
    void remove() {
      if (dialog.isActive) dialog.navigator?.removeRoute(dialog);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => remove());
    } else {
      remove();
    }
  }
}

ShadDialogRoute<T> _dialogRoute<T>(
  BuildContext context,
  WidgetBuilder builder,
) {
  final dialogTheme = ShadTheme.of(context).primaryDialogTheme;
  final animateIn = dialogTheme.animateIn ??
      const [
        FadeEffect(),
        ScaleEffect(begin: Offset(.95, .95), end: Offset(1, 1)),
      ];
  final animateOut = dialogTheme.animateOut ??
      const [
        FadeEffect(begin: 1, end: 0),
        ScaleEffect(begin: Offset(1, 1), end: Offset(.95, .95)),
      ];
  Duration longest(List<AnimateEffect<dynamic>> effects) => effects.fold(
        Duration.zero,
        (longest, effect) {
          final total = (effect.delay ?? Duration.zero) +
              (effect.duration ?? Animate.defaultDuration);
          return total > longest ? total : longest;
        },
      );
  return ShadDialogRoute<T>(
    pageBuilder: builder,
    barrierColor: const Color(0xcc000000),
    barrierDismissible: true,
    barrierLabel: '',
    transitionDuration: longest(animateIn),
    reverseTransitionDuration: longest(animateOut),
    transitionBuilder: (context, animation, _, child) {
      if (animation.status == AnimationStatus.completed) return child;
      return ShadAnimate(
        effects: animation.status == AnimationStatus.forward
            ? animateIn
            : animateOut,
        child: child,
      );
    },
  );
}

final _questions = <_ExitQuestion>[];

@useResult
Future<LeaveAnswer> guardUnsavedStrategyExit({
  required BuildContext context,
  required WidgetRef ref,
  required String source,
  bool closesWindow = false,
}) {
  final strategies = ref.read(strategyProvider.notifier);
  final asked = strategies.askedByTheUserNow();
  final request = _LeaveRequest(closesWindow: closesWindow);
  final asking =
      _questions.where((question) => question.takes(asked)).lastOrNull;
  if (asking != null) {
    asking.requests.add(request);
    return request.answer.future;
  }
  final question = _ExitQuestion(
    asked,
    ProviderScope.containerOf(context, listen: false),
  )..requests.add(request);
  _questions.add(question);
  final l10n = context.l10n;
  unawaited(() async {
    LeaveAnswer answer = const Stay();
    try {
      answer = await _askAbout(
        context: context,
        ref: ref,
        source: source,
        asked: asked,
        question: question,
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        l10n.unsavedGuardSaveFailed,
        error: error,
        stackTrace: stackTrace,
        source: source,
      );
    } finally {
      question.settle(answer);
    }
  }());
  return request.answer.future;
}

Future<LeaveAnswer> _askAbout({
  required BuildContext context,
  required WidgetRef ref,
  required String source,
  required OpenSeen asked,
  required _ExitQuestion question,
}) async {
  final l10n = context.l10n;
  final strategyState = ref.read(strategyProvider);
  final saveState = ref.read(strategySaveStateProvider);
  if (strategyState.source == StrategySource.cloud) {
    return _guardCloudStrategyExit(
      context: context,
      ref: ref,
      asked: asked,
      question: question,
    );
  }

  final hasTextDrafts = ref.read(textDraftProvider).isNotEmpty;
  if (strategyState.strategyName == null ||
      (!saveState.isDirty && !hasTextDrafts)) {
    return Leave(asked);
  }

  try {
    switch (await _autosaveUntilItHoldsEditsMadeMeanwhile(
      ref.read(strategyProvider.notifier),
      asked,
    )) {
      case NothingLeftUnsaved() || EditedDuringTheAutosave():
        return Leave(asked);
      case NotAutosaved():
        break;
    }
  } catch (error, stackTrace) {
    AppErrorReporter.reportError(
      l10n.unsavedGuardSaveFailed,
      error: error,
      stackTrace: stackTrace,
      source: source,
    );
  }

  if (!context.mounted) return const Stay();

  final decision = await _showUnsavedStrategyDialog(context, question);
  switch (decision) {
    case UnsavedStrategyDecision.save:
      try {
        final strategyId = strategyState.strategyId;
        if (strategyId == null) {
          return const Stay();
        }
        await _saveUntilItHoldsEditsMadeMeanwhile(ref, strategyId, asked);
      } catch (error, stackTrace) {
        AppErrorReporter.reportError(
          l10n.unsavedGuardSaveFailed,
          error: error,
          stackTrace: stackTrace,
          source: source,
        );
        return const Stay();
      }
      if (asked
              .isNow(ref.read(strategyProvider.notifier).askedByTheUserNow()) &&
          ref.read(strategySaveStateProvider).isDirty) {
        AppErrorReporter.reportError(l10n.unsavedGuardSaveFailed,
            source: source);
        return const Stay();
      }
      return Leave(asked);
    case UnsavedStrategyDecision.dontSave:
      return Leave(asked);
    case UnsavedStrategyDecision.cancel:
      return const Stay();
  }
}
