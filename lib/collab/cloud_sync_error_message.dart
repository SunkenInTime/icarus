import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/generated/convex_error_codes.dart';
import 'package:icarus/collab/src/convex_client_types.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

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

/// The server's code for a build whose cloud protocol it no longer accepts.
const clientUpgradeRequiredCode = 'CLIENT_UPGRADE_REQUIRED';

/// The queue's error while the server refuses this build.
const clientUpgradeRequiredQueueError =
    'Cloud sync is held until Icarus is updated ($clientUpgradeRequiredCode).';

/// Whether [error] is the server refusing this build. Nothing the build
/// sends or reads will be accepted until it is reloaded (web) or updated
/// (desktop). It is never the user's fault, nor the fault of the work it
/// refused. Text is matched by [isClientUpgradeRequiredReason].
bool isClientUpgradeRequiredError(Object? error) => switch (error) {
      ConvexFunctionException(:final rawCode) ||
      ConvexClientFunctionError(:final rawCode) ||
      ConvexTransportError(:final rawCode) =>
        rawCode == clientUpgradeRequiredCode,
      String() => isClientUpgradeRequiredReason(error),
      _ => false,
    };

/// Whether [reason], an error kept as text, is the server refusing a build:
/// exactly the text this build keeps, or the text a refused send left in the
/// outbox ('$error' of the generated client's exception, which the protocol 3
/// web build wrote too). Text that merely mentions the code is not.
bool isClientUpgradeRequiredReason(String? reason) =>
    reason == clientUpgradeRequiredQueueError || reason == _keptRefusal;

const _keptRefusal =
    'ConvexFunctionException($clientUpgradeRequiredCode, Client upgrade required)';

/// What the user is told when the server needs a newer Icarus, with the way
/// out their platform has. Desktop says what it can only once it knows
/// whether an update is there to install.
String clientUpgradeRequiredMessage({
  bool isWeb = kIsWeb,
  ClientUpdateAvailability update = ClientUpdateAvailability.available,
}) {
  if (isWeb) return 'Icarus was updated. Reload to keep syncing.';
  return switch (update) {
    ClientUpdateAvailability.available =>
      'Icarus was updated. Install the update to keep syncing.',
    ClientUpdateAvailability.checking =>
      'Icarus was updated. Looking for the update this app needs to keep '
          'syncing.',
    ClientUpdateAvailability.unavailable =>
      "Icarus was updated, but the update isn't available for this app yet. "
          'Your saved work stays on this device and syncs once the update is '
          'installed.',
  };
}

/// Whether the update a refused desktop build needs can be installed yet.
enum ClientUpdateAvailability { available, checking, unavailable }

String friendlyCloudSyncError(String raw) {
  if (isClientUpgradeRequiredReason(raw)) {
    return clientUpgradeRequiredMessage();
  }
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
