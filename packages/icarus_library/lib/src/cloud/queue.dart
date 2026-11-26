import 'dart:collection';

import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import '../rows.dart';
import 'events.dart';
import 'fold.dart';
import 'held_page_delete.dart';
import 'op_facts.dart';
import 'pending.dart';
import 'shown.dart';
import 'sync.dart';
import 'version.dart';

part 'derivation.dart';

final class QueueSession {
  const QueueSession({
    required this.connected,
    required this.build,
    required this.number,
    required this.sequence,
    int? labelsFrom,
    this.generation,
    this.basis,
  }) : labelsFrom = labelsFrom ?? number;

  final bool connected;
  final String build;
  final int number;
  final int labelsFrom;
  final int sequence;
  final Generation? generation;
  final ServerTimeBasis? basis;

  ResultOrder orderOf(ResultPoint point) => ResultOrder(
    session: number,
    client: point.client,
    snapshot: point.snapshot,
  );

  QueueSession _copy({
    bool? connected,
    int? sequence,
    Generation? generation,
    required ServerTimeBasis? basis,
  }) => QueueSession(
    connected: connected ?? this.connected,
    build: build,
    number: number,
    labelsFrom: labelsFrom,
    sequence: sequence ?? this.sequence,
    generation: generation ?? this.generation,
    basis: basis,
  );

  QueueSession withConnection({
    required bool connected,
    required ServerTimeBasis? basis,
  }) => _copy(connected: connected, basis: basis);

  QueueSession on(Generation generation) =>
      _copy(generation: generation, basis: basis);

  QueueSession get stepped => _copy(sequence: sequence + 1, basis: basis);

  bool labels(int label) =>
      label != 0 && label >= labelsFrom && label <= number;

  @override
  bool operator ==(Object other) =>
      other is QueueSession &&
      other.connected == connected &&
      other.build == build &&
      other.number == number &&
      other.labelsFrom == labelsFrom &&
      other.sequence == sequence &&
      other.generation == generation &&
      other.basis == basis;

  @override
  int get hashCode => Object.hash(
    connected,
    build,
    number,
    labelsFrom,
    sequence,
    generation,
    basis,
  );
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
    session: QueueSession(
      connected: false,
      build: build,
      number: 1,
      sequence: 0,
    ),
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

final class RefusedAgain extends PendingState {
  const RefusedAgain({required this.refusals, required this.backoff});

  final int refusals;
  final Backoff backoff;

  @override
  bool operator ==(Object other) =>
      other is RefusedAgain &&
      other.refusals == refusals &&
      other.backoff == backoff;

  @override
  int get hashCode => Object.hash(RefusedAgain, refusals, backoff);

  @override
  String toString() => 'refused and sent again ($refusals refusals, $backoff)';
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
  const RetryAfter(this.at, {required this.failedAt});

  final DateTime at;
  final DateTime failedAt;

  @override
  bool operator ==(Object other) =>
      other is RetryAfter && other.at == at && other.failedAt == failedAt;

  @override
  int get hashCode => Object.hash(RetryAfter, at, failedAt);

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

final class WrittenLongAgo extends UserReason {
  const WrittenLongAgo();

  @override
  bool operator ==(Object other) => other is WrittenLongAgo;

  @override
  int get hashCode => (WrittenLongAgo).hashCode;

  @override
  String toString() =>
      'written more than 29 days ago, too long to check against the server';
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

final class RowPageGone extends UserReason {
  const RowPageGone();

  @override
  bool operator ==(Object other) => other is RowPageGone;

  @override
  int get hashCode => (RowPageGone).hashCode;

  @override
  String toString() => 'its page is gone';
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

final class PageListResult extends ResultSubject {
  const PageListResult();

  @override
  bool operator ==(Object other) => other is PageListResult;

  @override
  int get hashCode => (PageListResult).hashCode;

  @override
  String toString() => 'the page list';
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
        Waiting() || Unanswered() || RefusedAgain() => true,
        Sending() || NeedsUser() => false,
      };
}

sealed class QueueEffect {
  const QueueEffect();
}

final class PageResultDeferred extends QueueEffect {
  const PageResultDeferred(this.page);

  final String page;

  @override
  bool operator ==(Object other) =>
      other is PageResultDeferred && other.page == page;

  @override
  int get hashCode => Object.hash(PageResultDeferred, page);

  @override
  String toString() => 'PageResultDeferred($page)';
}

final class StrategySetAside extends QueueEffect {
  const StrategySetAside(this.count);

  final int count;

  @override
  bool operator ==(Object other) =>
      other is StrategySetAside && other.count == count;

  @override
  int get hashCode => Object.hash(StrategySetAside, count);

  @override
  String toString() => 'StrategySetAside($count)';
}

final class SetAsideDiscarded extends QueueEffect {
  const SetAsideDiscarded(this.count);

  final int count;

  @override
  bool operator ==(Object other) =>
      other is SetAsideDiscarded && other.count == count;

  @override
  int get hashCode => Object.hash(SetAsideDiscarded, count);

  @override
  String toString() => 'SetAsideDiscarded($count)';
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
  SendBatch(
    this.attempt,
    this.clientId,
    List<StrategyOp> ops, {
    this.basis,
    this.strategyLife,
    Map<String, int> lives = const {},
  }) : ops = List.unmodifiable(ops),
       lives = Map.unmodifiable(lives);

  final int attempt;
  final String clientId;
  final List<StrategyOp> ops;
  final int? basis;
  final int? strategyLife;
  final Map<String, int> lives;

  @override
  String toString() =>
      'SendBatch($attempt, ${ops.map((op) => op.opId)}'
      '${basis == null ? '' : ', basis $basis'})';
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

final class ReportReplacedWithoutLife extends QueueEffect {
  const ReportReplacedWithoutLife(this.attempt);

  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is ReportReplacedWithoutLife && other.attempt == attempt;

  @override
  int get hashCode => Object.hash(ReportReplacedWithoutLife, attempt);

  @override
  String toString() => 'ReportReplacedWithoutLife($attempt)';
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
  Stepped(
    super.queue,
    List<QueueEffect> effects, {
    List<RowDecision> decisions = const [],
    this.tookResult = false,
  }) : effects = List.unmodifiable(effects),
       decisions = List.unmodifiable(decisions);

  final List<QueueEffect> effects;
  final List<RowDecision> decisions;
  final bool tookResult;
}

final class NotApplicable extends Step {
  NotApplicable(super.queue, this.why, {List<QueueEffect> effects = const []})
    : effects = List.unmodifiable(effects);

