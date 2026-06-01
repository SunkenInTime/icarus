import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:convex_flutter/convex_flutter.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
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
  cancelUpload,
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
  required bool showCancelUpload,
  required bool showRetryAuth,
}) async {
  final result = await showShadDialog<CloudExitDecision>(
    context: context,
    builder: (context) {
      return ShadDialog.alert(
        title: const Text('Cloud sync pending'),
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
          if (showCancelUpload)
            ShadButton.destructive(
              onPressed: () {
                Navigator.of(context).pop(CloudExitDecision.cancelUpload);
              },
              child: const Text('Cancel Upload'),
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
    final saveState = ref.read(strategySaveStateProvider);
    final queueState = ref.read(strategyOpQueueProvider);
    if (!saveState.hasPendingCloudSync &&
        !saveState.hasPendingMediaSync &&
        queueState.pending.isEmpty &&
        !queueState.isFlushing &&
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
  while (true) {
    final strategyState = ref.read(strategyProvider);
    final saveState = ref.read(strategySaveStateProvider);
    final queueState = ref.read(strategyOpQueueProvider);
    final authState = ref.read(authProvider);
    final mediaQueueState = ref.read(cloudMediaUploadQueueProvider);
    final hasPendingMediaJobs =
        mediaQueueState.jobsForStrategy(strategyState.strategyId).isNotEmpty;

    final hasPendingSync = saveState.hasPendingCloudSync ||
        saveState.hasPendingMediaSync ||
        hasPendingMediaJobs ||
        queueState.pending.isNotEmpty;
    final cloudError = saveState.cloudSyncError ?? queueState.lastError;
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
      'connected=${ConvexClient.instance.isConnected} '
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

    if (queueState.isFlushing && cloudError == null) {
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
      message: cloudError ??
          (saveState.mediaSyncErrorCount > 0
              ? 'Some media uploads failed. Retry sync or stay here until the queue clears.'
              : 'Icarus is still syncing cloud edits and media. Stay on this screen until sync completes.'),
      showCancelUpload: hasPendingMediaJobs,
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
      case CloudExitDecision.cancelUpload:
        AppErrorReporter.reportInfo(
          'Cloud exit guard canceling media uploads.',
          source: 'cloud_media.exit_guard',
        );
        final strategyId = strategyState.strategyId;
        if (strategyId == null) {
          return false;
        }
        await ref
            .read(cloudMediaUploadQueueProvider.notifier)
            .cancelUploadsForStrategy(strategyId);
        await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
        break;
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

  if (strategyState.strategyName == null || !saveState.isDirty) {
    await onContinue();
    return true;
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
