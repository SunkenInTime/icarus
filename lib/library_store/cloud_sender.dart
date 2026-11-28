import 'dart:async';
import 'dart:math';

import 'package:icarus/collab/cloud_results.dart' show DecodedRows;
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/landed_retiring.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus/library_store/live_results.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/stall_exits.dart';
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
    this.lookupGiveUpAfter = const Duration(seconds: 10),
    this.firstLiveResult = const Duration(seconds: 10),
    this.liveGrace = const Duration(seconds: 2),
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
  final Duration lookupGiveUpAfter;
  final Duration firstLiveResult;
  final Duration liveGrace;

  RetiringTiming get retiring => (
        quiet: quietBeforeRetiring,
        again: retireAgainAfter,
        stuck: readAgainAfter,
        rounds: unresolvedRounds,
      );

  int get unresolvedRounds => 3;

  int get accessReads => 6;

  Duration settleAfter(int unsettled) => readRetryAfter(unsettled);

  Duration? accessAfter(int unconfirmed) =>
      unconfirmed < accessReads ? readAgainAfter : null;

  Duration get readFloor => firstWriteRetry;

  Duration get sendFloor => wait;

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

typedef _Asked = ({int session, ResultPoint point});

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
  const _Skipped(this.why, [this.due]);

  final StallExit why;
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

enum _Why {
  adopt('the strategy was adopted', StallExit.firstRead),
  need('the queue asked for it', StallExit.unsettledResult),
  clock(
      'the queue asked for it, and our own answer carries a later server time '
      'than every result read since, with nothing in them showing our write',
      StallExit.answerAhead),
  access('edit access was lost', StallExit.viewerOnly),
  retire('landed work waits for a result', StallExit.landedWork),
  live('a live result arrived', StallExit.unsettledResult);

  const _Why(this.words, this.row);

  final String words;
  final StallExit row;
}

typedef _Planned = ({ReadOf read, _Why why});

sealed class _Answer {
  const _Answer();
}

final class _Converted extends _Answer {
  const _Converted(this.outcome);

  final StoreReadOutcome outcome;
}

final class _PageToConvert extends _Answer {
  const _PageToConvert(this.answer);

  final LivePageAnswer answer;
}

typedef _LiveResult = ({
  Account account,
  _Answer answer,
  ResultPoint point,
  DateTime at,
});

ResultPoint? _pointOf(StoreReadOutcome outcome) => switch (outcome) {
      StoreReadAnswered(:final point) ||
      StoreReadRefused(:final point) ||
      StoreReadUnreadable(:final point) =>
        point,
      StoreReadLost() => null,
    };

bool _isOlder(ResultPoint point, ResultPoint than) =>
    point.generation.isBefore(than.generation) ||
    (point.generation == than.generation && point.snapshot < than.snapshot);

final class _Live {
  _Live(this.since);

  DateTime since;
  var watchers = 0;
  int? deliveredOn;
  _LiveResult? _pending;
  _LiveResult? taking;
  var answers = 0;
  int? answersAtReconnect;
  DecodedRows? held;

  bool get answeredSinceReconnect => answersAtReconnect != answers;

  _LiveResult? get pending => _pending;

  bool get dropsOnReplace => _pending != null && !identical(_pending, taking);

  bool offered(_LiveResult result) {
    final held = _pending;
    if (held != null && _isOlder(result.point, held.point)) return false;
    _pending = result;
    return true;
  }

  void written(_LiveResult result) {
    if (identical(_pending, result)) _pending = null;
  }

  _LiveResult? owed() {
    final held = _pending;
    _pending = null;
    return held;
  }
}

sealed class _LiveGate {
  const _LiveGate();
}

final class _NotLive extends _LiveGate {
  const _NotLive();
}

final class _LiveCurrent extends _LiveGate {
  const _LiveCurrent();
}

final class _LiveAwaitingFirst extends _LiveGate {
  const _LiveAwaitingFirst(this.until);

  final DateTime until;
}

final class CloudSender implements LiveResults {
  CloudSender({
    required SenderStore store,
    required StoreBatchSend send,
    required StoreReads reads,
    required Future<({int client, int connection})> Function() generation,
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
    String? Function()? editorShows,
    Future<void> Function()? reconnect,
    CanRead? canRead,
  })  : _store = store,
        _canRead = canRead ?? appCanRead,
        _reconnect = reconnect ?? (() async {}),
        _governor = CallGovernor(
          reads: reads,
          send: send,
          timing: timing,
          clock: clock ?? DateTime.now,
          editorShows: editorShows ?? (() => null),
        ),
        _inputs = inputs,
        _timing = timing,
        _clock = clock ?? DateTime.now,
        _elapsed = elapsed ?? _monotonic(),
        _generation = generation,
        _recordsLost = recordsConnectionLost ?? (() => true);

  final Future<({int client, int connection})> Function() _generation;
  final Future<void> Function() _reconnect;
  final CanRead _canRead;

  Future<({int client, int connection})> _lookUpGeneration() =>
      _generation().timeout(_timing.lookupGiveUpAfter);

  final SenderStore _store;
  final CallGovernor _governor;
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
  final _unread = <String>{};
  final _lastSeen = <String, CloudStrategy>{};
  final retiring = Retiring();
  final _waits = <String, StallExit>{};
  final _live = <(String, ReadOf), _Live>{};
  final _clockHeldByLive = <String, Set<ReadOf>>{};
  final _heldByLiveSince = <(String, ReadOf), DateTime>{};
  final _owedPastTheWatch = <(String, ReadOf)>{};
  var liveTaken = 0;
  var liveRowsDecoded = 0;
  var liveReplaced = 0;
  var liveOlderDropped = 0;
  var liveOwed = 0;
  var clockWaitsOnLive = 0;
  var clockRoundsOnWatch = 0;
  var reconnectsAsked = 0;
  var looks = 0;
  var wakes = 0;
  var dues = 0;
  var acts = 0;
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

  int get reads => _governor.issued;

  bool get woken => _woken;

  DateTime? get armedFor => _armedFor;

  RunHold? get runHold => switch (this) {
        CloudSender(upgradeAsked: true) => const UpgradeHold(),
        CloudSender(signInWaitFrom: final from?) when from == _inputs.signIns =>
          SignInHold(from),
        _ => null,
      };

  CannotRead? cannotRead(String strategyId) =>
      _governor.access(strategyId, _inputs)?.cannot;

  AccessRung? accessRung(String strategyId) =>
      _governor.access(strategyId, _inputs);

  bool accessCheckStopped(String strategyId) =>
      _governor.accessStopped(strategyId, _inputs);

