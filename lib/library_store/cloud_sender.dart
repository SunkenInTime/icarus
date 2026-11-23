import 'dart:async';
import 'dart:math';

import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/landed_retiring.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:meta/meta.dart';

final class SenderTiming {
  const SenderTiming({
    this.wait = const Duration(milliseconds: 180),
    this.longestWait = const Duration(seconds: 1),
    this.giveUpAfter = const Duration(seconds: 45),
    this.firstWriteRetry = const Duration(seconds: 2),
    this.longestWriteRetry = const Duration(minutes: 1),
    this.heldRetry = const Duration(minutes: 1),
    this.readAgainAfter = const Duration(minutes: 10),
    this.quietBeforeRetiring = const Duration(seconds: 30),
    this.retireAgainAfter = const Duration(minutes: 5),
  });

  final Duration wait;
  final Duration longestWait;
  final Duration giveUpAfter;
  final Duration firstWriteRetry;
  final Duration longestWriteRetry;
  final Duration heldRetry;
  final Duration readAgainAfter;
  final Duration quietBeforeRetiring;
  final Duration retireAgainAfter;

  RetiringTiming get retiring => (
        quiet: quietBeforeRetiring,
        again: retireAgainAfter,
        stuck: readAgainAfter,
        rounds: unresolvedRounds,
      );

  int get unresolvedRounds => 3;

  Duration readRetryAfter(int failures) {
    final doubled = firstWriteRetry * pow(2, min(failures - 1, 10)).toInt();
    return doubled < readAgainAfter ? doubled : readAgainAfter;
  }

  Duration writeRetryAfter(int failures) {
    final doubled = firstWriteRetry * pow(2, min(failures - 1, 10)).toInt();
    return doubled < longestWriteRetry ? doubled : longestWriteRetry;
  }
}

sealed class RunHold {
  const RunHold();
}

final class UpgradeHold extends RunHold {
  const UpgradeHold();

  @override
  String toString() => 'the server asks for a newer build';
}

final class SignInHold extends RunHold {
  const SignInHold(this.from);

  final int from;

  @override
  String toString() => 'waiting for the sign-in to change from count $from';
}

typedef Bound = ({
  int connection,
  Account account,
  int signOuts,
  int number,
});

sealed class _Step {
  const _Step();
}

final class _Acted extends _Step {
  const _Acted();
}

final class _Skipped extends _Step {
  const _Skipped([this.due]);

  final DateTime? due;
}

final class _Restart extends _Step {
  const _Restart();
}

final class _Ended extends _Step {
  const _Ended();
}

sealed class _Session {
  const _Session();
}

final class _Open extends _Session {
  const _Open(this.number, {required this.opened});

  final int number;
  final bool opened;
}

final class _Stale extends _Session {
  const _Stale(this.why);

  final String why;
}

final class _Troubled extends _Session {
  const _Troubled(this.trouble);

  final StoreTrouble trouble;
}

typedef SenderView = ({String run, Map<String, String> strategies});

final class CouldNotResolve {
  const CouldNotResolve(this.subjects, {required this.until});

  final List<String> subjects;
  final DateTime until;

  @override
  String toString() => 'the queue still asks for ${subjects.join(' and ')} '
      'after reading them, so reads stop until $until or a change';
}

sealed class ReadOutlook {
  const ReadOutlook();
}

final class ReadNow extends ReadOutlook {
  const ReadNow(this.what);

  final String what;
}

final class ReadAt extends ReadOutlook {
  const ReadAt(this.at);

  final DateTime at;
}

final class NothingToRead extends ReadOutlook {
  const NothingToRead();
}

final class CannotRead {
  const CannotRead(this.why);

  final String why;

  @override
  String toString() => 'the server will not let this account read it: $why';
}

typedef ReadsUnder = ({Account? account, int? connection, int signOuts});

typedef ViewerWait = ({int lossAttempt, DateTime until});

typedef NeedRounds = ({int rounds, DateTime at});

typedef ReadMemory = ({
  ReadsUnder under,
  DateTime? retryAt,
  int failures,
  CannotRead? cannotRead,
  ViewerWait? viewer,
  Map<ResultSubject, NeedRounds> rounds,
  RetireReads retired,
});

ReadsUnder readsUnder(Snapshot snap) => (
      account: snap.account,
      connection: snap.connection,
      signOuts: snap.signOuts,
    );

ReadMemory freshReads(ReadsUnder under) => (
      under: under,
      retryAt: null,
      failures: 0,
      cannotRead: null,
      viewer: null,
      rounds: const {},
      retired: const {},
    );

extension on ReadMemory {
  ReadMemory failed(DateTime at, {CannotRead? cannotRead}) => (
        under: under,
        retryAt: at,
        failures: cannotRead == null ? failures + 1 : failures,
        cannotRead: cannotRead ?? this.cannotRead,
        viewer: viewer,
        rounds: rounds,
        retired: retired,
      );

