import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/replay_capture_queue_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/services/guarded_sign_out.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

typedef CloudSignOutPreparation = Future<void> Function();
typedef CloudEditorClose = Future<void> Function();
typedef RawSignOut = Future<bool> Function();

final cloudSignOutPreparationProvider = Provider<CloudSignOutPreparation>(
  (ref) => () async {
    final strategy = ref.read(strategyProvider);
    if (strategy.source != StrategySource.cloud ||
        strategy.strategyId == null) {
      return;
    }
    ref.read(textDraftProvider.notifier).commitAllDrafts();
    await ref
        .read(strategyProvider.notifier)
        .forceSaveNow(strategy.strategyId!);
    // Reconciliation promotes staged media only after the durable strategy op
    // proves its exact reference. Network processing continues independently.
    await ref
        .read(cloudMediaUploadQueueProvider.notifier)
        .retryNow(ignoreBackoff: true);
  },
);

final cloudEditorCloseProvider = Provider<CloudEditorClose>(
  (ref) => () async {
    if (ref.read(strategyProvider).source == StrategySource.cloud) {
      await ref.read(strategyProvider.notifier).clearCurrentStrategy();
    }
  },
);

final rawSignOutProvider = Provider<RawSignOut>(
  (ref) => () async {
    await ref.read(authProvider.notifier).signOut();
    return !ref.read(authProvider).isAuthenticated;
  },
);

final cloudSignOutRequestProvider = Provider<GuardedSignOutRequest>(
  (ref) {
    var requestInProgress = false;
    return (context) async {
      if (requestInProgress) return false;
      requestInProgress = true;
      try {
        return await _requestCloudSafeSignOut(context, ref);
      } finally {
        requestInProgress = false;
      }
    };
  },
);

Future<bool> _requestCloudSafeSignOut(
  BuildContext context,
  Ref ref,
) async {
  final accountId = ref.read(authProvider).user?.id;
  if (accountId == null) return false;

  try {
    await ref.read(cloudSignOutPreparationProvider)();
  } catch (_) {
    if (context.mounted) await _showPersistenceBlocked(context);
    return false;
  }

  final strategy = ref.read(strategyProvider);
  final saveState = ref.read(strategySaveStateProvider);
  final opQueue = ref.read(strategyOpQueueProvider);
  final mediaQueue = ref.read(cloudMediaUploadQueueProvider);
  final captureQueue = ref.read(replayCaptureQueueProvider);
  final captures = captureQueue.forAccount(accountId);
  final currentStrategyId =
      strategy.source == StrategySource.cloud ? strategy.strategyId : null;
  final stagedMedia = mediaQueue.jobs
      .where((job) =>
          job.accountId == accountId &&
          currentStrategyId == job.strategyPublicId &&
          !job.referenceDurable)
      .toList(growable: false);
  final hasUnstagedActiveWork = ref.read(textDraftProvider).isNotEmpty ||
      stagedMedia.isNotEmpty ||
      saveState.isSaving ||
      (saveState.isDirty &&
          opQueue.pending.isEmpty &&
          mediaQueue.jobsForStrategy(currentStrategyId).isEmpty);
  if (!opQueue.outboxIsReliable ||
      !mediaQueue.outboxIsReliable ||
      !captureQueue.isReliable ||
      hasUnstagedActiveWork) {
    if (context.mounted) await _showPersistenceBlocked(context);
    return false;
  }

  final strategyIds = <String>{
    ...opQueue.accountOutbox.strategies.keys,
    for (final job in mediaQueue.jobs)
      if (job.accountId == accountId) job.strategyPublicId,
    for (final capture in captures) capture.strategyId,
  };
  final workCount = opQueue.accountOutbox.workCount +
      mediaQueue.jobs.where((job) => job.accountId == accountId).length +
      captures.length;
  if (!context.mounted) return false;
  final confirmed = await _showSignOutConfirmation(
    context,
    workCount: workCount,
    strategyIds: strategyIds,
    currentStrategyId: currentStrategyId,
    currentStrategyName: strategy.strategyName,
    strategyNames: {
      // A replay capture's strategy may not be in the cloud yet.
      for (final capture in captures) capture.strategyId: capture.strategyName,
      ...ref.read(cloudStrategyNamesProvider),
    },
  );
  if (!confirmed) return false;

  try {
    await ref.read(cloudEditorCloseProvider)();
  } catch (_) {
    if (context.mounted) await _showPersistenceBlocked(context);
    return false;
  }
  final signedOut = await ref.read(rawSignOutProvider)();
  if (!signedOut) {
    if (context.mounted) {
      await _showSignOutFailed(
        context,
        ref.read(authProvider).errorMessage,
      );
    }
    return false;
  }
  if (context.mounted) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
  return true;
}

Future<void> _showPersistenceBlocked(BuildContext context) {
  return showShadDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ShadDialog.alert(
      title: Text(context.l10n.signOutGuardCantSignOutTitle),
      description: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(context.l10n.signOutGuardUnconfirmedDescription),
      ),
      actions: [
        ShadButton(
          key: const ValueKey('sign-out-persistence-blocked'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.signOutGuardStaySignedIn),
        ),
      ],
    ),
  );
}

Future<bool> _showSignOutConfirmation(
  BuildContext context, {
  required int workCount,
  required Set<String> strategyIds,
  required String? currentStrategyId,
  required String? currentStrategyName,
  required Map<String, String> strategyNames,
}) async {
  final l10n = context.l10n;
  final hasPendingWork = workCount > 0;
  final strategyLabels = strategyIds
      .map((id) => id == currentStrategyId &&
              currentStrategyName?.trim().isNotEmpty == true
          ? currentStrategyName!.trim()
          : (strategyNames[id]?.trim().isNotEmpty == true
              ? strategyNames[id]!.trim()
              : l10n.signOutGuardUnnamedStrategy))
      .toSet()
      .join(', ');
  final result = await showShadDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ShadDialog.alert(
      title: Text(
        hasPendingWork
            ? l10n.signOutGuardPendingTitle
            : l10n.signOutGuardConfirmTitle,
      ),
      description: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          hasPendingWork
              ? l10n.signOutGuardPendingDescription(
                  workCount,
                  strategyIds.length,
                  strategyLabels,
                )
              : l10n.signOutGuardNoPendingDescription,
        ),
      ),
      actions: [
        ShadButton.secondary(
          key: const ValueKey('sign-out-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        ShadButton.destructive(
          key: const ValueKey('sign-out-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(
            hasPendingWork
                ? l10n.signOutGuardSignOutAnyway
                : l10n.commonSignOut,
          ),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<void> _showSignOutFailed(BuildContext context, String? message) {
  return showShadDialog<void>(
    context: context,
    builder: (context) => ShadDialog.alert(
      title: Text(context.l10n.signOutGuardFailedTitle),
      description: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(message ?? context.l10n.signOutGuardFailedFallback),
      ),
      actions: [
        ShadButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.signOutGuardOk),
        ),
      ],
    ),
  );
}
