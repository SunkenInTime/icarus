import 'package:icarus_library/icarus_library.dart';

typedef RetiringTiming = ({Duration quiet, Duration again});

final class Retiring {
  static const list = '';

  final _active = <String, DateTime>{};
  final _clear = <String>{};
  final _readFor = <(String, String), (Set<(int, int)>, DateTime)>{};

  bool mayRetire(String id) => !_clear.contains(id);

  void active(String id, DateTime at) {
    _active[id] = at;
    _clear.remove(id);
  }

  ({String? read, DateTime? due}) next(
    String id,
    CloudStrategy cloud,
    DateTime now,
    RetiringTiming timing,
  ) {
    final landed = cloud.queue.landed;
    if (landed.isEmpty) {
      _clear.add(id);
      return (read: null, due: null);
    }
    final quietAt = (_active[id] ??= now).add(timing.quiet);
    if (quietAt.isAfter(now)) return (read: null, due: quietAt);
    final byPage = _byPage(cloud);
    DateTime? due;
    for (final MapEntry(key: page, value: works) in byPage.entries) {
      final (seen, at) = _readFor[(id, page)] ?? (const <(int, int)>{}, null);
      if (seen.containsAll(works)) continue;
      final again = at?.add(timing.again);
      if (again == null || !again.isAfter(now)) return (read: page, due: null);
      if (due == null || again.isBefore(due)) due = again;
    }
    if (due == null) _clear.add(id);
    return (read: null, due: due);
  }

  void read(String id, String page, CloudStrategy cloud, DateTime at) {
    _readFor[(id, page)] = (_byPage(cloud)[page] ?? const {}, at);
  }

  static Map<String, Set<(int, int)>> _byPage(CloudStrategy cloud) {
    final byPage = <String, Set<(int, int)>>{};
    for (final work in cloud.queue.landed) {
      final page = switch (targetOf(work.op)) {
        StrategyTarget() || PageTarget() || SettingsTarget() => list,
        final row => pagesNeeded(work.op).firstOrNull ??
            cloud.queue.shown.rows[row]?.page ??
            list,
      };
      (byPage[page] ??= {}).add((work.attempt, work.position));
    }
    return byPage;
  }
}
