import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class StrategySaveState {
  const StrategySaveState({
    required this.isDirty,
    required this.isSaving,
    required this.hasPendingCloudSync,
    required this.cloudSyncError,
    required this.hasPendingMediaSync,
    required this.mediaSyncErrorCount,
    required this.lastPersistedAt,
  });

  final bool isDirty;
  final bool isSaving;
  final bool hasPendingCloudSync;
  final String? cloudSyncError;
  final bool hasPendingMediaSync;
  final int mediaSyncErrorCount;
  final DateTime? lastPersistedAt;

  bool get canLeaveSafely =>
      !isDirty &&
      !isSaving &&
      !hasPendingCloudSync &&
      !hasPendingMediaSync &&
      cloudSyncError == null &&
      mediaSyncErrorCount == 0;

  StrategySaveState copyWith({
    bool? isDirty,
    bool? isSaving,
    bool? hasPendingCloudSync,
    String? cloudSyncError,
    bool? hasPendingMediaSync,
    int? mediaSyncErrorCount,
    bool clearCloudSyncError = false,
    DateTime? lastPersistedAt,
  }) {
    return StrategySaveState(
      isDirty: isDirty ?? this.isDirty,
      isSaving: isSaving ?? this.isSaving,
      hasPendingCloudSync: hasPendingCloudSync ?? this.hasPendingCloudSync,
      cloudSyncError:
          clearCloudSyncError ? null : (cloudSyncError ?? this.cloudSyncError),
      hasPendingMediaSync: hasPendingMediaSync ?? this.hasPendingMediaSync,
      mediaSyncErrorCount: mediaSyncErrorCount ?? this.mediaSyncErrorCount,
      lastPersistedAt: lastPersistedAt ?? this.lastPersistedAt,
    );
  }
}

final strategySaveStateProvider =
    NotifierProvider<StrategySaveStateNotifier, StrategySaveState>(
  StrategySaveStateNotifier.new,
);

class StrategySaveStateNotifier extends Notifier<StrategySaveState> {
  @override
  StrategySaveState build() {
    ref.listen<StrategyOpQueueState>(strategyOpQueueProvider, (previous, next) {
      final source = ref.read(strategyProvider).source;
      if (source != StrategySource.cloud) {
        return;
      }

      // THROWAWAY BUG: only work being sent counts as unsaved.
      final hasPendingSync = next.isFlushing;
      state = state.copyWith(
        isSaving: next.isFlushing,
        hasPendingCloudSync: hasPendingSync,
        cloudSyncError: next.lastError,
        clearCloudSyncError: next.lastError == null,
        isDirty: hasPendingSync ? true : state.isDirty,
      );

      if (!hasPendingSync && next.lastError == null) {
        state = state.copyWith(
          isDirty: false,
          lastPersistedAt: DateTime.now(),
        );
      }
    });

    ref.listen<CloudMediaUploadQueueState>(cloudMediaUploadQueueProvider, (
      previous,
      next,
    ) {
      final source = ref.read(strategyProvider).source;
      if (source != StrategySource.cloud) {
        return;
      }

      final strategyId = ref.read(strategyProvider).strategyId;
      final strategyJobs = next.jobsForStrategy(strategyId);
      final failedJobs = strategyJobs.where((job) => job.isFailed).length;
      final hasPendingMedia = strategyJobs.isNotEmpty;
      final hasPendingCloudSync = state.hasPendingCloudSync || hasPendingMedia;
      state = state.copyWith(
        hasPendingMediaSync: hasPendingMedia,
        mediaSyncErrorCount: failedJobs,
        isDirty: hasPendingCloudSync ? true : state.isDirty,
      );

      if (!hasPendingCloudSync &&
          state.cloudSyncError == null &&
          failedJobs == 0) {
        state = state.copyWith(
          isDirty: false,
          lastPersistedAt: DateTime.now(),
        );
      }
    });

    return const StrategySaveState(
      isDirty: false,
      isSaving: false,
      hasPendingCloudSync: false,
      cloudSyncError: null,
      hasPendingMediaSync: false,
      mediaSyncErrorCount: 0,
      lastPersistedAt: null,
    );
  }

  void reset() {
    state = const StrategySaveState(
      isDirty: false,
      isSaving: false,
      hasPendingCloudSync: false,
      cloudSyncError: null,
      hasPendingMediaSync: false,
      mediaSyncErrorCount: 0,
      lastPersistedAt: null,
    );
  }

  /// Counts edits marked unsaved. A save reads this before it snapshots the
  /// canvas, and passes it to [markPersisted].
  int get dirtyMarks => _dirtyMarks;
  int _dirtyMarks = 0;

  void markDirty() {
    _dirtyMarks++;
    state = state.copyWith(
      isDirty: true,
      clearCloudSyncError: true,
    );
  }

  void markSaving(bool value) {
    state = state.copyWith(isSaving: value);
  }

  void setPendingCloudSync(bool value) {
    state = state.copyWith(hasPendingCloudSync: value);
  }

  void setCloudSyncError(String? error) {
    state = state.copyWith(
      cloudSyncError: error,
      clearCloudSyncError: error == null,
    );
  }

  /// Clears an unsaved mark no op stands behind. Edits to a page the server
  /// no longer has leave one: they produce no op, so the queue never changes
  /// to clear it.
  void clearStaleCloudMark() {
    final queue = ref.read(strategyOpQueueProvider);
    if (!state.isDirty ||
        state.hasPendingMediaSync ||
        queue.isFlushing ||
        queue.pending.isNotEmpty ||
        queue.lastError != null) {
      return;
    }
    state = state.copyWith(
      isDirty: false,
      isSaving: false,
      hasPendingCloudSync: false,
      clearCloudSyncError: true,
      lastPersistedAt: DateTime.now(),
    );
  }

  /// The library holds the canvas as of [dirtyMarksSaved]. An edit marked
  /// after that isn't in what was written, so it stays unsaved.
  void markPersisted({int? dirtyMarksSaved}) {
    final editedSince =
        dirtyMarksSaved != null && dirtyMarksSaved != _dirtyMarks;
    state = state.copyWith(
      isDirty: editedSince,
      isSaving: false,
      hasPendingCloudSync: false,
      hasPendingMediaSync: false,
      mediaSyncErrorCount: 0,
      clearCloudSyncError: true,
      lastPersistedAt: DateTime.now(),
    );
  }
}
