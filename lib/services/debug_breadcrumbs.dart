import 'dart:collection';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:icarus/providers/in_app_debug_provider.dart'
    show formatDebugLogTimestamp;

/// The last few things the user and the app did, kept in memory so an error
/// in the debug report says what led up to it.
///
/// Only the shape of what happened goes in, never what the user wrote: a
/// text edit is its length, a strategy is local or cloud, not its name.
/// The same step repeated back to back is one line with a count, so typing
/// a sentence doesn't push everything else out.
class DebugBreadcrumbs {
  static const int capacity = 40;

  static final _crumbs = ListQueue<_Crumb>();

  /// Records that [what] happened in [area]. [detail] is the latest
  /// particulars; a repeat of the same [area] and [what] keeps the newest.
  static void add(String area, String what, {String? detail}) {
    final now = DateTime.now();
    final last = _crumbs.isEmpty ? null : _crumbs.last;
    if (last != null && last.area == area && last.what == what) {
      last
        ..count += 1
        ..lastAt = now
        ..detail = detail;
      return;
    }
    _crumbs.addLast(_Crumb(area: area, what: what, detail: detail, at: now));
    while (_crumbs.length > capacity) {
      _crumbs.removeFirst();
    }
  }

  /// The trail, oldest first, one line each, or null before anything
  /// happened.
  static String? describe() {
    if (_crumbs.isEmpty) return null;
    return _crumbs.map((crumb) => crumb.line).join('\n');
  }

  @visibleForTesting
  static void clear() => _crumbs.clear();
}

class _Crumb {
  _Crumb({
    required this.area,
    required this.what,
    required this.detail,
    required this.at,
  }) : lastAt = at;

  final String area;
  final String what;
  final DateTime at;
  String? detail;
  DateTime lastAt;
  int count = 1;

  String get line {
    final buffer = StringBuffer('${_time(at)}  $area: $what');
    if (detail != null && detail!.isNotEmpty) buffer.write(' ($detail)');
    if (count > 1) buffer.write(' x$count, last ${_time(lastAt)}');
    return buffer.toString();
  }

  /// The clock time with milliseconds: two steps a frame apart are the
  /// ones that race.
  static String _time(DateTime time) {
    final full = formatDebugLogTimestamp(time);
    final millis = time.millisecond.toString().padLeft(3, '0');
    return '${full.substring(full.indexOf(' ') + 1)}.$millis';
  }
}
