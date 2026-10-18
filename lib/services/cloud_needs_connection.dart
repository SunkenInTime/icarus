import 'package:icarus/const/settings.dart';

/// Said, at once, when a change to the cloud library is asked for while
/// the library shows this computer's copy of it.
const cloudNeedsConnectionMessage =
    "Needs a connection. Your cloud library can't change while you're "
    'offline.';

/// Refuses a change to the cloud library while [showsCopy] (see
/// cloudLibraryShowsCopyProvider): the cloud isn't ready, so the change
/// could only fail after a wait, under a banner that says changes sync
/// later. Shows the reason and returns true when it refuses.
bool refuseCloudChangeWhileOffline(bool showsCopy) {
  if (!showsCopy) return false;
  // Not an error: the neutral surface, as for a feature this platform lacks.
  Settings.showToast(
    message: cloudNeedsConnectionMessage,
    backgroundColor: Settings.tacticalVioletTheme.secondary,
  );
  return true;
}
