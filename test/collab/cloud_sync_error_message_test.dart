import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/src/convex_client_types.dart';

void main() {
  test('turns a forbidden Convex failure into a permission explanation', () {
    final message = friendlyCloudSyncError(
      'ConvexFunctionException(FORBIDDEN, Forbidden) '
      '(retry paused after 8 attempts)',
    );

    expect(message, contains('does not have permission'));
    expect(message, contains('remain on this device'));
    expect(message, isNot(contains('ConvexFunctionException')));
  });

  test('explains a lineup that clashes with one on another page', () {
    final message = friendlyCloudSyncError(
      'ConvexFunctionException(LINEUP_PAGE_MISMATCH, This lineup belongs to '
      'another page and cannot be moved)',
    );

    expect(message, contains('another page'));
    expect(message, contains('remains on this device'));
    expect(message, contains('Use cloud removes it here'));
    expect(message, isNot(contains('Keep mine')));
    expect(message, isNot(contains('LINEUP_PAGE_MISMATCH')));
  });

  test('explains a lineup whose origin or landing is gone', () {
    final message = friendlyCloudSyncError(
      "ConvexFunctionException(LINEUP_LINK_END_MISSING, This lineup's origin "
      'or landing spot is no longer on the page)',
    );

    expect(message, contains("origin or landing spot isn't on this page"));
    expect(message, contains('was not saved'));
    expect(message, contains('Keep mine tries again'));
    expect(message, contains('Use cloud drops your change'));
    expect(message, isNot(contains('LINEUP_LINK_END_MISSING')));
  });

  test('lineup refusals and oversized work are specific attention reasons', () {
    expect(isSpecificAttentionReason(lineupLinkEndMissingMessage), isTrue);
    expect(isSpecificAttentionReason(lineupPageMismatchMessage), isTrue);
    expect(isSpecificAttentionReason(lineupEndInUseMessage), isTrue);
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

  test('explains an origin or landing another lineup still uses', () {
    final message = friendlyCloudSyncError(
      'ConvexFunctionException(LINEUP_END_IN_USE, Another lineup still uses '
      'this origin or landing spot)',
    );

    expect(message, contains('still uses this origin or landing spot'));
    expect(message, contains('was not deleted'));
    expect(message, contains('Keep mine tries again'));
    expect(message, contains('Use cloud brings back that lineup'));
    expect(message, isNot(contains('LINEUP_END_IN_USE')));
  });

  test('does not expose unknown transport details', () {
    final message = friendlyCloudSyncError('socket exploded at 10.0.0.4');

    expect(message, "Some changes haven't reached the cloud yet.");
  });

  test('does not promise local durability when the outbox is uncertain', () {
    final message = friendlyCloudSyncError(
      'Cloud work could not be verified in the durable outbox. '
      'Nothing was sent.',
    );

    expect(message, contains('could not verify'));
    expect(message, contains('Nothing was sent'));
    expect(message, isNot(contains('remains saved')));
  });

  test('a failed outbox write is not called merely unsent', () {
    final message = friendlyCloudSyncError(
      'Cloud work could not be saved to the durable outbox: '
      'Bad state: disk write failed',
    );

    expect(message, unverifiedCloudWorkMessage);
  });

  group('a server that needs a newer Icarus', () {
    test('is told on the web to reload', () {
      expect(
        clientUpgradeRequiredMessage(isWeb: true),
        'Icarus was updated. Reload to keep syncing.',
      );
    });

    test('is told on desktop to install the update', () {
      expect(
        clientUpgradeRequiredMessage(isWeb: false),
        'Icarus was updated. Install the update to keep syncing.',
      );
    });

    test('is known from the refusal, however it was kept', () {
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
        // The text an older build's outbox kept, paused after retries.
        'ConvexFunctionException(CLIENT_UPGRADE_REQUIRED, Client upgrade '
            'required)',
        clientUpgradeRequiredQueueError,
      ]) {
        expect(isClientUpgradeRequiredError(error), isTrue, reason: '$error');
        expect(
          friendlyCloudSyncError('$error'),
          clientUpgradeRequiredMessage(),
          reason: '$error',
        );
      }
    });

    test('is not any other refusal', () {
      for (final error in <Object?>[
        null,
        'ConvexFunctionException(FORBIDDEN, Forbidden)',
        'Cloud connection is offline.',
        // How an argument validation failure reads: a client that sends a
        // field the server no longer knows, or omits one it requires.
        'ConvexClientFunctionError(CONVEX_ERROR, ArgumentValidationError: '
            'Object is missing the required field `clientProtocolVersion`.)',
      ]) {
        expect(isClientUpgradeRequiredError(error), isFalse, reason: '$error');
      }
      expect(
        friendlyCloudSyncError('ConvexFunctionException(FORBIDDEN, Forbidden)'),
        isNot(clientUpgradeRequiredMessage()),
      );
    });
  });
}
