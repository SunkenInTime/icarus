import 'dart:async';
import 'dart:math';

import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus_library/icarus_library.dart';

typedef SenderInputs = ({Account? account, int? connection, int authChanges});

enum ReleaseCause {
  sessionChanged('the connection, the sign-in or the account changed during '
      'the claim'),
  otherAccount('the server saw another account signed in'),
  held('sending was held while the claim was made');

  const ReleaseCause(this.words);

  final String words;
}

sealed class WritePurpose {
  const WritePurpose();
}

final class AnswerOf extends WritePurpose {
  const AnswerOf(this.batch);

  final ClaimedBatch batch;

  @override
  String toString() => 'the answer to $batch';
}

final class ReleaseOf extends WritePurpose {
  const ReleaseOf(this.batch, this.cause);

  final ClaimedBatch batch;
  final ReleaseCause cause;

  @override
  String toString() => 'giving back $batch unsent: ${cause.words}';
}

final class SessionOpening extends WritePurpose {
  const SessionOpening(this.mark);

  final SessionMark mark;

  @override
  String toString() => 'opening a session on connection ${mark.connection}';
}

final class SessionClosing extends WritePurpose {
  const SessionClosing();

  @override
  String toString() => 'recording that the connection was lost';
}

final class StoreWrite {
  StoreWrite(this.owner, List<QueueEvent> events, this.purpose)
      : events = List.unmodifiable(events);

  final Account owner;
  final List<QueueEvent> events;
  final WritePurpose purpose;
}

sealed class InFlight {
  const InFlight(this.request);

  final int request;
}

final class ClaimInFlight extends InFlight {
  const ClaimInFlight(super.request, this.session);

  final SessionMark session;

  @override
  String toString() => 'claiming';
}

final class CallInFlight extends InFlight {
  const CallInFlight(super.request, this.batch);

  final ClaimedBatch batch;

  @override
  String toString() => 'sending $batch';
}

final class WriteInFlight extends InFlight {
  const WriteInFlight(super.request, this.write);

  final StoreWrite write;

  @override
  String toString() => 'writing ${write.purpose}';
}

final class WriteRetry {
  const WriteRetry(this.failures, this.at, this.why);

  final int failures;
  final DateTime at;
  final String why;
}

final class Looked {
  const Looked(this.summary, this.why, this.retryAt);

  final StrategySummary summary;
  final String why;
  final DateTime? retryAt;
}

final class Parked {
  const Parked(this.summary, this.why);

  final StrategySummary summary;
  final String why;
}

final class StrategyMemory {
  SessionMark? session;
  bool restarted = false;
  StoreWrite? owed;
  WriteRetry? retry;
  Parked? parked;
  Looked? looked;
  StrategySummary? seen;
  DateTime? seenAt;
  InFlight? flight;
  final wanted = <int, List<Completer<bool>>>{};
}

final class RunMemory {
  bool upgradeAsked = false;
  int? signInWaitsFrom;
  String? held;
  String? shut;
  bool disposed = false;
}

sealed class StrategyStatus {
  const StrategyStatus();
}

final class StatusBusy extends StrategyStatus {
  const StatusBusy(this.flight);

  final InFlight flight;

  @override
  String toString() => 'busy: $flight';
}

final class StatusWaiting extends StrategyStatus {
  const StatusWaiting(this.why, {this.until});

  final String why;
  final DateTime? until;

  @override
  String toString() => until == null ? why : '$why, until $until';
}

final class StatusAllSent extends StrategyStatus {
  const StatusAllSent();

  @override
  String toString() => 'nothing to send';
}

sealed class SenderAction {
  const SenderAction();
}

final class StartWrite extends SenderAction {
  const StartWrite(this.write);

  final StoreWrite write;
}

final class StartClaim extends SenderAction {
  const StartClaim(this.session);

  final SessionMark session;
}

final class Plan {
  const Plan(this.status, {this.action, this.wakeAt, this.sessionOpen});

  final StrategyStatus status;
  final SenderAction? action;
  final DateTime? wakeAt;
  final SessionMark? sessionOpen;
}

final class SenderTiming {
  const SenderTiming({
    this.wait = const Duration(milliseconds: 180),
    this.giveUpAfter = const Duration(seconds: 45),
    this.firstWriteRetry = const Duration(seconds: 2),
    this.longestWriteRetry = const Duration(minutes: 1),
  });

