import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus_library/icarus_library.dart';

final class SenderTiming {
  const SenderTiming({
    this.wait = const Duration(milliseconds: 180),
    this.longestWait = const Duration(seconds: 1),
    this.giveUpAfter = const Duration(seconds: 45),
    this.firstWriteRetry = const Duration(seconds: 2),
    this.longestWriteRetry = const Duration(minutes: 1),
    this.heldRetry = const Duration(minutes: 1),
  });

  final Duration wait;
  final Duration longestWait;
  final Duration giveUpAfter;
  final Duration firstWriteRetry;
  final Duration longestWriteRetry;
  final Duration heldRetry;

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

typedef Bound = ({int connection, Account account, int number});

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

typedef _Arrival = ({
  int number,
  ResultForStore result,
  Completer<ResultOutcome> answer,
});

final class CloudSender implements ResultIntake {
  CloudSender({
    required SenderStore store,
    required StoreBatchSend send,
    required this.build,
    required this.clientId,
    Snapshot inputs = (account: null, connection: null, signIns: 0),
    SenderTiming timing = const SenderTiming(),
    DateTime Function()? clock,
    bool Function()? recordsConnectionLost,
  })  : _store = store,
        _send = send,
        _inputs = inputs,
        _timing = timing,
        _clock = clock ?? DateTime.now,
        _recordsLost = recordsConnectionLost ?? (() => true);

  final SenderStore _store;
  final StoreBatchSend _send;
  final SenderTiming _timing;
  final DateTime Function() _clock;
  final bool Function() _recordsLost;
  final String build;
  final String clientId;

  Snapshot _inputs;
  int? signInWaitFrom;
  var upgradeAsked = false;
  String? held;
  String? ended;
  var disposed = false;
  int? resultsSignIns;
  final bound = <String, Bound>{};
  final restarted = <String>{};
  final notBefore = <String, DateTime>{};
  final _failures = <String, int>{};
  final lastServed = <String, int>{};
  final _lastEdit = <String, DateTime>{};
  final _firstEdit = <String, DateTime>{};
  final _checkedClean = <String>{};
  final _results = ListQueue<_Arrival>();
  var _arrived = 0;
  var looks = 0;
  var wakes = 0;
  var dues = 0;
  var acts = 0;
  var inStep = false;
  Snapshot? sendingUnder;

  var _woken = true;
  Completer<void>? _waiting;
  Timer? _due;
  final _last = <String, String>{};
  final _views = StreamController<SenderView>.broadcast(sync: true);
  SenderView _view = (run: 'starting', strategies: const {});
  Future<void>? _running;

  SenderStore get store => _store;

  Snapshot get inputs => _inputs;

  SenderView get view => _view;

  Stream<SenderView> get views => _views.stream;

  Future<void> get done => _running ?? Future<void>.value();

  bool get busy => inStep || _results.isNotEmpty;

  RunHold? get runHold => switch (this) {
        CloudSender(upgradeAsked: true) => const UpgradeHold(),
        CloudSender(signInWaitFrom: final from?) when from == _inputs.signIns =>
          SignInHold(from),
        _ => null,
      };

  set inputs(Snapshot next) {
    if (disposed) return;
    _inputs = next;
    wake();
  }

  StreamSubscription<StoreChange>? _changes;

  void start() {
    _changes ??= _store.store.changes.listen(
      (change) => switch (change) {
        StrategyEdited(:final strategyPublicId) => edited(strategyPublicId),
        _ => wake(),
      },
      onDone: wake,
    );
    _running ??= _run();
  }

