import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';

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
}
