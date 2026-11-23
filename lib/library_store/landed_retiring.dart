import 'package:icarus_library/icarus_library.dart';

typedef RetiringTiming = ({
  Duration quiet,
  Duration again,
  Duration stuck,
  int rounds,
});

typedef RetireRead = ({Set<(int, int)> works, DateTime at, int rounds});

typedef RetireReads = Map<String, RetireRead>;

final class Retiring {
  static const list = '';

  final _active = <String, DateTime>{};
  final _clear = <String>{};

  bool mayRetire(String id) => !_clear.contains(id);

  void active(String id, DateTime at) {
    _active[id] = at;
    _clear.remove(id);
  }

  void looked(String id, CloudStrategy cloud, DateTime now) {
    if (cloud.queue.landed.isEmpty) {
      _clear.add(id);
      return;
    }
    _active.putIfAbsent(id, () => now);
  }

  ({String? read, DateTime? due}) next(
    String id,
    CloudStrategy cloud,
    DateTime now,
    RetiringTiming timing,
    RetireReads reads,
  ) {
    if (cloud.queue.landed.isEmpty) return (read: null, due: null);
    final quietAt = (_active[id] ?? now).add(timing.quiet);
    if (quietAt.isAfter(now)) return (read: null, due: quietAt);
    DateTime? due;
    for (final MapEntry(key: page, value: works) in _byPage(cloud).entries) {
      final prior = reads[page];
      if (prior == null) return (read: page, due: null);
      final stuck =
          prior.works.containsAll(works) && prior.rounds >= timing.rounds;
      final again = prior.at.add(stuck ? timing.stuck : timing.again);
      if (!again.isAfter(now)) return (read: page, due: null);
      if (due == null || again.isBefore(due)) due = again;
    }
    return (read: null, due: due);
  }

  void settled(String id, ({String? read, DateTime? due}) next) {
    if (next == (read: null, due: null)) _clear.add(id);
  }

  static RetireReads read(
    RetireReads reads,
    String page,
    CloudStrategy cloud,
    DateTime at,
  ) {
    final works = _byPage(cloud)[page] ?? const {};
    final prior = reads[page];
    return {
      ...reads,
      page: (
        works: works,
        at: at,
        rounds: prior != null && prior.works.containsAll(works)
            ? prior.rounds + 1
            : 1,
      ),
    };
  }

  static List<(String, DateTime)> stuck(
    CloudStrategy cloud,
    DateTime now,
    RetiringTiming timing,
    RetireReads reads,
  ) =>
      [
        for (final MapEntry(key: page, value: works) in _byPage(cloud).entries)
          if (reads[page] case final prior?
              when prior.rounds >= timing.rounds &&
                  prior.works.containsAll(works) &&
                  prior.at.add(timing.stuck).isAfter(now))
            (page, prior.at.add(timing.stuck)),
      ];

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
