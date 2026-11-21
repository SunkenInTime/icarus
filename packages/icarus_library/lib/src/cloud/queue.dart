import 'dart:collection';

import '../json.dart';
import '../ops.dart';
import 'events.dart';
import 'fold.dart';
import 'held_page_delete.dart';
import 'op_facts.dart';
import 'pending.dart';
import 'shown.dart';
import 'sync.dart';

part 'derivation.dart';

final class QueueSession {
  const QueueSession({
    required this.connected,
    required this.build,
    required this.number,
  });

  final bool connected;
  final String build;
  final int number;

  @override
  bool operator ==(Object other) =>
      other is QueueSession &&
      other.connected == connected &&
      other.build == build &&
      other.number == number;

  @override
  int get hashCode => Object.hash(connected, build, number);
}

final class CloudQueue {
  factory CloudQueue({
    required List<QueueEntry> entries,
    required Map<int, AttemptFact> attempts,
    required List<LandedWork> landed,
    required int nextAttempt,
    required int nextSession,
    required Shown shown,
    required StrategyFacts strategy,
    required QueueSession session,
  }) {
    final problem = _problemWith(entries, attempts, nextAttempt, strategy);
    if (problem != null) throw ArgumentError(problem);
    return CloudQueue._(
      entries: entries,
      attempts: attempts,
      landed: landed,
      nextAttempt: nextAttempt,
      nextSession: nextSession > session.number
          ? nextSession
          : session.number + 1,
      shown: shown,
      strategy: strategy,
      session: session,
      index: _Index.of(entries, attempts),
      lineage: null,
    );
  }

  CloudQueue._({
    required List<QueueEntry> entries,
    required Map<int, AttemptFact> attempts,
    required List<LandedWork> landed,
    required this.nextAttempt,
    required this.nextSession,
    required this.shown,
    required this.strategy,
    required this.session,
    required _Index index,
    required _Lineage? lineage,
  }) : entries = List.unmodifiable(entries),
       attempts = Map.unmodifiable(attempts),
       landed = List.unmodifiable(landed),
       _index = index,
       _lineage = lineage;

  factory CloudQueue.start({required String build}) => CloudQueue._(
    entries: const [],
    attempts: const {},
    landed: const [],
    nextAttempt: 1,
    nextSession: 2,
    shown: Shown.nothing,
    strategy: StrategyFacts.fresh,
    session: QueueSession(connected: false, build: build, number: 1),
    index: _Index.empty,
    lineage: null,
  );

  final List<QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  final List<LandedWork> landed;
  final int nextAttempt;
  final int nextSession;
  final Shown shown;
  final StrategyFacts strategy;
  final QueueSession session;
  final _Index _index;
  _Lineage? _lineage;
  _Derivation? _derived;

  QueueEntry? entry(String id) => _index.byId[id];

  CloudQueue raisedTo({required int nextAttempt, required int nextSession}) {
    if (nextAttempt <= this.nextAttempt && nextSession <= this.nextSession) {
      return this;
    }
    return CloudQueue._(
      entries: entries,
      attempts: attempts,
      landed: landed,
      nextAttempt: nextAttempt > this.nextAttempt
          ? nextAttempt
          : this.nextAttempt,
      nextSession: nextSession > this.nextSession
          ? nextSession
          : this.nextSession,
      shown: shown,
      strategy: strategy,
      session: session,
      index: _index,
      lineage: _Lineage(this, _Change()),
    );
  }

