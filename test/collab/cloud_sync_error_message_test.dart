import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';

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
