import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/settings.dart';

/// Returns true when [feature] runs here. Otherwise tells the user, in one
/// short toast, that it is desktop-only or coming to the web beta, and
/// returns false so the caller can stop.
bool ensureFeatureAvailable(WidgetRef ref, PlatformFeature feature) {
  final message =
      ref.read(platformPolicyProvider).unavailableMessage(feature);
  if (message == null) return true;
  // Not an error: the neutral surface, not the destructive one.
  Settings.showToast(
    message: message,
    backgroundColor: Settings.tacticalVioletTheme.secondary,
  );
  return false;
}
