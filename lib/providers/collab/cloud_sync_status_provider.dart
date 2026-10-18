import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
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

/// Where the cloud session stands, for the chip: null when there is no
/// session state to read (a build without auth, as in some tests), which
/// leaves the chip to the socket and the queues.
final _sessionStatusForSyncProvider = Provider<ConvexAuthStatus?>((ref) {
  try {
    return ref.watch(authProvider.select((auth) => auth.convexAuthStatus));
  } catch (_) {
    return null;
  }
});

/// The copy on this computer the editor is drawing instead of the server's
/// answer, and when that page was last matched with the server (null when
/// unknown). Null while the editor shows live answers.
final editorShownCopyProvider = Provider<({DateTime? copiedAt})?>((ref) {
  final snapshot = ref.watch(remoteEditorSnapshotProvider).valueOrNull;
  if (snapshot == null) return null;
  final page = snapshot.activePage;
  if (!snapshot.shell.fromCopy && !(page?.fromCopy ?? false)) return null;
  return (copiedAt: page?.copiedAt);
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
  final sessionStatus = ref.watch(_sessionStatusForSyncProvider);

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
      saveState.mediaSyncErrorCount > 0 ||
      accountMediaErrorCount > 0) {
    return CloudSyncStatus.attention;
  }
  // The socket can be back while the session is still offline, waiting on
  // a retry: nothing syncs until the session is ready again.
  if (!isConnected || sessionStatus == ConvexAuthStatus.offline) {
    return CloudSyncStatus.offline;
  }
  // Drawn from this computer's copy, because a read went unanswered: the
  // server hasn't confirmed what is on screen, so nothing is "Synced".
  if (ref.watch(editorShownCopyProvider) != null) {
    return CloudSyncStatus.offline;
  }
  // The session needs the user (expired, or refused by the server).
  if (sessionStatus == ConvexAuthStatus.incident) {
    return CloudSyncStatus.attention;
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
  // Synced is a promise the work is on the server, which only a ready
  // session can keep.
  if (sessionStatus != null && sessionStatus != ConvexAuthStatus.ready) {
    return CloudSyncStatus.syncing;
  }
  return CloudSyncStatus.synced;
});
