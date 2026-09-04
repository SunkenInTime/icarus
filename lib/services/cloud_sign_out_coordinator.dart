import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
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
      hasUnstagedActiveWork) {
    if (context.mounted) await _showPersistenceBlocked(context);
    return false;
  }

  final strategyIds = <String>{
    ...opQueue.accountOutbox.strategies.keys,
    for (final job in mediaQueue.jobs)
      if (job.accountId == accountId) job.strategyPublicId,
  };
  final activeUnknownOwnerJobs = mediaQueue.unknownOwnerJobsForStrategy(
    currentStrategyId,
  );
  if (activeUnknownOwnerJobs.isNotEmpty && currentStrategyId != null) {
    strategyIds.add(currentStrategyId);
  }
  final workCount = opQueue.accountOutbox.workCount +
      mediaQueue.jobs.where((job) => job.accountId == accountId).length +
      activeUnknownOwnerJobs.length;
  if (!context.mounted) return false;
  final confirmed = await _showSignOutConfirmation(
    context,
    workCount: workCount,
    strategyIds: strategyIds,
    currentStrategyId: currentStrategyId,
    currentStrategyName: strategy.strategyName,
    strategyNames: ref.read(cloudStrategyNamesProvider),
    hasLegacyMedia: activeUnknownOwnerJobs.isNotEmpty,
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
      title: const Text("Can't sign out yet"),
      description: const Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          'Icarus could not confirm that all pending cloud work is saved on '
          'this device. Stay signed in and try again.',
        ),
      ),
      actions: [
        ShadButton(
          key: const ValueKey('sign-out-persistence-blocked'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Stay Signed In'),
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
  required bool hasLegacyMedia,
}) async {
  final hasPendingWork = workCount > 0;
  final strategyLabels = strategyIds
      .map((id) => id == currentStrategyId &&
              currentStrategyName?.trim().isNotEmpty == true
          ? currentStrategyName!.trim()
          : (strategyNames[id]?.trim().isNotEmpty == true
              ? strategyNames[id]!.trim()
              : 'a cloud strategy'))
      .toSet()
      .join(', ');
  final result = await showShadDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ShadDialog.alert(
      title: Text(hasPendingWork ? 'Cloud work is still waiting' : 'Sign out?'),
      description: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          hasPendingWork
              ? '$workCount saved ${workCount == 1 ? 'change' : 'changes'} '
                  'across ${strategyIds.length} '
                  '${strategyIds.length == 1 ? 'strategy is' : 'strategies are'} '
                  'still waiting: $strategyLabels. The work remains on this '
                  'device and resumes only when this same account signs in '
                  'again.${hasLegacyMedia ? ' Older preserved media will not upload automatically.' : ''}'
              : 'Cloud strategies stay online. Pending work on this device '
                  'will remain tied to this account.',
        ),
      ),
      actions: [
        ShadButton.secondary(
          key: const ValueKey('sign-out-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ShadButton.destructive(
          key: const ValueKey('sign-out-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(hasPendingWork ? 'Sign Out Anyway' : 'Sign Out'),
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
      title: const Text('Sign out failed'),
      description: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(message ?? 'Icarus could not sign out. Please try again.'),
      ),
      actions: [
        ShadButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
