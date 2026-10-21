import 'dart:async';

import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/services/analytics_service.dart';

/// Counts the cloud work this install asks of the server, and reports the
/// counts as one anonymous `cloud_usage` event at most every
/// [reportInterval]. Convex bills the database bytes each call reads, and
/// what a call reads is measured offline per action (the cost harness), so
/// these counts are what it takes to know what a real user costs. Counts
/// only: no ids, names or content.
///
/// The counts are kept on disk as they change, and sent with the first
/// count once [reportInterval] has passed since the first one, or on the
/// next start ([reportLeftover]) when the session ends before that.
class CloudUsageMeter {
  CloudUsageMeter({
    Future<void> Function(String event, Map<String, Object> properties)? report,
    Map<String, int>? Function()? load,
    Future<void> Function(Map<String, int>? counts)? save,
    DateTime Function()? now,
    this.reportInterval = const Duration(minutes: 30),
  })  : _report = report ??
            ((event, properties) => AnalyticsService.instance
                .capture(event, properties: properties)),
        _load = load ?? _loadFromDisk,
        _save = save ?? _saveToDisk,
        _now = now ?? DateTime.now;

  static final CloudUsageMeter instance = CloudUsageMeter();

  static const _pendingKey = 'cloud_usage_pending';

  final Future<void> Function(String event, Map<String, Object> properties)
      _report;
  final Map<String, int>? Function() _load;
  final Future<void> Function(Map<String, int>? counts) _save;
  final DateTime Function() _now;
  final Duration reportInterval;

  final _counts = <String, int>{};
  DateTime? _firstCountAt;

  /// A batch of [ops] edits sent to the server (ops:applyBatch).
  void batchSent(int ops) => _count({'batches_sent': 1, 'ops_sent': ops});

  /// A page watched live, holding [rows] elements and lineups.
  void pageWatched(int rows) =>
      _count({'pages_watched': 1, 'page_rows_watched': rows});

  /// The offline copy's pass over a library of [strategies].
  void copyPass(int strategies) =>
      _count({'copy_passes': 1, 'copy_strategies_listed': strategies});

  /// A strategy read whole for the offline copy, holding [rows] elements and
  /// lineups.
  void copyFullRead(int rows) =>
      _count({'copy_full_reads': 1, 'copy_rows_read': rows});

  void _count(Map<String, int> by) {
    for (final MapEntry(:key, :value) in by.entries) {
      _counts[key] = (_counts[key] ?? 0) + value;
    }
    final first = _firstCountAt ??= _now();
    if (_now().difference(first) >= reportInterval) {
      unawaited(_reportCounted());
    } else {
      unawaited(_save(Map.of(_counts)));
    }
  }

  /// Sends the counts a session left unreported, from disk. Call once at
  /// start, before anything is counted.
  Future<void> reportLeftover() async {
    final leftover = _load();
    if (leftover == null || leftover.isEmpty) return;
    await _save(null);
    await _send(leftover, leftover: true);
  }

  Future<void> _reportCounted() async {
    final counts = Map.of(_counts);
    _counts.clear();
    _firstCountAt = null;
    await _save(null);
    await _send(counts, leftover: false);
  }

  Future<void> _send(Map<String, int> counts, {required bool leftover}) =>
      _report('cloud_usage', {
        ...counts,
        'interval_minutes': reportInterval.inMinutes,
        'from_last_session': leftover,
      });

  static Map<String, int>? _loadFromDisk() {
    if (!Hive.isBoxOpen(AnalyticsService.storageBoxName)) return null;
    final stored =
        Hive.box<dynamic>(AnalyticsService.storageBoxName).get(_pendingKey);
    if (stored is! Map) return null;
    return {
      for (final MapEntry(:key, :value) in stored.entries)
        if (key is String && value is int) key: value,
    };
  }

  static Future<void> _saveToDisk(Map<String, int>? counts) async {
    if (!Hive.isBoxOpen(AnalyticsService.storageBoxName)) return;
    final box = Hive.box<dynamic>(AnalyticsService.storageBoxName);
    if (counts == null) {
      await box.delete(_pendingKey);
    } else {
      await box.put(_pendingKey, counts);
    }
  }
}