  final Duration wait;
  final Duration giveUpAfter;
  final Duration firstWriteRetry;
  final Duration longestWriteRetry;

  Duration writeRetryAfter(int failures) {
    final doubled = firstWriteRetry * pow(2, min(failures - 1, 10)).toInt();
    return doubled < longestWriteRetry ? doubled : longestWriteRetry;
  }
}

String _whose(Account account) => account.subject;

Plan planFor(
  StoredStrategy stored,
  StrategyMemory memory,
  RunMemory run,
  SenderInputs inputs,
  DateTime now,
  SenderTiming timing, {
  required String build,
}) {
  if (run.shut case final why?) {
    return Plan(StatusWaiting('the store is shut: $why'));
  }
  if (memory.flight case final flight?) return Plan(StatusBusy(flight));
  if (run.disposed) return const Plan(StatusWaiting('the sender was disposed'));
  if (memory.parked case Parked(:final summary, :final why)
      when identical(summary, stored.summary)) {
    return Plan(StatusWaiting('held: $why'));
  }
  if (memory.retry case WriteRetry(:final at, :final why)
      when now.isBefore(at)) {
    return Plan(
      StatusWaiting('could not be written ($why); trying again', until: at),
      wakeAt: at,
    );
  }
  if (memory.owed case final owed?) {
    return Plan(StatusBusy(WriteInFlight(0, owed)), action: StartWrite(owed));
  }
  final owner = switch (stored.owner) {
    OwnedBy(:final account) => account,
    OwnerUnreadable() => null,
  };
  final connection = inputs.connection;
  if (connection == null) {
    if (memory.session case final open? when owner != null) {
      return Plan(
        StatusWaiting('the app is offline'),
        action: StartWrite(
          StoreWrite(
              open.account, const [ConnectionLost()], const SessionClosing()),
        ),
      );
    }
    return const Plan(StatusWaiting('the app is offline'));
  }
  if (owner == null) {
    return const Plan(StatusWaiting('held: its owner cannot be read'));
  }
  final account = inputs.account;
  if (account == null) {
    return Plan(
        StatusWaiting('the work of ${_whose(owner)}, and nobody is signed in'));
  }
  if (account != owner) {
    return Plan(
      StatusWaiting(
        'the work of ${_whose(owner)}, and ${_whose(account)} is signed in',
      ),
    );
  }
  final mark = (
    connection: connection,
    authChanges: inputs.authChanges,
    account: account,
  );
  final sending = _whySendingWaits(stored, memory, run, inputs, now, timing);
  final wantsSession =
      memory.wanted.containsKey(connection) || sending is _MayClaim;
  if (wantsSession && memory.session != mark) {
    final open = memory.session;
    return Plan(
      StatusWaiting('opening its session'),
      action: StartWrite(
        StoreWrite(
          owner,
          [
            if (!memory.restarted) AppRestarted(build: build),
            if (open != null && open.authChanges != mark.authChanges)
              const AccountChanged(),
            const ConnectionReturned(),
          ],
          SessionOpening(mark),
        ),
      ),
    );
  }
  final sessionOpen = memory.session == mark ? mark : null;
  return switch (sending) {
    _MayClaim() => Plan(
        StatusBusy(ClaimInFlight(0, mark)),
        action: StartClaim(mark),
        sessionOpen: sessionOpen,
      ),
    _Waits(:final why, :final until) => Plan(
        why == null ? const StatusAllSent() : StatusWaiting(why, until: until),
        wakeAt: until,
        sessionOpen: sessionOpen,
      ),
  };
}

sealed class _Sending {
  const _Sending();
}

final class _MayClaim extends _Sending {
  const _MayClaim();
}

final class _Waits extends _Sending {
  const _Waits(this.why, {this.until});

  final String? why;
  final DateTime? until;
}