  ReadMemory answered({
    required ViewerWait? viewer,
    required Map<ResultSubject, NeedRounds> rounds,
    required RetireReads retired,
  }) =>
      (
        under: under,
        retryAt: null,
        failures: 0,
        cannotRead: null,
        viewer: viewer,
        rounds: rounds,
        retired: retired,
      );

  ReadMemory withRounds(Map<ResultSubject, NeedRounds> rounds) => (
        under: under,
        retryAt: retryAt,
        failures: failures,
        cannotRead: cannotRead,
        viewer: viewer,
        rounds: rounds,
        retired: retired,
      );
}

typedef _Request = ({Account account, int signOuts});

sealed class _Candidate {
  const _Candidate();

  String get id;
}

final class _Adopt extends _Candidate {
  const _Adopt(this.id);

  @override
  final String id;
}

final class _Held extends _Candidate {
  const _Held(this.stored);

  final StoredStrategy stored;

  @override
  String get id => stored.id;
}

sealed class _Read {
  const _Read();
}

final class _ReadList extends _Read {
  const _ReadList();

  @override
  String toString() => 'the page list';
}

final class _ReadPage extends _Read {
  const _ReadPage(this.page);

  final String page;

  @override
  String toString() => 'page $page';
}

enum _Why {
  adopt('the strategy was adopted'),
  need('the queue asked for it'),
  access('edit access was lost'),
  retire('landed work waits for a result');

  const _Why(this.words);

  final String words;
}

typedef _Planned = ({_Read read, _Why why});

final class CloudSender {
  CloudSender({
    required SenderStore store,
    required StoreBatchSend send,
    required StoreReads reads,
    required this.build,
    required this.clientId,
    Snapshot inputs = (
      account: null,
      connection: null,
      signIns: 0,
      signOuts: 0,
    ),
    SenderTiming timing = const SenderTiming(),
    DateTime Function()? clock,
    Duration Function()? elapsed,
    bool Function()? recordsConnectionLost,
  })  : _store = store,
        _send = send,
        _reads = reads,
        _inputs = inputs,
        _timing = timing,
        _clock = clock ?? DateTime.now,
        _elapsed = elapsed ?? _monotonic(),
        _recordsLost = recordsConnectionLost ?? (() => true);

  final SenderStore _store;
  final StoreBatchSend _send;
  final StoreReads _reads;
  final SenderTiming _timing;
  final DateTime Function() _clock;
  final Duration Function() _elapsed;

  static Duration Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final bool Function() _recordsLost;
  final String build;
  final String clientId;

  Snapshot _inputs;
  int? signInWaitFrom;
  var upgradeAsked = false;
  String? held;
  String? ended;
  var disposed = false;
  final bound = <String, Bound>{};
  final restarted = <String>{};
  final notBefore = <String, DateTime>{};
  final _failures = <String, int>{};
  final lastServed = <String, int>{};
  final _lastEdit = <String, DateTime>{};
  final _firstEdit = <String, DateTime>{};
  final _checkedClean = <String>{};
  final _wanted = <String, _Request>{};
  final _memory = <String, ReadMemory>{};
  final _unread = <String>{};
  final _lastSeen = <String, CloudStrategy>{};
  final retiring = Retiring();
  var looks = 0;
  var wakes = 0;
  var dues = 0;
  var acts = 0;
  var reads = 0;
  var inStep = false;
  Snapshot? sendingUnder;
  String? reading;

  var _woken = true;
  Completer<void>? _waiting;
  Timer? _due;
  DateTime? _armedFor;
  final _last = <String, String>{};
  final _views = StreamController<SenderView>.broadcast();
  SenderView _view = (run: 'starting', strategies: const {});
  Future<void>? _running;

  SenderStore get store => _store;

  Snapshot get inputs => _inputs;

  SenderView get view => _view;

  Stream<SenderView> get views => _views.stream;

  Future<void> get done => _running ?? Future<void>.value();

  bool get busy => inStep;

  bool get woken => _woken;

  DateTime? get armedFor => _armedFor;

  RunHold? get runHold => switch (this) {
        CloudSender(upgradeAsked: true) => const UpgradeHold(),
        CloudSender(signInWaitFrom: final from?) when from == _inputs.signIns =>
          SignInHold(from),
        _ => null,
      };

  CannotRead? cannotRead(String strategyId) =>
      readMemory(strategyId).cannotRead;

  ReadMemory readMemory(String strategyId) =>
      _memoryUnder(strategyId, readsUnder(_inputs));

  @visibleForTesting
  void rememberReads(String strategyId, ReadMemory memory) =>
      _memory[strategyId] = memory;

  ReadMemory _memoryUnder(String id, ReadsUnder under) => switch (_memory[id]) {
        final kept? when kept.under == under => kept,
        _ => freshReads(under),
      };

  ReadMemory _boundMemory(String id, Snapshot snap) =>
      _memory[id] = _memoryUnder(id, readsUnder(snap));

  bool looksAt(StoredStrategy strategy) => switch (strategy.tally) {
        null => !_checkedClean.contains(strategy.id),
        _ => strategy.hasWorkToSend ||
            strategy.needsReading ||
            _unread.contains(strategy.id) ||
            retiring.mayRetire(strategy.id),
      };

