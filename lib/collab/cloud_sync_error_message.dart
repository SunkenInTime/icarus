import 'package:icarus/collab/collab_models.dart';

final _urlQuery = RegExp(r'''(https?://[^\s?#"'<>]+)\?[^\s"'<>]*''');
final _secretKeyValue = RegExp(
  r'''((?:access_token|refresh_token|provider_token|provider_refresh_token|code_verifier|token|X-Amz-Signature|X-Amz-Credential|X-Amz-Security-Token)["']?\s*[=:]\s*["']?)[^&#,;\s}\]"']+''',
  caseSensitive: false,
);

/// [error] as text safe to log for a sync or upload failure. URLs lose their
/// query (a presigned upload URL carries its signature and credential there),
/// and anything shaped like a token assignment is replaced with `<redacted>`.
String redactSyncDiagnosticText(Object? error) {
  return '$error'
      .replaceAllMapped(_urlQuery, (match) => '${match.group(1)}?<redacted>')
      .replaceAllMapped(
          _secretKeyValue, (match) => '${match.group(1)}<redacted>');
}

/// Follows a specific reason in the queue's error when other saved work
/// needs attention too, for whatever reason.
const otherWorkNeedsAttentionNote = 'Other saved work needs attention too.';

/// Whether [error] is the specific reason saved work needs attention, one
/// that [friendlyCloudSyncError] explains, rather than an edit that lost a
/// race to another. The sync button shows it in place of the generic
/// conflict text.
bool isSpecificAttentionReason(String error) {
  final lower = error.toLowerCase();
  return lower.contains('too large for cloud sync') ||
      lower.contains(lineupPageMismatchMessage.toLowerCase()) ||
      lower.contains(lineupLinkEndMissingMessage.toLowerCase()) ||
      lower.contains(lineupEndInUseMessage.toLowerCase()) ||
      lower.contains(pageDeletedMessage.toLowerCase());
}

/// A cloud change whose write to the durable outbox failed, or could not be
/// confirmed: it may not be on this device, and it was not sent.
const unverifiedCloudWorkMessage =
    'Icarus could not verify that this change was saved on this device. '
    'Nothing was sent. Keep this strategy open and retry.';

String friendlyCloudSyncError(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('strategy was deleted')) {
    return 'This strategy was deleted, so its unsent changes cannot be '
        'saved. Discard them from the library.';
  }
  if (lower.contains('unreadable saved work')) {
    return 'A saved cloud change could not be read. It remains on this '
        'device; keep this strategy open and recover the outbox before '
        'continuing.';
  }
  if (lower.contains('could not be verified in the durable outbox') ||
      lower.contains('could not be saved to the durable outbox')) {
    return unverifiedCloudWorkMessage;
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
  if (lower.contains('too large for cloud sync')) {
    return 'A saved change is too large for cloud sync. It remains saved on '
        'this device. Reduce it, then choose Keep mine to retry, or Use '
        'cloud to drop it.';
  }
  if (lower.contains(lineupPageMismatchMessage.toLowerCase())) {
    return 'This lineup clashes with one on another page, so it was not '
        'saved to the cloud. It remains on this device; Use cloud removes '
        'it here.';
  }
  if (lower.contains(lineupLinkEndMissingMessage.toLowerCase())) {
    return "This lineup's origin or landing spot isn't on this page in the "
        'cloud, so your change to it was not saved. Keep mine tries again; '
        'Use cloud drops your change.';
  }
  if (lower.contains(lineupEndInUseMessage.toLowerCase())) {
    return 'Another lineup in the cloud still uses this origin or landing '
        'spot, so it was not deleted. Keep mine tries again; Use cloud '
        'brings back that lineup here.';
  }
  if (lower.contains(pageDeletedMessage.toLowerCase())) {
    return 'The page these changes were on was deleted, so they were not '
        'saved. They remain on this device; Use cloud drops them.';
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