  final Inapplicable why;
  final List<QueueEffect> effects;
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

final class NotOfAnotherLife extends Inapplicable {
  const NotOfAnotherLife();

  @override
  String toString() =>
      'an edit said to be of another life names the record\'s own life';
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

final class StartedInAnotherLife extends Inapplicable {
  const StartedInAnotherLife();

  @override
  String toString() =>
      'a result read while this device held another life of the strategy';
}

final class OlderResult extends Inapplicable {
  const OlderResult();

  @override
  String toString() =>
      'a result read before one already taken, or of an earlier life';
}

final class SameResult extends Inapplicable {
  const SameResult();

  @override
  String toString() => 'a refusal at the point of the result already taken';
}

final class NothingSetAsideToDiscard extends Inapplicable {
  const NothingSetAsideToDiscard();

  @override
  String toString() => 'nothing is set aside';
}

final class NothingClaimed extends Inapplicable {
  const NothingClaimed();

  @override
  String toString() => 'NothingClaimed';
}

final class ConnectionAlreadyEnded extends Inapplicable {
  const ConnectionAlreadyEnded(this.generation);

  final Generation generation;

  @override
  String toString() => 'ConnectionAlreadyEnded($generation)';
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
  final decisions = <RowDecision>[];
  bool tookResult = false;
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

  int get nextPlace =>
      [
        -1,
        ...[for (final entry in entries) entry.place],
        if (strategy.setAside case SetAside(:final entries))
          for (final entry in entries) entry.place,
      ].reduce((a, b) => a > b ? a : b) +
      1;

  void setAsideAll(int? writtenIn, int replacedBy) {
    final kept = switch (strategy.setAside) {
      SetAside(:final generations) => generations,
      NothingSetAside() => const <SetAsideGeneration>[],
    };
    final moved = [...entries];
    for (final old in [...entries]) {
      index.remove(old);
      change.removed.add(old);
      change.touched.remove(old.id);
    }
    entries.clear();
    for (final attempt in [...attempts.values]) {
      dropAttempt(attempt);
    }
    landed.clear();
    strategy = strategy.copyWith(
      presence: Presence.present,
      setAside: moved.isEmpty && kept.isEmpty
          ? const NothingSetAside()
          : SetAside([
              ...kept,
              if (moved.isNotEmpty)
                SetAsideGeneration(
                  writtenIn: writtenIn,
                  replacedBy: replacedBy,
                  entries: moved,
                ),
            ]),
    );
    change.everything = true;
    if (moved.isNotEmpty) effects.add(StrategySetAside(moved.length));
  }

  void setAttempt(AttemptFact attempt) {
    final old = attempts[attempt.number];
    attempts[attempt.number] = attempt;
    if (old == null) index.addAttempt(attempt);
    if (old != null && attempt.outcome is AttemptRefusedWhole) {
      index.unsent(attempt, attempts);
    }
    for (final opId in attempt.opIds) {
      if (index.byId.containsKey(opId)) change.touched.add(opId);
    }
  }

  void dropAttempt(AttemptFact attempt) {
    attempts.remove(attempt.number);
    index.removeAttempt(attempt);
  }

  int get lastAttempt => nextAttempt - 1;

  int recordStep() {
    session = session.stepped;
    return session.sequence;
  }

  ResultOrder orderOf(ResultPoint point) => session.orderOf(point);

  void openSession({
    required bool connected,
    required String build,
    Generation? generation,
    bool sameLabels = false,
  }) {
    final number = nextSession++;
    session = QueueSession(
      connected: connected,
      build: build,
      number: number,
      labelsFrom: sameLabels ? session.labelsFrom : number,
      sequence: 0,
      generation: generation,
    );
    shown = shown.inNewSession();
    for (final (at, work) in [...landed.indexed]) {
      if (work.produced != null) landed[at] = work.withoutProduced();
    }
    for (final entry in [...entries]) {
      if (entry case PendingOp(
        :final authored,
      ) when _producesOf(authored)?.justifies ?? false) {
        put(
          entry.copyWith(
            authored: _withProduces(
              authored,
              _producesOf(authored)!.unjustified(),
            ),
          ),
        );
      }
    }
    change.everything = true;
    effects.add(SessionOpened(session.number));
  }

