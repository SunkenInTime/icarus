import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/src/convex_client_types.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/l10n/cloud_sync_error_text.dart';
import 'package:icarus/l10n/l10n.dart';

final _english = lookupAppLocalizations(const Locale('en'));

void main() {
  test('turns a forbidden Convex failure into a permission explanation', () {
    final message = friendlyCloudSyncError(
      _english,
      'ConvexFunctionException(FORBIDDEN, Forbidden) '
      '(retry paused after 8 attempts)',
    );

    expect(message, contains('does not have permission'));
    expect(message, contains('remain on this device'));
    expect(message, isNot(contains('ConvexFunctionException')));
  });

  test('says plainly when edit access is gone, and that the work is kept', () {
    expect(
      friendlyCloudSyncError(_english, editAccessRemovedMessage),
      'You no longer have edit access to this strategy. These changes stay '
      'on this device and were not saved to the cloud.',
    );
    // With other saved work waiting beside it, the reason still leads.
    expect(
      friendlyCloudSyncError(
        _english,
        '$editAccessRemovedMessage $otherWorkNeedsAttentionNote',
      ),
      editAccessRemovedMessage,
    );
    expect(isSpecificAttentionReason(editAccessRemovedMessage), isTrue);
  });

  test('explains a lineup that clashes with one on another page', () {
    final message = friendlyCloudSyncError(
      _english,
      'ConvexFunctionException(LINEUP_PAGE_MISMATCH, This lineup belongs to '
      'another page and cannot be moved)',
    );

    expect(message, contains('another page'));
    expect(message, contains('remains on this device'));
    expect(message, contains('Use cloud removes it here'));
    expect(message, isNot(contains('Keep mine')));
    expect(message, isNot(contains('LINEUP_PAGE_MISMATCH')));
  });

  test('explains a change to something a teammate deleted', () {
    final message = friendlyCloudSyncError(_english, teammateDeletedMessage);

    expect(message, contains('A teammate deleted what you changed'));
    expect(message, contains('Keep mine brings it back'));
    expect(message, contains('Use cloud lets it go'));
  });

  test('says when Keep mine cannot bring a deleted item back', () {
    final message = friendlyCloudSyncError(
      _english,
      teammateDeletedCannotRestoreMessage,
    );

    expect(message, contains('cannot bring it back'));
    expect(message, contains('Use cloud'));
    expect(message, isNot(contains('Keep mine')));
    expect(message, isNot(contains('matching revision')));
  });

  test('explains a lineup change saved in the old cloud format', () {
    final message = friendlyCloudSyncError(_english, retiredLineupOpMessage);

    expect(message, contains('older version of Icarus'));
    expect(message, contains('cannot be sent'));
    expect(message, contains('Use cloud'));
    expect(message, isNot(contains('Keep mine')));
  });

  test('explains a lineup group refused for overlapping another', () {
    final message = friendlyCloudSyncError(_english, lineupOverlapMessage);

    expect(message, contains('shares a spot'));
    expect(message, contains('not saved to the cloud'));
    expect(message, contains('Use cloud'));
    expect(message, isNot(contains(lineupOverlapMessage)));
    expect(isSpecificAttentionReason(lineupOverlapMessage), isTrue);
    // As the queue reports it beside other refused work.
    expect(
      isSpecificAttentionReason(
          '$lineupOverlapMessage. $otherWorkNeedsAttentionNote'),
      isTrue,
    );
  });

  test('a reason that is a whole sentence is not stopped twice', () {
    expect(
      withOtherWorkNeedsAttentionNote(incompletePageCopyMessage('Page 2')),
      "${incompletePageCopyMessage('Page 2')} $otherWorkNeedsAttentionNote",
    );
    expect(withOtherWorkNeedsAttentionNote(lineupOverlapMessage),
        '$lineupOverlapMessage. $otherWorkNeedsAttentionNote');
  });

  test('explains a page copy too large to make', () {
    final message = friendlyCloudSyncError(_english, pageTooLargeToCopyMessage);

    expect(message, contains('too large for the cloud to copy'));
    expect(message, contains('Keep mine'));
    expect(message, contains('Use cloud'));
    expect(isSpecificAttentionReason(pageTooLargeToCopyMessage), isTrue);
  });

  test('lineup refusals and oversized work are specific attention reasons', () {
    expect(isSpecificAttentionReason(lineupPageMismatchMessage), isTrue);
    expect(isSpecificAttentionReason(retiredLineupOpMessage), isTrue);
    expect(isSpecificAttentionReason(teammateDeletedMessage), isTrue);
    expect(
      isSpecificAttentionReason(teammateDeletedCannotRestoreMessage),
      isTrue,
    );
    expect(isSpecificAttentionReason(pageDeletedMessage), isTrue);
    expect(isSpecificAttentionReason(cloudOperationTooLargeMessage), isTrue);
    for (final reason in [
      'Some saved work needs attention.',
      'revision_mismatch',
      'The server rejected this change.',
    ]) {
      expect(isSpecificAttentionReason(reason), isFalse, reason: reason);
    }
  });

  test('does not expose unknown transport details', () {
    final message =
        friendlyCloudSyncError(_english, 'socket exploded at 10.0.0.4');

    expect(message, "Some changes haven't reached the cloud yet.");
  });

  test('does not promise local durability when the outbox is uncertain', () {
    final message = friendlyCloudSyncError(
      _english,
      'Cloud work could not be verified in the durable outbox. '
      'Nothing was sent.',
    );

    expect(message, contains('could not verify'));
    expect(message, contains('Nothing was sent'));
    expect(message, isNot(contains('remains saved')));
  });

  test('a failed outbox write is not called merely unsent', () {
    final message = friendlyCloudSyncError(
      _english,
      'Cloud work could not be saved to the durable outbox: '
      'Bad state: disk write failed',
    );

    expect(message, unverifiedCloudWorkMessage);
  });

  group('a server that needs a newer Icarus', () {
    test('is told on the web to reload', () {
      expect(
        clientUpgradeRequiredMessage(_english, isWeb: true),
        'Icarus was updated. Reload to keep syncing.',
      );
    });

    test('is told on desktop to install the update, once there is one', () {
      expect(
        clientUpgradeRequiredMessage(_english, isWeb: false),
        'Icarus was updated. Install the update to keep syncing.',
      );
      expect(
        clientUpgradeRequiredMessage(
          _english,
          isWeb: false,
          update: ClientUpdateAvailability.unavailable,
        ),
        "Icarus was updated, but the update isn't available for this app "
        'yet. Your saved work stays on this device and syncs once the update is '
        'installed.',
      );
      expect(
        clientUpgradeRequiredMessage(
          _english,
          isWeb: false,
          update: ClientUpdateAvailability.checking,
        ),
        isNot(contains('Install')),
      );
    });

    test('is known from the typed refusal', () {
      for (final error in <Object>[
        const ConvexFunctionException(
          code: ConvexErrorCode.clientUpgradeRequired,
          rawCode: 'CLIENT_UPGRADE_REQUIRED',
          message: 'Client upgrade required',
        ),
        const ConvexClientFunctionError(
          rawCode: 'CLIENT_UPGRADE_REQUIRED',
          message: 'Client upgrade required',
          data: null,
        ),
        const ConvexTransportError(
          rawCode: 'CLIENT_UPGRADE_REQUIRED',
          message: 'Client upgrade required',
        ),
      ]) {
        expect(isClientUpgradeRequiredError(error), isTrue, reason: '$error');
      }
    });

    test('is known from exactly the text a refusal leaves behind', () {
      for (final reason in [
        // What the outbox kept, in this build and the protocol 3 web build.
        'ConvexFunctionException(CLIENT_UPGRADE_REQUIRED, Client upgrade '
            'required)',
        clientUpgradeRequiredQueueError,
      ]) {
        expect(isClientUpgradeRequiredReason(reason), isTrue, reason: reason);
        expect(isClientUpgradeRequiredError(reason), isTrue, reason: reason);
        expect(
          friendlyCloudSyncError(_english, reason),
          clientUpgradeRequiredMessage(_english),
          reason: reason,
        );
      }
    });

    test('is not any other error, even one that mentions the code', () {
      for (final error in <Object?>[
        null,
        'ConvexFunctionException(FORBIDDEN, Forbidden)',
        'Cloud connection is offline.',
        // How an argument validation failure reads: a client that sends a
        // field the server no longer knows, or omits one it requires.
        'ConvexClientFunctionError(CONVEX_ERROR, ArgumentValidationError: '
            'Object is missing the required field `clientProtocolVersion`.)',
        // Text that only mentions the code is no refusal.
        'ConvexFunctionException(INVALID_PAYLOAD, name was '
            'CLIENT_UPGRADE_REQUIRED)',
        'CLIENT_UPGRADE_REQUIRED',
        StateError('CLIENT_UPGRADE_REQUIRED'),
        const ConvexFunctionException(
          code: ConvexErrorCode.invalidPayload,
          rawCode: 'INVALID_PAYLOAD',
          message: 'CLIENT_UPGRADE_REQUIRED',
        ),
      ]) {
        expect(isClientUpgradeRequiredError(error), isFalse, reason: '$error');
      }
      expect(
        friendlyCloudSyncError(
          _english,
          'ConvexFunctionException(INVALID_PAYLOAD, name was '
          'CLIENT_UPGRADE_REQUIRED)',
        ),
        isNot(clientUpgradeRequiredMessage(_english)),
      );
    });
  });
}
