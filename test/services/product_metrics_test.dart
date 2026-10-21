import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/product_metrics.dart';

void main() {
  late List<(String, Map<String, Object>)> sent;
  late ProductMetrics metrics;

  setUp(() {
    sent = [];
    metrics = ProductMetrics(
      capture: (event, properties) async => sent.add((event, properties)),
    );
  });

  test('sizes and times go out as buckets, not exact values', () {
    expect(
      [0, 1, 2, 10, 11, 50, 51, 200, 201].map(countBucket),
      ['0', '1', '2-10', '2-10', '11-50', '11-50', '51-200', '51-200', '200+'],
    );
    expect([0, 1, 2, 3, 4, 5, 9].map(peopleBucket),
        ['0', '1', '2', '3-4', '3-4', '5+', '5+']);
    expect(
      [
        const Duration(seconds: 59),
        const Duration(minutes: 4),
        const Duration(minutes: 29),
        const Duration(minutes: 119),
        const Duration(hours: 3),
      ].map(durationBucket),
      ['<1m', '1-5m', '5-30m', '30m-2h', '2h+'],
    );
  });

  test('only fixed reason codes are reported; messages become other', () {
    expect(syncReason('field_conflict'), 'field_conflict');
    expect(syncReason('FORBIDDEN'), 'FORBIDDEN');
    expect(syncReason("You can't edit Retake B anymore."), 'other');
    expect(syncReason('ana@example.com'), 'other');
    expect(syncReason(null), 'other');
  });

  test('each event carries fixed words and buckets only', () {
    metrics
      ..signIn(method: 'discord', succeeded: true)
      ..signUp('confirmation_sent')
      ..moveToCloud(kind: 'folder', strategies: 23, outcome: 'partial')
      ..localLibrary(strategies: 140, folders: 6)
      ..cloudLibrary(owned: 12, total: 15)
      ..conflictShown(count: 2, reason: 'field_conflict')
      ..conflictResolved('keep_both')
      ..syncFailed(reason: 'FORBIDDEN', changes: 3)
      ..offlineSession(
        duration: const Duration(minutes: 12),
        ended: 'online',
        queuedChanges: 4,
      )
      ..shareLinkCreated(role: 'editor', target: 'folder')
      ..shareJoined(role: 'viewer', target: 'strategy')
      ..shareMembership('removed')
      ..liveVisit(peakPeople: 3, duration: const Duration(minutes: 45));

    expect([
      for (final (event, properties) in sent) [event, properties]
    ], [
      [
        'cloud_sign_in',
        {'method': 'discord', 'outcome': 'success'}
      ],
      [
        'cloud_sign_up',
        {'outcome': 'confirmation_sent'}
      ],
      [
        'move_to_cloud',
        {'kind': 'folder', 'strategies': '11-50', 'outcome': 'partial'}
      ],
      [
        'local_library',
        {'strategies': '51-200', 'folders': '2-10'}
      ],
      [
        'cloud_library',
        {'owned_strategies': '11-50', 'strategies': '11-50'}
      ],
      [
        'sync_conflict_shown',
        {'conflicts': '2-10', 'reason': 'field_conflict'}
      ],
      [
        'sync_conflict_resolved',
        {'choice': 'keep_both'}
      ],
      [
        'sync_failed',
        {'reason': 'FORBIDDEN', 'changes': '2-10'}
      ],
      [
        'offline_session',
        {'duration': '5-30m', 'ended': 'online', 'queued_changes': '2-10'}
      ],
      [
        'share_link_created',
        {'role': 'editor', 'target': 'folder'}
      ],
      [
        'share_joined',
        {'role': 'viewer', 'target': 'strategy'}
      ],
      [
        'share_membership',
        {'change': 'removed'}
      ],
      [
        'live_visit',
        {'peak_people': '3-4', 'duration': '30m-2h'}
      ],
    ]);
  });
}
