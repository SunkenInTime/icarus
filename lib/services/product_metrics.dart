import 'dart:async';

import 'package:icarus/services/analytics_service.dart';

/// The anonymous product events about cloud: whether people get into it
/// (sign-in, moving their library, library size), whether it keeps its
/// promise (conflicts, failures, time offline), and whether they work on it
/// together (shares, people present). Sent through [AnalyticsService], so
/// they are off when analytics is off. Every property is a fixed word or a
/// bucket: no ids, names, emails, messages or content.
class ProductMetrics {
  ProductMetrics({
    Future<void> Function(String event, Map<String, Object> properties)?
        capture,
  }) : _capture = capture ??
            ((event, properties) => AnalyticsService.instance
                .capture(event, properties: properties));

  static final ProductMetrics instance = ProductMetrics();

  final Future<void> Function(String event, Map<String, Object> properties)
      _capture;

  void _send(String event, Map<String, Object> properties) =>
      unawaited(_capture(event, properties));

  // Cloud adoption.

  /// A sign-in that finished: [method] is `discord` or `email`; [outcome]
  /// is `success` or `failed`.
  void signIn({required String method, required bool succeeded}) =>
      _send('cloud_sign_in', {
        'method': method,
        'outcome': succeeded ? 'success' : 'failed',
      });

  /// An email sign-up that finished: `confirmation_sent`, `signed_in` or
  /// `failed`.
  void signUp(String outcome) => _send('cloud_sign_up', {'outcome': outcome});

  /// A move of local work to cloud that finished. [kind] is `strategy` or
  /// `folder`; [outcome] is `moved`, `partial`, `failed`, `not_moved` or
  /// `changed_meanwhile`.
  void moveToCloud({
    required String kind,
    required int strategies,
    required String outcome,
  }) =>
      _send('move_to_cloud', {
        'kind': kind,
        'strategies': countBucket(strategies),
        'outcome': outcome,
      });

  /// The local library's size, once a start.
  void localLibrary({required int strategies, required int folders}) =>
      _send('local_library', {
        'strategies': countBucket(strategies),
        'folders': countBucket(folders),
      });

  /// The cloud library's size, once a session (desktop, where the offline
  /// copy lists it).
  void cloudLibrary({required int owned, required int total}) =>
      _send('cloud_library', {
        'owned_strategies': countBucket(owned),
        'strategies': countBucket(total),
      });

  // Sync health.

  /// Conflicts told to the user at once: how many, and the first one's
  /// reason ([reason] is a fixed code, see [syncReason]).
  void conflictShown({required int count, required String reason}) =>
      _send('sync_conflict_shown', {
        'conflicts': countBucket(count),
        'reason': reason,
      });

  /// What the user chose for work the cloud refused: `keep_mine`, `retry`,
  /// `use_cloud`, `keep_both`, `keep_page` or `delete_anyway`.
  void conflictResolved(String choice) =>
      _send('sync_conflict_resolved', {'choice': choice});

  /// Changes the server refused for good, from one batch, by reason.
  void syncFailed({required String reason, required int changes}) =>
      _send('sync_failed', {
        'reason': reason,
        'changes': countBucket(changes),
      });

  /// A stretch offline that ended: how long, how it ended (`online`,
  /// `signed_out` or `incident`), and how many changes were waiting.
  void offlineSession({
    required Duration duration,
    required String ended,
    required int queuedChanges,
  }) =>
      _send('offline_session', {
        'duration': durationBucket(duration),
        'ended': ended,
        'queued_changes': countBucket(queuedChanges),
      });

  // Working together.

  /// A share link made: [role] `viewer` or `editor`; [target] `strategy` or
  /// `folder`.
  void shareLinkCreated({required String role, required String target}) =>
      _send('share_link_created', {'role': role, 'target': target});

  /// Someone joined through a share link they didn't already have access by.
  void shareJoined({required String role, required String target}) =>
      _send('share_joined', {'role': role, 'target': target});

  /// An owner changed who has access: `role_changed` or `removed`; or the
  /// user left something shared with them: `left`.
  void shareMembership(String change) =>
      _send('share_membership', {'change': change});

  /// One visit to a cloud strategy: the most other people present at once,
  /// and how long it lasted.
  void liveVisit({required int peakPeople, required Duration duration}) =>
      _send('live_visit', {
        'peak_people': peopleBucket(peakPeople),
        'duration': durationBucket(duration),
      });
}

/// [count] as a bucket, so sizes are comparable without being exact.
String countBucket(int count) => switch (count) {
      <= 0 => '0',
      1 => '1',
      <= 10 => '2-10',
      <= 50 => '11-50',
      <= 200 => '51-200',
      _ => '200+',
    };

/// [people] other people present, as a bucket.
String peopleBucket(int people) => switch (people) {
      <= 0 => '0',
      1 => '1',
      2 => '2',
      <= 4 => '3-4',
      _ => '5+',
    };

/// [duration] as a bucket.
String durationBucket(Duration duration) {
  final minutes = duration.inMinutes;
  if (minutes < 1) return '<1m';
  if (minutes < 5) return '1-5m';
  if (minutes < 30) return '5-30m';
  if (minutes < 120) return '30m-2h';
  return '2h+';
}

/// The server's reasons and error codes are fixed words; anything else (a
/// message) is reported as `other`.
String syncReason(String? reason) {
  if (reason == null) return 'other';
  return RegExp(r'^[a-z][a-z0-9_]{0,40}$').hasMatch(reason) ||
          RegExp(r'^[A-Z][A-Z0-9_]{0,40}$').hasMatch(reason)
      ? reason
      : 'other';
}
