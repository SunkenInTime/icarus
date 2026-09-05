import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
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

Future<UnsavedStrategyDecision> showUnsavedStrategyDialog(
  BuildContext context,
) async {
  final result = await showShadDialog<UnsavedStrategyDecision>(
    context: context,
    builder: (context) {
      return ShadDialog.alert(
        title: const Text('Save changes?'),
        description: const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'This strategy has unsaved changes. Do you want to save before leaving?',
          ),
        ),
        actions: [
          ShadButton.secondary(
            onPressed: () {
              Navigator.of(context).pop(UnsavedStrategyDecision.cancel);
            },
            child: const Text('Cancel'),
          ),
          ShadButton.destructive(
            onPressed: () {
              Navigator.of(context).pop(UnsavedStrategyDecision.dontSave);
            },
            child: const Text("Don't Save"),
          ),
          ShadButton(
            onPressed: () {
              Navigator.of(context).pop(UnsavedStrategyDecision.save);
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );

  return result ?? UnsavedStrategyDecision.cancel;
}

Future<CloudExitDecision> _showCloudSyncBlockedDialog(
  BuildContext context, {
  required String message,
  required bool allowLeaveAnyway,
  required bool showRetryAuth,
}) async {
  final result = await showShadDialog<CloudExitDecision>(
    context: context,
    builder: (context) {
      return ShadDialog.alert(
        title: const Text('Cloud sync pending'),
        actionsAxis: Axis.vertical,
        description: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(message),
        ),
        actions: [
          ShadButton.secondary(
            onPressed: () {
              Navigator.of(context).pop(CloudExitDecision.stay);
            },
            child: const Text('Stay Here'),
          ),
          if (showRetryAuth)
            ShadButton.secondary(
              onPressed: () {
                Navigator.of(context).pop(CloudExitDecision.retryAuth);
              },
              child: const Text('Retry Convex Auth'),
            ),
          if (allowLeaveAnyway)
            ShadButton.secondary(
              onPressed: () {
                Navigator.of(context).pop(CloudExitDecision.leaveAnyway);
              },
              child: const Text('Leave Anyway'),
            ),
          ShadButton(
            onPressed: () {
              Navigator.of(context).pop(CloudExitDecision.retrySync);
            },
            child: const Text('Retry Sync'),
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

Future<bool> _guardCloudStrategyExit({
  required BuildContext context,
  required WidgetRef ref,
  required Future<void> Function() onContinue,
}) async {
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
        'Failed to sync the active text edit before leaving.',
        error: error,
        stackTrace: stackTrace,
        source: 'cloud_media.exit_guard',
      );
      return false;
    }
  }

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
    if (!hasPendingSync && cloudError == null) {
      if (!context.mounted) {
        return false;
      }
      AppErrorReporter.reportInfo(
        'Cloud exit guard allowing leave: strategy=${strategyState.strategyId}',
        source: 'cloud_media.exit_guard',
      );
      await onContinue();
      return true;
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

    if (!context.mounted) {
      return false;
    }

    final decision = await _showCloudSyncBlockedDialog(
      context,
      message: _cloudSyncBlockedMessage(
        isConnected: isConnected,
        cloudError: cloudError,
        mediaErrorCount: saveState.mediaSyncErrorCount,
        canLeaveWithDurableWork: canLeaveWithDurableWork,
        hasUnreadableSavedWork: hasUnreadableSavedWork,
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
        return false;
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
        if (!canLeaveWithDurableWork || !context.mounted) {
          return false;
        }
        await onContinue();
        return true;
      case CloudExitDecision.retrySync:
        AppErrorReporter.reportInfo(
          'Cloud exit guard retrying sync.',
          source: 'cloud_media.exit_guard',
        );
        final strategyId = strategyState.strategyId;
        if (strategyId == null) {
          return false;
        }
        await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
        break;
    }
  }
}

String _cloudSyncBlockedMessage({
  required bool isConnected,
  required String? cloudError,
  required int mediaErrorCount,
  required bool canLeaveWithDurableWork,
  required bool hasUnreadableSavedWork,
}) {
  final base = !isConnected
      ? 'Icarus is offline, so these changes have not reached the cloud.'
      : (cloudError != null
          ? friendlyCloudSyncError(cloudError)
          : (mediaErrorCount > 0
              ? 'Some images have not reached the cloud.'
              : 'Icarus is still sending cloud edits and images.'));
  if (canLeaveWithDurableWork) {
    if (hasUnreadableSavedWork) {
      return '$base Leaving will not delete the saved device records. You '
          'can return to this strategy and retry.';
    }
    return '$base The pending work is saved on this device. You can leave '
        'and Icarus will retry it later.';
  }
  return '$base Stay here and retry because Icarus could not confirm that '
      'all pending work is saved on this device.';
}

Future<bool> guardUnsavedStrategyExit({
  required BuildContext context,
  required WidgetRef ref,
  required Future<void> Function() onContinue,
  required String source,
}) async {
  final strategyState = ref.read(strategyProvider);
  final saveState = ref.read(strategySaveStateProvider);
  if (strategyState.source == StrategySource.cloud) {
    return _guardCloudStrategyExit(
      context: context,
      ref: ref,
      onContinue: onContinue,
    );
  }

  final hasTextDrafts = ref.read(textDraftProvider).isNotEmpty;
  if (strategyState.strategyName == null ||
      (!saveState.isDirty && !hasTextDrafts)) {
    await onContinue();
    return true;
  }

  try {
    final canContinueSilently = await ref
        .read(strategyProvider.notifier)
        .flushPendingAutosaveBeforeExit();
    if (canContinueSilently) {
      await onContinue();
      return true;
    }
  } catch (error, stackTrace) {
    AppErrorReporter.reportError(
      'Failed to save strategy before leaving.',
      error: error,
      stackTrace: stackTrace,
      source: source,
    );
    return false;
  }

  if (!context.mounted) {
    return false;
  }

  final decision = await showUnsavedStrategyDialog(context);
  switch (decision) {
    case UnsavedStrategyDecision.save:
      try {
        final strategyId = strategyState.strategyId;
        if (strategyId == null) {
          return false;
        }
        await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
      } catch (error, stackTrace) {
        AppErrorReporter.reportError(
          'Failed to save strategy before leaving.',
          error: error,
          stackTrace: stackTrace,
          source: source,
        );
        return false;
      }
      await onContinue();
      return true;
    case UnsavedStrategyDecision.dontSave:
      ref.read(strategyProvider.notifier).cancelPendingSave();
      await onContinue();
      return true;
    case UnsavedStrategyDecision.cancel:
      return false;
  }
}