  @visibleForTesting
  void owesFreshRead(String strategyId, ReadOf read) {
    _governor.written(strategyId, read, late: true);
    wake();
  }

  StallExit? waitingOn(String strategyId) => switch (runHold) {
        _ when held != null => StallExit.heldByHand,
        _ when _inputs.account == null => StallExit.signedOut,
        _ when _inputs.connection == null => StallExit.offline,
        UpgradeHold() => StallExit.upgrade,
        SignInHold() => StallExit.signIn,
        null => _waits[strategyId],
      };

  ReadMemory readMemory(String strategyId) =>
      _governor.memory(strategyId, readsUnder(_inputs));

  @visibleForTesting
  void rememberReads(String strategyId, ReadMemory memory) =>
      _governor.remember(strategyId, memory);

  ReadMemory _boundMemory(String id, Snapshot snap) =>
      _governor.bind(id, readsUnder(snap));

  bool looksAt(StoredStrategy strategy) => switch (strategy.tally) {
        null => !_checkedClean.contains(strategy.id),
        _ => strategy.hasWorkToSend ||
            strategy.needsReading ||
            _livePending(strategy.id) ||
            _unread.contains(strategy.id) ||
            retiring.mayRetire(strategy.id) ||
            _governor.keeping.contains(strategy.id) ||
            switch (_lastSeen[strategy.id]) {
              final cloud? => switch (_plan(
                  strategy.id,
                  cloud,
                  _clock(),
                  _inputs,
                )) {
                  (planned: null, due: null, why: _) => false,
                  _ => true,
                },
              null => false,
            },
      };

  bool adopting(String strategyId) =>
      _wanted.containsKey(strategyId) || _unread.contains(strategyId);

