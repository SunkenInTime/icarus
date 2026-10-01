import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

enum CloudSyncStatus { synced, editing, syncing, offline, attention }

/// Whether some cloud work may not be on this device: an outbox could not be
/// read, or a write to it could not be confirmed. That work may live only in
/// memory, so this outranks every other sync state, the server refusing this
/// build included: nothing may suggest throwing the session away.
final cloudWorkDurabilityUncertainProvider = Provider<bool>((ref) {
  final opQueueState = ref.watch(strategyOpQueueProvider);
  final mediaQueueState = ref.watch(cloudMediaUploadQueueProvider);
  return opQueueState.loadIssues.isNotEmpty ||
      opQueueState.hasDurabilityFailure ||
      mediaQueueState.loadIssues.isNotEmpty ||
      mediaQueueState.durabilityError != null;
});

final cloudSyncStatusProvider = Provider<CloudSyncStatus>((ref) {
  final saveState = ref.watch(strategySaveStateProvider);
  final opQueueState = ref.watch(strategyOpQueueProvider);
  final mediaQueueState = ref.watch(cloudMediaUploadQueueProvider);
  final strategy = ref.watch(strategyProvider);
  final activeMediaJobs = mediaQueueState.jobsForStrategy(
    strategy.source == StrategySource.cloud ? strategy.strategyId : null,
  );
  final accountMediaErrorCount =
      mediaQueueState.jobs.where((job) => job.isFailed).length;
  final hasTextDrafts = ref.watch(
    textDraftProvider.select((drafts) => drafts.isNotEmpty),
  );
  final isConnected = ref.watch(convexConnectionProvider).valueOrNull ?? true;

  if (ref.watch(cloudWorkDurabilityUncertainProvider)) {
    return CloudSyncStatus.attention;
  }
  // The server refuses this build: nothing syncs until it is reloaded or
  // updated, whatever the queue holds.
  if (ref.watch(clientUpgradeRequiredProvider)) {
    return CloudSyncStatus.attention;
  }
  if (opQueueState.needsAttention ||
      opQueueState.accountOutbox.needsAttention ||
      ref.watch(activePageLiveSyncProvider.select(
        (liveSync) => liveSync.unsyncableLineupKeys.isNotEmpty,
      )) ||
      saveState.mediaSyncErrorCount > 0 ||
      accountMediaErrorCount > 0) {
    return CloudSyncStatus.attention;
  }
  if (!isConnected) {
    return CloudSyncStatus.offline;
  }
  if (saveState.cloudSyncError != null) {
    return CloudSyncStatus.attention;
  }
  if (hasTextDrafts) {
    return CloudSyncStatus.editing;
  }
  if (saveState.isSaving ||
      saveState.hasPendingCloudSync ||
      saveState.hasPendingMediaSync ||
      activeMediaJobs.isNotEmpty ||
      opQueueState.accountOutbox.hasWork ||
      mediaQueueState.jobs.isNotEmpty ||
      !opQueueState.durableLoaded ||
      !mediaQueueState.durableLoaded) {
    return CloudSyncStatus.syncing;
  }
  return CloudSyncStatus.synced;
});
