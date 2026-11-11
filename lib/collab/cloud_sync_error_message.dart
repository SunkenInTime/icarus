import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/generated/convex_error_codes.dart';
import 'package:icarus/collab/page_changes.dart';
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

/// [reason] followed by [otherWorkNeedsAttentionNote], stopped once: some
/// reasons are whole sentences already (incompletePageCopyMessage).
String withOtherWorkNeedsAttentionNote(String reason) =>
    '$reason${reason.endsWith('.') ? '' : '.'} $otherWorkNeedsAttentionNote';

/// Why saved work stopped being sent: the server refused it because this
/// account can no longer edit the strategy (its owner made them a viewer, or
/// removed them). The work is kept, paused; Retry sends it again, which
/// lands once edit access is back.
const editAccessRemovedMessage =
    'You no longer have edit access to this strategy. These changes stay on '
    'this device and were not saved to the cloud.';

/// Whether [error] is the specific reason saved work needs attention, one
/// that [friendlyCloudSyncError] explains, rather than an edit that lost a
/// race to another. The sync button shows it in place of the generic
/// conflict text.
bool isSpecificAttentionReason(String error) {
  final lower = error.toLowerCase();
  return heldPageDelete(error) != null ||
      lower.contains('too large for cloud sync') ||
      lower.contains(editAccessRemovedMessage.toLowerCase()) ||
      lower.contains(lineupPageMismatchMessage.toLowerCase()) ||
      lower.contains(lineupOverlapMessage.toLowerCase()) ||
      lower.contains(retiredLineupOpMessage.toLowerCase()) ||
      lower.contains(teammateDeletedMessage.toLowerCase()) ||
      lower.contains(pageDeletedMessage.toLowerCase()) ||
      lower.contains(undrawableWorkMessage.toLowerCase()) ||
      lower.contains(pageTooLargeToCopyMessage.toLowerCase()) ||
      lower.contains(_incompletePageCopyMark);
}

/// Why the add of a page "+" copied on this computer waits instead of being
/// sent: a crash or failed write left only part of the copy on disk (see
/// DurableOutboxRecord.pageCopyKeys). Its items wait with it. Nothing the
/// user made is lost, since the copy can be made again from [pageName]'s
/// source.
String incompletePageCopyMessage(String pageName) =>
    'The copy of $pageName $_incompletePageCopyMark, so it was not sent. '
    'Copy the page again, or choose Use cloud to discard it.';

const _incompletePageCopyMark = "didn't finish saving on this computer";

/// The page name in [reason], when it starts as an
/// [incompletePageCopyMessage] does; null otherwise.
String? incompletePageCopyPageName(String reason) {
  const start = 'The copy of ';
  final end = reason.lastIndexOf(' $_incompletePageCopyMark');
  if (!reason.startsWith(start) || end < start.length) return null;
  return reason.substring(start.length, end);
}

/// Whether [reason] is an [incompletePageCopyMessage].
bool isIncompletePageCopyReason(String? reason) =>
    reason != null && reason.contains(_incompletePageCopyMark);

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

/// Whether the update a refused desktop build needs can be installed yet.
enum ClientUpdateAvailability { available, checking, unavailable }