  CouldNotResolve? couldNotResolve(String strategyId, [CloudStrategy? cloud]) {
    final now = _clock();
    final memory = readMemory(strategyId);
    final stuck = [
      for (final MapEntry(key: read, value: (:count, :at, why: _))
          in memory.settle.entries)
        if (count >= _timing.unresolvedRounds)
          (read, at.add(_timing.settleAfter(count))),
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
    final planned = _plan(strategyId, cloud, now, _inputs);
    final blocked = notBefore[strategyId];
    return switch (planned) {
      (planned: (:final read, :final why), due: _, why: _) =>
        blocked != null && blocked.isAfter(now)
            ? ReadAt(blocked)
            : ReadNow('$read (${why.words})'),
      (planned: null, due: final at?, why: _) =>
        ReadAt(blocked != null && blocked.isAfter(at) ? blocked : at),
      (planned: null, due: null, why: _) => const NothingToRead(),
    };
  }

  set inputs(Snapshot next) {
    if (disposed) return;
    if (next.connection != _inputs.connection) {
      final now = _clock();
      for (final live in _live.values) {
        live
          ..deliveredOn = null
          ..since = now;
      }
    }
    _inputs = next;
    _dropRequestsNotMadeUnder(next);
    _governor.under(readsUnder(next));
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
        StrategyRefused(:final strategyPublicId, :final refusal) =>
          _store.refused(strategyPublicId, refusal),
        final StoredResultsDropped dropped => _store.report(
            StoredResultsDroppedReport(dropped.strategyPublicId, dropped),
          ),
        LibraryEdited(:final summaries) => _libraryEdited(summaries),
        _ => wake(),
      },
      onDone: wake,
    );
    for (final MapEntry(key: strategyId, value: refusal)
        in _store.store.refusedStrategies.entries) {
      _store.refused(strategyId, refusal);
    }
    for (final dropped in _store.store.resultsDropped) {
      _store.report(
        StoredResultsDroppedReport(dropped.strategyPublicId, dropped),
      );
    }
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
    retiring.active(strategyId, now);
    wake();
  }

  void _libraryEdited(List<StrategySummary> summaries) {
    for (final summary in summaries) {
      if (_waits[summary.publicId] == StallExit.localTrouble) {
        _governor.newEvidence(summary.publicId);
        notBefore.remove(summary.publicId);
      }
    }
    wake();
  }

  void retryNow(String strategyId) {
    final watches = [
      for (final read in _clockHeldByLive[strategyId] ?? const <ReadOf>{})
        if (_live[(strategyId, read)] case final live?) live,
    ];
    if (watches.any((live) => live.answeredSinceReconnect)) {
      for (final live in watches) {
        live.answersAtReconnect = live.answers;
      }
      reconnectsAsked++;
      unawaited(_askReconnect(strategyId));
    }
    _governor.newEvidence(strategyId);
    notBefore.remove(strategyId);
    wake();
  }

  Future<void> _askReconnect(String strategyId) async {
    try {
      await _reconnect();
    } catch (error) {
      _note(strategyId, 'the reconnect the retry asked for failed: $error');
    }
  }

  void editorOpened(String? strategyId) {
    _governor.userOpened(strategyId);
    wake();
  }

  @override
  void liveOpened(String strategyId, ReadOf subject) {
    if (disposed) return;
    final live = _live[(strategyId, subject)] ??= _Live(_clock());
    if (live.watchers == 0) {
      live
        ..since = _clock()
        ..deliveredOn = null;
    }
    live.watchers++;
    wake();
  }

  @override
  void liveArrived(
    String strategyId,
    ReadOf subject,
    Account account,
    StoreReadOutcome outcome,
  ) {
    if (disposed) return;
    final live = _live[(strategyId, subject)] ??= _Live(_clock());
    if (live.watchers == 0) live.watchers = 1;
    final point = _pointOf(outcome);
    if (point == null) {
      live.deliveredOn = null;
      wake();
      return;
    }
    _offer(live, account, _Converted(outcome), point);
  }

  @override
  void livePageArrived(
    String strategyId,
    ReadOfPage subject,
    Account account,
    LivePageAnswer answer,
  ) {
    if (disposed) return;
    final live = _live[(strategyId, subject)] ??= _Live(_clock());
    if (live.watchers == 0) live.watchers = 1;
    _offer(live, account, _PageToConvert(answer), answer.point);
  }

  void _offer(_Live live, Account account, _Answer answer, ResultPoint point) {
    live.answers++;
    final replacing = live.dropsOnReplace;
    if (live.offered(
      (account: account, answer: answer, point: point, at: _clock()),
    )) {
      if (replacing) liveReplaced++;
    } else {
      liveOlderDropped++;
    }
    live.deliveredOn = _inputs.connection;
    wake();
  }

  Future<StoreReadOutcome> _outcomeOf(
    String id,
    ReadOf read,
    _Answer answer,
  ) async {
    switch (answer) {
      case _Converted(:final outcome):
        return outcome;
      case _PageToConvert(:final answer):
        final live = _live[(id, read)];
        final held = live?.held ??
            DecodedRows.of(await _store.heldOnPage(id, answer.pagePublicId));
        live?.held = held;
        final (:outcome, :decoded) = livePageOutcome(
          answer,
          canRead: _canRead,
          held: held,
          decoded: held.keep,
        );
        liveRowsDecoded += decoded;
        return outcome;
    }
  }

  @override
  void liveClosed(String strategyId, ReadOf subject) {
    final live = _live[(strategyId, subject)];
    if (live == null) return;
    live.watchers--;
    _forgetEnded(strategyId, subject);
    wake();
  }

  void _forgetEnded(String strategyId, ReadOf subject) {
    if (_live[(strategyId, subject)] case final live?
        when live.watchers <= 0 && live.pending == null) {
      _live.remove((strategyId, subject));
    }
  }

  void _owe(String id, ReadOf read) {
    final live = _live[(id, read)];
    if (live?.owed() == null) return;
    liveOwed++;
    if (live!.watchers <= 0 || live.deliveredOn != _inputs.connection) {
      live.deliveredOn = null;
      _owedPastTheWatch.add((id, read));
    }
    _governor.written(id, read, late: true);
    _forgetEnded(id, read);
    wake();
  }

  bool _livePending(String id) => _live.entries
      .any((entry) => entry.key.$1 == id && entry.value.pending != null);

  ({ReadOf read, _LiveResult result})? _nextLive(String id, Account owner) {
    for (final MapEntry(key: (strategy, read), value: live)
        in _live.entries.toList()) {
      if (strategy != id) continue;
      final pending = live.pending;
      if (pending == null) continue;
      if (pending.account != owner) {
        _note(id, 'a live result of $read was read as another account');
        _owe(id, read);
        continue;
      }
      return (read: read, result: pending);
    }
    return null;
  }

  _LiveGate _liveGate(String id, ReadOf read, DateTime now, Snapshot snap) {
    final live = _live[(id, read)];
    if (live == null ||
        live.watchers <= 0 ||
        _owedPastTheWatch.contains((id, read))) {
      return const _NotLive();
    }
    if (live.deliveredOn case final on? when on == snap.connection) {
      return const _LiveCurrent();
    }
    final until = live.since.add(_timing.firstLiveResult);
    return until.isAfter(now) ? _LiveAwaitingFirst(until) : const _NotLive();
  }

  DateTime? _nextRoundOnWatch(
    String id,
    ReadOf read,
    DateTime now,
    Snapshot snap,
  ) =>
      switch (_governor.readAt(id, read, snap)) {
        ReadFrom(:final at?) when at.isAfter(now) => at,
        _ => null,
      };

  DateTime _roundDue(String id, ReadOf read, DateTime now, Snapshot snap) =>
      _nextRoundOnWatch(id, read, now, snap) ?? now;

  void _countClockHeldByLive(
    String id,
    CloudStrategy cloud,
    DateTime now,
    Snapshot snap,
  ) {
    final memory = _governor.memory(id, readsUnder(snap));
    final held = {
      for (final (:planned, wantedAt: _)
          in _readsWanted(id, cloud, now, memory))
        if (planned.why == _Why.clock &&
            _liveGate(id, planned.read, now, snap) is _LiveCurrent)
          planned.read,
    };
    final before = _clockHeldByLive[id] ?? const <ReadOf>{};
    clockWaitsOnLive += held.difference(before).length;
    for (final read in held) {
      if (_nextRoundOnWatch(id, read, now, snap) == null) {
        clockRoundsOnWatch++;
        _governor.remember(
          id,
          _boundMemory(id, snap).climbed('$read', now, StallExit.clockOnWatch),
        );
      }
    }
    if (held.isEmpty) {
      _clockHeldByLive.remove(id);
    } else {
      _clockHeldByLive[id] = held;
    }
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
        if ((held, snap.account) case (null, final account?)) {
          inStep = true;
          due = await _writeKeptWhileHeld(account);
          inStep = false;
          if (disposed) return;
        }
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
      _governor.keepOnly(
        (id) => _wanted.containsKey(id) || storedIds.contains(id),
      );
      _waits.removeWhere(
        (id, why) =>
            !_wanted.containsKey(id) &&
            !storedIds.contains(id) &&
            why != StallExit.viewerOnTakeUp &&
            why != StallExit.goneOnTakeUp,
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
            _waits.remove(candidate.id);
            lastServed[candidate.id] = looks;
            acts++;
            _woken = true;
          case _Skipped(:final why, due: final at?):
            _waits[candidate.id] = why;
            if (!at.isAfter(_clock())) {
              _woken = true;
            } else if (due == null || at.isBefore(due)) {
              due = at;
            }
            continue;
          case _Skipped(:final why):
            _waits[candidate.id] = why;
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
    _boundMemory(id, snap);
    if (notBefore[id] case final at? when at.isAfter(now)) {
      return _Skipped(StallExit.localTrouble, at);
    }
    if (_inputs != snap) return const _Restart();
    if (_store.store.refusedStrategies[id] case final refusal?) {
      _store.refused(id, refusal);
      _note(id, 'held: $refusal');
      return const _Skipped(StallExit.localTrouble);
    }
    const read = ReadOfList();
    final under = readsUnder(snap);
    final StoreReadOutcome outcome;
    final DateTime started;
    final kept = _governor.heldFor(id, read, under);
    switch (kept) {
      case (outcome: final held, started: final at, under: _, readIn: _):
        outcome = held;
        started = at;
      case null:
        switch (await _issue(id, account, read, snap, _Why.adopt)) {
          case NotYet(:final at, :final why):
            return _Skipped(why ?? StallExit.firstRead, at);
          case Answered(outcome: final fresh, started: final at):
            outcome = fresh;
            started = at;
        }
    }
    if (disposed) return const _Ended();
    if (_inputs != snap) {
      _note(
          id,
          'the page list read to adopt it came back after the inputs '
          'changed; it is read again');
      return const _Restart();
    }
    switch (outcome) {
      case StoreReadAnswered(
          base: final HeaderRead header,
          :final point,
          :final role
        ):
        if (role == null || !role.edits) {
          if (await _endedTakeUp(id, account, read, snap, point)
              case final step?) {
            return step;
          }
          _wanted.remove(id);
          _note(id, 'not adopted: this account can only view it');
          return const _Skipped(StallExit.viewerOnTakeUp);
        }
        final written = await _store.add(
          account,
          id,
          StampedRead(header, point),
        );
        if (disposed) return const _Ended();
        switch (written) {
          case WriteTroubled(:final trouble):
            _governor.hold(
              id,
              read,
              (outcome: outcome, started: started, under: under, readIn: null),
            );
            return _troubled(id, trouble);
          case WrittenWith(:final session):
            _governor.written(id, read, late: kept != null);
            restarted.add(id);
            if (_inputs != snap || session == null) return const _Restart();
            _wanted.remove(id);
            _unread.add(id);
            _governor.remember(id, freshReads(under));
            bound[id] = (
              connection: snap.connection!,
              account: account,
              signOuts: snap.signOuts,
              number: session,
            );
            _store
              ..report(ReadRecorded(id, '$read', _Why.adopt.words, at: now))
              ..report(SessionOpenedFor(id, session, snap));
            _note(id, 'adopted from the page list');
            return const _Acted();
        }
      case StoreReadAnswered(:final point):
        if (await _endedTakeUp(id, account, read, snap, point)
            case final step?) {
          return step;
        }
        _wanted.remove(id);
        _note(id, 'not adopted: the server no longer has it');
        return const _Skipped(StallExit.goneOnTakeUp);
      case final other:
        return _readRefused(id, account, read, other, snap);
    }
  }

  Future<_Step?> _endedTakeUp(
    String id,
    Account account,
    ReadOf read,
    Snapshot snap,
    ResultPoint point,
  ) async {
    if (await _onCurrentConnection(point)) {
      return disposed ? const _Ended() : null;
    }
    if (disposed) return const _Ended();
    return _unsettled(
      id,
      account,
      read,
      snap,
      'the read to adopt it came back on a connection that has ended, so it '
      'is read again',
      row: StallExit.lostRead,
    );
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
      return _Skipped(StallExit.localTrouble, at);
    }
    if (_settledAt(id) case final at? when at.isAfter(now)) {
      return _Skipped(StallExit.editsSettling, at);
    }
    CloudStrategy cloud;
    switch (await _store.read(id)) {
      case QueueFound(cloud: final found):
        cloud = found;
      case QueueTroubled(:final trouble):
        return _troubled(id, trouble);
    }
    if (disposed) return const _Ended();
    if (await _writeKept(id, owner, cloud) case final step?) return step;
    retiring.looked(id, cloud, now);
    _forgetResolved(id, cloud, snap);
    _lastSeen[id] = cloud;
    _countClockHeldByLive(id, cloud, now, snap);
    if (_unreadPages(cloud).isEmpty) {
      _unread.remove(id);
    } else {
      _unread.add(id);
    }
    final sends = openAttempts(cloud).isNotEmpty ||
        (_sendable(cloud) && pick(cloud, clientId) is Picked);
    _Planned? planned;
    DateTime? readDue;
    StallExit? reading;
    if (!sends) {
      switch (_plan(id, cloud, now, snap)) {
        case (planned: final next?, due: _, why: _):
          planned = next;
        case (planned: null, due: final at, :final why):
          readDue = at;
          reading = why;
      }
    }
    if (!sends && planned == null && !_livePending(id)) {
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
      return _Skipped(
          _restingOn(id, cloud, reading), _nextDue(id, cloud, snap));
    }
    switch (await _openSession(id, owner, snap)) {
      case _Open(:final opened):
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
    final session = cloud.queue.session.number;
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
    if (_nextLive(id, owner) case (:final read, :final result)) {
      return _takeLive(id, owner, snap, session, cloud, read, result);
    }
    final fresh = _plan(id, cloud, now, snap);
    switch (pick(cloud, clientId)) {
      case final Picked picked when _sendable(cloud):
        return _sendStep(id, owner, snap, picked, session);
      case Picked():
        if (fresh.planned case final next?) {
          return _readStep(id, owner, snap, session, cloud, next);
        }
        _note(id, 'held: ${standingOf(cloud.queue).name}');
        return _Skipped(
          _restingOn(id, cloud, fresh.why),
          _nextDue(id, cloud, snap),
        );
      case NothingSendable(:final why):
        if (fresh.planned case final next?) {
          return _readStep(id, owner, snap, session, cloud, next);
        }
        _note(id, why);
        return _Skipped(
          _restingOn(id, cloud, fresh.why),
          _nextDue(id, cloud, snap),
        );
    }
  }

  ({_Planned? planned, DateTime? due, StallExit? why}) _plan(
    String id,
    CloudStrategy cloud,
    DateTime now,
    Snapshot snap,
  ) {
    final memory = _governor.memory(id, readsUnder(snap));
    final reads = _readsWanted(id, cloud, now, memory).toList();
    _heldByLiveSince.removeWhere(
      (key, _) =>
          key.$1 == id && !reads.any((each) => each.planned.read == key.$2),
    );
    DateTime? due;
    StallExit? why;
    for (final (:planned, :wantedAt) in reads) {
      final gate = _liveGate(id, planned.read, now, snap);
      if (gate is _LiveCurrent && planned.why == _Why.clock) {
        final round = _roundDue(id, planned.read, now, snap);
        if (due == null || round.isBefore(due)) {
          due = round;
          why = StallExit.clockOnWatch;
        }
        continue;
      }
      final (wanted, wantedRow) = switch (gate) {
        _LiveCurrent() when planned.why == _Why.clock => (
            null,
            planned.why.row
          ),
        _LiveCurrent() => switch (_heldByLiveSince.putIfAbsent(
              (id, planned.read), () => now).add(_timing.liveGrace)) {
            final until when until.isAfter(now) => (until, planned.why.row),
            _ => (wantedAt, planned.why.row),
          },
        _LiveAwaitingFirst(:final until) when until.isAfter(wantedAt) => (
            until,
            StallExit.liveNoFirstResult
          ),
        _LiveAwaitingFirst() || _NotLive() => (wantedAt, planned.why.row),
      };
      if (wanted == null) {
        why ??= wantedRow;
        continue;
      }
      final (at, row) = switch (_governor.readAt(id, planned.read, snap)) {
        ReadStopped(:final why) => (null, why),
        ReadFrom(at: final from?, :final why) when from.isAfter(wanted) => (
            from,
            why ?? wantedRow
          ),
        ReadFrom() => (wanted, wantedRow),
      };
      if (at == null) {
        why ??= row;
        continue;
      }
      if (!at.isAfter(now)) return (planned: planned, due: null, why: null);
      if (due == null || at.isBefore(due)) {
        due = at;
        why = row;
      }
    }
    return (planned: null, due: due, why: why);
  }

  StallExit _restingOn(String id, CloudStrategy cloud, StallExit? reading) =>
      switch (standingOf(cloud.queue)) {
        Standing.deletedOnServer => StallExit.deletedOnServer,
        Standing.editAccessLost => _governor.access(id, _inputs)?.cannot == null
            ? StallExit.viewerOnly
            : StallExit.forbidden,
        Standing.upgradeRequired => StallExit.upgrade,
        Standing.held => StallExit.localTrouble,
        Standing.good => switch (Tally.of(cloud.queue, _clock())) {
            _ when reading != null => reading,
            Tally(setAside: > 0) => StallExit.replaced,
            Tally(:final attention)
                when attention.containsKey(Attention.retriesExhausted) =>
              StallExit.lostSend,
            Tally(needingYou: > 0) => StallExit.refusedEdit,
            Tally(stillGoing: > 0) => StallExit.lostSend,
            _ when cloud.queue.landed.isNotEmpty => StallExit.landedWork,
            _ => StallExit.notBeingRead,
          },
      };

  Iterable<({_Planned planned, DateTime wantedAt})> _readsWanted(
    String id,
    CloudStrategy cloud,
    DateTime now,
    ReadMemory memory,
  ) sync* {
    if (standingOf(cloud.queue) == Standing.deletedOnServer) return;
    if (standingOf(cloud.queue) == Standing.editAccessLost) {
      yield (
        planned: (read: const ReadOfList(), why: _Why.access),
        wantedAt: now,
      );
      return;
    }
    final needed = _needsOf(cloud).toList()
      ..sort(
        (a, b) => (_readOf(a) is ReadOfList ? 0 : 1)
            .compareTo(_readOf(b) is ReadOfList ? 0 : 1),
      );
    for (final need in needed) {
      final read = _readOf(need);
      final ahead = cloud.queue.shown.waitsOnClock(switch (read) {
        ReadOfList() => null,
        ReadOfPage(:final page) => page,
      });
      yield (
        planned: (read: read, why: ahead ? _Why.clock : _Why.need),
        wantedAt: now,
      );
    }
    for (final read in _governor.owedFresh(id)) {
      if (read case ReadOfPage(:final page)
          when cloud.queue.shown.trashed.containsKey(page)) {
        _governor.written(id, read);
        continue;
      }
      yield (planned: (read: read, why: _Why.need), wantedAt: now);
    }
    for (final page in _unreadPages(cloud)) {
      yield (planned: (read: ReadOfPage(page), why: _Why.adopt), wantedAt: now);
    }
    for (final (page, at) in retiring.wanted(
      id,
      cloud,
      now,
      _timing.retiring,
      memory.retired,
    )) {
      yield (
        planned: (
          read: page == Retiring.list ? const ReadOfList() : ReadOfPage(page),
          why: _Why.retire,
        ),
        wantedAt: at,
      );
    }
  }

  DateTime? _readAgainAt(String id, ReadOf read, Snapshot snap) =>
      switch (_governor.readAt(id, read, snap)) {
        ReadStopped() => null,
        ReadFrom(:final at) => at ?? _clock(),
      };

  static bool _shownRefused(CloudStrategy cloud, ReadOf read) => switch (read) {
        ReadOfList() => cloud.queue.shown.list is ReadRefused,
        ReadOfPage(:final page) =>
          cloud.queue.shown.pageRead(page) is ReadRefused,
      };

  static List<String> _unreadPages(CloudStrategy cloud) =>
      cloud.queue.shown.pagesToRead.toList();

  static ReadOf _readOf(ResultSubject subject) => switch (subject) {
        PageListResult() => const ReadOfList(),
        RowResult(
          target: StrategyTarget() || PageTarget() || SettingsTarget(),
        ) =>
          const ReadOfList(),
        RowResult(:final page?) => ReadOfPage(page),
        RowResult() => const ReadOfList(),
        PageResult(:final page) => ReadOfPage(page),
      };

  void _forgetResolved(String id, CloudStrategy cloud, Snapshot snap) {
    final memory = _boundMemory(id, snap);
    _governor.keepRungs(id, readsUnder(snap), {
      for (final (:planned, wantedAt: _)
          in _readsWanted(id, cloud, _clock(), memory))
        '${planned.read}',
    });
  }

  static bool _sendable(CloudStrategy cloud) =>
      standingOf(cloud.queue) == Standing.good;

  static int _accessLostAt(CloudStrategy cloud) =>
      cloud.queue.strategy.accessLostAt;

  static Set<ResultSubject> _needsOf(CloudStrategy cloud) => {
        for (final view in cloud.views.values)
          for (final hold in view.holds)
            if (hold case AwaitingResult(:final subject)) subject,
        ...owedReads(cloud.queue),
      };

  static DateTime? _earliest(DateTime? a, DateTime? b) => switch ((a, b)) {
        (null, _) => b,
        (_, null) => a,
        (final a?, final b?) => a.isBefore(b) ? a : b,
      };

  Future<Issued> _issue(
    String id,
    Account account,
    ReadOf read,
    Snapshot snap,
    _Why why,
  ) async {
    if (_store.shut != null) return const NotYet(null, StallExit.localTrouble);
    if (_store.store.refusedStrategies[id] case final refusal?) {
      _store.refused(id, refusal);
      _note(id, 'held: $refusal');
      return const NotYet(null, StallExit.localTrouble);
    }
    sendingUnder = snap;
    reading = why.words;
    try {
      return await _governor.issue(id, account, read, snap);
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
    final under = readsUnder(snap);
    final StoreReadOutcome outcome;
    final DateTime started;
    final kept = _governor.heldFor(id, read, under);
    switch (kept) {
      case (
            outcome: final kept,
            started: final at,
            under: _,
            readIn: final heldIn?
          )
          when heldIn == session:
        outcome = kept;
        started = at;
      case _:
        if (_governor.readAt(id, read, snap)
            case ReadFrom(:final at?, why: final row)
            when at.isAfter(_clock())) {
          return _Skipped(row ?? why.row, at);
        }
        switch (await _issue(id, owner, read, snap, why)) {
          case NotYet(:final at, why: final row):
            return _Skipped(row ?? why.row, at);
          case Answered(outcome: final fresh, started: final at):
            outcome = fresh;
            started = at;
            _owedPastTheWatch.remove((id, read));
        }
    }
    return _answered(
      id,
      owner,
      snap,
      session,
      cloud,
      planned,
      outcome,
      started,
      late: kept != null,
      troubled: () => _governor.hold(id, read, (
        outcome: outcome,
        started: started,
        under: under,
        readIn: session,
      )),
    );
  }

  Future<_Step> _takeLive(
    String id,
    Account owner,
    Snapshot snap,
    int session,
    CloudStrategy cloud,
    ReadOf read,
    _LiveResult result,
  ) async {
    var handled = false;
    _live[(id, read)]?.taking = result;
    final step = await _answered(
      id,
      owner,
      snap,
      session,
      cloud,
      (read: read, why: _Why.live),
      await _outcomeOf(id, read, result.answer),
      result.at,
      late: false,
      troubled: () {},
      handled: () => handled = true,
    );
    if (_live[(id, read)] case final live?
        when identical(live.taking, result)) {
      live.taking = null;
    }
    if (step is _Ended) return step;
    final troubled = step is _Skipped && step.why == StallExit.localTrouble;
    if (handled) {
      _live[(id, read)]?.written(result);
      _forgetEnded(id, read);
      if (step is _Acted) liveTaken++;
      if (step is! _Acted) _live[(id, read)]?.deliveredOn = null;
    } else if (!troubled) {
      _owe(id, read);
    }
    return step;
  }

  Future<_Step> _answered(
    String id,
    Account owner,
    Snapshot snap,
    int session,
    CloudStrategy cloud,
    _Planned planned,
    StoreReadOutcome outcome,
    DateTime started, {
    required bool late,
    required void Function() troubled,
    void Function()? handled,
  }) async {
    final (:read, :why) = planned;
    final marking = switch (why) {
      _Why.need || _Why.clock || _Why.adopt || _Why.live => cloud,
      _Why.access || _Why.retire => null,
    };
    if (disposed) return const _Ended();
    if (_inputs != snap) {
      _note(
          id,
          'read $read (${why.words}); it came back after the inputs '
          'changed, so it is dropped and read again');
      return const _Restart();
    }
    switch (outcome) {
      case StoreReadAnswered(:final base, :final point, :final role):
        final confirms = why == _Why.access && (role?.edits ?? false);
        final asked = (session: session, point: point);
        final now = await _currentGeneration();
        if (disposed) return const _Ended();
        if (now == null) {
          _note(
              id,
              'read $read came back while the client could not say which '
              'connection it is on, so it is read again');
          return const _Restart();
        }
        final written = await _store.write(owner, id, onConnection: now, [
          BaseArrived(base, session: session, point: point),
          if (confirms)
            EditAccessConfirmed(
              afterAttempt: _accessLostAt(cloud),
              session: session,
              point: point,
            ),
        ]);
        if (disposed) return const _Ended();
        if (written case WrittenWith(:final notApplied)
            when notApplied.isEmpty) {
          handled?.call();
        }
        switch (written) {
          case WriteTroubled(trouble: ResultNotStored(:final why)):
            _governor.written(id, read, late: late);
            _governor.keep(id, read, _refusedMark(read, why, asked));
            return _unsettled(
              id,
              owner,
              read,
              snap,
              'the store would not keep $read: $why',
              row: StallExit.unreadableRead,
              planned: cloud,
            );
          case WriteTroubled(:final trouble):
            troubled();
            return _troubled(id, trouble);
          case WrittenWith(:final notApplied) when notApplied.isNotEmpty:
            _governor.written(id, read, late: late);
            return _unsettled(
              id,
              owner,
              read,
              snap,
              'the queue did not take $read: ${notApplied.join('; ')}',
              row: StallExit.refusedResult,
              marking: marking,
              asked: asked,
              planned: cloud,
            );
          case WrittenWith(:final effects):
            _governor.written(id, read, late: late);
            if (read case ReadOfPage(:final page)
                when effects.any(
                  (effect) =>
                      effect is PageResultDeferred && effect.page == page,
                )) {
              return _unsettled(
                id,
                owner,
                read,
                snap,
                'the page list and page $page keep disagreeing about which '
                'life the page is in',
                row: StallExit.pageAheadOfList,
                marking: marking,
                asked: asked,
                planned: cloud,
              );
            }
        }
        if (_inputs != snap) return const _Restart();
        if (read is ReadOfList) _unread.add(id);
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
        handled?.call();
        return _readRefused(
          id,
          owner,
          read,
          other,
          snap,
          marking: marking,
          readIn: session,
          planned: cloud,
        );
    }
  }

  void _recorded(
    String id,
    ReadOf read,
    _Why why,
    StoreReadRole? role,
    CloudStrategy cloud,
    DateTime started,
    Snapshot snap,
  ) {
    switch (why) {
      case _Why.access when !(role?.edits ?? false):
        _governor.climbAccess(id, snap, null);
      case _Why.access ||
            _Why.need ||
            _Why.clock ||
            _Why.adopt ||
            _Why.retire ||
            _Why.live:
        _governor.accessConfirmed(id);
    }
    final memory = _boundMemory(id, snap);
    _governor.remember(
        id,
        switch (why) {
          _Why.need ||
          _Why.clock ||
          _Why.adopt =>
            memory.climbed('$read', started, why.row),
          _Why.retire => memory.withRetired(switch (read) {
              ReadOfPage(:final page) =>
                Retiring.read(memory.retired, page, cloud, started),
              ReadOfList() =>
                Retiring.read(memory.retired, Retiring.list, cloud, started),
            }),
          _Why.access || _Why.live => memory,
        });
    _store.report(ReadRecorded(id, '$read', why.words, at: started));
  }

  Future<_Step> _unsettled(
    String id,
    Account owner,
    ReadOf read,
    Snapshot snap,
    String why, {
    required StallExit row,
    CloudStrategy? marking,
    _Asked? asked,
    CloudStrategy? planned,
  }) async {
    final climbed = _boundMemory(id, snap).climbed('$read', _clock(), row);
    final count = climbed.settle['$read']!.count;
    _governor.remember(id, climbed);
    if ((marking, asked) case (final marking?, final asked?)
        when count >= _timing.unresolvedRounds &&
            !_shownRefused(marking, read)) {
      _governor.keep(id, read, _refusedMark(read, why, asked));
    } else if (asked case (:final point, session: _)) {
      _governor.keep(id, #stamp, ConnectionReturned(point.generation));
    }
    if (await _writeKept(id, owner) case final step?) return step;
    final at = _readAgainAt(id, read, snap);
    _note(id, '$why ($count in a row); reading $read again at $at');
    return _Skipped(row, _earliest(at, _nextDue(id, planned, snap)));
  }

  DateTime? _nextDue(String id, CloudStrategy? cloud, Snapshot snap) {
    if (cloud == null) return null;
    final now = _clock();
    final read = switch (_plan(id, cloud, now, snap)) {
      (planned: _?, due: _, why: _) => now,
      (planned: null, :final due, why: _) => due,
    };
    final send = switch (pick(cloud, clientId)) {
      Picked() when _sendable(cloud) =>
        _governor.sendAt(id) ?? _settledAt(id) ?? now,
      Picked() => null,
      NothingSendable(:final retryAt) => retryAt,
    };
    return _earliest(read, send);
  }

  static QueueEvent _refusedMark(ReadOf read, String problem, _Asked asked) =>
      ResultRefused(
        page: switch (read) {
          ReadOfPage(:final page) => page,
          ReadOfList() => null,
        },
        problem: problem,
        session: asked.session,
        point: asked.point,
      );

  Future<_Step?> _writeKept(
    String id,
    Account owner, [
    CloudStrategy? seen,
  ]) async {
    final kept = _governor.kept(id);
    if (kept.isEmpty) return null;
    var cloud = seen;
    if (cloud == null) {
      switch (await _store.read(id)) {
        case QueueFound(cloud: final found):
          cloud = found;
        case QueueTroubled(:final trouble):
          return _troubled(id, trouble);
      }
      if (disposed) return const _Ended();
    }
    for (final MapEntry(key: subject, value: write) in kept.entries) {
      if (subject case final ReadOf read when _shownRefused(cloud, read)) {
        _governor.keptWritten(id, subject);
        continue;
      }
      final events = await _onTheCurrentConnection([write]);
      if (disposed) return const _Ended();
      if (events == null) continue;
      final written = await _store.write(owner, id, events);
      if (disposed) return const _Ended();
      switch (written) {
        case WriteTroubled(:final trouble):
          return _troubled(id, trouble);
        case WrittenWith(:final effects):
          _governor.keptWritten(id, subject);
          _note(id, 'wrote what it had kept: $write');
          if (_holdsFrom(effects, _inputs)) return const _Restart();
      }
    }
    return null;
  }

  Future<DateTime?> _writeKeptWhileHeld(Account owner) async {
    DateTime? due;
    for (final id in _governor.keeping) {
      if (notBefore[id] case final at? when at.isAfter(_clock())) {
        due = _earliest(due, at);
        continue;
      }
      switch (await _writeKept(id, owner)) {
        case _Skipped(due: final at?):
          due = _earliest(due, at);
        case _Ended():
          return null;
        case _:
          break;
      }
      if (disposed) return null;
    }
    return due;
  }

  Future<_Step> _readRefused(
    String id,
    Account owner,
    ReadOf read,
    StoreReadOutcome outcome,
    Snapshot snap, {
    CloudStrategy? marking,
    int? readIn,
    CloudStrategy? planned,
  }) async {
    switch (outcome) {
      case StoreReadRefused(
          refusal: final refusal &&
              (StoreReadRefusal.accountMismatch ||
                  StoreReadRefusal.unauthenticated ||
                  StoreReadRefusal.upgradeRequired),
          :final why,
          :final point,
        ):
        final session = readIn;
        if (session == null) {
          if (await _onCurrentConnection(point)) {
            switch (refusal) {
              case StoreReadRefusal.upgradeRequired:
                upgradeAsked = true;
                _note(id, 'the read to adopt it asks for a newer build');
              case _:
                signInWaitFrom = snap.signIns;
                _note(
                    id,
                    'the read to adopt it was refused for the sign-in: '
                    '$why');
            }
            return const _Acted();
          }
          return _unsettled(
            id,
            owner,
            read,
            snap,
            'the read to adopt it was refused ($why) on a connection that has '
            'ended, so it is read again',
            row: StallExit.lostRead,
            planned: planned,
          );
        }
        final event = switch (refusal) {
          StoreReadRefusal.upgradeRequired => ReadRefusedForUpgrade(
              build: build,
              session: session,
              point: point,
            ),
          StoreReadRefusal.accountMismatch => ReadRefusedForSignIn(
              SignInRefusal.accountMismatch,
              session: session,
              point: point,
            ),
          _ => ReadRefusedForSignIn(
              SignInRefusal.unauthenticated,
              session: session,
              point: point,
            ),
        };
        if (event is ReadRefusedForUpgrade) _governor.keep(id, #upgrade, event);
        final events = await _onTheCurrentConnection([event]);
        if (disposed) return const _Ended();
        if (events == null) {
          return _unsettled(
            id,
            owner,
            read,
            snap,
            'the read was refused ($why), and the client did not say which '
            'connection it is on now',
            row: StallExit.lostRead,
            planned: planned,
          );
        }
        final written = await _store.write(owner, id, events);
        if (disposed) return const _Ended();
        switch (written) {
          case WriteTroubled(:final trouble):
            return _troubled(id, trouble);
          case WrittenWith(:final effects):
            _governor.keptWritten(id, #upgrade);
            if (_holdsFrom(effects, snap)) {
              _note(id, 'the read was refused: $why');
              return const _Acted();
            }
            return _unsettled(
              id,
              owner,
              read,
              snap,
              'the read was refused ($why) on a connection that has since '
              'ended',
              row: StallExit.lostRead,
              planned: planned,
            );
        }
      case StoreReadRefused(
          refusal: StoreReadRefusal.forbidden,
          :final why,
          :final point,
        ):
        if (!await _onCurrentConnection(point)) {
          if (disposed) return const _Ended();
          return _unsettled(
            id,
            owner,
            read,
            snap,
            'the read was refused ($why) on a connection that has ended, so '
            'it is read again',
            row: StallExit.lostRead,
            planned: planned,
          );
        }
        if (disposed) return const _Ended();
        final cannot = CannotRead(why);
        _governor.climbAccess(id, snap, cannot);
        final at = _readAgainAt(id, read, snap);
        _note(
          id,
          at == null
              ? '$cannot; reads stop until the user asks, a sign-in or the '
                  'app starts again'
              : '$cannot; reading again at $at',
        );
        return _Skipped(
          StallExit.forbidden,
          _earliest(at, _nextDue(id, planned, snap)),
        );
      case StoreReadUnreadable(:final problem, :final point):
        return _unsettled(
          id,
          owner,
          read,
          snap,
          'the read came back in rows this build cannot read ($problem)',
          row: StallExit.unreadableRead,
          marking: marking,
          planned: planned,
          asked: switch (readIn) {
            final session? => (session: session, point: point),
            null => null,
          },
        );
      case StoreReadLost(:final why):
        return _unsettled(
          id,
          owner,
          read,
          snap,
          'the read was lost ($why)',
          row: StallExit.lostRead,
          planned: planned,
        );
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
      return _Skipped(StallExit.editsSettling, at);
    }
    if (_governor.sendAt(id) case final at?) {
      return _Skipped(StallExit.sendSpacing, at);
    }
    final ClaimedBatch batch;
    switch (await _store.claim(
      owner,
      id,
      picked,
      _clock(),
      elapsed: _elapsed,
      session: session,
    )) {
      case Claimed(batch: final claimed):
        batch = claimed;
        _firstEdit.remove(id);
        _lastEdit.remove(id);
      case NotClaimed(:final why):
        _note(id, 'not claimed: $why');
        return _Skipped(
          StallExit.localTrouble,
          notBefore[id] = _clock().add(_timing.firstWriteRetry),
        );
      case ClaimTroubled(:final trouble):
        return _troubled(id, trouble);
    }
    if (disposed) return const _Ended();
    if (_whyNotSend(id, snap) case final why?) {
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
    final events = switch (outcome) {
      StoreBatchLost() => answersOf(batch, outcome, _clock()),
      _ => await _onTheCurrentConnection([
            ...answersOf(batch, outcome, _clock()),
            if (outcome
                case StoreBatchAnswered(
                  serverTime: final time?,
                  :final point,
                  :final answers,
                ) when answers.isNotEmpty)
              ServerTimeHeld(
                time,
                at: answeredAt,
                session: batch.session,
                point: point,
              ),
          ]) ??
          [
            TransportFailed(
              batch.attempt,
              TransportFailure.network,
              at: _clock(),
            ),
          ],
    };
    if (disposed) return const _Ended();
    final written = await _store.write(owner, id, events, batch: batch);
    if (disposed) return const _Ended();
    switch (written) {
      case WrittenWith(:final effects, :final notApplied):
        _holdsFrom(effects, snap);
        final evidence = _evidenceOf(batch, outcome, effects);
        if (evidence.isNotEmpty) _governor.newEvidence(id, evidence);
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

  static Set<ReadOf> _evidenceOf(
    ClaimedBatch batch,
    StoreBatchOutcome outcome,
    List<QueueEffect> effects,
  ) {
    final admitted = {
      for (final effect in effects)
        if (effect case AnswerAdmitted(:final attempt, :final opId)
            when attempt == batch.attempt)
          opId,
    };
    return switch (outcome) {
      StoreBatchRefusedWhole() ||
      StoreBatchOutsideWindow() when admitted.contains(null) =>
        {const ReadOfList()},
      StoreBatchAnswered(:final answers) => {
          for (final answer in answers)
            if (_refusesAnEdit(answer) && admitted.contains(answer.opId))
              for (final op in batch.ops)
                if (op.opId == answer.opId) _subjectOf(op),
        },
      _ => const {},
    };
  }

  bool _holdsFrom(List<QueueEffect> effects, Snapshot snap) {
    var holds = false;
    for (final effect in effects) {
      switch (effect) {
        case HoldSendingForUpgrade():
          upgradeAsked = true;
          holds = true;
        case ReportUnauthenticated() || ReportAccountMismatch():
          signInWaitFrom = snap.signIns;
          holds = true;
        case _:
          break;
      }
    }
    return holds;
  }

  static ReadOf _subjectOf(StrategyOp op) => switch (targetOf(op)) {
        StrategyTarget() ||
        PageTarget() ||
        SettingsTarget() =>
          const ReadOfList(),
        _ => switch (pagesNeeded(op).firstOrNull) {
            final page? => ReadOfPage(page),
            null => const ReadOfList(),
          },
      };

  static bool _refusesAnEdit(OpAnswer answer) => switch (answer) {
        RejectedAnswer() || FailedAnswer() => true,
        AppliedAnswer() ||
        NoopAnswer() ||
        AnswerWithoutLife() ||
        NoopWithoutRevision() =>
          false,
      };

  Future<bool> _onCurrentConnection(ResultPoint point) async {
    try {
      final now = await _lookUpGeneration();
      return point.client == now.client && point.connection == now.connection;
    } catch (_) {
      return false;
    }
  }

  Future<Generation?> _currentGeneration() async {
    if (_inputs.connection == null) return null;
    try {
      final now = await _lookUpGeneration();
      return Generation(client: now.client, connection: now.connection);
    } catch (_) {
      return null;
    }
  }

  Future<List<QueueEvent>?> _onTheCurrentConnection(
    List<QueueEvent> events,
  ) async {
    if (_inputs.connection == null) return null;
    try {
      final now = await _lookUpGeneration();
      return [
        ConnectionReturned(
          Generation(client: now.client, connection: now.connection),
        ),
        ...events,
      ];
    } catch (_) {
      return null;
    }
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
    final ({int client, int connection}) on;
    try {
      on = await _lookUpGeneration();
    } catch (error) {
      return _Troubled(
        NotWrittenNow('the client did not say which connection it is on: '
            '$error'),
      );
    }
    if (disposed) return const _Stale('the sender was disposed');
    if (snap != _inputs) {
      return const _Stale(
        'the connection, the account or the sign-in changed while the client '
        'said which connection it is on',
      );
    }
    final events = [
      if (!restarted.contains(id)) AppRestarted(build: build),
      if (last != null && last.account != account) const AccountChanged(),
      ConnectionReturned(
        Generation(client: on.client, connection: on.connection),
      ),
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

  String? _whyNotSend(String id, Snapshot snap) {
    final now = _inputs;
    if (held case final reason?) return 'sending is held: $reason';
    if (_store.shut case final shut?) return shut.why;
    if (_store.store.refusedStrategies[id] case final refusal?) {
      _store.refused(id, refusal);
      return 'the store refused the strategy: $refusal';
    }
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
        () =>
            _governor.send(batch) ??
            (throw StateError('a batch reached the governor inside the floor')),
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
        return _Skipped(
          StallExit.localTrouble,
          notBefore[id] = _clock().add(_timing.heldRetry),
        );
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
        return _Skipped(StallExit.localTrouble, at);
      case StrategyHeld(:final why) || ResultNotStored(:final why):
        final at = notBefore[id] = _clock().add(_timing.heldRetry);
        _note(id, 'held: $why; looking again at $at');
        return _Skipped(StallExit.localTrouble, at);
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
      StoreBatchAnswered(:final answers, :final complete, :final point) => [
          for (final answer in answers)
            OpAnswered(batch.attempt, answer, point: point),
          if (!complete)
            TransportFailed(
              batch.attempt,
              TransportFailure.missingAnswer,
              at: at,
            ),
        ],
      StoreBatchRefusedWhole(
        :final refusal,
        :final currentLife,
        :final point
      ) =>
        [
          BatchRefused(
            batch.attempt,
            refusal,
            point: point,
            at: at,
            currentLife: currentLife,
          ),
        ],
      StoreBatchLost(:final failure) => [
          TransportFailed(batch.attempt, failure, at: at),
        ],
      StoreBatchAccountMismatch(:final point) => [
          BatchAccountMismatch(batch.attempt, point: point),
        ],
      StoreBatchOutsideWindow(:final point) => [
          BatchRefused(
            batch.attempt,
            BatchRefusal.uncheckedTooLate,
            point: point,
            at: at,
          ),
        ],
    };
