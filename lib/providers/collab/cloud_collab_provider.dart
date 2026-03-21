import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/auth_provider.dart';

class CloudCollabModeState {
  const CloudCollabModeState({
    required this.featureFlagEnabled,
    required this.forceLocalFallback,
  });

  final bool featureFlagEnabled;
  final bool forceLocalFallback;

  bool isCloudEnabled({
    required bool isAuthenticated,
    required bool isConvexUserReady,
  }) {
    return featureFlagEnabled &&
        isAuthenticated &&
        isConvexUserReady &&
        !forceLocalFallback;
  }

  CloudCollabModeState copyWith({
    bool? featureFlagEnabled,
    bool? forceLocalFallback,
  }) {
    return CloudCollabModeState(
      featureFlagEnabled: featureFlagEnabled ?? this.featureFlagEnabled,
      forceLocalFallback: forceLocalFallback ?? this.forceLocalFallback,
    );
  }
}

final cloudCollabModeProvider =
    NotifierProvider<CloudCollabModeNotifier, CloudCollabModeState>(
  CloudCollabModeNotifier.new,
);

final isCloudCollabEnabledProvider = Provider<bool>((ref) {
  final auth = ref.watch(authProvider);
  final mode = ref.watch(cloudCollabModeProvider);
  return mode.isCloudEnabled(
    isAuthenticated: auth.isAuthenticated,
    isConvexUserReady: auth.isConvexUserReady,
  );
});

class CloudCollabModeNotifier extends Notifier<CloudCollabModeState> {
  @override
  CloudCollabModeState build() {
    // Feature-flagged dual mode; default enabled for authenticated users.
    return const CloudCollabModeState(
      featureFlagEnabled: true,
      forceLocalFallback: false,
    );
  }

  void setFeatureFlagEnabled(bool enabled) {
    state = state.copyWith(featureFlagEnabled: enabled);
  }

  void setForceLocalFallback(bool enabled) {
    state = state.copyWith(forceLocalFallback: enabled);
  }
}
