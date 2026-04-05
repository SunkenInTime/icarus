import 'dart:async';
import 'dart:convert';

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

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

final cloudMediaUploadQueueProvider = NotifierProvider<
    CloudMediaUploadQueueNotifier, CloudMediaUploadQueueState>(
  CloudMediaUploadQueueNotifier.new,
);

class CloudMediaUploadQueueNotifier extends Notifier<CloudMediaUploadQueueState> {
  Timer? _retryTimer;

  Box<CloudMediaUploadJob> get _box =>
      Hive.box<CloudMediaUploadJob>(HiveBoxNames.mediaUploadJobsBox);

  ConvexStrategyRepository get _repo =>
      ref.read(convexStrategyRepositoryProvider);

  @override
  CloudMediaUploadQueueState build() {
    ref.onDispose(() {
      _retryTimer?.cancel();
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

    final initialJobs = _readJobs();
    if (initialJobs.isNotEmpty) {
      Future<void>.microtask(() => retryNow());
    }
    return CloudMediaUploadQueueState(
      jobs: initialJobs,
      isProcessing: false,
    );
  }

  Future<void> enqueuePlacedImageUpload({
    required String imagePublicId,
    String? strategyPublicId,
    String? pagePublicId,
    String? fileExtension,
    String? mimeType,
    int? width,
    int? height,
  }) async {
    final strategyState = ref.read(strategyProvider);
    final resolvedStrategyId = strategyPublicId ?? strategyState.strategyId;
    final resolvedPageId =
        pagePublicId ?? ref.read(strategyPageSessionProvider).activePageId;
    if (strategyState.source != StrategySource.cloud ||
        resolvedStrategyId == null ||
        resolvedPageId == null) {
      return;
    }

    final normalizedExtension = normalizeImageExtension(fileExtension ?? '');
    await _upsertJob(
      CloudMediaUploadJob(
        jobId: imagePublicId,
        strategyPublicId: resolvedStrategyId,
        pagePublicId: resolvedPageId,
        ownerType: CloudMediaOwnerType.element,
        ownerPublicId: imagePublicId,
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
    retryNow(ignoreBackoff: true);
  }

  Future<void> enqueueJobForLocalFile({
    required String strategyPublicId,
    required String pagePublicId,
    required CloudMediaOwnerType ownerType,
    required String ownerPublicId,
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
        pagePublicId: pagePublicId,
        ownerType: ownerType,
        ownerPublicId: ownerPublicId,
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
    retryNow(ignoreBackoff: true);
  }

  Future<void> enqueueLineupMediaJobs({
    required String strategyPublicId,
    required String pagePublicId,
    required String lineupPublicId,
    required Iterable<SimpleImageData> images,
  }) async {
    for (final image in images) {
      final normalizedExtension = normalizeImageExtension(image.fileExtension);
      await _upsertJob(
        CloudMediaUploadJob(
          jobId: image.id,
          strategyPublicId: strategyPublicId,
          pagePublicId: pagePublicId,
          ownerType: CloudMediaOwnerType.lineup,
          ownerPublicId: lineupPublicId,
          assetPublicId: image.id,
          fileExtension: normalizedExtension,
          mimeType: mimeTypeForImageExtension(normalizedExtension),
          state: CloudMediaJobState.pendingUpload,
          attempts: 0,
          updatedAt: DateTime.now(),
        ),
      );
    }
    retryNow(ignoreBackoff: true);
  }

  Future<void> retryNow({bool ignoreBackoff = false}) async {
    _retryTimer?.cancel();
    unawaited(_processNextJob(ignoreBackoff: ignoreBackoff));
  }

  Future<void> setActiveStrategy(String? strategyPublicId) async {
    _retryTimer?.cancel();
    _refreshState();
    if (strategyPublicId != null) {
      await retryNow(ignoreBackoff: true);
    }
  }

  Future<void> clearJobsForStrategy(String strategyPublicId) async {
    final jobs = _readJobs()
        .where((job) => job.strategyPublicId == strategyPublicId)
        .toList(growable: false);
    for (final job in jobs) {
      await _box.delete(job.jobId);
    }
    _refreshState();
  }

  Future<void> _processNextJob({bool ignoreBackoff = false}) async {
    if (state.isProcessing) {
      return;
    }

    final nextJob = _nextRunnableJob(ignoreBackoff: ignoreBackoff);
    if (nextJob == null) {
      _scheduleRetryForNextEligibleJob();
      return;
    }

    state = state.copyWith(isProcessing: true);
    try {
      await _processJob(nextJob);
    } finally {
      _refreshState(isProcessing: false);
    }

    if (_readJobs().isNotEmpty) {
      unawaited(_processNextJob(ignoreBackoff: ignoreBackoff));
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
      _scheduleRetryForNextEligibleJob();
      return;
    }
    if (!auth.isAuthenticated ||
        !auth.isConvexUserReady ||
        auth.hasActiveAuthIncident ||
        !ConvexClient.instance.isConnected) {
      _scheduleRetryForNextEligibleJob();
      return;
    }

    if (job.state == CloudMediaJobState.pendingUpload || job.storageId == null) {
      await _uploadJobBlob(job);
      return;
    }

    await _attachUploadedJob(job);
  }

  Future<void> _uploadJobBlob(CloudMediaUploadJob job) async {
    try {
      final file = await PlacedImageProvider.getImageFile(
        strategyID: job.strategyPublicId,
        imageID: job.assetPublicId,
        fileExtension: job.fileExtension,
      );
      if (!await file.exists()) {
        await _markJobFailed(
          job,
          'Local media file is missing.',
          showToast: job.attempts == 0,
        );
        return;
      }

      final uploadUrl = await _repo.generateImageUploadUrl(job.strategyPublicId);
      if (uploadUrl.isEmpty) {
        throw StateError('Empty Convex upload URL');
      }

      final response = await http.post(
        Uri.parse(uploadUrl),
        headers: {
          'Content-Type': job.mimeType,
        },
        body: await file.readAsBytes(),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Upload failed (${response.statusCode}): ${response.body}',
        );
      }

      final storageId = _parseStorageId(response.body);
      await _box.put(
        job.jobId,
        job.copyWith(
          storageId: storageId,
          state: CloudMediaJobState.pendingAttach,
          attempts: 0,
          lastError: null,
          updatedAt: DateTime.now(),
        ),
      );
      _refreshState();
    } catch (error) {
      await _markJobFailed(
        job,
        '$error',
        showToast: job.attempts == 0,
      );
    }
  }

  Future<void> _attachUploadedJob(CloudMediaUploadJob job) async {
    try {
      await _repo.completeImageUpload(
        strategyPublicId: job.strategyPublicId,
        pagePublicId: job.pagePublicId,
        assetPublicId: job.assetPublicId,
        ownerType: job.ownerType,
        ownerPublicId: job.ownerPublicId,
        storageId: job.storageId!,
        mimeType: job.mimeType,
        fileExtension: job.fileExtension,
        width: job.width,
        height: job.height,
      );
      await _box.delete(job.jobId);
      _refreshState();
    } catch (error) {
      if (_isOwnerNotFoundError(error)) {
        await _box.put(
          job.jobId,
          job.copyWith(
            state: CloudMediaJobState.pendingAttach,
            attempts: job.attempts + 1,
            lastError: 'owner_not_found',
            updatedAt: DateTime.now(),
          ),
        );
        _refreshState();
        _scheduleRetryForNextEligibleJob();
        return;
      }

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
    await _box.put(
      job.jobId,
      job.copyWith(
        state: CloudMediaJobState.failed,
        attempts: job.attempts + 1,
        lastError: errorMessage,
        updatedAt: DateTime.now(),
      ),
    );
    _refreshState();
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

    final delay = earliest.isAfter(now) ? earliest.difference(now) : Duration.zero;
    _retryTimer = Timer(delay, () {
      unawaited(_processNextJob(ignoreBackoff: false));
    });
  }

  Future<void> _upsertJob(CloudMediaUploadJob nextJob) async {
    final existing = _box.get(nextJob.jobId);
    if (existing != null) {
      final merged = existing.copyWith(
        strategyPublicId: nextJob.strategyPublicId,
        pagePublicId: nextJob.pagePublicId,
        ownerType: nextJob.ownerType,
        ownerPublicId: nextJob.ownerPublicId,
        assetPublicId: nextJob.assetPublicId,
        fileExtension: nextJob.fileExtension,
        mimeType: nextJob.mimeType,
        width: nextJob.width,
        height: nextJob.height,
      );
      await _box.put(nextJob.jobId, merged);
    } else {
      await _box.put(nextJob.jobId, nextJob);
    }
    _refreshState();
  }

  List<CloudMediaUploadJob> _readJobs() {
    return _box.values.toList(growable: false);
  }

  void _refreshState({bool? isProcessing}) {
    state = state.copyWith(
      jobs: _readJobs(),
      isProcessing: isProcessing ?? state.isProcessing,
    );
  }

  String _parseStorageId(String responseBody) {
    final decoded = jsonDecode(responseBody);
    if (decoded is Map<String, dynamic>) {
      final storageId = decoded['storageId'];
      if (storageId is String && storageId.isNotEmpty) {
        return storageId;
      }
    }
    if (decoded is Map) {
      final storageId = decoded['storageId'];
      if (storageId is String && storageId.isNotEmpty) {
        return storageId;
      }
    }
    throw const FormatException('Convex upload response did not include storageId');
  }

  bool _isOwnerNotFoundError(Object error) {
    if (error is Map) {
      final code = error['code']?.toString().toUpperCase();
      final message = error['message']?.toString().toLowerCase();
      if (code == 'OWNER_NOT_FOUND' || message == 'owner_not_found') {
        return true;
      }
    }

    final normalized = error.toString().toLowerCase();
    return normalized.contains('owner_not_found') ||
        normalized.contains('owner not found');
  }
}
