import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_cloud_media_outbox.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

class CloudMediaUploadQueueState {
  const CloudMediaUploadQueueState({
    required this.jobs,
    required this.isProcessing,
    this.loadIssues = const <DurableCloudMediaOutboxLoadIssue>[],
    this.durableLoaded = true,
    this.durabilityError,
  });

  final List<CloudMediaUploadJob> jobs;
  final bool isProcessing;
  final List<DurableCloudMediaOutboxLoadIssue> loadIssues;
  final bool durableLoaded;
  final String? durabilityError;

  bool get outboxIsReliable =>
      durableLoaded && loadIssues.isEmpty && durabilityError == null;

  List<CloudMediaUploadJob> jobsForStrategy(String? strategyPublicId) {
    if (strategyPublicId == null) {
      return const [];
    }
    return jobs
        .where((job) => job.strategyPublicId == strategyPublicId)
        .toList(growable: false);
  }

  int pendingCountForStrategy(String? strategyPublicId) {
    return jobsForStrategy(strategyPublicId).length;
  }

  int errorCountForStrategy(String? strategyPublicId) {
    return jobsForStrategy(strategyPublicId)
        .where((job) => job.state == CloudMediaJobState.failed)
        .length;
  }

  CloudMediaUploadQueueState copyWith({
    List<CloudMediaUploadJob>? jobs,
    bool? isProcessing,
    String? durabilityError,
    bool clearDurabilityError = false,
  }) {
    return CloudMediaUploadQueueState(
      jobs: jobs ?? this.jobs,
      isProcessing: isProcessing ?? this.isProcessing,
      loadIssues: loadIssues,
      durableLoaded: durableLoaded,
      durabilityError: clearDurabilityError
          ? null
          : (durabilityError ?? this.durabilityError),
    );
  }
}

class _UploadProgressToastState {
  const _UploadProgressToastState({
    required this.message,
    required this.progress,
    required this.isComplete,
  });

  final String message;
  final double progress;
  final bool isComplete;
}

final cloudMediaUploadQueueProvider =
    NotifierProvider<CloudMediaUploadQueueNotifier, CloudMediaUploadQueueState>(
  CloudMediaUploadQueueNotifier.new,
);

typedef CloudMediaReferenceSnapshotLoader = Future<RemoteFullStrategySnapshot>
    Function(String strategyPublicId);

final cloudMediaReferenceSnapshotLoaderProvider =
    Provider<CloudMediaReferenceSnapshotLoader>(
  (ref) => ref.watch(convexStrategyRepositoryProvider).fetchFullSnapshot,
);

final cloudMediaAccountIdProvider = Provider<String?>(
  (ref) => ref.watch(authProvider.select((state) => state.user?.id)),
);

enum _MediaOutboxMutation { write, remove }