  CloudQueue build() {
    _pruneAttempts(this);
    if (shown.list != original.shown.list) change.everything = true;
    for (final page in {
      ...shown.pageReads.keys,
      ...original.shown.pageReads.keys,
    }) {
      if (shown.pageRead(page) != original.shown.pageRead(page)) {
        change.pages.add(page);
        for (final rows in [shown.rows, original.shown.rows]) {
          for (final MapEntry(:key, :value) in rows.entries) {
            if (value.page == page) change.targets.add(key);
          }
        }
      }
    }
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

  Stepped done() =>
      Stepped(build(), effects, decisions: decisions, tookResult: tookResult);
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
    NotApplicable(:final why) => _inapplicable(start, event, why, now),
  };
}

NotApplicable _inapplicable(
  CloudQueue start,
  QueueEvent event,
  Inapplicable why,
  DateTime now,
) {
  final point = switch (event) {
    BaseArrived(:final point, :final session) ||
    ResultRefused(
      :final point,
      :final session,
    ) when start.session.labels(session) => point,
    OpAnswered(:final point) || BatchRefused(:final point) => point,
    _ => null,
  };
  if (point == null) return NotApplicable(start, why);
  final admitted = _Edit(start, now);
  if (!_admitted(admitted, point) || admitted.session == start.session) {
    return NotApplicable(start, why);
  }
  return NotApplicable(admitted.build(), why, effects: admitted.effects);
}

Step _step(_Edit edit, CloudQueue queue, QueueEvent event, DateTime now) {
  switch (event) {
    case UserEdited(edit: final change, :final madeOn):
      final recordLife = edit.shown.strategy?.life;
      if ((madeOn, recordLife) case (
        final made?,
        final record?,
      ) when made != record) {
        return _setAsideEdit(edit, change, made, record, now);
      }
      return _userEdited(edit, change, now);
    case BatchClaimed(:final clientId, :final opIds, :final at, :final elapsed):
      return _claim(edit, clientId, opIds, at, elapsed?.call(), now);
    case ServerTimeHeld(:final serverTime, :final at, :final session):
      final held = edit.session.basis;
      if (edit.session.connected &&
          session == edit.session.number &&
          (held == null || serverTime > held.serverTime)) {
        edit.session = edit.session.withConnection(
          connected: true,
          basis: ServerTimeBasis(serverTime, heldAt: at),
        );
      }
      return edit.done();
    case ClaimReleased(:final attempt):
      return _closeAttempt(edit, attempt, const AttemptReleased());
    case TransportFailed(:final attempt, :final failure, :final at):
      return _closeAttempt(
        edit,
        attempt,
        AttemptFailed(TransportCut(failure), at),
      );
    case BatchRefused(
      :final attempt,
      :final refusal,
      :final at,
      :final currentLife,
      :final point,
    ):
      if (!_admitted(edit, point)) {
        return _lostToAnEndedConnection(edit, attempt);
      }
      return _batchRefused(edit, attempt, refusal, at, currentLife, point);
    case ReadRefusedForUpgrade(:final build):
      edit.strategy = edit.strategy.copyWith(
        upgradeTold: UpgradeToldTo(build, attempt: edit.nextAttempt - 1),
      );
      if (build == edit.session.build) {
        edit.effects.add(const HoldSendingForUpgrade());
      }
      return edit.done();
    case OpAnswered(:final attempt, :final answer, :final point):
      if (!_admitted(edit, point)) {
        return _lostToAnEndedConnection(edit, attempt);
      }
      return _answered(edit, attempt, answer, point);
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
      edit.session = edit.session.withConnection(connected: false, basis: null);
      return edit.done();
    case ConnectionReturned(:final generation):
      if (generation.client < 1) {
        return NotApplicable(queue, ConnectionAlreadyEnded(generation));
      }
      switch (edit.session.generation) {
        case final held? when generation.isBefore(held):
          return NotApplicable(queue, ConnectionAlreadyEnded(generation));
        case final held? when held == generation:
          edit.session = edit.session.withConnection(
            connected: true,
            basis: edit.session.basis,
          );
        case final held:
          edit.openSession(
            connected: true,
            build: edit.session.build,
            generation: generation,
            sameLabels: held != null,
          );
      }
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
    case UserDiscardedReplaced():
      final count = edit.strategy.setAside.count;
      if (count == 0) {
        return NotApplicable(queue, const NothingSetAsideToDiscard());
      }
      edit.strategy = edit.strategy.copyWith(setAside: const NothingSetAside());
      edit.effects.add(SetAsideDiscarded(count));
      return edit.done();
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
    case ResultRefused(
      :final page,
      :final problem,
      :final session,
      :final point,
      :final requestedAt,
    ):
      if (!edit.session.labels(session) || !_admitted(edit, point)) {
        return NotApplicable(queue, FromAnEndedSession(session));
      }
      final refused = Arrival(
        order: edit.orderOf(point),
        point: point,
        requestedAt: requestedAt,
        requestedIn: session,
      );
      if (edit.shown.fence case final fence?
          when refused.order.isBefore(fence)) {
        return NotApplicable(queue, const StartedInAnotherLife());
      }
      if (edit.shown.contentTakenOf(page) case final taken?
          when !taken.isBefore(refused.order)) {
        return NotApplicable(
          queue,
          taken == refused.order ? const SameResult() : const OlderResult(),
        );
      }
      if (edit.shown.refusedAtOf(page) case final earlier?
          when refused.order.isBefore(earlier)) {
        return NotApplicable(queue, const OlderResult());
      }
      final since = switch (switch (page) {
        final page? => edit.shown.pageRead(page),
        null => edit.shown.list,
      }) {
        ReadOwed(since: ResultAtOrAfter() && final owed) ||
        ReadRefused(
          since: ResultAtOrAfter() && final owed,
        ) when !owed.paidBy(refused, null) => owed,
        ReadOwed(since: ResultAtOrAfter()) ||
        ReadRefused(since: ResultAtOrAfter()) ||
        NotReadThisSession() ||
        ReadThisSession() => ResultAtOrAfter(refused.order),
        ReadOwed(since: final owed) || ReadRefused(since: final owed) => owed,
      };
      edit.shown = switch (page) {
        final page? => edit.shown.pageRefused(
          page,
          problem,
          since,
          at: refused.order,
        ),
        null => edit.shown.listRefused(problem, since, at: refused.order),
      };
      return edit.done();
    case EditOfAnotherLife(edit: final change, :final madeOn):
      final recordLife = edit.shown.strategy?.life;
      if (recordLife == null || madeOn == recordLife) {
        return NotApplicable(queue, const NotOfAnotherLife());
      }
      return _setAsideEdit(edit, change, madeOn, recordLife, now);
    case BaseArrived(
      :final base,
      :final session,
      :final point,
      :final requestedAt,
    ):
      if (!edit.session.labels(session) || !_admitted(edit, point)) {
        return NotApplicable(queue, FromAnEndedSession(session));
      }
      return _arrived(
        edit,
        base,
        Arrival(
          order: edit.orderOf(point),
          point: point,
          requestedAt: requestedAt,
          requestedIn: session,
        ),
      );
  }
}

bool _admitted(_Edit edit, ResultPoint point) {
  final generation = point.generation;
  if (generation.client < 1) return false;
  switch (edit.session.generation) {
    case null:
      edit.session = edit.session.on(generation);
    case final held when generation.isBefore(held):
      return false;
    case final held when held.isBefore(generation):
      edit.openSession(
        connected: true,
        build: edit.session.build,
        generation: generation,
        sameLabels: true,
      );
    case _:
      break;
  }
  return true;
}

Step _lostToAnEndedConnection(_Edit edit, int attempt) => _closeAttempt(
  edit,
  attempt,
  AttemptFailed(
    const TransportCut(TransportFailure.answeredOnEndedConnection),
    edit.now,
  ),
);

void _dropRefusedBases(_Edit edit, AttemptFact refused) {
  final bases = [
    for (final op in refused.ops)
      if (isUncheckedSend(op))
        if (edit.index.byId[op.opId] case PendingOp(:final basis?))
          basis.serverTime,
  ];
  if (bases.isEmpty) return;
  final refusedBasis = bases.reduce((a, b) => a < b ? a : b);
  for (final entry in [...edit.entries]) {
    if (entry case PendingOp(
      :final basis?,
    ) when basis.serverTime <= refusedBasis) {
      edit.put(entry.copyWith(dropBasis: true));
    }
  }
}

Step _batchRefused(
  _Edit edit,
  int attempt,
  BatchRefusal refusal,
  DateTime? at,
  int? currentLife,
  ResultPoint point,
) {
  final fact = edit.attempts[attempt];
  if (fact == null) return NotApplicable(edit.original, NoSuchAttempt(attempt));
  if (fact.outcome is! AttemptRefusedWhole) {
    edit.setAttempt(fact.withOutcome(AttemptRefusedWhole(refusal, at: at)));
  }
  if (refusal == BatchRefusal.uncheckedTooLate) _dropRefusedBases(edit, fact);
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
    case BatchRefusal.strategyReplaced:
      if (currentLife == null) {
        edit.effects.add(ReportReplacedWithoutLife(attempt));
      }
      edit.shown = edit.shown.owingListPast(
        edit.shown.strategy?.life,
        AfterRefusal(
          session: edit.session.number,
          point: point,
          step: edit.recordStep(),
          evidence: switch (currentLife) {
            final life? => StrategyLifeAtLeast(life),
            null => null,
          },
        ),
        named: currentLife,
      );
    case BatchRefusal.uncheckedTooLate:
      edit.session = edit.session.withConnection(
        connected: edit.session.connected,
        basis: null,
      );
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

enum ResultFit { applies, adopts, listFirst, older, startedInAnotherLife }

ResultFit resultFit(Shown shown, ArrivedBase base, Arrival arrival) {
  final held = shown.strategy?.life;
  if (shown.fence case final fence? when arrival.order.isBefore(fence)) {
    return ResultFit.startedInAnotherLife;
  }
  if (shown.takenFor(base) case final taken?
      when arrival.order.isBefore(taken)) {
    return ResultFit.older;
  }
  if (shown.owedBy(base) case final owed? when !owed.paidBy(arrival, base)) {
    return ResultFit.older;
  }
  return switch (base) {
    HeaderRead(:final strategy) => switch ((held, createdAtOf(strategy))) {
      (_, final listed?) when listed == _refusedLife(shown.list) =>
        ResultFit.older,
      (_, final listed?) when (namedLifeOf(shown.list) ?? listed) > listed =>
        ResultFit.older,
      (final held?, final listed?)
          when namedLifeOf(shown.list) != null && listed != held =>
        ResultFit.adopts,
      (final held?, final listed?) when listed > held => ResultFit.adopts,
      (final held?, final listed?)
          when listed < held && _refusedLife(shown.list) == held =>
        ResultFit.adopts,
      (final held?, final listed?) when listed < held => ResultFit.older,
      _ => ResultFit.applies,
    },
    PageRead(:final page) => switch (shown.pages[page.publicId]) {
      null when page is TrashedPage => ResultFit.applies,
      null => ResultFit.listFirst,
      final listed => switch ((listed.life, createdAtOf(page))) {
        (final listed?, final read?) when read > listed => ResultFit.listFirst,
        (final listed?, final read?) when read < listed => ResultFit.older,
        _ => ResultFit.applies,
      },
    },
    PageGone() || StrategyGone() => ResultFit.applies,
  };
}

int? _refusedLife(ReadState list) => switch (list) {
  ReadOwed(:final unlessLife) || ReadRefused(:final unlessLife) => unlessLife,
  NotReadThisSession() || ReadThisSession() => null,
};

Step _arrived(_Edit edit, ArrivedBase base, Arrival arrival) {
  switch (resultFit(edit.shown, base, arrival)) {
    case ResultFit.older:
      return NotApplicable(edit.original, const OlderResult());
    case ResultFit.startedInAnotherLife:
      return NotApplicable(edit.original, const StartedInAnotherLife());
    case ResultFit.listFirst:
      if (!isDebt(edit.shown.list)) {
        edit.shown = edit.shown.owingList(ResultAtOrAfter(arrival.order));
      }
      if (base case PageRead(:final page)) {
        edit.effects.add(PageResultDeferred(page.publicId));
      }
      return edit.done();
    case ResultFit.adopts:
      edit.tookResult = true;
      final written = edit.shown.strategy!.life!;
      final listed = createdAtOf((base as HeaderRead).strategy)!;
      edit.setAsideAll(written, listed);
      final taken = edit.shown;
      final adopted = Shown.nothing.taken(base, arrival: arrival);
      edit.decisions.addAll([
        for (final page in taken.knownPages) PageLeft(page),
        ...adopted.decisions,
      ]);
      edit.shown = adopted.shown.fencedAt(arrival.order, after: taken);
      return edit.done();
    case ResultFit.applies:
      edit.tookResult = true;
  }
  if (base is StrategyGone) {
    edit.strategy = edit.strategy.copyWith(presence: Presence.gone);
    edit.shown = edit.shown.taken(base, arrival: arrival).shown;
    return edit.done();
  }
  final before = edit.shown;
  final taken = edit.shown.taken(base, arrival: arrival);
  edit.decisions.addAll(taken.decisions);
  edit.shown = taken.shown;
  if (base case HeaderRead(:final strategy)) {
    for (final work in edit.landed) {
      if (work.op case PageAddOp(:final pagePublicId)
          when work.own &&
              _listShowsLanded(strategy, work, before.strategy?.life) &&
              !edit.shown.pages.containsKey(pagePublicId)) {
        edit.shown = edit.shown.withGone(pagePublicId);
      }
    }
  }
  if (base case PageRead(:final page, :final elements, :final lineupGroups)) {
    final held = {
      for (final row in elements) ElementTarget(row.publicId),
      for (final row in lineupGroups) LineupTarget(row.publicId),
    };
    for (final (at, work) in [...edit.landed.indexed]) {
      final added = switch (work.op) {
        ElementAddOp(:final pagePublicId) ||
        LineupGroupAddOp(:final pagePublicId) => pagePublicId,
        _ => null,
      };
      if (work.own &&
          !work.shownWithout &&
          added == page.publicId &&
          !held.contains(targetOf(work.op)) &&
          work.answeredAt.reachedBy(arrival)) {
        edit.landed[at] = work.seenWithout();
        edit.change.targets.add(targetOf(work.op));
      }
    }
  }
  for (final work in [...edit.landed]) {
    if (!_alreadyShown(edit.shown, work)) continue;
    edit.landed.remove(work);
    edit.change.lives.addAll([
      ...pagesNeeded(work.op),
      ?before.rows[targetOf(work.op)]?.page,
      ?edit.shown.rows[targetOf(work.op)]?.page,
    ]);
  }
  switch (base) {
    case HeaderRead():
      edit.change.everything = true;
    case PageRead(:final page, :final elements, :final lineupGroups):
      edit.change.pages.add(page.publicId);
      edit.change.targets.addAll([
        for (final row in elements) ElementTarget(row.publicId),
        for (final row in lineupGroups) LineupTarget(row.publicId),
        ..._shownOn(before, page.publicId),
      ]);
    case PageGone(:final pagePublicId):
      edit.change.pages.add(pagePublicId);
      edit.change.targets.addAll(_shownOn(before, pagePublicId));
    case StrategyGone():
      break;
  }
  return edit.done();
}

bool _listShowsLanded(StrategyRow listed, LandedWork work, int? landedIn) =>
    switch (versionOfRow(listed)) {
      final version? => version >= Version(work.revision, life: landedIn),
      null => false,
    };

bool _unchangedPrediction(Authored authored) => switch (authored) {
  AuthoredRow(:final revision, :final produces?) =>
    produces.revision == revision,
  _ => false,
};

void _laterUnjustified(_Edit edit, PendingOp entry, LandedWork work) {
  final row = targetOf(entry.op);
  for (final later in [...edit.entries]) {
    if (later case PendingOp(
      :final place,
      :final authored,
    ) when place > entry.place && targetOf(later.op) == row) {
      if (_producesOf(authored) case final produces? when produces.justifies) {
        edit.put(
          later.copyWith(
            authored: _withProduces(authored, produces.unjustified()),
          ),
        );
      }
    }
  }
  for (final (at, other) in [...edit.landed.indexed]) {
    if (other.produced != null &&
        targetOf(other.op) == row &&
        other.compareTo(work) > 0) {
      edit.landed[at] = other.withoutProduced();
      edit.change.targets.add(row);
    }
  }
}

Authored _withProduces(Authored authored, ProducedRow produces) =>
    switch (authored) {
      final AuthoredRow row => row.withProduces(produces),
      AuthoredNoRow() => AuthoredNoRow(produces: produces),
      final other => other,
    };

void _resultsStale(_Edit edit, PendingOp entry, StrategyOp sent) {
  final row = targetOf(sent);
  final pages = {
    ..._pagesOf(entry),
    ...pagesNeeded(sent),
    ?edit.shown.rows[row]?.page,
    if (row case PageTarget(:final pagePublicId)) pagePublicId,
    if (row case SettingsTarget(:final pagePublicId)) pagePublicId,
  };
  final list =
      row is StrategyTarget ||
      row is PageTarget ||
      row is SettingsTarget ||
      renumbersPages(sent);
  edit.shown = edit.shown.touched(pages, list: list);
  edit.change.lives.addAll({
    ...pages,
    if (list) ...{...edit.shown.pages.keys, ...edit.shown.fresh.listed},
  });
}

Iterable<Target> _shownOn(Shown shown, String page) => [
  for (final MapEntry(:key, :value) in shown.rows.entries)
    if (value.page == page) key,
];

bool _alreadyShown(Shown shown, LandedWork work) {
  final shownAt = shown.highest[checkTargetOf(work.op)];
  if (shownAt == null) return false;
  return _ownDelete(work) ? shownAt > work.version : shownAt >= work.version;
}

bool _ownDelete(LandedWork work) =>
    work.own && (work.op is ElementDeleteOp || work.op is LineupGroupDeleteOp);

Step _setAsideEdit(
  _Edit edit,
  Edit change,
  int? madeOn,
  int recordLife,
  DateTime now,
) {
  final queue = edit.original;
  final op = change.op;
  if (!isJson(op.toJson())) return NotApplicable(queue, NotJson(op.opId));
  if (_opIdTaken(edit, op.opId)) {
    return NotApplicable(queue, OpIdTaken(op.opId));
  }
  final entry = PendingOp(
    place: edit.nextPlace,
    work: switch (change) {
      PlainEdit() => OpWork(op),
      PageDeleteEdit(:final seen) => CheckedDelete(op as PageDeleteOp, seen),
    },
    scope: change.scope,
    authored: change.authored,
    authoredIn: edit.session.number,
    authoredAt: now,
    refusal: const NotRefused(),
    retriedAfter: edit.lastAttempt,
    strategyLife: madeOn,
  );
  final kept = switch (edit.strategy.setAside) {
    SetAside(:final generations) => generations,
    NothingSetAside() => const <SetAsideGeneration>[],
  };
  final joins = kept.indexWhere(
    (generation) =>
        generation.writtenIn == madeOn && generation.replacedBy == recordLife,
  );
  edit.strategy = edit.strategy.copyWith(
    setAside: SetAside([
      for (final (at, generation) in kept.indexed)
        at == joins
            ? SetAsideGeneration(
                writtenIn: madeOn,
                replacedBy: recordLife,
                entries: [...generation.entries, entry],
              )
            : generation,
      if (joins == -1)
        SetAsideGeneration(
          writtenIn: madeOn,
          replacedBy: recordLife,
          entries: [entry],
        ),
    ]),
  );
  edit.effects.add(const StrategySetAside(1));
  return edit.done();
}

bool _opIdTaken(_Edit edit, String opId) =>
    edit.indexOf(opId) != -1 ||
    switch (edit.strategy.setAside) {
      SetAside(:final entries) => entries.any((entry) => entry.id == opId),
      NothingSetAside() => false,
    };

Step _userEdited(_Edit edit, Edit change, DateTime now) {
  final queue = edit.original;
  final op = change.op;
  if (!isJson(op.toJson())) return NotApplicable(queue, NotJson(op.opId));
  if (_opIdTaken(edit, op.opId)) {
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
        (queue._index.attemptsByOp[last.id] ?? const []).isEmpty &&
        last.work is OpWork &&
        last.scope == change.scope &&
        last.authoredIn == edit.session.number &&
        expectedLifeOf(last) == _lifeAuthored(change.authored) &&
        last.strategyLife == queue.shown.strategy?.life &&
        view.state is Waiting &&
        view.holds.every((hold) => _foldableHold(hold, views))) {
      switch (fold(last.op, op)) {
        case FoldedOp(op: final folded):
          edit.replaceAt(
            at,
            last.copyWith(
              work: OpWork(folded),
              authored: _foldedAuthored(last.authored, change.authored),
            ),
          );
          edit.effects.add(OpRemoved(last.id, FoldedInto(folded.opId)));
          return edit.done();
        case KeptApart():
          break;
      }
    }
  }
  final placed = op;
  final row = targetOf(op);
  final authored = _justifiedOrNot(queue, edit.entries, row, change.authored);
  final behindOwn =
      edit.index.checkedUnder(checkTargetOf(op)).isNotEmpty ||
      (row is PageTarget &&
          queue._index.lastBefore(
                queue._index.under,
                const _Renumbering(),
                1 << 62,
              ) !=
              null) ||
      queue.landed.any(
        (work) =>
            !_alreadyShown(queue.shown, work) &&
            (targetOf(work.op) == row ||
                (row is PageTarget && renumbersPages(work.op))),
      );
  edit.append(
    PendingOp(
      place: edit.nextPlace,
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
      authoredAt: now,
      refusal: const NotRefused(),
      retriedAfter: edit.lastAttempt,
      behindOwn: behindOwn,
      basis: edit.session.basis,
      strategyLife: queue.shown.strategy?.life,
    ),
  );
  return edit.done();
}

Authored _justifiedOrNot(
  CloudQueue queue,
  List<QueueEntry> entries,
  Target row,
  Authored authored,
) {
  if (_producesOf(authored) == null) return authored;
  final ahead = entries
      .whereType<PendingOp>()
      .where((entry) => targetOf(entry.op) == row)
      .lastOrNull;
  final justified = switch ((authored, ahead)) {
    (AuthoredRow(:final revision, :final digest), final ahead?) =>
      switch (_producesOf(ahead.authored)) {
        final produced? =>
          produced.justifies &&
              produced.revision == revision &&
              produced.digest == digest,
        null => false,
      },
    (_, null) => _baseJustified(queue, row, authored),
    (AuthoredNoRow(), final ahead?) =>
      _producesOf(ahead.authored)?.justifies ?? false,
    _ => false,
  };
  if (justified) return authored;
  return _withProduces(authored, _producesOf(authored)!.unjustified());
}

bool _baseJustified(CloudQueue queue, Target row, Authored authored) =>
    switch ((authored, _knownRow(queue, row))) {
      (
        AuthoredRow(:final revision, :final digest),
        _KnownRow(revision: final known, digest: final shown, current: true),
      ) =>
        known == revision && (shown == null || shown == digest),
      (AuthoredNoRow(), null) => true,
      _ => false,
    };

ShownRow? _shownRow(Shown shown, Target target) => switch (target) {
  StrategyTarget() => shown.strategy,
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

sealed class _Verdict {
  const _Verdict();
}

final class _NameAt extends _Verdict {
  const _NameAt(this.revision, {this.until});

  final int? revision;
  final DateTime? until;
}

final class _AwaitRow extends _Verdict {
  const _AwaitRow(this.page, {this.until});

  final String? page;
  final DateTime? until;
}

final class _AskUser extends _Verdict {
  const _AskUser([this.reason = const ChangedUnseen()]);

  final UserReason reason;
}

enum _Writes { wholeRow, putBack, fields, other }

_Writes _writesOf(StrategyOp op) => switch (op) {
  ElementPatchOp(merge: null, payload: _?) ||
  LineupGroupPatchOp(merge: null, payload: _?) ||
  PagePatchOp() ||
  PageSettingsPatchOp() => _Writes.wholeRow,
  ElementAddOp(expectedElementRevision: _?) ||
  LineupGroupAddOp(expectedLineupRevision: _?) => _Writes.putBack,
  ElementPatchOp(merge: _?, pagePublicId: null) ||
  LineupGroupPatchOp(merge: _?, pagePublicId: null) => _Writes.fields,
  _ => _Writes.other,
};

sealed class _Known {
  const _Known();
}

final class _KnownRow extends _Known {
  const _KnownRow(
    this.page,
    this.revision,
    this.digest, {
    required this.current,
    required this.life,
  });

  final String? page;
  final int revision;
  final String? digest;
  final bool current;
  final int? life;
}

final class _NotKnown extends _Known {
  const _NotKnown(this.revision, {required this.life});

  final int revision;
  final int? life;
}

_Known? _knownRow(CloudQueue queue, Target row) {
  final shown = queue.shown;
  final result = _shownRow(shown, row);
  final current = switch (row) {
    PageTarget() || SettingsTarget() => shown.headerThisSession,
    _ => result != null && shown.pageReadThisSession(result.page),
  };
  _Known? best = switch ((row, result)) {
    (StrategyTarget(), _) => switch (shown.strategy) {
      ShownRow(revision: final revision?, :final digest, :final life) =>
        _KnownRow(
          null,
          revision,
          digest,
          current: shown.headerThisSession,
          life: life,
        ),
      _ => null,
    },
    (
      _,
      ShownRow(
        :final page,
        revision: final revision?,
        :final digest,
        :final life,
      ),
    ) =>
      _KnownRow(page, revision, digest, current: current, life: life),
    _ => null,
  };
  Version versionOf(_Known known) => switch (known) {
    _KnownRow(:final revision, :final life) ||
    _NotKnown(:final revision, :final life) => Version(revision, life: life),
  };
  for (final work in queue.landed) {
    if (targetOf(work.op) != row) continue;
    if (best != null && versionOf(best) >= work.version) continue;
    best = switch (work.produced) {
      ProducedRow(:final page, :final revision, :final digest, :final life) =>
        _KnownRow(page, revision, digest, current: true, life: life),
      null => _NotKnown(work.revision, life: work.life),
    };
  }
  return best;
}

_Verdict _judge(CloudQueue queue, PendingOp entry, DateTime now) {
  final op = entry.op;
  final authored = expectedOf(op);
  if (authored == null) return const _NameAt(null);
  if (entry.authored case KeptOverServer(:final revision)) {
    return _NameAt(revision);
  }
  final row = targetOf(op);
  switch (_writesOf(op)) {
    case _Writes.fields:
      return _NameAt(authored);
    case _Writes.other:
      if (!entry.behindOwn) return _NameAt(authored);
      return _wholeBehindOwn(queue, entry, row, authored);
    case _Writes.putBack:
      final seen = entry.authored;
      final delete = queue.landed
          .where(
            (work) =>
                work.own &&
                _deletes(work.op) &&
                targetOf(work.op) == row &&
                work.revision == authored,
          )
          .lastOrNull;
      if (delete == null || seen is! AuthoredRow) return const _AskUser();
      final until = delete.firstSentAt.add(resendWindow);
      if (!now.isBefore(until)) return const _AskUser();
      if (entry.scope case OnPage(
        :final pagePublicId,
      ) when _pageGone(queue.shown, pagePublicId)) {
        return const _AskUser(RowPageGone());
      }
      return switch (_knownRow(queue, row)) {
        _KnownRow(:final revision, :final digest, current: true)
            when revision == authored && digest == seen.digest =>
          _NameAt(authored, until: until),
        _KnownRow(current: true) => const _AskUser(),
        _KnownRow(:final page) => _AwaitRow(page, until: until),
        _ => _AwaitRow(switch (entry.scope) {
          OnPage(:final pagePublicId) => pagePublicId,
          _ => null,
        }, until: until),
      };
    case _Writes.wholeRow:
      if (!entry.behindOwn) return _NameAt(authored);
      return _wholeBehindOwn(queue, entry, row, authored);
  }
}

ProducedRow? _producesOf(Authored authored) => switch (authored) {
  AuthoredRow(:final produces) || AuthoredNoRow(:final produces) => produces,
  _ => null,
};

Authored _foldedAuthored(Authored earlier, Authored later) {
  final first = _producesOf(earlier);
  final last = _producesOf(later);
  final produces = first == null || last == null
      ? null
      : ProducedRow(
          page: last.page,
          revision: switch (earlier) {
            AuthoredRow(:final revision, :final digest) =>
              digest == last.digest ? revision : revision + 1,
            _ => first.revision,
          },
          life: last.life,
          digest: last.digest,
          justifies: first.justifies,
        );
  return switch (earlier) {
    AuthoredRow(
      :final revision,
      :final life,
      :final digest,
      :final payloadVersion,
      :final movedRow,
    ) =>
      AuthoredRow(
        revision: revision,
        life: life,
        digest: digest,
        payloadVersion: payloadVersion,
        produces: produces,
        movedRow:
            movedRow ??
            switch (later) {
              AuthoredRow(:final movedRow) => movedRow,
              _ => null,
            },
      ),
    AuthoredNoRow() => AuthoredNoRow(produces: produces),
    final other => other,
  };
}

bool _pageGone(Shown shown, String page) =>
    shown.goneThisSession.contains(page) ||
    (shown.headerThisSession &&
        !shown.pages.containsKey(page) &&
        shown.highest.containsKey(PageTarget(page)));

bool _deletes(StrategyOp op) =>
    op is ElementDeleteOp || op is LineupGroupDeleteOp;

_Verdict _wholeBehindOwn(
  CloudQueue queue,
  PendingOp entry,
  Target row,
  int authored,
) {
  final shown = queue.shown;
  final seen = entry.authored;
  final known = _knownRow(queue, row);
  final lastShownOn = _shownRow(shown, row)?.page;
  final page = switch ((row, known, entry.scope)) {
    (StrategyTarget(), _, _) => null,
    (PageTarget(:final pagePublicId), _, _) => pagePublicId,
    (SettingsTarget(:final pagePublicId), _, _) => pagePublicId,
    (_, _KnownRow(:final page?), _) => page,
    _ when lastShownOn != null => lastShownOn,
    (_, _, OnPage(:final pagePublicId)) => pagePublicId,
    (_, _, Moving(:final from)) => from,
    _ => null,
  };
  if (page != null && _pageGone(shown, page)) {
    return const _AskUser(RowPageGone());
  }
  final renumbering =
      row is PageTarget &&
      queue.landed.any(
        (work) => renumbersPages(work.op) && !_alreadyShown(shown, work),
      );
  if (renumbering) return _AwaitRow(page);
  switch (known) {
    case _KnownRow(:final revision, :final digest, :final current):
      final asSeen = switch ((seen, digest)) {
        (AuthoredRow(), null) => revision == authored,
        (final AuthoredRow seen, final digest?) =>
          digest == seen.produces?.digest ||
              (revision == authored && digest == seen.digest),
        _ => false,
      };
      if (asSeen && current) return _NameAt(authored);
      return current ? const _AskUser() : _AwaitRow(page);
    case _NotKnown():
      final left = queue.landed.any(
        (work) => targetOf(work.op) == row && work.shownWithout,
      );
      final pageCurrent = switch (row) {
        PageTarget() || SettingsTarget() => shown.headerThisSession,
        _ => page != null && shown.pageReadThisSession(page),
      };
      if (left ||
          (pageCurrent &&
              shown.highest.containsKey(row) &&
              _shownRow(shown, row) == null)) {
        return const _AskUser();
      }
      return _AwaitRow(page);
    case null:
      return _NameAt(authored);
  }
}

PendingOp _named(_Edit edit, PendingOp entry, int revision) {
  if (expectedOf(entry.op) == revision) return entry;
  final named = entry.copyWith(work: _workAt(entry.work, revision));
  edit.put(named);
  return named;
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
  Duration? elapsed,
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
  final lives = <String, int>{};
  int? basis;
  PendingOp? first;
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
    if (!fitsBatch(entry, first)) {
      return NotApplicable(
        queue,
        NotInThatState(opId, 'written in another life of the strategy'),
      );
    }
    first ??= entry;
    final named = switch ((view.state, _judge(queue, entry, now))) {
      (Waiting() || RefusedAgain(), _NameAt(:final revision?)) => _named(
        edit,
        entry,
        revision,
      ),
      _ => entry,
    };
    final sent = sendable(queue, named, elapsed);
    ops.add(sent);
    if (expectedLifeOf(entry) case final life?) lives[sent.opId] = life;
    if (isUncheckedSend(sent)) {
      final own = named.basis!.serverTime;
      if (basis == null || own < basis) basis = own;
    }
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
  edit.effects.add(
    SendBatch(
      number,
      clientId,
      ops,
      basis: basis,
      strategyLife: first?.strategyLife,
      lives: lives,
    ),
  );
  return edit.done();
}

bool fitsBatch(PendingOp entry, PendingOp? first) =>
    first == null || entry.strategyLife == first.strategyLife;

int? expectedLifeOf(PendingOp entry) => _lifeAuthored(entry.authored);

int? _lifeAuthored(Authored authored) => switch (authored) {
  AuthoredRow(:final life) || KeptOverServer(:final life) => life,
  AuthoredNoRow() || AuthoredUnreadable() => null,
};

StrategyOp sendable(CloudQueue queue, PendingOp entry, Duration? elapsed) =>
    sendForm(
      entry.op,
      sendPolicy(
        attempted: (queue._index.attemptsByOp[entry.id] ?? const []).isNotEmpty,
        connected: queue.session.connected,
        writtenThisSession: entry.authoredIn == queue.session.number,
        basis: entry.basis,
        elapsed: elapsed,
      ),
    );

SendPolicy sendPolicy({
  required bool attempted,
  required bool connected,
  required bool writtenThisSession,
  required ServerTimeBasis? basis,
  required Duration? elapsed,
}) => switch ((attempted, connected && writtenThisSession, basis, elapsed)) {
  (true, _, _, _) => SendPolicy.checked,
  (false, false, _, _) => SendPolicy.checked,
  (false, true, null, _) => SendPolicy.checked,
  (false, true, _?, null) => SendPolicy.checked,
  (false, true, final basis?, final elapsed?)
      when elapsed - basis.heldAt > liveFor =>
    SendPolicy.checked,
  (false, true, _?, _?) => SendPolicy.live,
};

bool isUncheckedSend(StrategyOp sent) => switch (sent) {
  ElementPatchOp(merge: FieldMerge(base: null)) ||
  LineupGroupPatchOp(merge: FieldMerge(base: null)) ||
  ElementDeleteOp(lastWriterWins: true) ||
  LineupGroupDeleteOp(lastWriterWins: true) => true,
  _ => false,
};

Step _answered(_Edit edit, int attempt, OpAnswer answer, ResultPoint point) {
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
  final answeredAt = AfterAnswer(
    edit.orderOf(point),
    serverTime: point.serverTime,
  );
  _resultsStale(edit, entry, sent.op);
  void landed(int revision, {required int? life, required bool ours}) =>
      _landed(
        edit,
        entry,
        sent,
        revision,
        life: life,
        ours: ours,
        answeredAt: answeredAt,
      );
  switch (answer) {
    case AppliedAnswer(:final revision, :final life):
      landed(revision, life: life, ours: true);
      edit.remove(entry.id, const Delivered(Delivery.applied));
    case NoopAnswer(
      :final revision,
      :final life,
      replay: NoopReplay.appliedWhenFirstReceived,
    ):
      landed(revision, life: life, ours: true);
      edit.remove(entry.id, const Delivered(Delivery.applied));
    case NoopAnswer(
      :final revision,
      :final life,
      replay: NoopReplay.notApplied,
    ):
      landed(revision, life: life, ours: false);
      edit.remove(entry.id, const Delivered(Delivery.alreadyThere));
    case AnswerWithoutLife(:final revision):
      edit.put(
        entry.copyWith(refusal: RefusedWith(AnsweredWithoutLife(revision))),
      );
    case RejectedAnswer(current: ServerSnapshot(life: null, :final revision)):
      edit.put(
        entry.copyWith(refusal: RefusedWith(AnsweredWithoutLife(revision))),
      );
    case NoopWithoutRevision():
      edit.remove(entry.id, const Delivered(Delivery.nothingToDo));
    case RejectedAnswer(reason: RejectionReason.rowReplaced, :final current):
      _oweTheRowsRead(edit, entry, point, current);
      edit.put(
        entry.copyWith(
          refusal: RefusedWith(
            RejectedByServer(RejectionReason.rowReplaced, current),
          ),
        ),
      );
    case RejectedAnswer(:final reason, :final current):
      if (current case final ServerSnapshot snapshot
          when _alreadyAsWritten(entry.op, snapshot)) {
        landed(snapshot.revision, life: snapshot.life, ours: false);
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

void _oweTheRowsRead(
  _Edit edit,
  PendingOp entry,
  ResultPoint point,
  ServerCopy? current,
) {
  final page = switch (targetOf(entry.op)) {
    StrategyTarget() || PageTarget() || SettingsTarget() => null,
    final row => edit.shown.rows[row]?.page ?? _pagesOf(entry).firstOrNull,
  };
  final checked = checkTargetOf(entry.op);
  final since = AfterRefusal(
    session: edit.session.number,
    point: point,
    step: edit.recordStep(),
    evidence: switch ((current, checked)) {
      (
        ServerSnapshot(target: SnapshotTarget.strategy) &&
            final ServerSnapshot snapshot,
        StrategyTarget(),
      ) ||
      (
        ServerSnapshot(target: SnapshotTarget.page) &&
            final ServerSnapshot snapshot,
        PageTarget(),
      ) ||
      (
        ServerSnapshot(target: SnapshotTarget.element) &&
            final ServerSnapshot snapshot,
        ElementTarget(),
      ) ||
      (
        ServerSnapshot(target: SnapshotTarget.lineup) &&
            final ServerSnapshot snapshot,
        LineupTarget(),
      ) => RowAtLeast(
        checked,
        life: snapshot.life,
        revision: snapshot.revision,
      ),
      _ => null,
    },
  );
  if (page == null) {
    edit.shown = edit.shown.owingList(since);
  } else {
    edit.change.pages.add(page);
    edit.shown = edit.shown.owingPage(page, since);
  }
}

void _landed(
  _Edit edit,
  PendingOp entry,
  ({int attempt, int position, StrategyOp op}) carried,
  int revision, {
  required int? life,
  required bool ours,
  required AfterAnswer answeredAt,
}) {
  final sent = carried.op;
  final produced = switch (entry.authored) {
    AuthoredRow(:final produces?) || AuthoredNoRow(:final produces?)
        when produces.justifies &&
            produces.revision == revision &&
            (ours || _unchangedPrediction(entry.authored)) =>
      produces,
    _ => null,
  };
  final firstSent =
      [
        for (final number in edit.index.attemptsByOp[entry.id] ?? const <int>[])
          if (edit.attempts[number] case final attempt?
              when attempt.outcome is! AttemptRefusedWhole)
            attempt.at,
      ].fold<DateTime?>(
        null,
        (first, at) => first == null || at.isBefore(first) ? at : first,
      );
  final work = LandedWork(
    attempt: carried.attempt,
    position: carried.position,
    op: sent,
    revision: revision,
    life: life,
    shape: _shapeOf(sent),
    own: ours,
    firstSentAt: firstSent ?? edit.attempts[carried.attempt]!.at,
    produced: produced,
    movedRow: switch (entry.authored) {
      AuthoredRow(:final movedRow) => movedRow,
      _ => null,
    },
    answeredAt: answeredAt,
  );
  if (!_alreadyShown(edit.shown, work)) {
    edit.landed
      ..add(work)
      ..sort((a, b) => a.compareTo(b));
  }
  if (produced == null) _laterUnjustified(edit, entry, work);
  edit.change.targets
    ..add(checkTargetOf(sent))
    ..add(targetOf(sent));
  edit.change.lives.addAll([
    ...pagesNeeded(sent),
    ?edit.shown.rows[targetOf(sent)]?.page,
  ]);
  if (renumbersPages(sent)) edit.change.everything = true;
}

bool _userMayReplace(EntryView view) => switch (view.state) {
  NeedsUser(
    reason: RefusedByServer() ||
        ChangedUnseen() ||
        WindowClosed() ||
        WrittenLongAgo() ||
        RowPageGone(),
  ) =>
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
      authored: switch (expectedOf(replacement)) {
        final revision? => KeptOverServer(
          revision,
          life: switch (entry.refusal) {
            RefusedWith(
              refusal: RejectedByServer(current: ServerSnapshot(:final life)),
            ) =>
              life,
            _ => null,
          },
        ),
        null => authored,
      },
      authoredIn: edit.session.number,
      authoredAt: now,
      refusal: const NotRefused(),
      retriedAfter: edit.lastAttempt,
      strategyLife: entry.strategyLife,
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
  if (entry is PendingOp) {
    final entity = entityOf(entry.op);
    for (final later in [...edit.entries]) {
      if (later is PendingOp &&
          later.place > entry.place &&
          entityOf(later.op) == entity) {
        edit.remove(later.id, RemovedByUser(action, landingOf(queue, later)));
      }
    }
  }
  return edit.done();
}
