import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/page_changes.dart';
import 'package:icarus/l10n/generated/app_localizations.dart';

// The words the user reads for a cloud sync reason. The reasons themselves
// (lib/collab/cloud_sync_error_message.dart) are kept in the outbox and
// matched as text, so they stay English and unchanged; only what is drawn
// from them is translated.

/// What the user is told when the server needs a newer Icarus, with the way
/// out their platform has. Desktop says what it can only once it knows
/// whether an update is there to install.
String clientUpgradeRequiredMessage(
  AppLocalizations l10n, {
  bool isWeb = kIsWeb,
  ClientUpdateAvailability update = ClientUpdateAvailability.available,
}) {
  if (isWeb) return l10n.syncErrorClientUpgradeWeb;
  return switch (update) {
    ClientUpdateAvailability.available => l10n.syncErrorClientUpgradeAvailable,
    ClientUpdateAvailability.checking => l10n.syncErrorClientUpgradeChecking,
    ClientUpdateAvailability.unavailable =>
      l10n.syncErrorClientUpgradeUnavailable,
  };
}

/// What the user is told about a page delete held for them (see
/// heldPageDelete). A page this device could not check is never said to
/// have changed: nothing says it did.
String heldPageDeleteMessage(
  AppLocalizations l10n,
  ({String page, bool checked}) held,
) =>
    held.checked
        ? l10n.syncErrorHeldPageDeleteChanged(held.page)
        : l10n.syncErrorHeldPageDeleteUnchecked(held.page);

/// What the user is told about an [incompletePageCopyMessage], alone or
/// followed by [otherWorkNeedsAttentionNote]. A reason of another shape is
/// shown as it was saved.
String _incompletePageCopyText(AppLocalizations l10n, String raw) {
  final pageName = incompletePageCopyPageName(raw);
  if (pageName == null) return raw;
  final reason = incompletePageCopyMessage(pageName);
  if (raw == reason) return l10n.syncErrorIncompletePageCopy(pageName);
  if (raw == withOtherWorkNeedsAttentionNote(reason)) {
    return l10n.syncErrorIncompletePageCopyWithOtherWork(pageName);
  }
  return raw;
}

String friendlyCloudSyncError(AppLocalizations l10n, String raw) {
  if (isClientUpgradeRequiredReason(raw)) {
    return clientUpgradeRequiredMessage(l10n);
  }
  if (heldPageDelete(raw) case final held?) {
    return heldPageDeleteMessage(l10n, held);
  }
  final lower = raw.toLowerCase();
  if (isIncompletePageCopyReason(lower)) {
    return _incompletePageCopyText(l10n, raw);
  }
  if (lower.contains('strategy was deleted')) {
    return l10n.syncErrorStrategyDeleted;
  }
  if (lower.contains('unreadable saved work')) {
    return l10n.syncErrorUnreadableSavedWork;
  }
  if (lower.contains('could not be verified in the durable outbox') ||
      lower.contains('could not be saved to the durable outbox')) {
    return l10n.syncErrorUnverifiedCloudWork;
  }
  if (lower.contains(editAccessRemovedMessage.toLowerCase())) {
    return l10n.syncErrorEditAccessRemoved;
  }
  if (lower.contains('forbidden')) {
    return l10n.syncErrorForbidden;
  }
  if (lower.contains('retry paused')) {
    return l10n.syncErrorRetryPaused;
  }
  if (lower.contains(pageTooLargeToCopyMessage.toLowerCase())) {
    return l10n.syncErrorPageTooLargeToCopy;
  }
  if (lower.contains('too large for cloud sync')) {
    return l10n.syncErrorTooLargeForCloudSync;
  }
  if (lower.contains(lineupOverlapMessage.toLowerCase())) {
    return l10n.syncErrorLineupOverlap;
  }
  if (lower.contains(lineupPageMismatchMessage.toLowerCase())) {
    return l10n.syncErrorLineupPageMismatch;
  }
  if (lower.contains(teammateDeletedCannotRestoreMessage.toLowerCase())) {
    return l10n.syncErrorTeammateDeletedCannotRestore;
  }
  if (lower.contains(teammateDeletedMessage.toLowerCase())) {
    return l10n.syncErrorTeammateDeleted;
  }
  if (lower.contains(retiredLineupOpMessage.toLowerCase())) {
    return l10n.syncErrorRetiredLineupOp;
  }
  if (lower.contains(undrawableWorkMessage.toLowerCase())) {
    return l10n.syncErrorUndrawableWork;
  }
  if (lower.contains(pageDeletedMessage.toLowerCase())) {
    return l10n.syncErrorPageDeleted;
  }
  if (lower.contains('needs attention')) {
    return l10n.syncErrorConflict;
  }
  if (lower.contains('cannot be retried automatically')) {
    return l10n.syncErrorCannotRetryAutomatically;
  }
  if (lower.contains('auth')) {
    return l10n.syncErrorSessionExpired;
  }
  if (lower.contains('offline') || lower.contains('connection')) {
    return l10n.syncErrorUnreachable;
  }
  if (lower.contains('setup is not ready')) {
    return l10n.syncErrorStartingUp;
  }
  return l10n.syncErrorGeneric;
}