class CloudMediaUploadQueueNotifier
    extends Notifier<CloudMediaUploadQueueState> {
  static const Duration _blockedRetryDelay = Duration(seconds: 30);
  Timer? _retryTimer;
  Timer? _uploadCompletionDismissTimer;
  ToastificationItem? _uploadProgressToast;
  ValueNotifier<_UploadProgressToastState>? _uploadProgressToastState;
  int _uploadProgressTotalJobs = 0;
  final Map<String, int> _uploadBytesSentByJob = {};
  final Map<String, int> _uploadBytesTotalByJob = {};
  final Set<String> _uploadCompletingJobs = {};
  final Set<String> _uploadCompletedJobs = {};
  final Map<String, CloudMediaUploadJob> _jobsByStorageKey = {};
  final Set<String> _restoredStagedJobIds = {};
  final Map<String, _MediaOutboxMutation> _unverifiedByStorageKey = {};
  Future<void> _writeTail = Future<void>.value();
  bool _disposed = false;
  late DurableCloudMediaOutboxStore _store;

  ConvexStrategyRepository get _repo =>
      ref.read(convexStrategyRepositoryProvider);

  @override
  CloudMediaUploadQueueState build() {
    _store = ref.read(durableCloudMediaOutboxStoreProvider);
    final loaded = _store.load();
    _jobsByStorageKey.addEntries(
      loaded.jobs.map(
        (job) => MapEntry(durableCloudMediaOutboxStorageKey(job), job),
      ),
    );
    _restoredStagedJobIds.addAll(
      loaded.jobs
          .where((job) => !job.referenceDurable)
          .map(durableCloudMediaOutboxStorageKey),
    );
    ref.onDispose(() {
      _disposed = true;
      _retryTimer?.cancel();
      _uploadCompletionDismissTimer?.cancel();
      final toast = _uploadProgressToast;
      if (toast != null) {
        Settings.dismissToast(toast, showRemoveAnimation: false);
      }
      _uploadProgressToastState?.dispose();
    });

    ref.listen<AppAuthState>(authProvider, (previous, next) {
      final becameReady =
          !(previous?.isConvexUserReady ?? false) && next.isConvexUserReady;
      final authRecovered = (previous?.hasActiveAuthIncident ?? false) &&
          !next.hasActiveAuthIncident;
      if (becameReady || authRecovered) {
        retryNow(ignoreBackoff: true);
      }
    });

    ref.listen<String?>(cloudMediaAccountIdProvider, (previous, next) {
      if (previous == next) return;
      _refreshState();
      if (next != null && next.isNotEmpty) {
        retryNow(ignoreBackoff: true);
      }
    });

    ref.listen<AsyncValue<bool>>(convexConnectionProvider, (previous, next) {
      final reconnected =
          previous?.valueOrNull != true && next.valueOrNull == true;
      if (reconnected) {
        retryNow(ignoreBackoff: true);
      }
    });

    if (_jobsByStorageKey.isNotEmpty) {
      scheduleMicrotask(() {
        if (!_disposed) retryNow(ignoreBackoff: true);
      });
    }

    return CloudMediaUploadQueueState(
      jobs: _readJobs(),
      isProcessing: false,
      loadIssues: loaded.issues,
      durableLoaded: true,
    );
  }

  Future<void> enqueuePlacedImageUpload({
    required String imagePublicId,
    String? strategyPublicId,
    String? fileExtension,
    String? mimeType,
    int? width,
    int? height,
  }) async {
    final strategyState = ref.read(strategyProvider);
    final resolvedStrategyId = strategyPublicId ?? strategyState.strategyId;
    if (strategyState.source != StrategySource.cloud ||
        resolvedStrategyId == null) {
      _logMedia(
        'enqueue.skipped image=$imagePublicId '
        'strategy=$resolvedStrategyId '
        'source=${strategyState.source?.name ?? 'unknown'}',
      );
      return;
    }

    final accountId = _requireActiveAccountId();
    final normalizedExtension = normalizeImageExtension(fileExtension ?? '');
    await _upsertJob(
      CloudMediaUploadJob(
        jobId: imagePublicId,
        accountId: accountId,
        strategyPublicId: resolvedStrategyId,
        assetPublicId: imagePublicId,
        fileExtension: normalizedExtension,
        mimeType: mimeType ?? mimeTypeForImageExtension(normalizedExtension),
        width: width,
        height: height,
        state: CloudMediaJobState.pendingUpload,
        referenceDurable: false,
        attempts: 0,
        updatedAt: DateTime.now(),
      ),
    );
    _logMedia(
      'enqueue.placed_image_staged ${_describeJob(_getJob(imagePublicId))}',
    );
  }

  Future<void> enqueueJobForLocalFile({
    required String strategyPublicId,
    required String assetPublicId,
    required String fileExtension,
    String? mimeType,
    int? width,
    int? height,
  }) async {
    final accountId = _requireActiveAccountId();
    final normalizedExtension = normalizeImageExtension(fileExtension);
    await _upsertJob(
      CloudMediaUploadJob(
        jobId: assetPublicId,
        accountId: accountId,
        strategyPublicId: strategyPublicId,
        assetPublicId: assetPublicId,
        fileExtension: normalizedExtension,
        mimeType: mimeType ?? mimeTypeForImageExtension(normalizedExtension),
        width: width,
        height: height,
        state: CloudMediaJobState.pendingUpload,
        referenceDurable: false,
        attempts: 0,
        updatedAt: DateTime.now(),
      ),
    );
    _logMedia('enqueue.local_file ${_describeJob(_getJob(assetPublicId))}');
    retryNow(ignoreBackoff: true);
  }

  Future<void> enqueueLineupMediaJobs({
    required String strategyPublicId,
    required Iterable<SimpleImageData> images,
  }) async {
    final accountId = _requireActiveAccountId();
    final imageList = images.toList(growable: false);
    final jobs = <CloudMediaUploadJob>[
      for (final image in imageList)
        CloudMediaUploadJob(
          jobId: image.id,
          accountId: accountId,
          strategyPublicId: strategyPublicId,
          assetPublicId: image.id,
          fileExtension: normalizeImageExtension(image.fileExtension),
          mimeType: mimeTypeForImageExtension(image.fileExtension),
          state: CloudMediaJobState.pendingUpload,
          referenceDurable: false,
          attempts: 0,
          updatedAt: DateTime.now(),
        ),
    ];
    await _upsertJobsAtomically(jobs);
    for (final image in imageList) {
      _logMedia('enqueue.lineup_image ${_describeJob(_getJob(image.id))}');
    }
  }

  Future<void> commitStagedMediaReferences({
    required String strategyPublicId,
    required Iterable<String> assetPublicIds,
  }) async {
    final accountId = _requireActiveAccountId();
    final requestedIds = assetPublicIds.toSet();
    final staged = _readJobs()
        .where(
          (job) =>
              job.accountId == accountId &&
              job.strategyPublicId == strategyPublicId &&
              requestedIds.contains(job.assetPublicId) &&
              !job.referenceDurable,
        )
        .toList(growable: false);
    if (staged.isEmpty) return;

    await ref
        .read(strategyProvider.notifier)
        .notifyCloudMutation(flushImmediately: false);
    final opQueueState = ref.read(strategyOpQueueProvider);
    if (!opQueueState.outboxIsReliable) {
      throw StateError(
        'The strategy reference could not be saved to the durable outbox.',
      );
    }
    final durableOps = ref.read(durableStrategyOutboxStoreProvider).load();
    if (durableOps.issues.isNotEmpty) {
      throw StateError(
        'The strategy reference outbox contains unreadable saved work.',
      );
    }
    final pendingOps = <StrategyOp>[
      for (final record in durableOps.records)
        if (record.accountId == accountId &&
            record.strategyPublicId == strategyPublicId) ...[
          record.pending.op,
          if (record.successorPending case final successor?) successor.op,
        ],
    ];
    final missingReferences = staged
        .where(
          (job) => !pendingOps.any(
            (op) => _opReferencesAsset(op, job.assetPublicId),
          ),
        )
        .toList(growable: false);
    if (missingReferences.isNotEmpty) {
      RemoteFullStrategySnapshot? serverSnapshot;
      if (ref.read(authProvider).isConvexUserReady &&
          ref.read(convexConnectionSnapshotProvider)) {
        try {
          serverSnapshot =
              await ref.read(cloudMediaReferenceSnapshotLoaderProvider)(
            strategyPublicId,
          );
        } catch (_) {
          serverSnapshot = null;
        }
      }
      if (serverSnapshot == null ||
          missingReferences.any(
            (job) =>
                !_snapshotReferencesAsset(serverSnapshot!, job.assetPublicId),
          )) {
        _scheduleRetryForNextEligibleJob(
          minimumDelay: _blockedRetryDelay,
        );
        throw StateError(
          'The strategy reference was not admitted to the durable outbox.',
        );
      }
    }

    if (ref.read(cloudMediaAccountIdProvider) != accountId) {
      throw StateError('The active account changed before media was queued.');
    }

    await _putJobsAtomically([
      for (final job in staged)
        job.copyWith(
          referenceDurable: true,
          updatedAt: DateTime.now(),
        ),
    ]);
    _refreshState();
    await retryNow(ignoreBackoff: true);
  }

  Future<void> retryNow({bool ignoreBackoff = false}) async {
    if (_disposed) return;
    _retryTimer?.cancel();
    await _reconcileStagedJobReferences();
    if (_disposed) return;
    _logMedia(
      'retry_now ignoreBackoff=$ignoreBackoff jobs=${_readJobs().length}',
    );
    unawaited(_processNextJob(ignoreBackoff: ignoreBackoff));
  }

  Future<void> setActiveStrategy(String? strategyPublicId) async {
    _refreshState();
    if (strategyPublicId != null) {
      await retryNow(ignoreBackoff: true);
    }
  }

  Future<void> reconcilePageMedia({
    required String strategyPublicId,
    required Iterable<PlacedImage> placedImages,
    required Map<String, RemoteImageAsset> assetsById,
  }) async {
    for (final image in placedImages) {
      final asset = assetsById[image.id];
      final hasActiveRemote =
          asset?.uploadStatus == 'active' && (asset?.url?.isNotEmpty ?? false);
      if (hasActiveRemote || _getJob(image.id) != null) {
        continue;
      }

      final file = await PlacedImageProvider.getImageFile(
        strategyID: strategyPublicId,
        imageID: image.id,
        fileExtension: image.fileExtension ?? '',
      );
      if (!await file.exists()) {
        _logMedia(
          'reconcile.local_missing image=${image.id} '
          'strategy=$strategyPublicId status=${asset?.uploadStatus ?? 'none'}',
        );
        continue;
      }

      await enqueueJobForLocalFile(
        strategyPublicId: strategyPublicId,
        assetPublicId: image.id,
        fileExtension: image.fileExtension ?? '',
      );
    }
  }

  Future<void> clearJobsForStrategy(String strategyPublicId) async {
    final jobs = _readJobs()
        .where((job) => job.strategyPublicId == strategyPublicId)
        .toList(growable: false);
    for (final job in jobs) {
      await _deleteJob(job);
    }
    _refreshState();
  }

  Future<void> _processNextJob({bool ignoreBackoff = false}) async {
    if (state.isProcessing) {
      return;
    }

    final nextJob = _nextRunnableJob(ignoreBackoff: ignoreBackoff);
    if (nextJob == null) {
      _logMedia(
        'process.idle ignoreBackoff=$ignoreBackoff jobs=${_readJobs().length}',
      );
      _scheduleRetryForNextEligibleJob();
      return;
    }

    state = state.copyWith(isProcessing: true);
    _logMedia('process.start ${_describeJob(nextJob)}');
    late final bool madeProgress;
    try {
      madeProgress = await _processJob(nextJob);
    } finally {
      _refreshState(isProcessing: false);
      _logMedia('process.finish jobs=${state.jobs.length}');
    }

    if (madeProgress && _readJobs().isNotEmpty) {
      // Only bypass backoff for the initial user-triggered kick. Follow-up
      // attempts must honor retry timing so transient attach failures do not
      // hammer Convex in a tight loop.
      unawaited(_processNextJob(ignoreBackoff: false));
    }
  }

  CloudMediaUploadJob? _nextRunnableJob({required bool ignoreBackoff}) {
    final jobs = _readJobs()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final now = DateTime.now();
    for (final job in jobs) {
      if (!job.referenceDurable) {
        continue;
      }
      if (ignoreBackoff || !_nextAttemptAt(job).isAfter(now)) {
        return job;
      }
    }
    return null;
  }

  Future<bool> _processJob(CloudMediaUploadJob job) async {
    if (!_belongsToActiveAccount(job)) {
      _logMedia('process.blocked account_mismatch ${_describeJob(job)}');
      return false;
    }
    final mode = ref.read(cloudCollabModeProvider);
    final auth = ref.read(authProvider);
    if (!mode.featureFlagEnabled || mode.forceLocalFallback) {
      _logMedia(
        'process.blocked featureFlag=${mode.featureFlagEnabled} '
        'forceLocalFallback=${mode.forceLocalFallback} ${_describeJob(job)}',
      );
      _scheduleRetryForNextEligibleJob(minimumDelay: _blockedRetryDelay);
      return false;
    }
    if (!auth.isAuthenticated ||
        !auth.isConvexUserReady ||
        auth.hasActiveAuthIncident ||
        !ref.read(convexConnectionSnapshotProvider)) {
      _logMedia(
        'process.blocked auth=${auth.isAuthenticated} '
        'userReady=${auth.isConvexUserReady} '
        'authIncident=${auth.hasActiveAuthIncident} '
        'connected=${ref.read(convexConnectionSnapshotProvider)} '
        '${_describeJob(job)}',
      );
      _scheduleRetryForNextEligibleJob(minimumDelay: _blockedRetryDelay);
      return false;
    }

    if (!job.hasUploadedRemoteObject) {
      await _uploadJobBlob(job);
      return true;
    }

    await _attachUploadedJob(job);
    return true;
  }

  Future<void> _uploadJobBlob(CloudMediaUploadJob job) async {
    if (!_belongsToActiveAccount(job)) return;
    try {
      _logMedia('upload.local_lookup ${_describeJob(job)}');
      final file = await PlacedImageProvider.getImageFile(
        strategyID: job.strategyPublicId,
        imageID: job.assetPublicId,
        fileExtension: job.fileExtension,
      );
      if (!await file.exists()) {
        _logMedia(
            'upload.local_missing path=${file.path} ${_describeJob(job)}');
        if (await _deleteJobWhenReferenceIsGone(job)) {
          return;
        }
        await _markJobFailed(
          job,
          'Local media file is missing.',
          showToast: job.attempts == 0,
        );
        return;
      }

      final byteSize = await file.length();
      if (!_belongsToActiveAccount(job)) {
        _logMedia('upload.deferred account_changed ${_describeJob(job)}');
        return;
      }
      _setUploadByteProgress(
        job.jobId,
        sentBytes: 0,
        totalBytes: byteSize,
      );
      _logMedia(
        'upload.intent.request bytes=$byteSize ${_describeJob(job)}',
      );
      final intent = await _repo.generateImageUploadUrl(
        strategyPublicId: job.strategyPublicId,
        assetPublicId: job.assetPublicId,
        mimeType: job.mimeType,
        fileExtension: job.fileExtension,
        byteSize: byteSize,
        width: job.width,
        height: job.height,
      );
      if (intent.uploadUrl.isEmpty) {
        throw StateError('Empty R2 upload URL');
      }
      _logMedia(
        'upload.intent.received provider=${intent.provider} '
        'uploadId=${intent.uploadId} objectKey=${intent.objectKey} '
        'expiresAt=${intent.expiresAt.toIso8601String()} '
        'maxBytes=${intent.maxBytes} ${_describeJob(job)}',
      );
      if (intent.maxBytes > 0 && byteSize > intent.maxBytes) {
        throw StateError(
          'Image exceeds maximum upload size (${intent.maxBytes} bytes).',
        );
      }

      if (!_belongsToActiveAccount(job)) {
        _logMedia('upload.deferred account_changed ${_describeJob(job)}');
        return;
      }

      _logMedia('upload.put.start bytes=$byteSize ${_describeJob(job)}');
      final response = await _putFileWithProgress(
        job: job,
        file: file,
        uploadUrl: intent.uploadUrl,
        headers: intent.requiredHeaders,
        byteSize: byteSize,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Upload failed (${response.statusCode}): ${response.body}',
        );
      }
      _logMedia(
        'upload.put.success status=${response.statusCode} '
        'etag=${response.headers['etag']} ${_describeJob(job)}',
      );

      await _putJob(
        job.copyWith(
          provider: intent.provider,
          uploadId: intent.uploadId,
          objectKey: intent.objectKey,
          storageId: null,
          etag: response.headers['etag'],
          byteSize: byteSize,
          uploadUrlExpiresAt: intent.expiresAt,
          state: CloudMediaJobState.pendingAttach,
          attempts: 0,
          lastError: null,
          updatedAt: DateTime.now(),
        ),
      );
      _refreshState();
      _markUploadCompleting(job.jobId);
      _logMedia(
        'upload.pending_attach ${_describeJob(_getJob(job.jobId))}',
      );
    } catch (error) {
      _logMedia('upload.failed error=$error ${_describeJob(job)}');
      await _markJobFailed(
        job,
        '$error',
        showToast: job.attempts == 0,
      );
    }
  }

  Future<bool> _deleteJobWhenReferenceIsGone(
    CloudMediaUploadJob job,
  ) async {
    final durableOps = ref.read(durableStrategyOutboxStoreProvider).load();
    if (durableOps.issues.isNotEmpty) return false;
    final pendingReferences = durableOps.records.any(
      (record) =>
          record.accountId == job.accountId &&
          record.strategyPublicId == job.strategyPublicId &&
          (_opReferencesAsset(record.pending.op, job.assetPublicId) ||
              (record.successorPending != null &&
                  _opReferencesAsset(
                    record.successorPending!.op,
                    job.assetPublicId,
                  ))),
    );
    if (pendingReferences ||
        !ref.read(authProvider).isConvexUserReady ||
        !ref.read(convexConnectionSnapshotProvider)) {
      return false;
    }

    late final RemoteFullStrategySnapshot snapshot;
    try {
      snapshot = await ref.read(cloudMediaReferenceSnapshotLoaderProvider)(
        job.strategyPublicId,
      );
    } catch (error) {
      _logMedia(
        'missing_source.reference_check_deferred '
        'strategy=${job.strategyPublicId} error=$error',
      );
      return false;
    }
    final current = _getJob(job.jobId);
    if (!_belongsToActiveAccount(job) ||
        current == null ||
        current.updatedAt != job.updatedAt ||
        _snapshotReferencesAsset(snapshot, job.assetPublicId)) {
      return false;
    }

    final deleted = await _deleteJob(job, onlyIfUnreferenced: true);
    if (!deleted) return false;
    _refreshState();
    _logMedia(
      'missing_source.removed_unreferenced job=${job.jobId} '
      'strategy=${job.strategyPublicId}',
    );
    return true;
  }

  Future<http.Response> _putFileWithProgress({
    required CloudMediaUploadJob job,
    required File file,
    required String uploadUrl,
    required Map<String, String> headers,
    required int byteSize,
  }) async {
    final request = http.StreamedRequest('PUT', Uri.parse(uploadUrl));
    request.headers.addAll(headers);
    if (!request.headers.containsKey('Content-Type')) {
      request.headers['Content-Type'] = job.mimeType;
    }
    request.contentLength = byteSize;

    final responseFuture = request.send();
    var sentBytes = 0;
    try {
      await for (final chunk in file.openRead()) {
        request.sink.add(chunk);
        sentBytes += chunk.length;
        _setUploadByteProgress(
          job.jobId,
          sentBytes: sentBytes,
          totalBytes: byteSize,
        );
      }
      if (sentBytes < byteSize) {
        _setUploadByteProgress(
          job.jobId,
          sentBytes: byteSize,
          totalBytes: byteSize,
        );
      }
      unawaited(request.sink.close().catchError((_) {}));
      final streamedResponse = await responseFuture;
      return http.Response.fromStream(streamedResponse);
    } catch (_) {
      unawaited(request.sink.close().catchError((_) {}));
      rethrow;
    }
  }

  Future<void> _attachUploadedJob(CloudMediaUploadJob job) async {
    if (!_belongsToActiveAccount(job)) return;
    try {
      _logMedia('attach.start ${_describeJob(job)}');
      if ((job.provider == 'r2' || job.uploadId != null) &&
          (job.uploadId == null || job.objectKey == null)) {
        throw StateError('R2 upload job is missing upload intent metadata.');
      }
      if ((job.provider == null || job.provider == 'convex') &&
          job.uploadId == null &&
          job.storageId == null) {
        throw StateError('Upload job is missing remote storage metadata.');
      }

      await _repo.completeImageUpload(
        strategyPublicId: job.strategyPublicId,
        assetPublicId: job.assetPublicId,
        provider: job.provider,
        uploadId: job.uploadId,
        objectKey: job.objectKey,
        storageId: job.storageId,
        etag: job.etag,
        mimeType: job.mimeType,
        fileExtension: job.fileExtension,
        byteSize: job.byteSize,
        width: job.width,
        height: job.height,
      );
      await _deleteJob(job);
      if (_uploadProgressToast != null) {
        _markUploadComplete(job.jobId);
      }
      _refreshState();
      _logMedia('attach.success image=${job.assetPublicId} '
          'strategy=${job.strategyPublicId}');
    } catch (error) {
      _logMedia('attach.failed error=$error ${_describeJob(job)}');
      final missingIntent = isMissingImageUploadIntentError(error);
      await _markJobFailed(
        missingIntent
            ? job.copyWith(
                provider: null,
                uploadId: null,
                objectKey: null,
                storageId: null,
                etag: null,
                uploadUrlExpiresAt: null,
              )
            : job,
        '$error',
        showToast: job.attempts == 0,
      );
    }
  }

  Future<void> _markJobFailed(
    CloudMediaUploadJob job,
    String errorMessage, {
    required bool showToast,
  }) async {
    await _putJob(
      job.copyWith(
        state: CloudMediaJobState.failed,
        attempts: job.attempts + 1,
        lastError: errorMessage,
        updatedAt: DateTime.now(),
      ),
    );
    _refreshState();
    _logMedia(
        'job.failed showToast=$showToast ${_describeJob(_getJob(job.jobId))}');
    if (showToast) {
      Settings.showToast(
        message: 'Media upload failed. Tap Save to retry cloud sync.',
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
    }
    _scheduleRetryForNextEligibleJob();
  }

  DateTime _nextAttemptAt(CloudMediaUploadJob job) {
    if (job.attempts <= 0) {
      return job.updatedAt;
    }

    final baseSeconds = 5 * (1 << (job.attempts - 1).clamp(0, 5));
    final cappedSeconds = baseSeconds > 300 ? 300 : baseSeconds;
    return job.updatedAt.add(Duration(seconds: cappedSeconds));
  }

  void _scheduleRetryForNextEligibleJob({Duration? minimumDelay}) {
    _retryTimer?.cancel();
    final allJobs = _readJobs();
    final jobs =
        allJobs.where((job) => job.referenceDurable).toList(growable: false);
    if (jobs.isEmpty) {
      if (allJobs.any((job) => !job.referenceDurable)) {
        _retryTimer = Timer(
          minimumDelay ?? _blockedRetryDelay,
          () => unawaited(retryNow()),
        );
      }
      return;
    }

    final now = DateTime.now();
    DateTime? earliest;
    for (final job in jobs) {
      final candidate = _nextAttemptAt(job);
      if (earliest == null || candidate.isBefore(earliest)) {
        earliest = candidate;
      }
    }

    if (earliest == null) {
      return;
    }

    var delay =
        earliest.isAfter(now) ? earliest.difference(now) : Duration.zero;
    if (minimumDelay != null && delay < minimumDelay) {
      delay = minimumDelay;
    }
    _logMedia(
        'retry.scheduled delayMs=${delay.inMilliseconds} jobs=${jobs.length}');
    _retryTimer = Timer(delay, () => unawaited(retryNow()));
  }

  Future<void> _reconcileStagedJobReferences() async {
    final accountId = ref.read(cloudMediaAccountIdProvider);
    if (accountId == null || accountId.isEmpty) return;
    final staged = _readJobs()
        .where(
          (job) => job.accountId == accountId && !job.referenceDurable,
        )
        .toList(growable: false);
    if (staged.isEmpty) return;

    final durableOps = ref.read(durableStrategyOutboxStoreProvider).load();
    final pendingOps =
        <({String accountId, String strategyPublicId, StrategyOp op})>[
      for (final record in durableOps.records) ...[
        (
          accountId: record.accountId,
          strategyPublicId: record.strategyPublicId,
          op: record.pending.op,
        ),
        if (record.successorPending case final successor?)
          (
            accountId: record.accountId,
            strategyPublicId: record.strategyPublicId,
            op: successor.op,
          ),
      ],
    ];
    final readyFromDurableOps = staged
        .where(
          (job) => pendingOps.any(
            (pending) =>
                pending.accountId == accountId &&
                pending.strategyPublicId == job.strategyPublicId &&
                _opReferencesAsset(pending.op, job.assetPublicId),
          ),
        )
        .toList(growable: false);
    for (final job in readyFromDurableOps) {
      if (ref.read(cloudMediaAccountIdProvider) != accountId) return;
      final promoted = job.copyWith(
        referenceDurable: true,
        updatedAt: DateTime.now(),
      );
      await _writeJobs([promoted], () => _store.put(promoted), replacing: job);
    }

    if (durableOps.issues.isNotEmpty) return;
    final unresolved = _readJobs()
        .where((job) => !job.referenceDurable)
        .toList(growable: false);
    if (unresolved.isEmpty ||
        !ref.read(authProvider).isConvexUserReady ||
        !ref.read(convexConnectionSnapshotProvider)) {
      return;
    }

    final byStrategy = <String, List<CloudMediaUploadJob>>{};
    for (final job in unresolved) {
      (byStrategy[job.strategyPublicId] ??= []).add(job);
    }
    for (final entry in byStrategy.entries) {
      late final RemoteFullStrategySnapshot snapshot;
      try {
        snapshot = await ref
            .read(cloudMediaReferenceSnapshotLoaderProvider)(entry.key);
      } catch (error) {
        _logMedia(
          'reference_reconcile.deferred strategy=${entry.key} error=$error',
        );
        continue;
      }

      if (ref.read(cloudMediaAccountIdProvider) != accountId) return;

      for (final job in entry.value) {
        if (ref.read(cloudMediaAccountIdProvider) != accountId) return;
        // Both jobs and op references may change while the server is read.
        // Never promote or delete using a stale copy of a media job.
        if (!identical(_getJob(job.jobId), job)) continue;
        final localReference = _hasLocalReference(job);
        if (_snapshotReferencesAsset(snapshot, job.assetPublicId) ||
            localReference == true) {
          final promoted = job.copyWith(
            referenceDurable: true,
            updatedAt: DateTime.now(),
          );
          await _writeJobs(
            [promoted],
            () => _store.put(promoted),
            replacing: job,
          );
        } else if (localReference == false &&
            _restoredStagedJobIds.contains(
              durableCloudMediaOutboxStorageKey(job),
            )) {
          await _deleteJob(job, onlyIfUnreferenced: true);
        }
      }
      _refreshState();
    }
  }

  bool _snapshotReferencesAsset(
    RemoteFullStrategySnapshot snapshot,
    String assetPublicId,
  ) {
    for (final elements in snapshot.elementsByPage.values) {
      if (elements.any(
        (element) =>
            !element.deleted &&
            element.elementType == 'image' &&
            element.publicId == assetPublicId,
      )) {
        return true;
      }
    }
    for (final lineups in snapshot.lineupsByPage.values) {
      if (lineups.any(
        (lineup) =>
            !lineup.deleted &&
            _jsonContainsAssetId(lineup.payload, assetPublicId),
      )) {
        return true;
      }
    }
    return false;
  }

  bool _opReferencesAsset(StrategyOp op, String assetPublicId) {
    if (op is ElementAddOp) {
      return op.elementPublicId == assetPublicId;
    }
    if (op is ElementPatchOp) {
      return op.elementPublicId == assetPublicId;
    }
    if (op is LineupAddOp) {
      return _jsonContainsAssetId(op.payload, assetPublicId);
    }
    if (op is LineupPatchOp) {
      return _jsonContainsAssetId(op.payload, assetPublicId);
    }
    return false;
  }

  bool _jsonContainsAssetId(Object? value, String assetPublicId) {
    if (value is Map) {
      if (value['id'] == assetPublicId) return true;
      return value.values.any(
        (child) => _jsonContainsAssetId(child, assetPublicId),
      );
    }
    if (value is Iterable) {
      return value.any(
        (child) => _jsonContainsAssetId(child, assetPublicId),
      );
    }
    return false;
  }

  Future<void> _upsertJob(CloudMediaUploadJob nextJob) async {
    await _putJob(_mergeJob(nextJob));
    _refreshState();
  }

  Future<void> _upsertJobsAtomically(
    Iterable<CloudMediaUploadJob> nextJobs,
  ) async {
    final mergedById = <String, CloudMediaUploadJob>{};
    for (final nextJob in nextJobs) {
      mergedById[nextJob.jobId] = _mergeJob(nextJob);
    }
    await _putJobsAtomically(mergedById.values);
    _refreshState();
  }

  CloudMediaUploadJob _mergeJob(CloudMediaUploadJob nextJob) {
    final existing =
        _jobsByStorageKey[durableCloudMediaOutboxStorageKey(nextJob)];
    if (existing == null) return nextJob;
    if (existing.isFailed) {
      return existing.copyWith(
        strategyPublicId: nextJob.strategyPublicId,
        assetPublicId: nextJob.assetPublicId,
        fileExtension: nextJob.fileExtension,
        mimeType: nextJob.mimeType,
        width: nextJob.width,
        height: nextJob.height,
        byteSize: nextJob.byteSize,
        state: nextJob.state,
        referenceDurable: nextJob.referenceDurable,
        attempts: 0,
        provider: null,
        uploadId: null,
        objectKey: null,
        storageId: null,
        etag: null,
        uploadUrlExpiresAt: null,
        lastError: null,
        updatedAt: DateTime.now(),
      );
    }
    return existing.copyWith(
      strategyPublicId: nextJob.strategyPublicId,
      assetPublicId: nextJob.assetPublicId,
      fileExtension: nextJob.fileExtension,
      mimeType: nextJob.mimeType,
      width: nextJob.width,
      height: nextJob.height,
      byteSize: nextJob.byteSize,
      referenceDurable: existing.referenceDurable || nextJob.referenceDurable,
      updatedAt: DateTime.now(),
    );
  }

  List<CloudMediaUploadJob> _readJobs() {
    final accountId = ref.read(cloudMediaAccountIdProvider);
    if (accountId == null || accountId.isEmpty) return const [];
    return _jobsByStorageKey.values
        .where((job) => job.accountId == accountId)
        .toList(growable: false);
  }

  CloudMediaUploadJob? _getJob(String jobId) {
    final accountId = ref.read(cloudMediaAccountIdProvider);
    if (accountId == null || accountId.isEmpty) return null;
    final job = _jobsByStorageKey[durableCloudMediaOutboxStorageKeyFor(
      accountId: accountId,
      jobId: jobId,
    )];
    return job != null && _belongsToActiveAccount(job) ? job : null;
  }

  String _requireActiveAccountId() {
    final accountId = ref.read(cloudMediaAccountIdProvider);
    if (accountId == null || accountId.isEmpty) {
      throw StateError(
        'Cloud media cannot be queued without an authenticated account.',
      );
    }
    return accountId;
  }

  bool _belongsToActiveAccount(CloudMediaUploadJob job) {
    final accountId = ref.read(cloudMediaAccountIdProvider);
    return accountId != null &&
        accountId.isNotEmpty &&
        job.accountId == accountId;
  }

  Future<void> _putJob(CloudMediaUploadJob job) async {
    await _writeJobs([job], () => _store.put(job));
  }

  Future<void> _putJobsAtomically(
    Iterable<CloudMediaUploadJob> jobs,
  ) async {
    final jobList = jobs.toList(growable: false);
    if (jobList.isEmpty) return;
    await _writeJobs(jobList, () => _store.putAll(jobList));
  }

  // Null means unreadable records or unverified writes prevent proving that
  // this asset is unreferenced. Include in-memory ops still being persisted.
  bool? _hasLocalReference(CloudMediaUploadJob job) {
    final durable = ref.read(durableStrategyOutboxStoreProvider).load();
    final queue = ref.read(strategyOpQueueProvider);
    if (durable.issues.isNotEmpty ||
        !queue.durableLoaded ||
        queue.hasDurabilityFailure) return null;
    final durableReference = durable.records.any((record) =>
        record.accountId == job.accountId &&
        record.strategyPublicId == job.strategyPublicId &&
        (_opReferencesAsset(record.pending.op, job.assetPublicId) ||
            (record.successorPending != null &&
                _opReferencesAsset(
                    record.successorPending!.op, job.assetPublicId))));
    if (durableReference) return true;
    final pendingReference = queue.accountId == job.accountId &&
        queue.strategyPublicId == job.strategyPublicId &&
        queue.pending.any(
            (pending) => _opReferencesAsset(pending.op, job.assetPublicId));
    return pendingReference ? null : false;
  }

  Future<void> _writeJobs(
    List<CloudMediaUploadJob> jobs,
    Future<void> Function() persist, {
    CloudMediaUploadJob? replacing,
  }) =>
      _serializeWrite(() async {
        if (replacing != null &&
            !identical(_getJob(replacing.jobId), replacing)) return;
        final keys = jobs.map(durableCloudMediaOutboxStorageKey).toSet();
        try {
          await persist();
          for (final job in jobs) {
            final key = durableCloudMediaOutboxStorageKey(job);
            _jobsByStorageKey[key] = job;
            if (job.referenceDurable) _restoredStagedJobIds.remove(key);
          }
          for (final key in keys) {
            _unverifiedByStorageKey.remove(key);
          }
          _refreshState();
        } catch (error, stackTrace) {
          for (final key in keys) {
            _unverifiedByStorageKey[key] = _MediaOutboxMutation.write;
          }
          _recordDurabilityFailure(error, stackTrace);
          rethrow;
        }
      });

  Future<bool> _deleteJob(
    CloudMediaUploadJob job, {
    bool onlyIfUnreferenced = false,
  }) =>
      _serializeWrite(() async {
        final key = durableCloudMediaOutboxStorageKey(job);
        if (onlyIfUnreferenced &&
            (!_belongsToActiveAccount(job) ||
                !identical(_jobsByStorageKey[key], job) ||
                _unverifiedByStorageKey[key] == _MediaOutboxMutation.write ||
                _hasLocalReference(job) != false)) return false;
        try {
          await _store.remove(job);
          _jobsByStorageKey.remove(key);
          _restoredStagedJobIds.remove(key);
          _unverifiedByStorageKey.remove(key);
          _refreshState();
          return true;
        } catch (error, stackTrace) {
          _unverifiedByStorageKey[key] = _MediaOutboxMutation.remove;
          _recordDurabilityFailure(error, stackTrace);
          rethrow;
        }
      });

  Future<T> _serializeWrite<T>(Future<T> Function() action) {
    final result = _writeTail.then((_) => action());
    _writeTail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void _recordDurabilityFailure(Object error, StackTrace stackTrace) {
    AppErrorReporter.reportError(
      'Failed to update the durable media outbox.',
      error: error,
      stackTrace: stackTrace,
      source: 'cloud_media.upload_queue',
    );
    _refreshState(isProcessing: false);
  }

  void _refreshState({bool? isProcessing}) {
    if (_disposed) return;
    final accountId = ref.read(cloudMediaAccountIdProvider);
    final prefix =
        accountId == null ? null : '${Uri.encodeComponent(accountId)}|';
    final hasUnverifiedWrites = prefix != null &&
        _unverifiedByStorageKey.keys.any((key) => key.startsWith(prefix));
    state = state.copyWith(
      jobs: _readJobs(),
      isProcessing: isProcessing ?? state.isProcessing,
      durabilityError: hasUnverifiedWrites
          ? 'Media work could not be saved on this device.'
          : null,
      clearDurabilityError: !hasUnverifiedWrites,
    );
    _syncUploadProgressToast();
  }

  void _syncUploadProgressToast() {
    final activeUploadCount = state.jobs
        .where(
          (job) =>
              job.state != CloudMediaJobState.failed && job.referenceDurable,
        )
        .length;

    if (activeUploadCount > 0) {
      if (_uploadProgressToast == null) {
        final uploadHasStarted = _uploadBytesTotalByJob.isNotEmpty ||
            _uploadCompletingJobs.isNotEmpty;
        if (!uploadHasStarted) {
          return;
        }
        _uploadCompletionDismissTimer?.cancel();
        _uploadProgressTotalJobs = activeUploadCount;
        _uploadProgressToastState = ValueNotifier<_UploadProgressToastState>(
          _buildUploadToastState(activeUploadCount),
        );
        _uploadProgressToast = _showUploadProgressToast();
        return;
      }

      final inferredTotal = _uploadCompletedJobs.length + activeUploadCount;
      if (inferredTotal > _uploadProgressTotalJobs) {
        _uploadProgressTotalJobs = inferredTotal;
      }
      _uploadProgressToastState?.value =
          _buildUploadToastState(activeUploadCount);
      return;
    }

    final toast = _uploadProgressToast;
    if (toast == null) {
      _resetUploadToastState();
      return;
    }

    final toastState = _uploadProgressToastState;
    if (toastState != null && _uploadCompletedJobs.isNotEmpty) {
      toastState.value = const _UploadProgressToastState(
        message: 'Image upload complete',
        progress: 1,
        isComplete: true,
      );
      _uploadCompletionDismissTimer?.cancel();
      _uploadCompletionDismissTimer = Timer(
        const Duration(milliseconds: 1400),
        () {
          if (_uploadProgressToast == toast) {
            Settings.dismissToast(toast);
            _resetUploadToastState();
          }
        },
      );
      return;
    }

    Settings.dismissToast(toast);
    _resetUploadToastState();
  }

  _UploadProgressToastState _buildUploadToastState(int activeUploadCount) {
    final totalJobs = _uploadProgressTotalJobs <= 0
        ? activeUploadCount
        : _uploadProgressTotalJobs;
    final progress = totalJobs <= 0 ? 0.0 : _currentUploadProgress(totalJobs);
    return _UploadProgressToastState(
      message: activeUploadCount == 1
          ? 'Uploading image...'
          : 'Uploading $activeUploadCount images...',
      progress: progress,
      isComplete: false,
    );
  }

  double _currentUploadProgress(int totalJobs) {
    var progressUnits = _uploadCompletedJobs.length.toDouble();
    final activeJobIds = state.jobs
        .where(
          (job) =>
              job.state != CloudMediaJobState.failed && job.referenceDurable,
        )
        .map((job) => job.jobId);

    for (final jobId in activeJobIds) {
      if (_uploadCompletedJobs.contains(jobId)) {
        continue;
      }
      if (_uploadCompletingJobs.contains(jobId)) {
        progressUnits += 0.94;
        continue;
      }

      final totalBytes = _uploadBytesTotalByJob[jobId] ?? 0;
      final sentBytes = _uploadBytesSentByJob[jobId] ?? 0;
      if (totalBytes <= 0) {
        continue;
      }
      final byteProgress = (sentBytes / totalBytes).clamp(0.0, 1.0).toDouble();
      progressUnits += byteProgress * 0.9;
    }

    return (progressUnits / totalJobs).clamp(0.0, 1.0).toDouble();
  }

  ToastificationItem _showUploadProgressToast() {
    final stateNotifier = _uploadProgressToastState!;
    return toastification.showCustom(
      autoCloseDuration: null,
      alignment: Alignment.bottomCenter,
      builder: (context, holder) {
        return ValueListenableBuilder<_UploadProgressToastState>(
          valueListenable: stateNotifier,
          builder: (context, toastState, _) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              width: 280,
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                color: toastState.isComplete
                    ? Settings.allyBGColor
                    : Settings.tacticalVioletTheme.primary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Settings.tacticalVioletTheme.border,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: Text(
                      toastState.message,
                      key: ValueKey<String>(toastState.message),
                      style: ShadTheme.of(context)
                          .textTheme
                          .small
                          .copyWith(color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        begin: 0,
                        end: toastState.progress.clamp(0, 1),
                      ),
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, _) {
                        return LinearProgressIndicator(
                          value: value,
                          minHeight: 4,
                          backgroundColor: Colors.white.withValues(alpha: 0.22),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _resetUploadToastState() {
    _uploadCompletionDismissTimer?.cancel();
    _uploadCompletionDismissTimer = null;
    _uploadProgressToast = null;
    _uploadProgressToastState?.dispose();
    _uploadProgressToastState = null;
    _uploadProgressTotalJobs = 0;
    _uploadBytesSentByJob.clear();
    _uploadBytesTotalByJob.clear();
    _uploadCompletingJobs.clear();
    _uploadCompletedJobs.clear();
  }

  void _setUploadByteProgress(
    String jobId, {
    required int sentBytes,
    required int totalBytes,
  }) {
    _uploadBytesSentByJob[jobId] = sentBytes;
    _uploadBytesTotalByJob[jobId] = totalBytes;
    _publishUploadProgressToast();
  }

  void _markUploadCompleting(String jobId) {
    _uploadCompletingJobs.add(jobId);
    _publishUploadProgressToast();
  }

  void _markUploadComplete(String jobId) {
    _uploadCompletingJobs.remove(jobId);
    _uploadCompletedJobs.add(jobId);
    _uploadBytesSentByJob.remove(jobId);
    _uploadBytesTotalByJob.remove(jobId);
    _publishUploadProgressToast();
  }

  void _publishUploadProgressToast() {
    final activeUploadCount = state.jobs
        .where(
          (job) =>
              job.state != CloudMediaJobState.failed && job.referenceDurable,
        )
        .length;
    if (activeUploadCount <= 0) {
      return;
    }
    if (_uploadProgressToastState == null) {
      _syncUploadProgressToast();
    }
    if (_uploadProgressToastState == null) return;
    _uploadProgressToastState!.value =
        _buildUploadToastState(activeUploadCount);
  }

  void _logMedia(String message) {
    AppErrorReporter.reportInfo(
      message,
      source: 'cloud_media.upload_queue',
    );
  }

  String _describeJob(CloudMediaUploadJob? job) {
    if (job == null) {
      return 'job=null';
    }
    return 'job=${job.jobId} image=${job.assetPublicId} '
        'account=${job.accountId} '
        'strategy=${job.strategyPublicId} state=${job.state.name} '
        'attempts=${job.attempts} provider=${job.provider ?? 'none'} '
        'hasUploadId=${job.uploadId != null} '
        'hasObjectKey=${job.objectKey != null} '
        'hasStorageId=${job.storageId != null} '
        'byteSize=${job.byteSize ?? 'unknown'} '
        'lastError=${job.lastError ?? 'none'}';
  }
}
