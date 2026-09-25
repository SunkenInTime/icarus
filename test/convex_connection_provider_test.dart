import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';

void main() {
  test('the connection snapshot follows the connection after its first read',
      () async {
    // On web the socket is still opening when the app starts. A snapshot
    // that kept its first read said offline forever, so the op queue never
    // sent an edit.
    final changes = StreamController<bool>();
    addTearDown(changes.close);
    final container = ProviderContainer(overrides: [
      convexConnectionProvider.overrideWith((ref) => changes.stream),
    ]);
    addTearDown(container.dispose);
    container.listen(convexConnectionProvider, (_, __) {});

    changes.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(convexConnectionSnapshotProvider), isFalse);

    changes.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(convexConnectionSnapshotProvider), isTrue);

    changes.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(convexConnectionSnapshotProvider), isFalse);
  });

  group('redactSyncDiagnosticText', () {
    test('drops the query of a presigned upload URL', () {
      const error = 'ClientException: Failed to fetch, uri=https://abc.r2.'
          'cloudflarestorage.com/icarus-media/strategies/s/images/i/1.png'
          '?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=key%2F2026'
          '&X-Amz-Signature=deadbeef';

      final redacted = redactSyncDiagnosticText(error);

      expect(
        redacted,
        'ClientException: Failed to fetch, uri=https://abc.r2.'
        'cloudflarestorage.com/icarus-media/strategies/s/images/i/1.png'
        '?<redacted>',
      );
    });

    test('hides token assignments outside URLs', () {
      expect(
        redactSyncDiagnosticText('failed access_token=abc.def refresh_token: '
            'xyz X-Amz-Signature=beef'),
        'failed access_token=<redacted> refresh_token: <redacted> '
        'X-Amz-Signature=<redacted>',
      );
    });

    test('leaves ordinary errors readable', () {
      expect(
        redactSyncDiagnosticText(StateError('Cloud connection is offline.')),
        'Bad state: Cloud connection is offline.',
      );
      expect(
        redactSyncDiagnosticText('see https://example.com/docs for help'),
        'see https://example.com/docs for help',
      );
    });
  });
}