  bool adopting(String strategyId) =>
      _wanted.containsKey(strategyId) || _unread.contains(strategyId);

  CouldNotResolve? couldNotResolve(String strategyId, [CloudStrategy? cloud]) {
    final now = _clock();
    final memory = readMemory(strategyId);
    final stuck = [
      for (final MapEntry(key: subject, value: (:rounds, :at))
          in memory.rounds.entries)
        if (rounds >= _timing.unresolvedRounds &&
            at.add(_timing.readAgainAfter).isAfter(now))
          ('$subject', at.add(_timing.readAgainAfter)),
      if (cloud ?? _lastSeen[strategyId] case final seen?)
        for (final (page, until)
            in Retiring.stuck(seen, now, _timing.retiring, memory.retired))
          (
            'landed work on ${page == Retiring.list ? 'the page list' : 'page $page'}',
            until
          ),
    ];
    if (stuck.isEmpty) return null;
    return CouldNotResolve(
      [for (final (subject, _) in stuck) subject],
      until:
          stuck.map((entry) => entry.$2).reduce((a, b) => a.isAfter(b) ? a : b),
    );
  }

  ReadOutlook outlook(String strategyId, CloudStrategy cloud) {
    final now = _clock();
    final planned = _plan(strategyId, cloud, now, readMemory(strategyId));
    final blocked = notBefore[strategyId];
    return switch (planned) {
      (planned: (:final read, :final why), due: _) =>
        blocked != null && blocked.isAfter(now)
            ? ReadAt(blocked)
            : ReadNow('$read (${why.words})'),
      (planned: null, due: final at?) =>
        ReadAt(blocked != null && blocked.isAfter(at) ? blocked : at),
      (planned: null, due: null) => const NothingToRead(),
    };
  }

  void _forget(String id) {
    if (_memory[id] case final kept? when kept.rounds.isNotEmpty) {
      _memory[id] = kept.withRounds(const {});
    }
  }

  set inputs(Snapshot next) {
    if (disposed) return;
    _inputs = next;
    _dropRequestsNotMadeUnder(next);
    _memory.removeWhere((_, memory) => memory.under != readsUnder(next));
    wake();
  }

  void _dropRequestsNotMadeUnder(Snapshot snap) => _wanted.removeWhere(
        (_, request) =>
            request.account != snap.account ||
            request.signOuts != snap.signOuts,
      );

  StreamSubscription<StoreChange>? _changes;

  void start() {
    _changes ??= _store.store.changes.listen(
      (change) => switch (change) {
        StrategyEdited(:final strategyPublicId) => edited(strategyPublicId),
        _ => wake(),
      },
      onDone: wake,
    );
    _running ??= _loop();
  }

