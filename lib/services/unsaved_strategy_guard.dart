import 'dart:async';

import 'package:flutter/material.dart';
import 'package:icarus/strategy/autosave_before_exit.dart';
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
  final result = await showShadDialog<UnsavedStrategyDecision>(
    context: context,
    builder: (context) {
      final l10n = context.l10n;
      return _AskedBy(
        question,
        child: ShadDialog.alert(
          title: Text(l10n.unsavedGuardTitle),
          description: Text(l10n.unsavedGuardDescription),
          actions: [
            ShadButton.ghost(
              onPressed: () {
                Navigator.of(context).pop(UnsavedStrategyDecision.cancel);
              },
              child: Text(l10n.commonCancel),
            ),
            ShadButton.destructive(
              onPressed: () {
                Navigator.of(context).pop(UnsavedStrategyDecision.dontSave);
              },
              child: Text(l10n.unsavedGuardDontSave),
            ),
            ShadButton(
              onPressed: () {
                Navigator.of(context).pop(UnsavedStrategyDecision.save);
              },
              child: Text(l10n.commonSave),
            ),
          ],
        ),
      );
    },
  );

  return result ?? UnsavedStrategyDecision.cancel;
}

class _AskedBy extends StatefulWidget {
  const _AskedBy(this.question, {required this.child});

  final _ExitQuestion question;
  final Widget child;

  @override
  State<_AskedBy> createState() => _AskedByState();
}

class _AskedByState extends State<_AskedBy> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ModalRoute.of(context) case final dialog? when mounted) {
        widget.question.asks(dialog);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

Future<CloudExitDecision> _showCloudSyncBlockedDialog(
  BuildContext context,
  _ExitQuestion question, {
  required String message,
  required bool allowLeaveAnyway,
  required bool showRetryAuth,
}) async {
  final result = await showShadDialog<CloudExitDecision>(
    context: context,
    builder: (context) {
      final l10n = context.l10n;
      return _AskedBy(question,
          child: ShadDialog.alert(
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
                        Navigator.of(context).pop(CloudExitDecision.stay);
                      },
                      child: Text(l10n.unsavedGuardStayHere),
                    ),
                    if (showRetryAuth)
                      ShadButton.secondary(
                        onPressed: () {
                          Navigator.of(context)
                              .pop(CloudExitDecision.retryAuth);
                        },
                        child: Text(l10n.unsavedGuardRetrySignIn),
                      ),
                    if (allowLeaveAnyway)
                      ShadButton.secondary(
                        onPressed: () {
                          Navigator.of(context)
                              .pop(CloudExitDecision.leaveAnyway);
                        },
                        child: Text(l10n.unsavedGuardLeaveAnyway),
                      ),
                    ShadButton(
                      onPressed: () {
                        Navigator.of(context).pop(CloudExitDecision.retrySync);
                      },
                      child: Text(l10n.unsavedGuardRetrySync),
                    ),
                  ],
                ),
              ),
            ],
          ));
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

    if (!context.mounted ||
        !asked.isNow(
            ref.read(strategyProvider.notifier).askedByTheUserNow())) {
      return const Stay();
    }

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
    question.answered();

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
  const _Asking(this.dialog);

  final Route<dynamic> dialog;
}

final class _Settled extends _QuestionState {
  const _Settled();
}

final class _ExitQuestion {
  _ExitQuestion(this.asked, this._strategies, this._edits);

  final OpenSeen asked;
  final StrategyProvider _strategies;
  final StrategySaveStateNotifier _edits;
  final requests = <_LeaveRequest>[];
  _QuestionState _state = const _Saving();
  List<ProviderSubscription<Object?>> _watching = const [];

  bool _isAboutWhatIsOpen() =>
      asked.isNow(_strategies.askedByTheUserNow());

  bool takes(OpenSeen now) => _state is! _Settled && asked.isNow(now);

  void watch(ProviderContainer container) {
    void check() {
      if (_state is _Asking && !_isAboutWhatIsOpen()) abandon();
    }

    _watching = [
      container.listen(strategyProvider, (_, __) => check()),
      container.listen(strategyOpeningProvider, (_, __) => check()),
    ];
  }

  void asks(Route<dynamic> dialog) {
    switch (_state) {
      case _Settled():
        _remove(dialog);
      case _Saving() || _Asking():
        _state = _Asking(dialog);
        if (!_isAboutWhatIsOpen()) abandon();
    }
  }

  void answered() {
    if (_state is _Asking) _state = const _Saving();
  }

  void abandon() {
    if (_state case _Asking(:final dialog)) {
      settle(const Stay());
      _remove(dialog);
    }
  }

  void settle(LeaveAnswer answer) {
    if (_state is _Settled) return;
    _state = const _Settled();
    _questions.remove(this);
    for (final watch in _watching) {
      watch.close();
    }
    final goes = switch (answer) {
      Stay() => null,
      Leave() => requests.lastWhere(
          (request) => request.closesWindow,
          orElse: () => requests.last,
        ),
    };
    final leave = answer;
    for (final request in requests) {
      request.answer.complete(identical(request, goes) ? leave : const Stay());
    }
  }

  static void _remove(Route<dynamic> dialog) {
    if (dialog.isActive) dialog.navigator?.removeRoute(dialog);
  }
}

final _questions = <_ExitQuestion>[];

void endExitQuestionsWithoutAnEditor() {
  for (final question in [..._questions]) {
    question.abandon();
  }
}

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
    strategies,
    ref.read(strategySaveStateProvider.notifier),
  )..requests.add(request);
  _questions.add(question);
  question.watch(ProviderScope.containerOf(context, listen: false));
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

  if (!context.mounted ||
      !asked.isNow(
          ref.read(strategyProvider.notifier).askedByTheUserNow())) {
    return const Stay();
  }

  final decision = await _showUnsavedStrategyDialog(context, question);
  question.answered();
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
