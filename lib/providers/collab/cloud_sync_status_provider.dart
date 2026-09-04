import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

enum CloudSyncStatus { synced, editing, syncing, offline, attention }

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

  final hasDurabilityProblem = opQueueState.loadIssues.isNotEmpty ||
      opQueueState.hasDurabilityFailure ||
      mediaQueueState.loadIssues.isNotEmpty ||
      mediaQueueState.durabilityError != null;
  if (hasDurabilityProblem) {
    return CloudSyncStatus.attention;
  }
  if (opQueueState.needsAttention ||
      opQueueState.accountOutbox.needsAttention ||
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