  void wake() {
    wakes++;
    _woken = true;
    final waiting = _waiting;
    _waiting = null;
    _due?.cancel();
    _due = null;
    _armedFor = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  void edited(String strategyId) {
    final now = _clock();
    _lastEdit[strategyId] = now;
    _firstEdit[strategyId] ??= now;
    _checkedClean.remove(strategyId);
    _forget(strategyId);
    retiring.active(strategyId, now);
    wake();
  }

  void adopt(String strategyId) {
    final account = _inputs.account;
    if (account == null) return;
    _wanted[strategyId] = (account: account, signOuts: _inputs.signOuts);
    wake();
  }

  void hold(String reason) {
    held = reason;
    _publish();
    wake();
  }

  void release() {
    held = null;
    _publish();
    wake();
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    unawaited(_changes?.cancel());
    wake();
    _publish();
    unawaited(_views.close());
  }

  Future<void> _loop() async {
    DateTime? due;
    while (!disposed) {
      await _sleepUntilWoken(due);
      if (disposed) return;
      _woken = false;
      looks++;
      due = null;
      if (_store.shut case final shut?) {
        _end(shut.why);
        return;
      }
      final snap = _inputs;
      if ((snap.connection == null || snap.account == null) &&
          bound.isNotEmpty) {
        inStep = true;
        await _sessionsEnded();
        inStep = false;
        if (disposed) return;
      }
      if (held != null ||
          snap.connection == null ||
          snap.account == null ||
          upgradeAsked ||
          signInWaitFrom == snap.signIns) {
        _publish();
        continue;
      }
      final account = snap.account!;
      final now = _clock();
      final stored = _store.strategies();
      _dropRequestsNotMadeUnder(snap);
      for (final strategy in stored) {
        _wanted.remove(strategy.id);
      }
      final storedIds = {for (final strategy in stored) strategy.id};
      _memory.removeWhere(
        (id, _) => !_wanted.containsKey(id) && !storedIds.contains(id),
      );
      final candidates = <_Candidate>[
        for (final id in _wanted.keys) _Adopt(id),
        for (final strategy in stored)
          if (strategy.ownerAccount == account && looksAt(strategy))
            _Held(strategy),
      ]..sort(
          (a, b) => (lastServed[a.id] ?? -1).compareTo(lastServed[b.id] ?? -1),
        );
      for (final candidate in candidates) {
        if (_inputs != snap || held != null) {
          _woken = true;
          break;
        }
        inStep = true;
        final step = switch (candidate) {
          _Adopt(:final id) => await _adopt(id, account, snap, now),
          _Held(:final stored) => await _step(stored, account, snap, now),
        };
        inStep = false;
        switch (step) {
          case _Acted():
            lastServed[candidate.id] = looks;
            acts++;
            _woken = true;
          case _Skipped(due: final at?):
            if (!at.isAfter(_clock())) {
              _woken = true;
            } else if (due == null || at.isBefore(due)) {
              due = at;
            }
            continue;
          case _Skipped():
            continue;
          case _Restart():
            break;
          case _Ended():
            return;
        }
        break;
      }
      _publish();
    }
  }

  Future<void> _sleepUntilWoken(DateTime? due) async {
    if (_woken || disposed) return;
    final waiting = _waiting = Completer<void>();
    if (due != null) {
      _armedFor = due;
      final delay = due.difference(_clock());
      _due = Timer(delay.isNegative ? Duration.zero : delay, () {
        dues++;
        wakes--;
        wake();
      });
    }
    await waiting.future;
  }

  Future<void> _sessionsEnded() async {
    final lost = [...bound.entries];
    bound.clear();
    for (final MapEntry(key: strategyId, value: session) in lost) {
      if (disposed) return;
      if (!_recordsLost()) continue;
      await _store.write(session.account, strategyId, const [ConnectionLost()]);
    }
  }

  Future<_Step> _adopt(
    String id,
    Account account,
    Snapshot snap,
    DateTime now,
  ) async {
    final memory = _boundMemory(id, snap);
    for (final at in [notBefore[id], memory.retryAt]) {
      if (at != null && at.isAfter(now)) return _Skipped(at);
    }
    if (_inputs != snap) return const _Restart();
    final outcome =
        await _fetch(id, account, const _ReadList(), snap, _Why.adopt);
    if (disposed) return const _Ended();
    if (_inputs != snap) {
      _note(
          id,
          'the page list read to adopt it came back after the inputs '
          'changed; it is read again');
      return const _Restart();
    }
    switch (outcome) {
      case StoreReadAnswered(base: final HeaderRead header, :final role):
        if (role == null || !role.edits) {
          _wanted.remove(id);
          _note(id, 'not adopted: this account can only view it');
          return const _Acted();
        }
        final written = await _store.add(account, id, header);
        if (disposed) return const _Ended();
        switch (written) {
          case WriteTroubled(:final trouble):
            return _troubled(id, trouble);
          case WrittenWith(:final session):
            restarted.add(id);
            if (_inputs != snap || session == null) return const _Restart();
            _wanted.remove(id);
            _unread.add(id);
            _memory[id] = freshReads(readsUnder(snap));
            bound[id] = (
              connection: snap.connection!,
              account: account,
              signOuts: snap.signOuts,
              number: session,
            );
            _store
              ..report(
                ReadRecorded(id, '${const _ReadList()}', _Why.adopt.words,
                    at: now),
              )
              ..report(SessionOpenedFor(id, session, snap));
            _note(id, 'adopted from the page list');
            return const _Acted();
        }
      case StoreReadAnswered():
        _wanted.remove(id);
        _note(id, 'not adopted: the server no longer has it');
        return const _Acted();
      case final other:
        return _readRefused(id, other, snap);
    }
  }

  Future<_Step> _step(
    StoredStrategy stored,
    Account owner,
    Snapshot snap,
    DateTime now,
  ) async {
    final id = stored.id;
    _boundMemory(id, snap);
    if (notBefore[id] case final at? when at.isAfter(now)) {
      return _Skipped(at);
    }
    if (_settledAt(id) case final at? when at.isAfter(now)) {
      return _Skipped(at);
    }
    CloudStrategy cloud;
    switch (await _store.read(id)) {
      case QueueFound(cloud: final found):
        cloud = found;
      case QueueTroubled(:final trouble):
        return _troubled(id, trouble);
    }
    if (disposed) return const _Ended();
    retiring.looked(id, cloud, now);
    _forgetResolved(id, cloud, snap);
    _lastSeen[id] = cloud;
    if (_unreadPages(cloud).isEmpty) {
      _unread.remove(id);
    } else {
      _unread.add(id);
    }
    final sends = openAttempts(cloud).isNotEmpty ||
        (_sendable(cloud) && pick(cloud, clientId) is Picked);
    _Planned? planned;
    DateTime? readDue;
    if (!sends) {
      switch (_plan(id, cloud, now, _boundMemory(id, snap))) {
        case (planned: final next?, due: _):
          planned = next;
        case (planned: null, due: final at):
          readDue = at;
      }
    }
    if (!sends && planned == null) {
      DateTime? retryAt;
      if (pick(cloud, clientId)
          case NothingSendable(:final why, retryAt: final at)) {
        _note(id, why);
        retryAt = at;
      }
      if (stored.tally == null && retryAt == null && readDue == null) {
        _checkedClean.add(id);
      }
      retiring.settled(
        id,
        retiring.next(
            id, cloud, now, _timing.retiring, _boundMemory(id, snap).retired),
      );
      return _Skipped(_earliest(retryAt, readDue));
    }
    final int session;
    switch (await _openSession(id, owner, snap)) {
      case _Open(:final opened, :final number):
        session = number;
        if (opened) {
          switch (await _store.read(id)) {
            case QueueFound(cloud: final fresh):
              cloud = fresh;
            case QueueTroubled(:final trouble):
              return _troubled(id, trouble);
          }
        }
      case _Stale(:final why):
        _note(id, 'no session: $why');
        return const _Restart();
      case _Troubled(:final trouble):
        return _troubled(id, trouble);
    }
    if (disposed) return const _Ended();
    if (held != null || _inputs != snap) return const _Restart();
    final open = openAttempts(cloud);
    if (open.isNotEmpty) {
      final at = _clock();
      final written = await _store.write(owner, id, [
        for (final attempt in open)
          TransportFailed(attempt, TransportFailure.network, at: at),
      ]);
      if (disposed) return const _Ended();
      _note(id, 'closed attempts $open that no call answers');
      return _afterWrite(id, written, mustApply: true);
    }
    final fresh = _plan(id, cloud, _clock(), _boundMemory(id, snap));
    switch (pick(cloud, clientId)) {
      case final Picked picked when _sendable(cloud):
        return _sendStep(id, owner, snap, picked, session);
      case Picked():
        if (fresh.planned case final next?) {
          return _readStep(id, owner, snap, session, cloud, next);
        }
        _note(id, 'held: ${standingOf(cloud.queue).name}');
        return _Skipped(fresh.due);
      case NothingSendable(:final why, :final retryAt):
        if (fresh.planned case final next?) {
          return _readStep(id, owner, snap, session, cloud, next);
        }
        _note(id, why);
        return _Skipped(_earliest(retryAt, fresh.due));
    }
  }

  ({_Planned? planned, DateTime? due}) _plan(
    String id,
    CloudStrategy cloud,
    DateTime now,
    ReadMemory memory,
  ) {
    if (memory.retryAt case final at? when at.isAfter(now)) {
      return (planned: null, due: at);
    }
    if (standingOf(cloud.queue) == Standing.editAccessLost) {
      return switch (memory.viewer) {
        (:final lossAttempt, :final until)
            when lossAttempt == _accessLostAt(cloud) && until.isAfter(now) =>
          (planned: null, due: until),
        _ => (planned: (read: const _ReadList(), why: _Why.access), due: null),
      };
    }
    DateTime? due;
    void later(DateTime at) {
      if (due == null || at.isBefore(due!)) due = at;
    }

    final needed = _needsOf(cloud).toList()
      ..sort(
        (a, b) => (_readOf(a) is _ReadList ? 0 : 1)
            .compareTo(_readOf(b) is _ReadList ? 0 : 1),
      );
    for (final need in needed) {
      final at = switch (memory.rounds[need]) {
        null => now,
        (:final rounds, :final at) when rounds >= _timing.unresolvedRounds =>
          at.add(_timing.readAgainAfter),
        (:final rounds, :final at) => at.add(_timing.readRetryAfter(rounds)),
      };
      if (!at.isAfter(now)) {
        return (planned: (read: _readOf(need), why: _Why.need), due: null);
      }
      later(at);
    }
    if (_unreadPages(cloud).firstOrNull case final page?) {
      return (planned: (read: _ReadPage(page), why: _Why.adopt), due: null);
    }
    switch (retiring.next(id, cloud, now, _timing.retiring, memory.retired)) {
      case (read: final String page?, due: _):
        return (
          planned: (
            read: page == Retiring.list ? const _ReadList() : _ReadPage(page),
            why: _Why.retire,
          ),
          due: null,
        );
      case (read: null, due: final at?):
        later(at);
      case (read: null, due: null):
        break;
    }
    return (planned: null, due: due);
  }

  static List<String> _unreadPages(CloudStrategy cloud) => [
        for (final page in cloud.queue.shown.pages.keys)
          if (!cloud.queue.shown.content.containsKey(page)) page,
      ];

  static _Read _readOf(ResultSubject subject) => switch (subject) {
        PageListResult() => const _ReadList(),
        RowResult(
          target: StrategyTarget() || PageTarget() || SettingsTarget(),
        ) =>
          const _ReadList(),
        RowResult(:final page?) => _ReadPage(page),
        RowResult() => const _ReadList(),
        PageResult(:final page) => _ReadPage(page),
      };

  void _forgetResolved(String id, CloudStrategy cloud, Snapshot snap) {
    final memory = _boundMemory(id, snap);
    final raised = _needsOf(cloud);
    final now = _clock();
    final kept = {
      for (final MapEntry(key: subject, value: rounds) in memory.rounds.entries)
        if (raised.contains(subject) &&
            (rounds.rounds < _timing.unresolvedRounds ||
                rounds.at.add(_timing.readAgainAfter).isAfter(now)))
          subject: rounds,
    };
    if (kept.length != memory.rounds.length) {
      _memory[id] = memory.withRounds(kept);
    }
  }

  static bool _sendable(CloudStrategy cloud) =>
      standingOf(cloud.queue) == Standing.good;

  static int _accessLostAt(CloudStrategy cloud) =>
      cloud.queue.strategy.accessLostAt;

  static Set<ResultSubject> _needsOf(CloudStrategy cloud) => {
        for (final view in cloud.views.values)
          for (final hold in view.holds)
            if (hold case AwaitingResult(:final subject)) subject,
      };

  static DateTime? _earliest(DateTime? a, DateTime? b) => switch ((a, b)) {
        (null, _) => b,
        (_, null) => a,
        (final a?, final b?) => a.isBefore(b) ? a : b,
      };

  Future<StoreReadOutcome> _fetch(
    String id,
    Account account,
    _Read read,
    Snapshot snap,
    _Why why,
  ) async {
    reads++;
    sendingUnder = snap;
    reading = why.words;
    try {
      return await Future<StoreReadOutcome>.sync(
        () => switch (read) {
          _ReadList() =>
            _reads.pageList(strategyPublicId: id, account: account),
          _ReadPage(:final page) => _reads.page(
              strategyPublicId: id,
              pagePublicId: page,
              account: account,
            ),
        },
      ).then((outcome) => outcome).timeout(
            _timing.giveUpAfter,
            onTimeout: () => StoreReadLost(
              TransportFailure.timeout,
              'no answer within ${_timing.giveUpAfter.inSeconds} s',
            ),
          );
    } catch (error) {
      return StoreReadLost(TransportFailure.network, 'the read threw: $error');
    } finally {
      sendingUnder = null;
      reading = null;
    }
  }

  Future<_Step> _readStep(
    String id,
    Account owner,
    Snapshot snap,
    int session,
    CloudStrategy cloud,
    _Planned planned,
  ) async {
    final (:read, :why) = planned;
    final started = _clock();
    final outcome = await _fetch(id, owner, read, snap, why);
    if (disposed) return const _Ended();
    if (_inputs != snap) {
      _note(
          id,
          'read $read (${why.words}); it came back after the inputs '
          'changed, so it is dropped and read again');
      return const _Restart();
    }
    switch (outcome) {
      case StoreReadAnswered(:final base, :final role):
        final confirms = why == _Why.access && (role?.edits ?? false);
        final written = await _store.write(owner, id, [
          BaseArrived(base, session: session),
          if (confirms) EditAccessConfirmed(afterAttempt: _accessLostAt(cloud)),
        ]);
        if (disposed) return const _Ended();
        switch (written) {
          case WriteTroubled(:final trouble):
            return _troubled(id, trouble);
          case WrittenWith(:final notApplied) when notApplied.isNotEmpty:
            return _readFailed(
              id,
              'the queue did not take $read: ${notApplied.join('; ')}',
              snap,
            );
          case WrittenWith():
            break;
        }
        if (_inputs != snap) return const _Restart();
        _recorded(id, read, why, role, cloud, started, snap);
        _note(
            id,
            switch (why) {
              _Why.access when confirms => 'read $read: edit access confirmed',
              _Why.access => 'read $read: this account still cannot edit it',
              _ => 'read $read (${why.words})',
            });
        _failures.remove(id);
        notBefore.remove(id);
        return const _Acted();
      case final other:
        return _readRefused(id, other, snap);
    }
  }

  void _recorded(
    String id,
    _Read read,
    _Why why,
    StoreReadRole? role,
    CloudStrategy cloud,
    DateTime started,
    Snapshot snap,
  ) {
    final memory = _boundMemory(id, snap);
    _memory[id] = memory.answered(
      viewer: switch (why) {
        _Why.access when role?.edits ?? false => null,
        _Why.access => (
            lossAttempt: _accessLostAt(cloud),
            until: started.add(_timing.readAgainAfter),
          ),
        _ => memory.viewer,
      },
      rounds: switch (why) {
        _Why.need => {
            ...memory.rounds,
            for (final need in _needsOf(cloud))
              if ('${_readOf(need)}' == '$read')
                need: (
                  rounds: (memory.rounds[need]?.rounds ?? 0) + 1,
                  at: started,
                ),
          },
        _ => memory.rounds,
      },
      retired: switch ((why, read)) {
        (_Why.retire, _ReadPage(:final page)) =>
          Retiring.read(memory.retired, page, cloud, started),
        (_Why.retire, _ReadList()) =>
          Retiring.read(memory.retired, Retiring.list, cloud, started),
        _ => memory.retired,
      },
    );
    _store.report(ReadRecorded(id, '$read', why.words, at: started));
  }

  _Step _readFailed(String id, String words, Snapshot snap) {
    final memory = _boundMemory(id, snap);
    final at = _clock().add(_timing.readRetryAfter(memory.failures + 1));
    _memory[id] = memory.failed(at);
    _note(id, '$words; reading again at $at');
    return _Skipped(at);
  }

  _Step _readRefused(String id, StoreReadOutcome outcome, Snapshot snap) {
    switch (outcome) {
      case StoreReadRefused(
          refusal: StoreReadRefusal.accountMismatch ||
              StoreReadRefusal.unauthenticated,
          :final why
        ):
        signInWaitFrom = snap.signIns;
        _note(id, 'the read was refused for the sign-in: $why');
        return const _Acted();
      case StoreReadRefused(refusal: StoreReadRefusal.upgradeRequired):
        upgradeAsked = true;
        _note(id, 'the read asks for a newer build');
        return const _Acted();
      case StoreReadRefused(refusal: StoreReadRefusal.forbidden, :final why):
        final cannot = CannotRead(why);
        final at = _clock().add(_timing.readAgainAfter);
        _memory[id] = _boundMemory(id, snap).failed(at, cannotRead: cannot);
        _note(id, '$cannot; reading again at $at');
        return _Skipped(at);
      case StoreReadUnreadable(:final problem):
        return _readFailed(
          id,
          'the read came back in rows this build cannot read ($problem)',
          snap,
        );
      case StoreReadLost(:final why):
        return _readFailed(id, 'the read was lost ($why)', snap);
      case StoreReadAnswered():
        return const _Acted();
    }
  }

  Future<_Step> _sendStep(
    String id,
    Account owner,
    Snapshot snap,
    Picked picked,
    int session,
  ) async {
    if (_settledAt(id) case final at? when at.isAfter(_clock())) {
      return _Skipped(at);
    }
    final ClaimedBatch batch;
    switch (await _store.claim(
      owner,
      id,
      picked,
      _clock(),
      elapsed: _elapsed(),
      session: session,
    )) {
      case Claimed(batch: final claimed):
        batch = claimed;
        _firstEdit.remove(id);
        _lastEdit.remove(id);
      case NotClaimed(:final why):
        _note(id, 'not claimed: $why');
        return _Skipped(notBefore[id] = _clock().add(_timing.firstWriteRetry));
      case ClaimTroubled(:final trouble):
        return _troubled(id, trouble);
    }
    if (disposed) return const _Ended();
    if (_whyNotSend(snap) case final why?) {
      final written = await _store.write(
        owner,
        id,
        [ClaimReleased(batch.attempt)],
        batch: batch,
      );
      if (disposed) return const _Ended();
      _note(id, 'gave back $batch unsent: $why');
      return _afterWrite(id, written, mustApply: true);
    }
    sendingUnder = snap;
    _store.report(BatchSentAs(id, batch));
    final outcome = await _call(batch);
    final answeredAt = _elapsed();
    sendingUnder = null;
    if (disposed) return const _Ended();
    if (outcome is StoreBatchOutsideWindow &&
        batch.basis == null &&
        batch.unchecked.isNotEmpty) {
      _store.report(UncheckedWithoutBasis(id, batch));
    }
    switch (outcome) {
      case StoreBatchRefusedWhole(refusal: BatchRefusal.unauthenticated) ||
            StoreBatchAccountMismatch():
        signInWaitFrom = snap.signIns;
      case StoreBatchRefusedWhole(refusal: BatchRefusal.upgradeRequired):
        upgradeAsked = true;
      case _:
        break;
    }
    final written = await _store.write(
      owner,
      id,
      outcome is StoreBatchAccountMismatch
          ? [ClaimReleased(batch.attempt)]
          : [
              ...answersOf(batch, outcome, _clock()),
              if (outcome case StoreBatchAnswered(serverTime: final time?))
                ServerTimeHeld(time, at: answeredAt, session: batch.session),
            ],
      batch: batch,
    );
    if (disposed) return const _Ended();
    switch (written) {
      case WrittenWith(:final effects, :final notApplied):
        if (effects.any((effect) => effect is HoldSendingForUpgrade)) {
          upgradeAsked = true;
        }
        if (effects.any((effect) => effect is ReportUnauthenticated)) {
          signInWaitFrom = snap.signIns;
        }
        _forget(id);
        retiring.active(id, _clock());
        _note(
          id,
          notApplied.isEmpty
              ? 'sent $batch'
              : 'sent $batch; the queue did not apply ${notApplied.join('; ')}',
        );
        _failures.remove(id);
        notBefore.remove(id);
      case WriteTroubled(:final trouble):
        if (_troubled(id, trouble) is _Ended) return const _Ended();
    }
    return const _Acted();
  }

  Future<_Session> _openSession(
    String id,
    Account owner,
    Snapshot snap,
  ) async {
    final connection = snap.connection!;
    final account = snap.account!;
    final last = bound[id];
    if (last != null &&
        last.connection == connection &&
        last.account == account &&
        last.signOuts == snap.signOuts) {
      return _Open(last.number, opened: false);
    }
    if (snap != _inputs) {
      return const _Stale(
        'the connection, the account or the sign-in changed before the '
        'session was opened',
      );
    }
    final events = [
      if (!restarted.contains(id)) AppRestarted(build: build),
      if (last != null && last.account != account) const AccountChanged(),
      const ConnectionReturned(),
    ];
    final written = await _store.write(owner, id, events, readSession: true);
    if (disposed) return const _Stale('the sender was disposed');
    switch (written) {
      case WriteTroubled(:final trouble):
        return _Troubled(trouble);
      case WrittenWith(:final session):
        restarted.add(id);
        if (snap != _inputs) {
          return const _Stale(
            'the connection or the account changed while the session opened',
          );
        }
        if (session == null) {
          return const _Troubled(
            NotWrittenNow('the session was written but not read back'),
          );
        }
        bound[id] = (
          connection: connection,
          account: account,
          signOuts: snap.signOuts,
          number: session,
        );
        _store.report(SessionOpenedFor(id, session, snap));
        return _Open(session, opened: true);
    }
  }

  DateTime? _settledAt(String id) {
    final last = _lastEdit[id];
    if (last == null) return null;
    final quiet = last.add(_timing.wait);
    final longest = _firstEdit[id]!.add(_timing.longestWait);
    return quiet.isBefore(longest) ? quiet : longest;
  }

  String? _whyNotSend(Snapshot snap) {
    final now = _inputs;
    if (held case final reason?) return 'sending is held: $reason';
    if (_store.shut case final shut?) return shut.why;
    if (upgradeAsked) return 'the server asks for a newer build';
    if (signInWaitFrom == now.signIns) return 'waiting for the sign-in';
    if (now != snap) {
      return 'the connection, the sign-in or the account changed during the '
          'claim';
    }
    return null;
  }

  Future<StoreBatchOutcome> _call(ClaimedBatch batch) async {
    try {
      return await Future<StoreBatchOutcome>.sync(
        () => _send(
          strategyPublicId: batch.strategyId,
          clientId: batch.clientId,
          ops: batch.ops,
          account: batch.account,
          serverTime: ServerTimeAsked(basis: batch.basis),
        ),
      ).then((outcome) => outcome).timeout(
            _timing.giveUpAfter,
            onTimeout: () => StoreBatchLost(
              TransportFailure.timeout,
              'no answer within ${_timing.giveUpAfter.inSeconds} s',
            ),
          );
    } catch (error) {
      return StoreBatchLost(TransportFailure.network, 'the send threw: $error');
    }
  }

  _Step _afterWrite(String id, Written written, {required bool mustApply}) {
    switch (written) {
      case WrittenWith(:final notApplied)
          when mustApply && notApplied.isNotEmpty:
        _note(id, 'the queue did not apply it: ${notApplied.join('; ')}');
        return _Skipped(notBefore[id] = _clock().add(_timing.heldRetry));
      case WrittenWith():
        _failures.remove(id);
        notBefore.remove(id);
        return const _Acted();
      case WriteTroubled(:final trouble):
        return _troubled(id, trouble);
    }
  }

  _Step _troubled(String id, StoreTrouble trouble) {
    switch (trouble) {
      case NotWrittenNow(:final why):
        final failures = _failures[id] = (_failures[id] ?? 0) + 1;
        final at =
            notBefore[id] = _clock().add(_timing.writeRetryAfter(failures));
        _note(id, 'could not be written ($why); trying again at $at');
        return _Skipped(at);
      case StrategyHeld(:final why):
        final at = notBefore[id] = _clock().add(_timing.heldRetry);
        _note(id, 'held: $why; looking again at $at');
        return _Skipped(at);
      case StoreShut(:final why):
        _end(why);
        return const _Ended();
    }
  }

  void _end(String why) {
    ended ??= why;
    _publish();
  }

  void _note(String id, String words) {
    _last[id] = words;
    _publish();
  }

  void _publish() {
    final next = (
      run: switch (this) {
        CloudSender(disposed: true) => 'disposed',
        CloudSender(ended: final why?) => 'ended: $why',
        CloudSender(held: final why?) => 'held: $why',
        CloudSender(runHold: final hold?) => 'held: $hold',
        _ => 'running',
      },
      strategies: Map<String, String>.unmodifiable(_last),
    );
    final changed = next.run != _view.run ||
        next.strategies.length != _view.strategies.length ||
        next.strategies.entries
            .any((entry) => _view.strategies[entry.key] != entry.value);
    _view = next;
    if (changed && !_views.isClosed) _views.add(next);
  }
}

List<QueueEvent> answersOf(
  ClaimedBatch batch,
  StoreBatchOutcome outcome,
  DateTime at,
) =>
    switch (outcome) {
      StoreBatchAnswered(:final answers, :final complete) => [
          for (final answer in answers) OpAnswered(batch.attempt, answer),
          if (!complete)
            TransportFailed(
              batch.attempt,
              TransportFailure.missingAnswer,
              at: at,
            ),
        ],
      StoreBatchRefusedWhole(:final refusal) => [
          BatchRefused(batch.attempt, refusal),
        ],
      StoreBatchLost(:final failure) => [
          TransportFailed(batch.attempt, failure, at: at),
        ],
      StoreBatchAccountMismatch() => [ClaimReleased(batch.attempt)],
      StoreBatchOutsideWindow() => [
          BatchRefused(batch.attempt, BatchRefusal.uncheckedTooLate),
        ],
    };
