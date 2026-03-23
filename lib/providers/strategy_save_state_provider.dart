import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class StrategySaveState {
  const StrategySaveState({
    required this.isDirty,
    required this.isSaving,
    required this.hasPendingCloudSync,
    required this.cloudSyncError,
    required this.lastPersistedAt,
  });

  final bool isDirty;
  final bool isSaving;
  final bool hasPendingCloudSync;
  final String? cloudSyncError;
  final DateTime? lastPersistedAt;

  bool get canLeaveSafely =>
      !isDirty && !isSaving && !hasPendingCloudSync && cloudSyncError == null;

  StrategySaveState copyWith({
    bool? isDirty,
    bool? isSaving,
    bool? hasPendingCloudSync,
    String? cloudSyncError,
    bool clearCloudSyncError = false,
    DateTime? lastPersistedAt,
  }) {
    return StrategySaveState(
      isDirty: isDirty ?? this.isDirty,
      isSaving: isSaving ?? this.isSaving,
      hasPendingCloudSync: hasPendingCloudSync ?? this.hasPendingCloudSync,
      cloudSyncError:
          clearCloudSyncError ? null : (cloudSyncError ?? this.cloudSyncError),
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

      final hasPendingSync = next.isFlushing || next.pending.isNotEmpty;
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

    return const StrategySaveState(
      isDirty: false,
      isSaving: false,
      hasPendingCloudSync: false,
      cloudSyncError: null,
      lastPersistedAt: null,
    );
  }

  void reset() {
    state = const StrategySaveState(
      isDirty: false,
      isSaving: false,
      hasPendingCloudSync: false,
      cloudSyncError: null,
      lastPersistedAt: null,
    );
  }

  void markDirty() {
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

  void markPersisted() {
    state = state.copyWith(
      isDirty: false,
      isSaving: false,
      hasPendingCloudSync: false,
      clearCloudSyncError: true,
      lastPersistedAt: DateTime.now(),
    );
  }
}