  void wake() {
    wakes++;
    _woken = true;
    final waiting = _waiting;
    _waiting = null;
    _due?.cancel();
    _due = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  void edited(String strategyId) {
    final now = _clock();
    _lastEdit[strategyId] = now;
    _firstEdit[strategyId] ??= now;
    _checkedClean.remove(strategyId);
    wake();
  }

  @override
  void resultsFrom(int signIns) => resultsSignIns ??= signIns;

  @override
  Future<ResultOutcome> take(ResultForStore result) {
    if (disposed || ended != null) {
      return Future.value(
        ResultNotRecorded(ended ?? 'the sender was disposed'),
      );
    }
    final answer = Completer<ResultOutcome>();
    _results.add((number: ++_arrived, result: result, answer: answer));
    wake();
    return answer.future;
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
    _refuseWaitingResults('the sender was disposed');
    wake();
    _publish();
    unawaited(_views.close());
  }

  void _refuseWaitingResults(String why) {
    while (_results.isNotEmpty) {
      final (:answer, number: _, result: _) = _results.removeFirst();
      if (!answer.isCompleted) answer.complete(ResultNotRecorded(why));
    }
  }

  Future<void> _run() async {
    try {
      await _loop();
    } finally {
      _refuseWaitingResults(
        ended ?? (disposed ? 'the sender was disposed' : 'the loop stopped'),
      );
    }
  }

  Future<bool> _recordArrivals({int? before}) async {
    while (_results.isNotEmpty &&
        (before == null || _results.first.number < before)) {
      final (number: _, :result, :answer) = _results.removeFirst();
      final outcome = await _takeResult(result);
      if (!answer.isCompleted) answer.complete(outcome);
      if (disposed || ended != null) return false;
    }
    return true;
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
      inStep = true;
      final going = await _recordArrivals();
      inStep = false;
      if (!going) return;
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
      final now = _clock();
      final candidates = [
        for (final stored in _store.strategies())
          if (stored.ownerAccount == snap.account &&
              (stored.tally == null
                  ? !_checkedClean.contains(stored.id)
                  : stored.hasWorkToSend))
            stored,
      ]..sort(
          (a, b) => (lastServed[a.id] ?? -1).compareTo(lastServed[b.id] ?? -1),
        );
      for (final stored in candidates) {
        inStep = true;
        final step = await _step(stored, stored.ownerAccount!, snap, now);
        inStep = false;
        switch (step) {
          case _Acted():
            lastServed[stored.id] = looks;
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

  Future<ResultOutcome> _takeResult(ResultForStore result) async {
    final stamp = result.stamp;
    final id = result.strategyId;
    final takenUnder = resultsSignIns;
    if (takenUnder == null) {
      return const ResultStale('results have not begun for this run');
    }
    if (stamp.account != _inputs.account) {
      return const ResultStale(
        'the account its read named is not the account signed in',
      );
    }
    if (stamp != _inputs) {
      return const ResultStale(
        'the connection, the account or the sign-in changed since',
      );
    }
    if (stamp.signIns != takenUnder) {
      return const ResultStale(
        'results stop for the run at the first change of sign-in, because '
        'the reads that bring them do not yet name their account',
      );
    }
    final (connection, account) = (stamp.connection, stamp.account);
    if (connection == null || account == null) {
      return const ResultStale('it arrived offline or signed out');
    }
    StoredStrategy? listed;
    for (final stored in _store.strategies()) {
      if (stored.id == id) listed = stored;
    }
    if (listed == null) {
      if (result is! ListResultForStore) {
        return const ResultStale('the store does not hold the strategy yet');
      }
      final written = await _store.add(account, id, result.header);
      if (disposed) return const ResultNotRecorded('the sender was disposed');
      switch (written) {
        case WriteTroubled(trouble: StoreShut(:final why)):
          _end(why);
          return ResultNotRecorded(why);
        case WriteTroubled(:final trouble):
          return ResultNotRecorded(trouble.why);
        case WrittenWith(:final session):
          restarted.add(id);
          if (stamp != _inputs) {
            return const ResultStale(
              'the connection or the account changed while it was added',
            );
          }
          if (session == null) {
            return const ResultNotRecorded('its session could not be read');
          }
          bound[id] =
              (connection: connection, account: account, number: session);
          _store.reports
            ..add(SessionOpenedFor(id, session, stamp))
            ..add(
              ResultWritten(
                id,
                session,
                stamp,
                inputsWhenWritten: _inputs,
                result: result,
              ),
            );
          return ResultRecorded(session, added: true);
      }
    }
    if (listed.ownerAccount != account) {
      return const ResultNotRecorded('the strategy is another account\'s');
    }
    final int number;
    switch (await _openSession(id, account, stamp)) {
      case _Open(number: final open):
        number = open;
      case _Stale(:final why):
        return ResultStale(why);
      case _Troubled(:final trouble):
        if (trouble is StoreShut) _end(trouble.why);
        return ResultNotRecorded(trouble.why);
    }
    final base = switch (result) {
      ListResultForStore(:final header) => header as ArrivedBase,
      PageResultForStore(:final page) => page,
    };
    final inputsWhenWritten = _inputs;
    final written = await _store.write(account, id, [
      BaseArrived(base, session: number),
    ]);
    if (disposed) return const ResultNotRecorded('the sender was disposed');
    switch (written) {
      case WriteTroubled(:final trouble):
        if (trouble is StoreShut) _end(trouble.why);
        return ResultNotRecorded(trouble.why);
      case WrittenWith(:final notApplied) when notApplied.isNotEmpty:
        return ResultStale(notApplied.join('; '));
      case WrittenWith():
        _checkedClean.remove(id);
        _store.reports.add(
          ResultWritten(
            id,
            number,
            stamp,
            inputsWhenWritten: inputsWhenWritten,
            result: result,
          ),
        );
        return ResultRecorded(number, added: false);
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
        last.account == account) {
      return _Open(last.number, opened: false);
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
        bound[id] = (connection: connection, account: account, number: session);
        _store.reports.add(SessionOpenedFor(id, session, snap));
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

  Future<_Step> _step(
    StoredStrategy stored,
    Account owner,
    Snapshot snap,
    DateTime now,
  ) async {
    final id = stored.id;
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
    if (openAttempts(cloud).isEmpty) {
      if (pick(cloud, clientId)
          case NothingSendable(:final why, :final retryAt)) {
        if (stored.tally == null && retryAt == null) _checkedClean.add(id);
        _note(id, why);
        return _Skipped(retryAt);
      }
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
    final Picked picked;
    switch (pick(cloud, clientId)) {
      case NothingSendable(:final why, :final retryAt):
        _note(id, why);
        return _Skipped(retryAt);
      case final Picked found:
        picked = found;
    }
    final ClaimedBatch batch;
    switch (await _store.claim(owner, id, picked, _clock())) {
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
    final outcome = await _call(batch);
    final answeredAs = ++_arrived;
    sendingUnder = null;
    if (disposed) return const _Ended();
    if (!await _recordArrivals(before: answeredAs)) return const _Ended();
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
          : answersOf(batch, outcome, _clock()),
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
        ),
      ).timeout(
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
    };