_Sending _whySendingWaits(
  StoredStrategy stored,
  StrategyMemory memory,
  RunMemory run,
  SenderInputs inputs,
  DateTime now,
  SenderTiming timing,
) {
  final tally = stored.tally;
  final work = tally == null ||
      tally.waiting.containsKey(Underway.unsent) ||
      tally.waiting.containsKey(Underway.answerUnknown) ||
      tally.waiting.containsKey(Underway.sending);
  if (tally != null && tally.standing != Standing.good) {
    return tally.stillGoing > 0
        ? _Waits('held by the queue: ${tally.standing.name}')
        : const _Waits(null);
  }
  if (!work) {
    return tally.waiting.containsKey(Underway.awaitingResult)
        ? _Waits(
            '${tally.waiting[Underway.awaitingResult]} ops wait for a result '
            'from the server, which nothing reads while the editor does not '
            'show this strategy',
          )
        : const _Waits(null);
  }
  if (run.held case final reason?) return _Waits('sending is held: $reason');
  if (run.upgradeAsked) {
    return const _Waits('held: the server asks for a newer build');
  }
  if (run.signInWaitsFrom == inputs.authChanges) {
    return const _Waits('waiting for the sign-in to change');
  }
  if (memory.looked case Looked(:final summary, :final why, :final retryAt)
      when identical(summary, stored.summary) &&
          (retryAt == null || now.isBefore(retryAt))) {
    return _Waits(why, until: retryAt);
  }
  final settled = memory.seenAt?.add(timing.wait);
  if (settled != null && now.isBefore(settled)) {
    return _Waits('settling', until: settled);
  }
  return const _MayClaim();
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

typedef SenderView = ({String run, Map<String, StrategyStatus> strategies});

final class CloudSender implements StoreSessions {
  CloudSender({
    required SenderStore store,
    required StoreBatchSend send,
    required String build,
    SenderInputs inputs = (account: null, connection: null, authChanges: 0),
    SenderTiming timing = const SenderTiming(),
    DateTime Function()? clock,
  })  : _store = store,
        _send = send,
        _build = build,
        _inputs = inputs,
        _timing = timing,
        _clock = clock ?? DateTime.now;

  final SenderStore _store;
  final StoreBatchSend _send;
  final String _build;
  final SenderTiming _timing;
  final DateTime Function() _clock;
  final run = RunMemory();
  final memories = <String, StrategyMemory>{};
  final _views = StreamController<SenderView>.broadcast(sync: true);
  SenderInputs _inputs;
  SenderView _view = (run: 'not started', strategies: const {});
  Timer? _timer;
  var _request = 0;
  var _pumping = false;
  var _again = false;

  SenderStore get store => _store;

  SenderInputs get inputs => _inputs;

  SenderView get view => _view;

  Stream<SenderView> get views => _views.stream;

  set inputs(SenderInputs next) {
    if (run.disposed) return;
    _inputs = next;
    _pump();
  }

  void nudge() => _pump();

  void hold(String reason) {
    run.held = reason;
    _pump();
  }

  void release() {
    run.held = null;
    _pump();
  }

  void dispose() {
    if (run.disposed) return;
    run.disposed = true;
    _timer?.cancel();
    _timer = null;
    for (final memory in memories.values) {
      _answerWanted(memory, open: null, ending: true);
    }
    _publish();
    unawaited(_views.close());
  }

  @override
  Future<bool> sessionOn(String strategyId, int connection) {
    if (run.disposed || run.shut != null) return Future.value(false);
    final waiting = Completer<bool>();
    (memories[strategyId] ??= StrategyMemory())
        .wanted
        .putIfAbsent(connection, () => [])
        .add(waiting);
    _pump();
    return waiting.future;
  }

  @override
  void addedOn(String strategyId, int connection) {
    final account = _inputs.account;
    final memory = memories[strategyId] ??= StrategyMemory();
    memory.restarted = true;
    if (account != null && _inputs.connection == connection) {
      memory.session = (
        connection: connection,
        authChanges: _inputs.authChanges,
        account: account,
      );
    }
    _pump();
  }

  void _pump() {
    if (_pumping) {
      _again = true;
      return;
    }
    _pumping = true;
    try {
      do {
        _again = false;
        _pumpOnce();
        _publish();
      } while (_again);
    } finally {
      _pumping = false;
    }
  }

  final _statuses = <String, StrategyStatus>{};

  void _pumpOnce() {
    if (run.disposed) return;
    final now = _clock();
    if (_store.shut case final shut? when run.shut == null) {
      run.shut = shut.why;
    }
    DateTime? wakeAt;
    final listed = <String>{};
    for (final stored in _store.strategies()) {
      listed.add(stored.id);
      final memory = memories[stored.id] ??= StrategyMemory();
      if (!identical(memory.seen, stored.summary)) {
        memory.seen = stored.summary;
        memory.seenAt = now;
      }
      final plan = planFor(
        stored,
        memory,
        run,
        _inputs,
        now,
        _timing,
        build: _build,
      );
      _statuses[stored.id] = plan.status;
      if (plan.wakeAt case final at?
          when wakeAt == null || at.isBefore(wakeAt)) {
        wakeAt = at;
      }
      switch (plan.action) {
        case StartWrite(:final write):
          _startWrite(stored.id, memory, write);
        case StartClaim(:final session):
          _startClaim(stored.id, memory, session);
        case null:
          break;
      }
      _answerWanted(memory, open: plan.sessionOpen?.connection);
    }
    for (final MapEntry(:key, :value) in memories.entries) {
      if (!listed.contains(key)) _answerWanted(value, open: null, ending: true);
    }
    _arm(wakeAt);
  }

  void _answerWanted(
    StrategyMemory memory, {
    required int? open,
    bool ending = false,
  }) {
    for (final connection in [...memory.wanted.keys]) {
      final bool? answer = connection == open
          ? true
          : ending || connection != _inputs.connection || memory.flight == null
              ? false
              : null;
      if (answer == null) continue;
      for (final waiting in memory.wanted.remove(connection)!) {
        waiting.complete(answer);
      }
    }
  }

  void _arm(DateTime? at) {
    _timer?.cancel();
    _timer = null;
    if (at == null || run.disposed) return;
    final delay = at.difference(_clock());
    _timer = Timer(delay.isNegative ? Duration.zero : delay, _pump);
  }

  void _publish() {
    final next = (
      run: switch (run) {
        RunMemory(disposed: true) => 'disposed',
        RunMemory(shut: final why?) => 'ended: the store is shut: $why',
        RunMemory(held: final why?) => 'held: $why',
        RunMemory(upgradeAsked: true) =>
          'held: the server asks for a newer build',
        _ => 'running',
      },
      strategies: Map<String, StrategyStatus>.unmodifiable(_statuses),
    );
    final changed = next.run != _view.run ||
        !_sameStatuses(next.strategies, _view.strategies);
    _view = next;
    if (changed && !_views.isClosed) _views.add(next);
  }

  static bool _sameStatuses(
    Map<String, StrategyStatus> a,
    Map<String, StrategyStatus> b,
  ) =>
      a.length == b.length &&
      a.entries.every((entry) => '${b[entry.key]}' == '${entry.value}');

  void _startWrite(String strategyId, StrategyMemory memory, StoreWrite write) {
    final request = ++_request;
    memory.flight = WriteInFlight(request, write);
    final events = write.events;
    final batch = switch (write.purpose) {
      AnswerOf(:final batch) || ReleaseOf(:final batch) => batch,
      _ => null,
    };
    unawaited(
      _settle(
        () => _store.write(write.owner, strategyId, events, batch: batch),
        (error) => WriteTroubled(StoreShut('the write threw: $error')),
      ).then((written) => _written(strategyId, memory, request, written)),
    );
  }

  void _written(
    String strategyId,
    StrategyMemory memory,
    int request,
    Written written,
  ) {
    final flight = memory.flight;
    if (flight is! WriteInFlight || flight.request != request) return;
    memory.flight = null;
    if (run.disposed) return;
    final now = _clock();
    switch (written) {
      case WrittenWith(:final effects):
        memory.retry = null;
        memory.looked = null;
        switch (flight.write.purpose) {
          case AnswerOf(:final batch):
            memory.owed = null;
            if (effects.any((effect) => effect is HoldSendingForUpgrade)) {
              run.upgradeAsked = true;
            }
            if (effects.any((effect) => effect is ReportUnauthenticated)) {
              run.signInWaitsFrom = batch.session.authChanges;
            }
          case ReleaseOf():
            memory.owed = null;
          case SessionOpening(:final mark):
            memory.session = mark;
            memory.restarted = true;
          case SessionClosing():
            memory.session = null;
        }
      case WriteTroubled(trouble: NotWrittenNow(:final why)):
        final failures = (memory.retry?.failures ?? 0) + 1;
        memory.retry = WriteRetry(
          failures,
          now.add(_timing.writeRetryAfter(failures)),
          why,
        );
      case WriteTroubled(trouble: StrategyHeld(:final why)):
        if (memory.seen case final summary?) {
          memory.parked = Parked(summary, why);
        }
      case WriteTroubled(trouble: StoreShut(:final why)):
        run.shut = why;
    }
    _pump();
  }

  void _startClaim(
      String strategyId, StrategyMemory memory, SessionMark session) {
    final request = ++_request;
    memory.flight = ClaimInFlight(request, session);
    unawaited(
      _settle(
        () => _store.claim(strategyId, session, _clock()),
        (error) => ClaimTroubled(StoreShut('the claim threw: $error')),
      ).then((result) => _claimed(strategyId, memory, request, result)),
    );
  }

  void _claimed(
    String strategyId,
    StrategyMemory memory,
    int request,
    ClaimResult result,
  ) {
    final flight = memory.flight;
    if (flight is! ClaimInFlight || flight.request != request) return;
    memory.flight = null;
    if (run.disposed) return;
    switch (result) {
      case Claimed(:final batch):
        final cause = _whyNotSend(batch);
        if (cause == null) {
          _call(strategyId, memory, batch);
        } else {
          memory.owed = StoreWrite(
            batch.account,
            [ClaimReleased(batch.attempt)],
            ReleaseOf(batch, cause),
          );
        }
      case NothingNow(:final why, :final retryAt):
        if (memory.seen case final summary?) {
          memory.looked = Looked(summary, why, retryAt);
        }
      case ClaimTroubled(trouble: NotWrittenNow(:final why)):
        final failures = (memory.retry?.failures ?? 0) + 1;
        memory.retry = WriteRetry(
          failures,
          _clock().add(_timing.writeRetryAfter(failures)),
          why,
        );
      case ClaimTroubled(trouble: StrategyHeld(:final why)):
        if (memory.seen case final summary?) {
          memory.parked = Parked(summary, why);
        }
      case ClaimTroubled(trouble: StoreShut(:final why)):
        run.shut = why;
    }
    _pump();
  }

  ReleaseCause? _whyNotSend(ClaimedBatch batch) {
    final now = _inputs;
    if (run.held != null ||
        run.upgradeAsked ||
        run.signInWaitsFrom == now.authChanges) {
      return ReleaseCause.held;
    }
    if (now.connection != batch.session.connection ||
        now.authChanges != batch.session.authChanges ||
        now.account != batch.session.account) {
      return ReleaseCause.sessionChanged;
    }
    return null;
  }

  void _call(String strategyId, StrategyMemory memory, ClaimedBatch batch) {
    final request = ++_request;
    memory.flight = CallInFlight(request, batch);
    final call = _settle(
      () => Future<StoreBatchOutcome>.sync(
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
      ),
      (error) =>
          StoreBatchLost(TransportFailure.network, 'the send threw: $error'),
    );
    unawaited(
      call.then((outcome) => _answered(strategyId, memory, request, outcome)),
    );
  }

  void _answered(
    String strategyId,
    StrategyMemory memory,
    int request,
    StoreBatchOutcome outcome,
  ) {
    final flight = memory.flight;
    if (flight is! CallInFlight || flight.request != request) return;
    memory.flight = null;
    if (run.disposed) return;
    final batch = flight.batch;
    switch (outcome) {
      case StoreBatchRefusedWhole(refusal: BatchRefusal.unauthenticated):
        run.signInWaitsFrom = batch.session.authChanges;
      case StoreBatchRefusedWhole(refusal: BatchRefusal.upgradeRequired):
        run.upgradeAsked = true;
      case _:
        break;
    }
    if (outcome is StoreBatchAccountMismatch) {
      run.signInWaitsFrom = batch.session.authChanges;
      memory.owed = StoreWrite(
        batch.account,
        [ClaimReleased(batch.attempt)],
        ReleaseOf(batch, ReleaseCause.otherAccount),
      );
    } else {
      memory.owed = StoreWrite(
        batch.account,
        answersOf(batch, outcome, _clock()),
        AnswerOf(batch),
      );
    }
    _pump();
  }

  static Future<T> _settle<T>(
    Future<T> Function() work,
    T Function(Object error) failed,
  ) async {
    try {
      return await work();
    } catch (error) {
      return failed(error);
    }
  }
}
