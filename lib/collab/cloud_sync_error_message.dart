String friendlyCloudSyncError(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('unreadable saved work')) {
    return 'A saved cloud change could not be read. It remains on this '
        'device; keep this strategy open and recover the outbox before '
        'continuing.';
  }
  if (lower.contains('forbidden')) {
    return 'This account does not have permission to save these changes. '
        'They remain on this device. Ask the owner for edit access, then '
        'retry.';
  }
  if (lower.contains('retry paused')) {
    return 'A saved cloud change is paused after repeated failures. Retry '
        'when the connection and account are healthy.';
  }
  if (lower.contains('needs attention')) {
    return 'Another edit reached the cloud first. Your version remains '
        'saved on this device.';
  }
  if (lower.contains('cannot be retried automatically')) {
    return 'The server cannot match this retained edit to a current cloud '
        'revision. It remains saved on this device.';
  }
  if (lower.contains('auth')) {
    return 'Your cloud session needs to be refreshed — retry, or sign in '
        'again from the library.';
  }
  if (lower.contains('offline') || lower.contains('connection')) {
    return 'The cloud could not be reached.';
  }
  if (lower.contains('setup is not ready')) {
    return 'Cloud sync is still starting up.';
  }
  return "Some changes haven't reached the cloud yet.";
}