  static String? _problemWith(
    List<QueueEntry> entries,
    Map<int, AttemptFact> attempts,
    int nextAttempt,
    StrategyFacts strategy,
  ) {
    final ids = <String>{};
    int? lastPlace;
    for (final entry in entries) {
      if (!ids.add(entry.id)) return 'two entries share the id ${entry.id}';
      if (lastPlace != null && entry.place <= lastPlace) {
        return 'entry ${entry.id} is not after the entry before it';
      }
      lastPlace = entry.place;
      if (entry case PendingOp(
        :final retriedAfter,
      ) when retriedAfter >= nextAttempt) {
        return 'entry ${entry.id} was retried after an attempt not yet made';
      }
    }
    if (nextAttempt < 1) return 'attempts are numbered from 1';
    for (final MapEntry(:key, :value) in attempts.entries) {
      if (key != value.number) {
        return 'attempt ${value.number} is filed under $key';
      }
      if (key < 1 || key >= nextAttempt) {
        return 'attempt $key would be numbered again';
      }
    }
    if (strategy.accessLostAt >= nextAttempt ||
        strategy.accessConfirmedAt >= nextAttempt) {
      return 'edit access is ordered by an attempt not yet made';
    }
    if (strategy.upgradeTold case UpgradeToldTo(
      :final attempt,
    ) when attempt >= nextAttempt) {
      return 'the upgrade was asked for by an attempt not yet made';
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CloudQueue &&
      _sameList(other.entries, entries) &&
      sameMap(other.attempts, attempts) &&
      _sameList(other.landed, landed) &&
      other.nextAttempt == nextAttempt &&
      other.nextSession == nextSession &&
      other.shown == shown &&
      other.strategy == strategy &&
      other.session == session;

  @override
  int get hashCode =>
      Object.hash(entries.length, nextAttempt, nextSession, strategy);

  static bool _sameList(List<Object> a, List<Object> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
}

enum Standing { good, editAccessLost, upgradeRequired, deletedOnServer, held }

Standing standingOf(CloudQueue queue) => switch (queue.strategy) {
  StrategyFacts(presence: Presence.gone) => Standing.deletedOnServer,
  StrategyFacts(:final accessLostAt, :final accessConfirmedAt)
      when accessLostAt > accessConfirmedAt =>
    Standing.editAccessLost,
  StrategyFacts(upgradeTold: UpgradeToldTo(:final build))
      when build == queue.session.build =>
    Standing.upgradeRequired,
  StrategyFacts() => Standing.good,
};

Set<String> pagesOf(PendingOp entry) => {
  ...switch (entry.scope) {
    StrategyWide() => const <String>[],
    OnPage(:final pagePublicId) => [pagePublicId],
    Moving(:final from, :final to) => [from, to],
  },
  ...pagesNeeded(entry.op),
};

sealed class PendingState {
  const PendingState();
}

final class Waiting extends PendingState {
  const Waiting();

  @override
  bool operator ==(Object other) => other is Waiting;

  @override
  int get hashCode => (Waiting).hashCode;

  @override
  String toString() => 'waiting';
}

final class Sending extends PendingState {
  const Sending(this.attempt);

  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is Sending && other.attempt == attempt;

  @override
  int get hashCode => Object.hash(Sending, attempt);

  @override
  String toString() => 'sending in $attempt';
}

final class Unanswered extends PendingState {
  const Unanswered({
    required this.clientId,
    required this.firstSentAt,
    required this.failures,
    required this.backoff,
  });

  final String clientId;
  final DateTime firstSentAt;
  final int failures;
  final Backoff backoff;

  @override
  bool operator ==(Object other) =>
      other is Unanswered &&
      other.clientId == clientId &&
      other.firstSentAt == firstSentAt &&
      other.failures == failures &&
      other.backoff == backoff;

  @override
  int get hashCode =>
      Object.hash(Unanswered, clientId, firstSentAt, failures, backoff);

  @override
  String toString() => 'unanswered ($failures failures, $backoff)';
}

final class NeedsUser extends PendingState {
  const NeedsUser(this.reason);

  final UserReason reason;

  @override
  bool operator ==(Object other) =>
      other is NeedsUser && other.reason == reason;

  @override
  int get hashCode => Object.hash(NeedsUser, reason);

  @override
  String toString() => 'needs user: $reason';
}

sealed class Backoff {
  const Backoff();
}

final class RetryNow extends Backoff {
  const RetryNow();

  @override
  bool operator ==(Object other) => other is RetryNow;

  @override
  int get hashCode => (RetryNow).hashCode;

  @override
  String toString() => 'retry now';
}

final class RetryAfter extends Backoff {
  const RetryAfter(this.at);

  final DateTime at;

  @override
  bool operator ==(Object other) => other is RetryAfter && other.at == at;

  @override
  int get hashCode => Object.hash(RetryAfter, at);

  @override
  String toString() => 'retry after ${at.toIso8601String()}';
}

sealed class UserReason {
  const UserReason();
}

final class RefusedByServer extends UserReason {
  const RefusedByServer(this.refusal);

  final ServerRefusal refusal;

  @override
  bool operator ==(Object other) =>
      other is RefusedByServer && other.refusal == refusal;

  @override
  int get hashCode => Object.hash(RefusedByServer, refusal);

  @override
  String toString() => '$refusal';
}

final class WindowClosed extends UserReason {
  const WindowClosed();

  @override
  bool operator ==(Object other) => other is WindowClosed;

  @override
  int get hashCode => (WindowClosed).hashCode;

  @override
  String toString() => 'the server may have forgotten whether it landed';
}

final class RetriesExhausted extends UserReason {
  const RetriesExhausted();

  @override
  bool operator ==(Object other) => other is RetriesExhausted;

  @override
  int get hashCode => (RetriesExhausted).hashCode;

  @override
  String toString() => 'retries exhausted';
}

final class DeleteHeld extends UserReason {
  const DeleteHeld(this.cause);

  final HeldDeleteCause cause;

  @override
  bool operator ==(Object other) => other is DeleteHeld && other.cause == cause;

  @override
  int get hashCode => Object.hash(DeleteHeld, cause);

  @override
  String toString() => 'page delete held (${cause.name})';
}

final class Oversized extends UserReason {
  const Oversized();

  @override
  bool operator ==(Object other) => other is Oversized;

  @override
  int get hashCode => (Oversized).hashCode;

  @override
  String toString() => 'oversized';
}

final class ChangedUnseen extends UserReason {
  const ChangedUnseen();

  @override
  bool operator ==(Object other) => other is ChangedUnseen;

  @override
  int get hashCode => (ChangedUnseen).hashCode;

  @override
  String toString() => 'changed by someone else since the user saw it';
}

final class RetiredFormat extends UserReason {
  const RetiredFormat();

  @override
  bool operator ==(Object other) => other is RetiredFormat;

  @override
  int get hashCode => (RetiredFormat).hashCode;

  @override
  String toString() => 'a format this build no longer sends';
}

sealed class Hold {
  const Hold();
}

final class BehindEntry extends Hold {
  const BehindEntry(this.opId, this.why);

  final String opId;
  final Dependency why;

  @override
  bool operator ==(Object other) =>
      other is BehindEntry && other.opId == opId && other.why == why;

  @override
  int get hashCode => Object.hash(BehindEntry, opId, why);

  @override
  String toString() => 'behind $opId (${why.name})';
}

enum Dependency {
  sameRow,
  strategyChange,
  pageChange,
  pageAdd,
  pageDelete,
  pageWork,
}

final class UntilRetryTime extends Hold {
  const UntilRetryTime(this.at);

  final DateTime at;

  @override
  bool operator ==(Object other) => other is UntilRetryTime && other.at == at;

  @override
  int get hashCode => Object.hash(UntilRetryTime, at);

  @override
  String toString() => 'until ${at.toIso8601String()}';
}

final class AwaitingResult extends Hold {
  const AwaitingResult(this.subject);

  final ResultSubject subject;

  @override
  bool operator ==(Object other) =>
      other is AwaitingResult && other.subject == subject;

  @override
  int get hashCode => Object.hash(AwaitingResult, subject);

  @override
  String toString() => 'awaiting a result for $subject';
}

sealed class ResultSubject {
  const ResultSubject();
}

final class RowResult extends ResultSubject {
  const RowResult(this.target, this.page);

  final Target target;
  final String? page;

  @override
  bool operator ==(Object other) =>
      other is RowResult && other.target == target && other.page == page;

  @override
  int get hashCode => Object.hash(RowResult, target, page);

  @override
  String toString() => '$target';
}

final class PageResult extends ResultSubject {
  const PageResult(this.page);

  final String page;

  @override
  bool operator ==(Object other) => other is PageResult && other.page == page;

  @override
  int get hashCode => Object.hash(PageResult, page);

  @override
  String toString() => 'page $page';
}

final class EntryView {
  EntryView(this.state, List<Hold> holds) : holds = List.unmodifiable(holds);

  final PendingState state;
  final List<Hold> holds;

  @override
  bool operator ==(Object other) =>
      other is EntryView &&
      other.state == state &&
      _sameHolds(other.holds, holds);

  @override
  int get hashCode => Object.hash(state, holds.length);

  static bool _sameHolds(List<Hold> a, List<Hold> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool get sendable =>
      holds.isEmpty &&
      switch (state) {
        Waiting() || Unanswered() => true,
        Sending() || NeedsUser() => false,
      };
}

sealed class QueueEffect {
  const QueueEffect();
}

final class OpRemoved extends QueueEffect {
  const OpRemoved(this.opId, this.cause);

  final String opId;
  final RemovalCause cause;

  @override
  bool operator ==(Object other) =>
      other is OpRemoved && other.opId == opId && other.cause == cause;

  @override
  int get hashCode => Object.hash(OpRemoved, opId, cause);

  @override
  String toString() => 'OpRemoved($opId, $cause)';
}

final class SendBatch extends QueueEffect {
  SendBatch(this.attempt, this.clientId, List<StrategyOp> ops)
    : ops = List.unmodifiable(ops);

  final int attempt;
  final String clientId;
  final List<StrategyOp> ops;

  @override
  String toString() => 'SendBatch($attempt, ${ops.map((op) => op.opId)})';
}

final class SessionOpened extends QueueEffect {
  const SessionOpened(this.session);

  final int session;

  @override
  bool operator ==(Object other) =>
      other is SessionOpened && other.session == session;

  @override
  int get hashCode => Object.hash(SessionOpened, session);

  @override
  String toString() => 'SessionOpened($session)';
}

final class ReportUnauthenticated extends QueueEffect {
  const ReportUnauthenticated();

  @override
  String toString() => 'ReportUnauthenticated';
}

final class HoldSendingForUpgrade extends QueueEffect {
  const HoldSendingForUpgrade();

  @override
  String toString() => 'HoldSendingForUpgrade';
}

sealed class RemovalCause {
  const RemovalCause();
}

final class Delivered extends RemovalCause {
  const Delivered(this.how);

  final Delivery how;

  @override
  bool operator ==(Object other) => other is Delivered && other.how == how;

  @override
  int get hashCode => Object.hash(Delivered, how);

  @override
  String toString() => 'Delivered(${how.name})';
}

enum Delivery { applied, alreadyThere, nothingToDo, alreadyAsWritten }

final class FoldedInto extends RemovalCause {
  const FoldedInto(this.opId);

  final String opId;

  @override
  bool operator ==(Object other) => other is FoldedInto && other.opId == opId;

  @override
  int get hashCode => Object.hash(FoldedInto, opId);

  @override
  String toString() => 'FoldedInto($opId)';
}

final class RemovedByUser extends RemovalCause {
  const RemovedByUser(this.action, this.landing);

  final UserRemoval action;
  final Landing landing;

  @override
  bool operator ==(Object other) =>
      other is RemovedByUser &&
      other.action == action &&
      other.landing == landing;

  @override
  int get hashCode => Object.hash(RemovedByUser, action, landing);

  @override
  String toString() => 'RemovedByUser(${action.name}, ${landing.name})';
}

enum UserRemoval { discarded, usedCloud, replacedByKeepMine }

sealed class Step {
  const Step(this.queue);

  final CloudQueue queue;
}

final class Stepped extends Step {
  Stepped(super.queue, List<QueueEffect> effects)
    : effects = List.unmodifiable(effects);

  final List<QueueEffect> effects;
}

final class NotApplicable extends Step {
  const NotApplicable(super.queue, this.why);

  final Inapplicable why;
}

sealed class Inapplicable {
  const Inapplicable();
}

final class NoSuchOp extends Inapplicable {
  const NoSuchOp(this.opId);

  final String opId;

  @override
  String toString() => 'NoSuchOp($opId)';
}

final class NotInThatState extends Inapplicable {
  const NotInThatState(this.opId, this.view);

  final String opId;
  final String view;

  @override
  String toString() => 'NotInThatState($opId: $view)';
}

final class HeldBack extends Inapplicable {
  HeldBack(this.opId, List<Hold> holds) : holds = List.unmodifiable(holds);

  final String opId;
  final List<Hold> holds;

  @override
  String toString() => 'HeldBack($opId, $holds)';
}

final class NoSuchAttempt extends Inapplicable {
  const NoSuchAttempt(this.attempt);

  final int attempt;

  @override
  String toString() => 'NoSuchAttempt($attempt)';
}

final class NotInAttempt extends Inapplicable {
  const NotInAttempt(this.opId, this.attempt);

  final String opId;
  final int attempt;

  @override
  String toString() => 'NotInAttempt($opId, $attempt)';
}

final class OpIdTaken extends Inapplicable {
  const OpIdTaken(this.opId);

  final String opId;

  @override
  String toString() => 'OpIdTaken($opId)';
}

final class NotJson extends Inapplicable {
  const NotJson(this.opId);

  final String opId;

  @override
  String toString() => 'NotJson($opId)';
}

final class StandingBlocks extends Inapplicable {
  const StandingBlocks(this.standing);

  final Standing standing;

  @override
  String toString() => 'StandingBlocks(${standing.name})';
}

final class OutOfOrder extends Inapplicable {
  const OutOfOrder(this.opId);

  final String opId;

  @override
  String toString() => 'OutOfOrder($opId)';
}

final class OtherClient extends Inapplicable {
  const OtherClient(this.opId, this.clientId);

  final String opId;
  final String clientId;

  @override
  String toString() => 'OtherClient($opId, $clientId)';
}

final class OtherEntity extends Inapplicable {
  const OtherEntity(this.opId);

  final String opId;

  @override
  String toString() => 'OtherEntity($opId)';
}

final class NothingClaimed extends Inapplicable {
  const NothingClaimed();

  @override
  String toString() => 'NothingClaimed';
}

final class FromAnEndedSession extends Inapplicable {
  const FromAnEndedSession(this.session);

  final int session;

  @override
  String toString() => 'FromAnEndedSession($session)';
}

Landing landingOf(CloudQueue queue, QueueEntry entry) => switch (entry) {
  RetiredOp(:final landing) => landing,
  final PendingOp op =>
    (queue._index.attemptsByOp[op.id] ?? const []).isEmpty
        ? Landing.notLanded
        : Landing.mayHaveLanded,
};

Target checkTargetOf(StrategyOp op) => switch (op) {
  StrategyPatchOp() ||
  PageAddOp() ||
  PageDeleteOp() ||
  PageReorderOp() => const StrategyTarget(),
  _ => targetOf(op),
};

LandedShape _shapeOf(StrategyOp sent) => switch (sent) {
  ElementPatchOp(merge: _?) ||
  LineupGroupPatchOp(merge: _?) ||
  PageAddOp() ||
  PageDeleteOp() ||
  PageReorderOp() => LandedShape.partial,
  _ => LandedShape.whole,
};

final class _Edit {
  _Edit(this.original, this.now)
    : entries = [...original.entries],
      attempts = {...original.attempts},
      landed = [...original.landed],
      nextAttempt = original.nextAttempt,
      nextSession = original.nextSession,
      shown = original.shown,
      strategy = original.strategy,
      session = original.session,
      index = _IndexEdit(original._index);

  final CloudQueue original;
  final DateTime now;
  final List<QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  final List<LandedWork> landed;
  int nextAttempt;
  int nextSession;
  Shown shown;
  StrategyFacts strategy;
  QueueSession session;
  final _IndexEdit index;
  final change = _Change();
  final effects = <QueueEffect>[];

  int indexOf(String id) {
    final entry = index.byId[id];
    if (entry == null) return -1;
    var low = 0;
    var high = entries.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (entries[middle].place < entry.place) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  void replaceAt(int at, PendingOp entry) {
    final old = entries[at];
    entries[at] = entry;
    index.replace(old, entry);
    if (old.id != entry.id) change.removed.add(old);
    change.touched.add(entry.id);
  }

  void put(PendingOp entry) => replaceAt(indexOf(entry.id), entry);

  void append(PendingOp entry) {
    entries.add(entry);
    index.add(entry);
    change.touched.add(entry.id);
  }

  void remove(String id, RemovalCause cause) {
    final old = entries.removeAt(indexOf(id));
    index.remove(old);
    change.removed.add(old);
    change.touched.remove(id);
    effects.add(OpRemoved(id, cause));
  }

  void setAttempt(AttemptFact attempt) {
    final old = attempts[attempt.number];
    attempts[attempt.number] = attempt;
    if (old == null) index.addAttempt(attempt);
    for (final opId in attempt.opIds) {
      if (index.byId.containsKey(opId)) change.touched.add(opId);
    }
  }

  void dropAttempt(AttemptFact attempt) {
    attempts.remove(attempt.number);
    index.removeAttempt(attempt);
  }

  int get lastAttempt => nextAttempt - 1;

  void openSession({required bool connected, required String build}) {
    session = QueueSession(
      connected: connected,
      build: build,
      number: nextSession++,
    );
    shown = shown.inNewSession();
    change.everything = true;
    effects.add(SessionOpened(session.number));
  }

  CloudQueue build() {
    _pruneAttempts(this);
    return CloudQueue._(
      entries: entries,
      attempts: attempts,
      landed: landed,
      nextAttempt: nextAttempt,
      nextSession: nextSession,
      shown: shown,
      strategy: strategy,
      session: session,
      index: index.build(),
      lineage: _Lineage(original, change),
    );
  }

  Stepped done() => Stepped(build(), effects);
}

CloudQueue recordExpiries(CloudQueue queue, DateTime now) {
  final due = queue._index.dueBy(now);
  if (due.isEmpty) return queue;
  final edit = _Edit(queue, now);
  for (final id in due) {
    if (edit.index.byId[id] case final PendingOp entry
        when entry.window is WindowOpen) {
      edit.put(entry.copyWith(window: const WindowPassed()));
    }
  }
  return edit.build();
}

void _pruneAttempts(_Edit edit) {
  final affected = {
    ...edit.change.touched,
    for (final entry in edit.change.removed) entry.id,
  };
  final numbers = {for (final id in affected) ...?edit.index.attemptsByOp[id]};
  for (final number in numbers) {
    final attempt = edit.attempts[number];
    if (attempt == null) continue;
    derivationWork.visits++;
    final live = attempt.opIds.any(
      (opId) => switch (edit.index.byId[opId]) {
        PendingOp(refusal: NotRefused()) => true,
        _ => false,
      },
    );
    if (!live) edit.dropAttempt(attempt);
  }
}

Step transition(CloudQueue queue, QueueEvent event, {required DateTime now}) {
  final start = recordExpiries(queue, now);
  final step = _step(_Edit(start, now), start, event, now);
  return switch (step) {
    Stepped() => step,
    NotApplicable(:final why) => NotApplicable(start, why),
  };
}

Step _step(_Edit edit, CloudQueue queue, QueueEvent event, DateTime now) {
  switch (event) {
    case UserEdited(edit: final change):
      return _userEdited(edit, change, now);
    case BatchClaimed(:final clientId, :final opIds, :final at):
      return _claim(edit, clientId, opIds, at, now);
    case ClaimReleased(:final attempt):
      return _closeAttempt(edit, attempt, const AttemptReleased());
    case TransportFailed(:final attempt, :final failure, :final at):
      return _closeAttempt(
        edit,
        attempt,
        AttemptFailed(TransportCut(failure), at),
      );
    case BatchRefused(:final attempt, :final refusal):
      return _batchRefused(edit, attempt, refusal);
    case OpAnswered(:final attempt, :final answer):
      return _answered(edit, attempt, answer);
    case AppRestarted(:final build):
      for (final attempt in [...edit.attempts.values]) {
        if (attempt.outcome is AttemptOpen) {
          edit.setAttempt(
            attempt.withOutcome(
              AttemptFailed(const AppClosedWhileSending(), now),
            ),
          );
        }
      }
      edit.openSession(connected: false, build: build);
      return edit.done();
    case ConnectionLost():
      edit.session = QueueSession(
        connected: false,
        build: edit.session.build,
        number: edit.session.number,
      );
      return edit.done();
    case ConnectionReturned():
      edit.openSession(connected: true, build: edit.session.build);
      return edit.done();
    case AccountChanged():
      edit.openSession(
        connected: edit.session.connected,
        build: edit.session.build,
      );
      return edit.done();
    case EditAccessConfirmed(:final afterAttempt):
      if (afterAttempt < 1 || afterAttempt >= edit.nextAttempt) {
        return NotApplicable(queue, NoSuchAttempt(afterAttempt));
      }
      if (afterAttempt > edit.strategy.accessConfirmedAt) {
        edit.strategy = edit.strategy.copyWith(accessConfirmedAt: afterAttempt);
      }
      return edit.done();
    case UserRetried(:final opId):
      final entry = queue.entry(opId);
      if (entry is! PendingOp) return NotApplicable(queue, NoSuchOp(opId));
      final view = entryViews(queue, now)[opId]!;
      if (view.state case NeedsUser(reason: RetriesExhausted())) {
        edit.put(entry.copyWith(retriedAfter: edit.lastAttempt));
        return edit.done();
      }
      return NotApplicable(queue, NotInThatState(opId, '${view.state}'));
    case UserKeptMine(:final opId, :final replacement, :final authored):
      return _keepMine(edit, opId, replacement, authored, now);
    case UserUsedCloud(:final opId):
      return _userRemoves(edit, opId, UserRemoval.usedCloud, now);
    case UserDiscarded(:final opId):
      return _userRemoves(edit, opId, UserRemoval.discarded, now);
    case UserDeletedAnyway(:final opId):
      final entry = queue.entry(opId);
      if (entry == null) return NotApplicable(queue, NoSuchOp(opId));
      final view = entryViews(queue, now)[opId];
      if ((entry, view?.state) case (
        PendingOp(work: CheckedDelete(:final op)) && final PendingOp delete,
        NeedsUser(reason: DeleteHeld()),
      )) {
        edit.put(delete.copyWith(work: OpWork(op)));
        return edit.done();
      }
      return NotApplicable(queue, NotInThatState(opId, '${view?.state}'));
    case BaseArrived(:final base, :final session):
      if (session != edit.session.number) {
        return NotApplicable(queue, FromAnEndedSession(session));
      }
      return _arrived(edit, base);
  }
}

Step _batchRefused(_Edit edit, int attempt, BatchRefusal refusal) {
  final fact = edit.attempts[attempt];
  if (fact == null) return NotApplicable(edit.original, NoSuchAttempt(attempt));
  if (fact.outcome is AttemptOpen) {
    edit.setAttempt(fact.withOutcome(AttemptRefusedWhole(refusal)));
  }
  switch (refusal) {
    case BatchRefusal.upgradeRequired:
      final later = switch (edit.strategy.upgradeTold) {
        UpgradeToldTo(attempt: final told) => attempt > told,
        NoUpgradeTold() => true,
      };
      if (later) {
        edit.strategy = edit.strategy.copyWith(
          upgradeTold: UpgradeToldTo(fact.build, attempt: attempt),
        );
      }
      if (fact.build == edit.session.build) {
        edit.effects.add(const HoldSendingForUpgrade());
      }
    case BatchRefusal.unauthenticated:
      edit.effects.add(const ReportUnauthenticated());
    case BatchRefusal.editAccessRemoved:
      if (attempt > edit.strategy.accessLostAt) {
        edit.strategy = edit.strategy.copyWith(accessLostAt: attempt);
      }
    case BatchRefusal.strategyDeleted:
      edit.strategy = edit.strategy.copyWith(presence: Presence.gone);
  }
  return edit.done();
}

Step _closeAttempt(_Edit edit, int attempt, AttemptOutcome outcome) {
  final fact = edit.attempts[attempt];
  if (fact == null) return NotApplicable(edit.original, NoSuchAttempt(attempt));
  if (fact.outcome is AttemptOpen) {
    edit.setAttempt(fact.withOutcome(outcome));
  }
  return edit.done();
}

Step _arrived(_Edit edit, ArrivedBase base) {
  if (base is StrategyGone) {
    edit.strategy = edit.strategy.copyWith(presence: Presence.gone);
    return edit.done();
  }
  edit.shown = edit.shown.take(base);
  edit.landed.removeWhere((work) => _alreadyShown(edit.shown, work));
  switch (base) {
    case HeaderRead():
      edit.change.everything = true;
    case PageRead(:final page, :final elements, :final lineupGroups):
      edit.change.pages.add(page.publicId);
      edit.change.targets.addAll([
        for (final row in elements) ElementTarget(row.publicId),
        for (final row in lineupGroups) LineupTarget(row.publicId),
      ]);
    case PageGone(:final pagePublicId):
      edit.change.pages.add(pagePublicId);
    case StrategyGone():
      break;
  }
  return edit.done();
}

bool _alreadyShown(Shown shown, LandedWork work) {
  final revision = shown.highest[checkTargetOf(work.op)];
  return revision != null && revision >= work.revision;
}

Step _userEdited(_Edit edit, Edit change, DateTime now) {
  final queue = edit.original;
  final op = change.op;
  if (!isJson(op.toJson())) return NotApplicable(queue, NotJson(op.opId));
  if (edit.indexOf(op.opId) != -1) {
    return NotApplicable(queue, OpIdTaken(op.opId));
  }
  final target = targetOf(op);
  final onRow = queue._index.under[target] ?? const <_Slot>[];
  if ((change, queue.entry(onRow.lastOrNull?.$2 ?? '')) case (
    PlainEdit(),
    final PendingOp last,
  )) {
    final at = edit.indexOf(last.id);
    final views = entryViews(queue, now);
    final view = views[last.id]!;
    final alone =
        !queue._index.anyAfter(const _PageList(), last.place) &&
        !_pagesOf(
          last,
        ).any((page) => queue._index.anyAfter(_OnPage(page), last.place));
    if (alone &&
        last.work is OpWork &&
        last.scope == change.scope &&
        last.authoredIn == edit.session.number &&
        view.state is Waiting &&
        view.holds.every((hold) => _foldableHold(hold, views))) {
      switch (fold(last.op, op)) {
        case FoldedOp(op: final folded):
          edit.replaceAt(at, last.copyWith(work: OpWork(folded)));
          edit.effects.add(OpRemoved(last.id, FoldedInto(folded.opId)));
          return edit.done();
        case KeptApart():
          break;
      }
    }
  }
  final shift = _chainShift(edit, op) ?? _landedShift(queue, checkTargetOf(op));
  final placed = switch (expectedOf(op)) {
    final expected? when shift != 0 => rebased(op, expected + shift),
    _ => op,
  };
  final authored = _behindLandedMerge(queue, placed, switch (change.authored) {
    final AuthoredRow row when shift != 0 => row.at(row.revision + shift),
    final other => other,
  });
  edit.append(
    PendingOp(
      place: edit.entries.isEmpty ? 0 : edit.entries.last.place + 1,
      work: switch (change) {
        PlainEdit() => OpWork(placed),
        PageDeleteEdit(:final seen) => CheckedDelete(
          placed as PageDeleteOp,
          seen,
        ),
      },
      scope: change.scope,
      authored: authored,
      authoredIn: edit.session.number,
      refusal: const NotRefused(),
      retriedAfter: edit.lastAttempt,
    ),
  );
  return edit.done();
}

int? _chainShift(_Edit edit, StrategyOp op) {
  final expected = expectedOf(op);
  if (expected == null) return null;
  final slots = edit.index.checkedUnder(checkTargetOf(op)).toList();
  for (final (_, id) in slots.reversed) {
    if (edit.index.byId[id] case final PendingOp before) {
      final ahead = expectedOf(before.op);
      if (ahead != null) return ahead + 1 - expected;
    }
  }
  return null;
}

int _shownRevision(Shown shown, Target target) => switch (target) {
  StrategyTarget() => shown.strategyRevision ?? 0,
  PageTarget(:final pagePublicId) => shown.pages[pagePublicId]?.revision ?? 0,
  SettingsTarget(:final pagePublicId) =>
    shown.settings[pagePublicId]?.revision ?? 0,
  ElementTarget() || LineupTarget() => shown.rows[target]?.revision ?? 0,
};

int _landedShift(CloudQueue queue, Target target) {
  final mine = [
    for (final work in queue.landed)
      if (checkTargetOf(work.op) == target) work.revision,
  ];
  if (mine.isEmpty) return 0;
  final latest = mine.reduce((a, b) => a > b ? a : b);
  return latest - (_shownRevision(queue.shown, target) + mine.length);
}

Authored _behindLandedMerge(
  CloudQueue queue,
  StrategyOp op,
  Authored authored,
) {
  if (authored is! AuthoredRow || !_waitsOnLanded(op)) return authored;
  final target = checkTargetOf(op);
  final behind = queue.landed.any(
    (work) => work.shape == LandedShape.partial && _landedOver(work, target),
  );
  return behind ? AuthoredBehindMerge(authored) : authored;
}

bool _waitsOnLanded(StrategyOp op) =>
    switch (checkTargetOf(op)) {
      ElementTarget() || LineupTarget() || PageTarget() => true,
      _ => false,
    } &&
    checkKindOf(sendForm(op, SendPolicy.checked)) == CheckKind.revision;

bool _landedOver(LandedWork work, Target target) => switch (target) {
  PageTarget() => renumbersPages(work.op) || checkTargetOf(work.op) == target,
  _ => checkTargetOf(work.op) == target,
};

ShownRow? _shownRow(Shown shown, Target target) => switch (target) {
  StrategyTarget() => null,
  PageTarget(:final pagePublicId) => shown.pages[pagePublicId],
  SettingsTarget(:final pagePublicId) => shown.settings[pagePublicId],
  ElementTarget() || LineupTarget() => shown.rows[target],
};

Work _workAt(Work work, int revision) => switch (work) {
  OpWork(:final op) => OpWork(rebased(op, revision)),
  CheckedDelete(:final op, :final seen) => CheckedDelete(
    rebased(op, revision) as PageDeleteOp,
    seen,
  ),
};

PendingOp _confirmed(_Edit edit, PendingOp entry) {
  final row = switch (entry.authored) {
    AuthoredBehindMerge(:final row) => row,
    _ => null,
  };
  if (row == null) return entry;
  final target = checkTargetOf(entry.op);
  final revision = _shownRow(edit.shown, target)?.revision ?? row.revision;
  final confirmed = entry.copyWith(
    work: _workAt(entry.work, revision),
    authored: row.at(revision),
  );
  edit.put(confirmed);
  final delta = revision - row.revision;
  if (delta == 0) return confirmed;
  for (final (place, id) in edit.index.checkedUnder(target).toList()) {
    if (place <= entry.place) continue;
    final next = edit.index.byId[id];
    if (next is! PendingOp || next.refusal is! NotRefused) continue;
    if ((edit.index.attemptsByOp[id] ?? const []).isNotEmpty) continue;
    final expected = expectedOf(next.op);
    final seen = _seenRow(next.authored);
    if (expected == null || seen == null) continue;
    edit.put(
      next.copyWith(
        work: _workAt(next.work, expected + delta),
        authored: switch (next.authored) {
          AuthoredBehindMerge() => AuthoredBehindMerge(
            seen.at(seen.revision + delta),
          ),
          _ => seen.at(seen.revision + delta),
        },
      ),
    );
  }
  return confirmed;
}

bool _foldableHold(Hold hold, Map<String, EntryView> views) => switch (hold) {
  BehindEntry(:final opId, why: Dependency.sameRow) => switch (views[opId]) {
    EntryView(state: Sending() || Unanswered()) => true,
    _ => false,
  },
  UntilRetryTime() => true,
  BehindEntry() || AwaitingResult() => false,
};

Step _claim(
  _Edit edit,
  String clientId,
  List<String> opIds,
  DateTime at,
  DateTime now,
) {
  final queue = edit.original;
  if (opIds.isEmpty) return NotApplicable(queue, const NothingClaimed());
  final standing = standingOf(queue);
  if (standing != Standing.good) {
    return NotApplicable(queue, StandingBlocks(standing));
  }
  final views = entryViews(queue, now);
  var previous = -1;
  final ops = <StrategyOp>[];
  for (final opId in opIds) {
    final index = edit.indexOf(opId);
    if (index == -1) return NotApplicable(queue, NoSuchOp(opId));
    if (index <= previous) return NotApplicable(queue, OutOfOrder(opId));
    previous = index;
    final entry = edit.entries[index];
    final view = views[opId];
    if (entry is! PendingOp || view == null) {
      return NotApplicable(queue, NotInThatState(opId, 'not a pending op'));
    }
    if (view.holds.isNotEmpty) {
      return NotApplicable(queue, HeldBack(opId, view.holds));
    }
    if (!view.sendable) {
      return NotApplicable(queue, NotInThatState(opId, '${view.state}'));
    }
    if (view.state case Unanswered(
      clientId: final owner,
    ) when owner != clientId) {
      return NotApplicable(queue, OtherClient(opId, owner));
    }
    ops.add(sendable(queue, _confirmed(edit, entry)));
  }
  final number = edit.nextAttempt++;
  edit.setAttempt(
    AttemptFact(
      number: number,
      clientId: clientId,
      build: queue.session.build,
      at: at,
      ops: ops,
      outcome: const AttemptOpen(),
    ),
  );
  edit.effects.add(SendBatch(number, clientId, ops));
  return edit.done();
}

StrategyOp sendable(CloudQueue queue, PendingOp entry) {
  final sent = (queue._index.attemptsByOp[entry.id] ?? const []).isNotEmpty;
  final live =
      !sent &&
      queue.session.connected &&
      entry.authoredIn == queue.session.number;
  return sendForm(entry.op, live ? SendPolicy.live : SendPolicy.checked);
}

Step _answered(_Edit edit, int attempt, OpAnswer answer) {
  final queue = edit.original;
  final fact = edit.attempts[attempt];
  if (fact == null) return NotApplicable(queue, NoSuchAttempt(attempt));
  if (!fact.opIds.contains(answer.opId)) {
    return NotApplicable(queue, NotInAttempt(answer.opId, attempt));
  }
  final index = edit.indexOf(answer.opId);
  if (index == -1) return NotApplicable(queue, NoSuchOp(answer.opId));
  final entry = edit.entries[index];
  if (entry is! PendingOp) return NotApplicable(queue, NoSuchOp(answer.opId));
  if (attempt > edit.strategy.accessConfirmedAt) {
    edit.strategy = edit.strategy.copyWith(accessConfirmedAt: attempt);
  }
  if (entry.refusal is! NotRefused) return edit.done();
  final position = fact.ops.indexWhere((op) => op.opId == answer.opId);
  final sent = (attempt: attempt, position: position, op: fact.ops[position]);
  switch (answer) {
    case AppliedAnswer(:final revision):
      _landed(edit, entry, sent, revision, ours: true);
      edit.remove(entry.id, const Delivered(Delivery.applied));
    case NoopAnswer(
      :final revision,
      replay: NoopReplay.appliedWhenFirstReceived,
    ):
      _landed(edit, entry, sent, revision, ours: true);
      edit.remove(entry.id, const Delivered(Delivery.applied));
    case NoopAnswer(:final revision, replay: NoopReplay.notApplied):
      _landed(edit, entry, sent, revision, ours: false);
      edit.remove(entry.id, const Delivered(Delivery.alreadyThere));
    case NoopWithoutRevision():
      edit.remove(entry.id, const Delivered(Delivery.nothingToDo));
    case RejectedAnswer(:final reason, :final current):
      if (current case final ServerSnapshot snapshot
          when _alreadyAsWritten(entry.op, snapshot)) {
        _landed(edit, entry, sent, snapshot.revision, ours: false);
        edit.remove(entry.id, const Delivered(Delivery.alreadyAsWritten));
      } else {
        edit.put(
          entry.copyWith(
            refusal: RefusedWith(RejectedByServer(reason, current)),
          ),
        );
      }
    case FailedAnswer(:final code, :final message):
      edit.put(
        entry.copyWith(refusal: RefusedWith(FailedOnServer(code, message))),
      );
  }
  return edit.done();
}

bool _alreadyAsWritten(StrategyOp op, ServerSnapshot snapshot) {
  final value = snapshot.value;
  bool same(String key, Object? wanted) =>
      value.containsKey(key) && sameJson(value[key], wanted);
  return switch (op) {
    StrategyPatchOp(
      :final name,
      :final mapData,
      themeProfile: KeepValue(),
      themeOverridePalette: KeepValue(),
    )
        when snapshot.target == SnapshotTarget.strategy &&
            (name != null || mapData != null) =>
      (name == null || same('name', name)) &&
          (mapData == null || same('mapData', mapData)),
    PagePatchOp(:final name, :final isAutoNamed, :final isAttack)
        when snapshot.target == SnapshotTarget.page &&
            (name != null || isAutoNamed != null || isAttack != null) =>
      (name == null || same('name', name)) &&
          (isAutoNamed == null || same('isAutoNamed', isAutoNamed)) &&
          (isAttack == null || same('isAttack', isAttack)),
    _ => false,
  };
}

void _landed(
  _Edit edit,
  PendingOp entry,
  ({int attempt, int position, StrategyOp op}) carried,
  int revision, {
  required bool ours,
}) {
  final sent = carried.op;
  final shape = _shapeOf(sent);
  final work = LandedWork(
    attempt: carried.attempt,
    position: carried.position,
    op: sent,
    revision: revision,
    shape: shape,
  );
  if (!_alreadyShown(edit.shown, work)) {
    edit.landed
      ..add(work)
      ..sort((a, b) => a.compareTo(b));
  }
  if (shape == LandedShape.partial && renumbersPages(sent)) {
    for (final next in [...edit.entries]) {
      if (next is! PendingOp || next.op is! PagePatchOp) continue;
      if (next.refusal is! NotRefused) continue;
      if ((edit.index.attemptsByOp[next.id] ?? const []).isNotEmpty) continue;
      if (next.authored case final AuthoredRow row) {
        edit.put(next.copyWith(authored: AuthoredBehindMerge(row)));
      }
    }
  }
  final target = checkTargetOf(entry.op);
  final expected = expectedOf(entry.op);
  if (expected == null) return;
  final shift = revision - (expected + 1);
  for (final (place, id) in edit.index.checkedUnder(target)) {
    derivationWork.visits++;
    if (place <= entry.place) continue;
    final next = edit.index.byId[id];
    if (next is! PendingOp || next.refusal is! NotRefused) continue;
    if ((edit.index.attemptsByOp[id] ?? const []).isNotEmpty) continue;
    final theirs = expectedOf(next.op);
    if (theirs == null || theirs <= expected) continue;
    if (!ours && _isPutBack(next.op)) {
      edit.put(next.copyWith(authored: const AuthoredOverOthers()));
      continue;
    }
    final work = _workAt(next.work, theirs + shift);
    final behind =
        shape == LandedShape.partial &&
        (target is ElementTarget || target is LineupTarget) &&
        checkKindOf(sendForm(next.op, SendPolicy.checked)) ==
            CheckKind.revision;
    final authored = switch ((behind, next.authored)) {
      (true, AuthoredRow() || AuthoredBehindMerge()) => AuthoredBehindMerge(
        _seenRow(next.authored)!.at(theirs + shift),
      ),
      (false, AuthoredRow() || AuthoredBehindMerge()) => _seenRow(
        next.authored,
      )!.at(theirs + shift),
      (_, final other) => other,
    };
    edit.put(next.copyWith(work: work, authored: authored));
  }
}

AuthoredRow? _seenRow(Authored authored) => switch (authored) {
  final AuthoredRow row => row,
  AuthoredBehindMerge(:final row) => row,
  _ => null,
};

bool _isPutBack(StrategyOp op) => switch (op) {
  ElementAddOp(expectedElementRevision: _?) ||
  LineupGroupAddOp(expectedLineupRevision: _?) => true,
  _ => false,
};

bool _userMayReplace(EntryView view) => switch (view.state) {
  NeedsUser(reason: RefusedByServer() || ChangedUnseen() || WindowClosed()) =>
    true,
  _ => false,
};

Step _keepMine(
  _Edit edit,
  String opId,
  StrategyOp replacement,
  Authored authored,
  DateTime now,
) {
  final queue = edit.original;
  final entry = queue.entry(opId);
  if (entry is! PendingOp) return NotApplicable(queue, NoSuchOp(opId));
  final view = entryViews(queue, now)[opId]!;
  if (!_userMayReplace(view)) {
    return NotApplicable(queue, NotInThatState(opId, '${view.state}'));
  }
  if (entityOf(replacement) != entityOf(entry.op) ||
      replacement.type != entry.op.type) {
    return NotApplicable(queue, OtherEntity(replacement.opId));
  }
  if (!isJson(replacement.toJson())) {
    return NotApplicable(queue, NotJson(replacement.opId));
  }
  if (edit.indexOf(replacement.opId) != -1) {
    return NotApplicable(queue, OpIdTaken(replacement.opId));
  }
  edit.replaceAt(
    edit.indexOf(opId),
    PendingOp(
      place: entry.place,
      work: switch (entry.work) {
        CheckedDelete(:final seen) when replacement is PageDeleteOp =>
          CheckedDelete(replacement, seen),
        _ => OpWork(replacement),
      },
      scope: entry.scope,
      authored: authored,
      authoredIn: edit.session.number,
      refusal: const NotRefused(),
      retriedAfter: edit.lastAttempt,
    ),
  );
  edit.effects.add(
    OpRemoved(
      opId,
      RemovedByUser(UserRemoval.replacedByKeepMine, landingOf(queue, entry)),
    ),
  );
  return edit.done();
}

Step _userRemoves(_Edit edit, String opId, UserRemoval action, DateTime now) {
  final queue = edit.original;
  final entry = queue.entry(opId);
  if (entry == null) return NotApplicable(queue, NoSuchOp(opId));
  final standing = standingOf(queue);
  final allowed = switch (entry) {
    RetiredOp() => action == UserRemoval.discarded,
    final PendingOp op => switch ((entryViews(queue, now)[op.id]!, action)) {
      (EntryView(state: Sending()), _) => false,
      (final view, UserRemoval.usedCloud) => _userMayReplace(view),
      (EntryView(state: NeedsUser()), _) => true,
      (_, _) =>
        standing == Standing.deletedOnServer ||
            standing == Standing.editAccessLost,
    },
  };
  if (!allowed) {
    return NotApplicable(queue, NotInThatState(opId, 'not removable now'));
  }
  edit.remove(opId, RemovedByUser(action, landingOf(queue, entry)));
  return edit.done();
}
