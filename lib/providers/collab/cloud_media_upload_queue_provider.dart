import 'dart:async';
import 'dart:io';

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
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
  });

  final List<CloudMediaUploadJob> jobs;
  final bool isProcessing;

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
  }) {
    return CloudMediaUploadQueueState(
      jobs: jobs ?? this.jobs,
      isProcessing: isProcessing ?? this.isProcessing,
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

class CloudMediaUploadQueueNotifier
    extends Notifier<CloudMediaUploadQueueState> {
  Timer? _retryTimer;
  Timer? _uploadCompletionDismissTimer;
  ToastificationItem? _uploadProgressToast;
  ValueNotifier<_UploadProgressToastState>? _uploadProgressToastState;
  int _uploadProgressTotalJobs = 0;
  final Map<String, int> _uploadBytesSentByJob = {};
  final Map<String, int> _uploadBytesTotalByJob = {};
  final Set<String> _uploadCompletingJobs = {};
  final Set<String> _uploadCompletedJobs = {};
  final Map<String, CloudMediaUploadJob> _jobsById = {};

  ConvexStrategyRepository get _repo =>
      ref.read(convexStrategyRepositoryProvider);

  @override
  CloudMediaUploadQueueState build() {
    ref.onDispose(() {
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

    return const CloudMediaUploadQueueState(
      jobs: [],
      isProcessing: false,
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

    final normalizedExtension = normalizeImageExtension(fileExtension ?? '');
    await _upsertJob(
      CloudMediaUploadJob(
        jobId: imagePublicId,
        strategyPublicId: resolvedStrategyId,
        assetPublicId: imagePublicId,
        fileExtension: normalizedExtension,
        mimeType: mimeType ?? mimeTypeForImageExtension(normalizedExtension),
        width: width,
        height: height,
        state: CloudMediaJobState.pendingUpload,
        attempts: 0,
        updatedAt: DateTime.now(),
      ),
    );
    _logMedia(
      'enqueue.placed_image ${_describeJob(_getJob(imagePublicId))}',
    );
    retryNow(ignoreBackoff: true);
  }

  Future<void> enqueueJobForLocalFile({
    required String strategyPublicId,
    required String assetPublicId,
    required String fileExtension,
    String? mimeType,
    int? width,
    int? height,
  }) async {
    final normalizedExtension = normalizeImageExtension(fileExtension);
    await _upsertJob(
      CloudMediaUploadJob(
        jobId: assetPublicId,
        strategyPublicId: strategyPublicId,
        assetPublicId: assetPublicId,
        fileExtension: normalizedExtension,
        mimeType: mimeType ?? mimeTypeForImageExtension(normalizedExtension),
        width: width,
        height: height,
        state: CloudMediaJobState.pendingUpload,
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
    for (final image in images) {
      final normalizedExtension = normalizeImageExtension(image.fileExtension);
      await _upsertJob(
        CloudMediaUploadJob(
          jobId: image.id,
          strategyPublicId: strategyPublicId,
          assetPublicId: image.id,
          fileExtension: normalizedExtension,
          mimeType: mimeTypeForImageExtension(normalizedExtension),
          state: CloudMediaJobState.pendingUpload,
          attempts: 0,
          updatedAt: DateTime.now(),
        ),
      );
      _logMedia('enqueue.lineup_image ${_describeJob(_getJob(image.id))}');
    }
    retryNow(ignoreBackoff: true);
  }

  Future<void> retryNow({bool ignoreBackoff = false}) async {
    _retryTimer?.cancel();
    _logMedia(
      'retry_now ignoreBackoff=$ignoreBackoff jobs=${_readJobs().length}',
    );
    unawaited(_processNextJob(ignoreBackoff: ignoreBackoff));
  }

  Future<void> setActiveStrategy(String? strategyPublicId) async {
    _retryTimer?.cancel();
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
      _deleteJob(job.jobId);
    }
    _refreshState();
  }

  Future<void> cancelUpload(String assetPublicId) async {
    final job = _getJob(assetPublicId);
    if (job == null) {
      return;
    }
    _deleteJob(job.jobId);
    _refreshState();

    try {
      final file = await PlacedImageProvider.getImageFile(
        strategyID: job.strategyPublicId,
        imageID: job.assetPublicId,
        fileExtension: job.fileExtension,
      );
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Failed to delete canceled media upload file.',
        error: error,
        stackTrace: stackTrace,
        source: 'cloud_media.upload_queue',
      );
    }

    ref.read(placedImageProvider.notifier).removeImage(job.assetPublicId);
  }

  Future<void> cancelUploadsForStrategy(String strategyPublicId) async {
    final jobs = _readJobs()
        .where((job) => job.strategyPublicId == strategyPublicId)
        .toList(growable: false);
    for (final job in jobs) {
      await cancelUpload(job.assetPublicId);
    }
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
    try {
      await _processJob(nextJob);
    } finally {
      _refreshState(isProcessing: false);
      _logMedia('process.finish jobs=${state.jobs.length}');
    }

    if (_readJobs().isNotEmpty) {
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
      if (ignoreBackoff || !_nextAttemptAt(job).isAfter(now)) {
        return job;
      }
    }
    return null;
  }

  Future<void> _processJob(CloudMediaUploadJob job) async {
    final mode = ref.read(cloudCollabModeProvider);
    final auth = ref.read(authProvider);
    if (!mode.featureFlagEnabled || mode.forceLocalFallback) {
      _logMedia(
        'process.blocked featureFlag=${mode.featureFlagEnabled} '
        'forceLocalFallback=${mode.forceLocalFallback} ${_describeJob(job)}',
      );
      _scheduleRetryForNextEligibleJob();
      return;
    }
    if (!auth.isAuthenticated ||
        !auth.isConvexUserReady ||
        auth.hasActiveAuthIncident ||
        !ConvexClient.instance.isConnected) {
      _logMedia(
        'process.blocked auth=${auth.isAuthenticated} '
        'userReady=${auth.isConvexUserReady} '
        'authIncident=${auth.hasActiveAuthIncident} '
        'connected=${ConvexClient.instance.isConnected} '
        '${_describeJob(job)}',
      );
      _scheduleRetryForNextEligibleJob();
      return;
    }

    if (!job.hasUploadedRemoteObject) {
      await _uploadJobBlob(job);
      return;
    }

    await _attachUploadedJob(job);
  }

  Future<void> _uploadJobBlob(CloudMediaUploadJob job) async {
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
        await _markJobFailed(
          job,
          'Local media file is missing.',
          showToast: job.attempts == 0,
        );
        return;
      }

      final byteSize = await file.length();
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

      _putJob(
        job.jobId,
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
      _deleteJob(job.jobId);
      if (_uploadProgressToast != null) {
        _markUploadComplete(job.jobId);
      }
      _refreshState();
      _logMedia('attach.success image=${job.assetPublicId} '
          'strategy=${job.strategyPublicId}');
    } catch (error) {
      _logMedia('attach.failed error=$error ${_describeJob(job)}');
      await _markJobFailed(
        job,
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
    _putJob(
      job.jobId,
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

  void _scheduleRetryForNextEligibleJob() {
    _retryTimer?.cancel();
    final jobs = _readJobs();
    if (jobs.isEmpty) {
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

    final delay =
        earliest.isAfter(now) ? earliest.difference(now) : Duration.zero;
    _logMedia(
        'retry.scheduled delayMs=${delay.inMilliseconds} jobs=${jobs.length}');
    _retryTimer = Timer(delay, () {
      unawaited(_processNextJob(ignoreBackoff: false));
    });
  }

  Future<void> _upsertJob(CloudMediaUploadJob nextJob) async {
    final existing = _getJob(nextJob.jobId);
    if (existing != null) {
      final merged = existing.isFailed
          ? existing.copyWith(
              strategyPublicId: nextJob.strategyPublicId,
              assetPublicId: nextJob.assetPublicId,
              fileExtension: nextJob.fileExtension,
              mimeType: nextJob.mimeType,
              width: nextJob.width,
              height: nextJob.height,
              byteSize: nextJob.byteSize,
              state: CloudMediaJobState.pendingUpload,
              attempts: 0,
              provider: null,
              uploadId: null,
              objectKey: null,
              storageId: null,
              etag: null,
              uploadUrlExpiresAt: null,
              lastError: null,
              updatedAt: DateTime.now(),
            )
          : existing.copyWith(
              strategyPublicId: nextJob.strategyPublicId,
              assetPublicId: nextJob.assetPublicId,
              fileExtension: nextJob.fileExtension,
              mimeType: nextJob.mimeType,
              width: nextJob.width,
              height: nextJob.height,
              byteSize: nextJob.byteSize,
              updatedAt: DateTime.now(),
            );
      _putJob(nextJob.jobId, merged);
    } else {
      _putJob(nextJob.jobId, nextJob);
    }
    _refreshState();
  }

  List<CloudMediaUploadJob> _readJobs() {
    return _jobsById.values.toList(growable: false);
  }

  CloudMediaUploadJob? _getJob(String jobId) {
    return _jobsById[jobId];
  }

  void _putJob(String jobId, CloudMediaUploadJob job) {
    _jobsById[jobId] = job;
  }

  void _deleteJob(String jobId) {
    _jobsById.remove(jobId);
  }

  void _refreshState({bool? isProcessing}) {
    state = state.copyWith(
      jobs: _readJobs(),
      isProcessing: isProcessing ?? state.isProcessing,
    );
    _syncUploadProgressToast();
  }

  void _syncUploadProgressToast() {
    final activeUploadCount = state.jobs
        .where((job) => job.state != CloudMediaJobState.failed)
        .length;

    if (activeUploadCount > 0) {
      if (_uploadProgressToast == null) {
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
        .where((job) => job.state != CloudMediaJobState.failed)
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
      final byteProgress =
          (sentBytes / totalBytes).clamp(0.0, 1.0).toDouble();
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
                          backgroundColor:
                              Colors.white.withValues(alpha: 0.22),
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
        .where((job) => job.state != CloudMediaJobState.failed)
        .length;
    if (_uploadProgressToastState == null || activeUploadCount <= 0) {
      return;
    }
    _uploadProgressToastState!.value = _buildUploadToastState(activeUploadCount);
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
        'strategy=${job.strategyPublicId} state=${job.state.name} '
        'attempts=${job.attempts} provider=${job.provider ?? 'none'} '
        'hasUploadId=${job.uploadId != null} '
        'hasObjectKey=${job.objectKey != null} '
        'hasStorageId=${job.storageId != null} '
        'byteSize=${job.byteSize ?? 'unknown'} '
        'lastError=${job.lastError ?? 'none'}';
  }
}
