import 'dart:collection';

import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import 'events.dart';
import 'evidence.dart';
import 'fold.dart';
import 'op_facts.dart';
import 'pending.dart';
import 'sync.dart';

part 'derivation.dart';

final class QueueSession {
  const QueueSession({
    required this.connected,
    required this.build,
    required this.readsFrom,
  });

  factory QueueSession.start(String build, {required int nextRead}) =>
      QueueSession(connected: false, build: build, readsFrom: nextRead);

  final bool connected;
  final String build;
  final int readsFrom;

  int get readsAfter => readsFrom - 1;

  @override
  bool operator ==(Object other) =>
      other is QueueSession &&
      other.connected == connected &&
      other.build == build &&
      other.readsFrom == readsFrom;

  @override
  int get hashCode => Object.hash(connected, build, readsFrom);
}

bool startedAfter(int read, int marker) => read > marker;

final class CloudQueue {
  factory CloudQueue({
    required List<QueueEntry> entries,
    required Map<int, AttemptFact> attempts,
    required int nextAttempt,
    required int nextRead,
    required Evidence base,
    required StrategyFacts strategy,
    required QueueSession session,
  }) {
    final problem = _problemWith(
      entries,
      attempts,
      nextAttempt,
      nextRead,
      base,
      strategy,
    );
    if (problem != null) throw ArgumentError(problem);
    return CloudQueue._(
      entries: entries,
      attempts: attempts,
      nextAttempt: nextAttempt,
      nextRead: nextRead,
      base: base,
      strategy: strategy,
      session: session,
      index: _Index.of(entries, attempts),
      lineage: null,
    );
  }

  CloudQueue._({
    required List<QueueEntry> entries,
    required Map<int, AttemptFact> attempts,
    required this.nextAttempt,
    required this.nextRead,
    required this.base,
    required this.strategy,
    required this.session,
    required _Index index,
    required _Lineage? lineage,
  }) : entries = List.unmodifiable(entries),
       attempts = Map.unmodifiable(attempts),
       _index = index,
       _lineage = lineage;

  factory CloudQueue.start({required String build}) => CloudQueue._(
    entries: const [],
    attempts: const {},
    nextAttempt: 1,
    nextRead: 1,
    base: Evidence.none,
    strategy: StrategyFacts.fresh,
    session: QueueSession.start(build, nextRead: 1),
    index: _Index.empty,
    lineage: null,
  );

  final List<QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  final int nextAttempt;
  final int nextRead;
  final Evidence base;
  final StrategyFacts strategy;
  final QueueSession session;
  final _Index _index;
  _Lineage? _lineage;
  _Derivation? _derived;
  (DateTime, CloudQueue)? _remembered;

  QueueEntry? entry(String id) => _index.byId[id];

  CloudQueue raisedTo({required int nextAttempt, required int nextRead}) {
    if (nextAttempt <= this.nextAttempt && nextRead <= this.nextRead) {
      return this;
    }
    return CloudQueue._(
      entries: entries,
      attempts: attempts,
      nextAttempt: nextAttempt > this.nextAttempt
          ? nextAttempt
          : this.nextAttempt,
      nextRead: nextRead > this.nextRead ? nextRead : this.nextRead,
      base: base,
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
    int nextRead,
    Evidence base,
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
        answer: AnsweredApplied(:final afterRead) ||
            AnsweredRefused(:final afterRead),
      ) when afterRead >= nextRead) {
        return 'entry ${entry.id} was answered after a read not yet started';
      }
      if (entry case PendingOp(
        :final retriedAfter,
      ) when retriedAfter >= nextAttempt) {
        return 'entry ${entry.id} was retried after an attempt not yet made';
      }
      if (entry case PendingOp(
        memory: Forgotten(:final afterRead),
      ) when afterRead >= nextRead) {
        return 'entry ${entry.id} was forgotten after a read not yet started';
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
      if (value.afterRead >= nextRead) {
        return 'attempt $key was made after a read not yet started';
      }
    }
    if (nextRead < 1 || base.lastRead >= nextRead) {
      return 'reads are numbered from 1 and never numbered again';
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
      _sameEntries(other.entries, entries) &&
      sameMap(other.attempts, attempts) &&
      other.nextAttempt == nextAttempt &&
      other.nextRead == nextRead &&
      other.base == base &&
      other.strategy == strategy &&
      other.session == session;

  @override
  int get hashCode =>
      Object.hash(entries.length, nextAttempt, nextRead, strategy);

  static bool _sameEntries(List<QueueEntry> a, List<QueueEntry> b) =>
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

final class NeverSent extends PendingState {
  const NeverSent();

  @override
  bool operator ==(Object other) => other is NeverSent;

  @override
  int get hashCode => (NeverSent).hashCode;

  @override
  String toString() => 'never sent';
}

final class Claimed extends PendingState {
  const Claimed(this.attempt);

  final int attempt;

  @override
  bool operator ==(Object other) =>
      other is Claimed && other.attempt == attempt;

  @override
  int get hashCode => Object.hash(Claimed, attempt);

  @override
  String toString() => 'claimed in $attempt';
}

final class AnswerUnknown extends PendingState {
  const AnswerUnknown({
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
      other is AnswerUnknown &&
      other.clientId == clientId &&
      other.firstSentAt == firstSentAt &&
      other.failures == failures &&
      other.backoff == backoff;

  @override
  int get hashCode =>
      Object.hash(AnswerUnknown, clientId, firstSentAt, failures, backoff);

  @override
  String toString() => 'answer unknown ($failures failures, $backoff)';
}

final class Accepted extends PendingState {
  const Accepted(this.revision);

  final int revision;

  @override
  bool operator ==(Object other) =>
      other is Accepted && other.revision == revision;

  @override
  int get hashCode => Object.hash(Accepted, revision);

  @override
  String toString() => 'accepted at $revision';
}

final class ServerRefused extends PendingState {
  const ServerRefused(this.refusal);

  final ServerRefusal refusal;

  @override
  bool operator ==(Object other) =>
      other is ServerRefused && other.refusal == refusal;

  @override
  int get hashCode => Object.hash(ServerRefused, refusal);

  @override
  String toString() => 'refused: $refusal';
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

final class RetriesExhausted extends Backoff {
  const RetriesExhausted();

  @override
  bool operator ==(Object other) => other is RetriesExhausted;

  @override
  int get hashCode => (RetriesExhausted).hashCode;

  @override
  String toString() => 'retries exhausted';
}

sealed class Go {
  const Go();
}

final class Free extends Go {
  const Free();

  @override
  bool operator ==(Object other) => other is Free;

  @override
  int get hashCode => (Free).hashCode;

  @override
  String toString() => 'free';
}

final class NeedsUser extends Go {
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

final class NeedsFreshId extends Go {
  const NeedsFreshId(this.reason);

  final ReissueReason reason;

  @override
  bool operator ==(Object other) =>
      other is NeedsFreshId && other.reason == reason;

  @override
  int get hashCode => Object.hash(NeedsFreshId, reason);

  @override
  String toString() => 'needs a fresh op id: $reason';
}

sealed class ReissueReason {
  const ReissueReason();
}

final class ServerForgot extends ReissueReason {
  const ServerForgot();

  @override
  bool operator ==(Object other) => other is ServerForgot;

  @override
  int get hashCode => (ServerForgot).hashCode;

  @override
  String toString() => 'the server forgot the op and the row is as authored';
}

final class PageLiveAgain extends ReissueReason {
  const PageLiveAgain();

  @override
  bool operator ==(Object other) => other is PageLiveAgain;

  @override
  int get hashCode => (PageLiveAgain).hashCode;

  @override
  String toString() => 'refused on a deleted page that is live again';
}

sealed class UserReason {
  const UserReason();
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

final class ServerForgotAnswer extends UserReason {
  const ServerForgotAnswer();

  @override
  bool operator ==(Object other) => other is ServerForgotAnswer;

  @override
  int get hashCode => (ServerForgotAnswer).hashCode;

  @override
  String toString() => 'the server forgot whether it landed';
}

final class PayloadVersionChanged extends UserReason {
  const PayloadVersionChanged();

  @override
  bool operator ==(Object other) => other is PayloadVersionChanged;

  @override
  int get hashCode => (PayloadVersionChanged).hashCode;

  @override
  String toString() => 'written by another version since the user saw it';
}

final class OnDeletedPage extends UserReason {
  const OnDeletedPage(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is OnDeletedPage && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(OnDeletedPage, pagePublicId);

  @override
  String toString() => 'on deleted page $pagePublicId';
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

enum HeldDeleteCause { pageChanged, contentNeverRead }

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
  pageCopy,
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

final class AwaitingProof extends Hold {
  const AwaitingProof(this.claim);

  final Claim claim;

  ReadNeed get need => claim.need;

  @override
  bool operator ==(Object other) =>
      other is AwaitingProof && other.claim == claim;

  @override
  int get hashCode => Object.hash(AwaitingProof, claim);

  @override
  String toString() => 'awaiting a read of ${claim.need}';
}

final class AwaitingBase extends Hold {
  const AwaitingBase(this.target);

  final Target target;

  @override
  bool operator ==(Object other) =>
      other is AwaitingBase && other.target == target;

  @override
  int get hashCode => Object.hash(AwaitingBase, target);

  @override
  String toString() => 'awaiting the base for $target';
}

final class EntryView {
  EntryView(this.state, this.go, List<Hold> holds)
    : holds = List.unmodifiable(holds);

  final PendingState state;
  final Go go;
  final List<Hold> holds;

  @override
  bool operator ==(Object other) =>
      other is EntryView &&
      other.state == state &&
      other.go == go &&
      _sameHolds(other.holds, holds);

  @override
  int get hashCode => Object.hash(state, go, holds.length);

  static bool _sameHolds(List<Hold> a, List<Hold> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool get sendable =>
      holds.isEmpty &&
      go is Free &&
      switch (state) {
        NeverSent() => true,
        AnswerUnknown(backoff: RetryNow() || RetryAfter()) => true,
        _ => false,
      };
}

int _answeredAfterRead(PendingOp entry) => switch (entry.answer) {
  AnsweredApplied(:final afterRead) ||
  AnsweredRefused(:final afterRead) => afterRead,
  NotAnswered() || AnsweredNothingToDo() => 0,
};

String? _authoredPage(Scope scope) => switch (scope) {
  OnPage(:final pagePublicId) => pagePublicId,
  Moving(:final from) => from,
  StrategyWide() => null,
};

bool _isPutBack(StrategyOp op) => switch (op) {
  ElementAddOp(expectedElementRevision: _?) ||
  LineupGroupAddOp(expectedLineupRevision: _?) => true,
  _ => false,
};

int _later(int a, int b) => a > b ? a : b;

Go _overOwnDelete(
  CloudQueue queue,
  PendingOp entry,
  PendingOp delete,
  List<Hold> holds,
) {
  if (entry.memory is Forgotten || delete.memory is Forgotten) {
    return const NeedsUser(ServerForgotAnswer());
  }
  switch ((delete.answer, entry.authored)) {
    case (
          AnsweredApplied(
            by: AppliedBy.thisClient,
            :final revision,
            :final afterRead,
          ),
          AuthoredRow(revision: final tombstone),
        )
        when tombstone == revision:
      final claim = RowAsAuthored(
        targetOf(entry.op),
        entry.authored,
        onPage: _authoredPage(entry.scope),
        after: _later(afterRead, queue.session.readsAfter),
      );
      return switch (queue.base.proves(claim)) {
        ProvenAt(revision: final seen) when seen == revision => const Free(),
        Unproven() => _waitFor(claim, holds),
        ProvenAt() ||
        Proven() ||
        Disproven() => const NeedsUser(ChangedUnseen()),
      };
    case _:
      return const NeedsUser(ChangedUnseen());
  }
}

Go _waitFor(Claim claim, List<Hold> holds) {
  holds.add(AwaitingProof(claim));
  return const Free();
}

int? _payloadVersionOf(StrategyOp op) => switch (op) {
  ElementPatchOp(:final payload?) => payload.payloadVersion,
  LineupGroupPatchOp(:final payload?) => payload.payloadVersion,
  _ => null,
};

Go _checked(
  CloudQueue queue,
  PendingOp entry,
  PendingState state,
  String? acceptedSameRow,
  bool Function(String page) acceptedOnPage,
  List<Hold> holds,
) {
  final evidence = queue.base;
  final target = targetOf(entry.op);
  final page = _authoredPage(entry.scope);
  final mark = queue.session.readsAfter;
  if (state is AnswerUnknown) {
    switch (entry.memory) {
      case Remembered():
        return const Free();
      case Forgotten(:final afterRead):
        if (checkKindOf(sendForm(entry.op, SendPolicy.checked)) !=
            CheckKind.revision) {
          return const NeedsUser(ServerForgotAnswer());
        }
        final claim = RowAsAuthored(
          target,
          entry.authored,
          onPage: page,
          after: _later(afterRead, mark),
        );
        return switch ((evidence.proves(claim), entry.authored)) {
          (Unproven(), _) => _waitFor(claim, holds),
          (ProvenAt(:final revision), AuthoredRow(revision: final authored))
              when revision == authored =>
            const NeedsFreshId(ServerForgot()),
          (ProvenAt() || Proven(), AuthoredNoRow()) => const NeedsFreshId(
            ServerForgot(),
          ),
          _ => const NeedsUser(ServerForgotAnswer()),
        };
    }
  }
  if (_isPutBack(entry.op)) {
    if (queue.entry(acceptedSameRow ?? '') case final PendingOp delete
        when delete.op is ElementDeleteOp || delete.op is LineupGroupDeleteOp) {
      return _overOwnDelete(queue, entry, delete, holds);
    }
  }
  if ((target, page) case (ElementTarget() || LineupTarget(), final page?)) {
    final still = RowStillOn(
      target,
      page: page,
      existed: entry.authored is AuthoredRow,
      after: 0,
    );
    if (evidence.proves(still) is Disproven) {
      if (acceptedSameRow != null) {
        holds.add(AwaitingBase(target));
        return const Free();
      }
      return const NeedsUser(ChangedUnseen());
    }
  }
  if ((entry.authored, _payloadVersionOf(entry.op)) case (
    AuthoredRow(payloadVersion: final authored?),
    _?,
  )) {
    final version = RowPayloadVersion(
      target,
      payloadVersion: authored,
      after: 0,
    );
    if (evidence.proves(version) is Disproven) {
      return const NeedsUser(PayloadVersionChanged());
    }
  }
  if (checkKindOf(sendForm(entry.op, entry.policy)) == CheckKind.revision) {
    if (acceptedSameRow != null) {
      holds.add(AwaitingBase(target));
      return const Free();
    }
    final claim = RowAsAuthored(
      target,
      entry.authored,
      onPage: page,
      after: mark,
    );
    switch (evidence.proves(claim)) {
      case Proven() || ProvenAt():
        break;
      case Disproven():
        return const NeedsUser(ChangedUnseen());
      case Unproven():
        return _waitFor(claim, holds);
    }
  }
  if (entry.work case CheckedDelete(:final op, :final seen)) {
    final page = op.pagePublicId;
    final content = seen.content;
    if (content is! ContentSeen) {
      return const NeedsUser(DeleteHeld(HeldDeleteCause.contentNeverRead));
    }
    final claim = PageAsSeen(page, seen, after: mark);
    switch (evidence.proves(claim)) {
      case Proven() || ProvenAt():
        break;
      case Unproven():
        return _waitFor(claim, holds);
      case Disproven():
        if (acceptedOnPage(page)) {
          holds.add(AwaitingBase(PageTarget(page)));
          return const Free();
        }
        return const NeedsUser(DeleteHeld(HeldDeleteCause.pageChanged));
    }
  }
  return const Free();
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

final class ReadNumbered extends QueueEffect {
  const ReadNumbered(this.read);

  final int read;

  @override
  bool operator ==(Object other) => other is ReadNumbered && other.read == read;

  @override
  int get hashCode => Object.hash(ReadNumbered, read);

  @override
  String toString() => 'ReadNumbered($read)';
}

final class BaseRowsChanged extends QueueEffect {
  BaseRowsChanged(List<BaseChange> changes)
    : changes = List.unmodifiable(changes);

  final List<BaseChange> changes;

  @override
  String toString() => 'BaseRowsChanged(${changes.length})';
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

final class SeenInBase extends RemovalCause {
  const SeenInBase();

  @override
  bool operator ==(Object other) => other is SeenInBase;

  @override
  int get hashCode => (SeenInBase).hashCode;

  @override
  String toString() => 'SeenInBase';
}

final class NothingToWaitFor extends RemovalCause {
  const NothingToWaitFor();

  @override
  bool operator ==(Object other) => other is NothingToWaitFor;

  @override
  int get hashCode => (NothingToWaitFor).hashCode;

  @override
  String toString() => 'NothingToWaitFor';
}

final class AlreadyGone extends RemovalCause {
  const AlreadyGone();

  @override
  bool operator ==(Object other) => other is AlreadyGone;

  @override
  int get hashCode => (AlreadyGone).hashCode;

  @override
  String toString() => 'AlreadyGone';
}

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

final class RetriedUnder extends RemovalCause {
  const RetriedUnder(this.opId);

  final String opId;

  @override
  bool operator ==(Object other) => other is RetriedUnder && other.opId == opId;

  @override
  int get hashCode => Object.hash(RetriedUnder, opId);

  @override
  String toString() => 'RetriedUnder($opId)';
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
  const Step();
}

final class Stepped extends Step {
  Stepped(this.queue, List<QueueEffect> effects)
    : effects = List.unmodifiable(effects);

  final CloudQueue queue;
  final List<QueueEffect> effects;
}

final class NotApplicable extends Step {
  const NotApplicable(this.why);

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

final class NothingToReissue extends Inapplicable {
  const NothingToReissue();

  @override
  String toString() => 'NothingToReissue';
}

final class PageNotStored extends Inapplicable {
  const PageNotStored(this.pagePublicId);

  final String pagePublicId;

  @override
  String toString() => 'PageNotStored($pagePublicId)';
}

final class NoSuchRead extends Inapplicable {
  const NoSuchRead(this.read);

  final int read;

  @override
  String toString() => 'NoSuchRead($read)';
}

Landing landingOf(CloudQueue queue, QueueEntry entry) => switch (entry) {
  RetiredOp(:final landing) => landing,
  final PendingOp op => switch (stateOf(queue, op)) {
    NeverSent() || ServerRefused() => Landing.notLanded,
    Claimed() || AnswerUnknown() || Accepted() => Landing.mayHaveLanded,
  },
};

final class _Edit {
  _Edit(this.original, this.now)
    : entries = [...original.entries],
      attempts = {...original.attempts},
      nextAttempt = original.nextAttempt,
      nextRead = original.nextRead,
      base = original.base,
      strategy = original.strategy,
      session = original.session,
      index = _IndexEdit(original._index);

  final CloudQueue original;
  final DateTime now;
  final List<QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  int nextAttempt;
  int nextRead;
  Evidence base;
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

  void downgradeAll() {
    change.everything = true;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] case final PendingOp entry
          when entry.policy == SendPolicy.live) {
        replaceAt(i, entry.copyWith(policy: SendPolicy.checked));
      }
    }
  }

  int get lastAttempt => nextAttempt - 1;

  int get lastRead => nextRead - 1;

  Stepped done() {
    _settle(this);
    return Stepped(
      CloudQueue._(
        entries: entries,
        attempts: attempts,
        nextAttempt: nextAttempt,
        nextRead: nextRead,
        base: base,
        strategy: strategy,
        session: session,
        index: index.build(),
        lineage: _Lineage(original, change),
      ),
      effects,
    );
  }
}

CloudQueue _remembered(CloudQueue queue, DateTime now) {
  if (queue._index.firstForgetting case final first?
      when !now.isBefore(first)) {
    final edit = _Edit(queue, now);
    _remember(edit);
    return edit.done().queue;
  }
  return queue;
}

void _remember(_Edit edit) {
  for (final id in edit.index.forgottenBy(edit.now)) {
    if (edit.index.byId[id] case final PendingOp entry
        when entry.memory is Remembered) {
      edit.put(entry.copyWith(memory: Forgotten(afterRead: edit.lastRead)));
    }
  }
}

void _settle(_Edit edit) {
  final answered = edit.index.answered;
  final candidates = <String>{};
  final pageDeletes = <String>{};
  bool deleteNotAnswered(String id) => switch (edit.index.byId[id]) {
    PendingOp(
      op: ElementDeleteOp() || LineupGroupDeleteOp(),
      answer: NotAnswered(),
    ) =>
      true,
    _ => false,
  };
  void consider(Iterable<_Slot> slots) {
    for (final (_, id) in slots) {
      derivationWork.visits++;
      if (answered.contains(id) || deleteNotAnswered(id)) candidates.add(id);
    }
  }

  if (edit.change.everything) {
    candidates.addAll(answered);
    for (final entry in edit.entries) {
      if (deleteNotAnswered(entry.id)) candidates.add(entry.id);
    }
  } else {
    for (final id in edit.change.touched) {
      if (answered.contains(id) || deleteNotAnswered(id)) candidates.add(id);
      if (edit.index.byId[id] case PendingOp(op: PageDeleteOp())) {
        pageDeletes.add(id);
      }
    }
    for (final target in edit.change.targets) {
      consider(edit.index.underOf(target));
    }
    for (final page in edit.change.pages) {
      consider(edit.index.underOf(_OnPage(page)));
      for (final (_, id) in edit.index.underOf(_PageLife(page))) {
        derivationWork.visits++;
        pageDeletes.add(id);
      }
    }
  }
  if (edit.change.everything) {
    for (final entry in edit.entries) {
      if (entry case PendingOp(op: PageDeleteOp())) pageDeletes.add(entry.id);
    }
  }
  final ordered = [
    for (final id in {...candidates, ...pageDeletes})
      if (edit.index.byId[id] case final PendingOp entry) entry,
  ]..sort((a, b) => a.place.compareTo(b.place));
  bool backingAPutBack(PendingOp entry) {
    if (entry.op is! ElementDeleteOp && entry.op is! LineupGroupDeleteOp) {
      return false;
    }
    for (final (place, id) in edit.index.underOf(targetOf(entry.op))) {
      derivationWork.visits++;
      if (place <= entry.place) continue;
      return switch (edit.index.byId[id]) {
        final PendingOp next =>
          _isPutBack(next.op) &&
              next.answer is NotAnswered &&
              (edit.index.attemptsByOp[id] ?? const []).isEmpty,
        _ => false,
      };
    }
    return false;
  }

  for (final entry in ordered) {
    if (backingAPutBack(entry)) continue;
    final cause = switch (entry.answer) {
      AnsweredNothingToDo() => const NothingToWaitFor(),
      AnsweredApplied(:final revision, :final afterRead) => _settledAt(
        edit.base,
        entry,
        revision,
        afterRead,
      ),
      NotAnswered() => _notAnsweredSettled(edit, entry),
      AnsweredRefused() => null,
    };
    if (cause != null) edit.remove(entry.id, cause);
  }
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
        PendingOp(answer: NotAnswered()) => true,
        _ => false,
      },
    );
    if (!live) edit.dropAttempt(attempt);
  }
}

RemovalCause? _notAnsweredSettled(_Edit edit, PendingOp entry) {
  final sent = [
    for (final number in edit.index.attemptsByOp[entry.id] ?? const <int>[])
      ?edit.attempts[number],
  ];
  if (sent.any((attempt) => attempt.outcome is AttemptOpen)) return null;
  final after = sent.fold(
    _later(edit.session.readsAfter, edit.lastRead - 1),
    (latest, attempt) => _later(latest, attempt.afterRead),
  );
  final claim = switch (entry.op) {
    PageDeleteOp(:final pagePublicId) when sent.isNotEmpty => PageIsGone(
      pagePublicId,
      after: after,
    ),
    ElementDeleteOp() || LineupGroupDeleteOp()
        when edit.index.underOf(targetOf(entry.op)).first.$2 == entry.id =>
      RowIsGone(
        targetOf(entry.op),
        onPage: _authoredPage(entry.scope),
        after: after,
      ),
    _ => null,
  };
  if (claim == null || edit.base.proves(claim) is! Proven) return null;
  return entry.op is PageDeleteOp ? const SeenInBase() : const AlreadyGone();
}

Claim settlementOf(PendingOp entry, int revision, int afterRead) {
  final target = targetOf(entry.op);
  return switch (entry.scope) {
    Moving(:final to) => RowShownOn(
      target,
      revision: revision,
      page: to,
      after: afterRead,
    ),
    _ => RowShown(
      target,
      revision: revision,
      lookIn: _authoredPage(entry.scope),
      after: afterRead,
    ),
  };
}

RemovalCause? _settledAt(
  Evidence base,
  PendingOp entry,
  int revision,
  int afterRead,
) {
  final pages = switch (entry.scope) {
    Moving(:final to) => {to},
    _ => _pagesOf(entry),
  };
  if (pages.any(
    (page) => base.proves(PageIsGone(page, after: afterRead)) is Proven,
  )) {
    return const SeenInBase();
  }
  return base.proves(settlementOf(entry, revision, afterRead)) is Proven
      ? const SeenInBase()
      : null;
}

StrategyOp sendable(CloudQueue queue, PendingOp entry) {
  for (final number in queue._index.attemptsByOp[entry.id] ?? const <int>[]) {
    final attempt = queue.attempts[number];
    if (attempt == null || attempt.outcome is! AttemptFailed) continue;
    for (final op in attempt.ops) {
      if (op.opId == entry.id) return op;
    }
  }
  final sent = sendForm(entry.op, entry.policy);
  final target = targetOf(sent);
  final revision = switch (queue.base.proves(RowRevision(target, after: 0))) {
    ProvenAt(:final revision) => revision,
    Proven() ||
    Disproven() ||
    Unproven() => _acceptedRevisionBefore(queue, entry, target),
  };
  return revision == null ? sent : rebased(sent, revision);
}

int? _acceptedRevisionBefore(CloudQueue queue, PendingOp entry, Target target) {
  final slots = queue._index.accepted[target] ?? const <_Slot>[];
  for (var i = _slotAt(slots, entry.place) - 1; i >= 0; i--) {
    derivationWork.visits++;
    if (queue._index.byId[slots[i].$2] case PendingOp(
      answer: AnsweredApplied(:final revision),
      :final op,
    ) when targetOf(op) == target) {
      return revision;
    }
  }
  return null;
}

Step transition(CloudQueue queue, QueueEvent event, {required DateTime now}) {
  final edit = _Edit(_remembered(queue, now), now);
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
      final fact = edit.attempts[attempt];
      if (fact == null) return NotApplicable(NoSuchAttempt(attempt));
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
      edit.downgradeAll();
      edit.session = QueueSession.start(build, nextRead: edit.nextRead);
      return edit.done();
    case ConnectionLost():
      edit.downgradeAll();
      edit.session = QueueSession(
        connected: false,
        build: edit.session.build,
        readsFrom: edit.session.readsFrom,
      );
      return edit.done();
    case AccountChanged():
      edit.downgradeAll();
      edit.session = QueueSession(
        connected: edit.session.connected,
        build: edit.session.build,
        readsFrom: edit.nextRead,
      );
      return edit.done();
    case ConnectionReturned():
      edit.change.everything = true;
      edit.session = QueueSession(
        connected: true,
        build: edit.session.build,
        readsFrom: edit.nextRead,
      );
      return edit.done();
    case EditAccessConfirmed(:final afterAttempt):
      if (afterAttempt < 1 || afterAttempt >= edit.nextAttempt) {
        return NotApplicable(NoSuchAttempt(afterAttempt));
      }
      if (afterAttempt > edit.strategy.accessConfirmedAt) {
        edit.strategy = edit.strategy.copyWith(accessConfirmedAt: afterAttempt);
      }
      return edit.done();
    case UserRetried(:final opId):
      return _userRetried(edit, opId, now);
    case UserKeptMine(:final opId, :final replacement, :final authored):
      return _keepMine(edit, opId, replacement, authored, now);
    case UserUsedCloud(:final opId):
      return _userRemoves(edit, opId, UserRemoval.usedCloud, now);
    case UserDiscarded(:final opId):
      return _userRemoves(edit, opId, UserRemoval.discarded, now);
    case UserDeletedAnyway(:final opId):
      final entry = queue.entry(opId);
      if (entry == null) return NotApplicable(NoSuchOp(opId));
      final view = entryViews(queue, now)[opId];
      if ((entry, view?.go) case (
        PendingOp(work: CheckedDelete(:final op)) && final PendingOp delete,
        NeedsUser(reason: DeleteHeld()),
      )) {
        edit.put(delete.copyWith(work: OpWork(op)));
        return edit.done();
      }
      return NotApplicable(NotInThatState(opId, '${view?.go}'));
    case Reissue(:final freshOpIds):
      return _reissue(edit, freshOpIds, now);
    case ReadStarted():
      edit.effects.add(ReadNumbered(edit.nextRead++));
      return edit.done();
    case BaseArrived(:final base, :final read):
      if (read < 1 || read >= edit.nextRead) {
        return NotApplicable(NoSuchRead(read));
      }
      final taken = edit.base.take(base, read);
      edit.base = taken.evidence;
      if (taken.changes.isNotEmpty) {
        edit.effects.add(BaseRowsChanged(taken.changes));
      }
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
          edit.strategy = edit.strategy.copyWith(presence: Presence.gone);
      }
      return edit.done();
  }
}

Step _closeAttempt(_Edit edit, int attempt, AttemptOutcome outcome) {
  final fact = edit.attempts[attempt];
  if (fact == null) return NotApplicable(NoSuchAttempt(attempt));
  if (fact.outcome is AttemptOpen) {
    edit.setAttempt(fact.withOutcome(outcome));
  }
  return edit.done();
}

Step _userEdited(_Edit edit, Edit change, DateTime now) {
  final op = change.op;
  if (!isJson(op.toJson())) return NotApplicable(NotJson(op.opId));
  if (edit.indexOf(op.opId) != -1) return NotApplicable(OpIdTaken(op.opId));
  final queue = edit.original;
  final policy = queue.session.connected ? SendPolicy.live : SendPolicy.checked;
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
        view.state is NeverSent &&
        view.go is Free &&
        view.holds.every((hold) => _foldableHold(hold, views))) {
      switch (fold(last.op, op)) {
        case FoldedOp(op: final folded):
          edit.replaceAt(
            at,
            last.copyWith(
              work: OpWork(folded),
              policy: policy == SendPolicy.checked ? policy : last.policy,
            ),
          );
          edit.effects.add(OpRemoved(last.id, FoldedInto(folded.opId)));
          return edit.done();
        case KeptApart():
          break;
      }
    }
  }
  edit.append(
    PendingOp(
      place: edit.entries.isEmpty ? 0 : edit.entries.last.place + 1,
      work: switch (change) {
        PlainEdit() => OpWork(op),
        PageDeleteEdit(:final op, :final seen) => CheckedDelete(op, seen),
      },
      scope: change.scope,
      authored: change.authored,
      policy: policy,
      answer: const NotAnswered(),
      retriedAfter: edit.lastAttempt,
    ),
  );
  return edit.done();
}

bool _foldableHold(Hold hold, Map<String, EntryView> views) => switch (hold) {
  BehindEntry(:final opId, why: Dependency.sameRow) => switch (views[opId]) {
    EntryView(state: Claimed() || AnswerUnknown(), go: Free()) => true,
    _ => false,
  },
  UntilRetryTime() => true,
  BehindEntry() || AwaitingProof() || AwaitingBase() => false,
};

Step _claim(
  _Edit edit,
  String clientId,
  List<String> opIds,
  DateTime at,
  DateTime now,
) {
  if (opIds.isEmpty) return const NotApplicable(NothingClaimed());
  final queue = edit.original;
  final standing = standingOf(queue);
  if (standing != Standing.good) return NotApplicable(StandingBlocks(standing));
  final views = entryViews(queue, now);
  var previous = -1;
  final ops = <StrategyOp>[];
  for (final opId in opIds) {
    final index = edit.indexOf(opId);
    if (index == -1) return NotApplicable(NoSuchOp(opId));
    if (index <= previous) return NotApplicable(OutOfOrder(opId));
    previous = index;
    final entry = edit.entries[index];
    final view = views[opId];
    if (entry is! PendingOp || view == null) {
      return NotApplicable(NotInThatState(opId, 'not a pending op'));
    }
    if (view.holds.isNotEmpty) return NotApplicable(HeldBack(opId, view.holds));
    if (!view.sendable) {
      return NotApplicable(NotInThatState(opId, '${view.state}, ${view.go}'));
    }
    if (view.state case AnswerUnknown(
      clientId: final owner,
    ) when owner != clientId) {
      return NotApplicable(OtherClient(opId, owner));
    }
    ops.add(sendable(queue, entry));
  }
  final number = edit.nextAttempt++;
  edit.setAttempt(
    AttemptFact(
      number: number,
      clientId: clientId,
      build: queue.session.build,
      at: at,
      afterRead: edit.lastRead,
      ops: ops,
      outcome: const AttemptOpen(),
    ),
  );
  edit.effects.add(SendBatch(number, clientId, ops));
  return edit.done();
}

Step _answered(_Edit edit, int attempt, OpAnswer answer) {
  final fact = edit.attempts[attempt];
  if (fact == null) return NotApplicable(NoSuchAttempt(attempt));
  if (!fact.opIds.contains(answer.opId)) {
    return NotApplicable(NotInAttempt(answer.opId, attempt));
  }
  final index = edit.indexOf(answer.opId);
  if (index == -1) return NotApplicable(NoSuchOp(answer.opId));
  final entry = edit.entries[index];
  if (entry is! PendingOp) return NotApplicable(NoSuchOp(answer.opId));
  if (attempt > edit.strategy.accessConfirmedAt) {
    edit.strategy = edit.strategy.copyWith(accessConfirmedAt: attempt);
  }
  if (entry.answer is! NotAnswered) return edit.done();
  final afterRead = edit.lastRead;
  edit.put(
    entry.copyWith(
      answer: switch (answer) {
        AppliedAnswer(:final revision) => AnsweredApplied(
          revision,
          AppliedBy.thisClient,
          afterRead: afterRead,
        ),
        NoopAnswer(
          :final revision,
          replay: NoopReplay.appliedWhenFirstReceived,
        ) =>
          AnsweredApplied(revision, AppliedBy.thisClient, afterRead: afterRead),
        NoopAnswer(:final revision, replay: NoopReplay.notApplied) =>
          AnsweredApplied(
            revision,
            AppliedBy.alreadyThere,
            afterRead: afterRead,
          ),
        NoopWithoutRevision() => const AnsweredNothingToDo(),
        RejectedAnswer(:final reason, :final current) => AnsweredRefused(
          RejectedByServer(reason, current),
          afterRead: afterRead,
        ),
        FailedAnswer(:final code, :final message) => AnsweredRefused(
          FailedOnServer(code, message),
          afterRead: afterRead,
        ),
      },
    ),
  );
  return edit.done();
}

Step _userRetried(_Edit edit, String opId, DateTime now) {
  final queue = edit.original;
  final entry = queue.entry(opId);
  if (entry is! PendingOp) return NotApplicable(NoSuchOp(opId));
  final state = stateOf(queue, entry);
  if (state case AnswerUnknown(backoff: RetriesExhausted())) {
    edit.put(entry.copyWith(retriedAfter: edit.lastAttempt));
    return edit.done();
  }
  return NotApplicable(NotInThatState(opId, '$state'));
}

bool _userMayReplace(EntryView view) => switch ((view.state, view.go)) {
  (ServerRefused(), _) => true,
  (_, NeedsUser(reason: ChangedUnseen() || ServerForgotAnswer())) => true,
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
  if (entry is! PendingOp) return NotApplicable(NoSuchOp(opId));
  final view = entryViews(queue, now)[opId]!;
  if (!_userMayReplace(view)) {
    return NotApplicable(NotInThatState(opId, '${view.state}, ${view.go}'));
  }
  if (entityOf(replacement) != entityOf(entry.op) ||
      replacement.type != entry.op.type) {
    return NotApplicable(OtherEntity(replacement.opId));
  }
  if (!isJson(replacement.toJson())) {
    return NotApplicable(NotJson(replacement.opId));
  }
  if (edit.indexOf(replacement.opId) != -1) {
    return NotApplicable(OpIdTaken(replacement.opId));
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
      policy: SendPolicy.checked,
      answer: const NotAnswered(),
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
  if (entry == null) return NotApplicable(NoSuchOp(opId));
  final standing = standingOf(queue);
  final allowed = switch (entry) {
    RetiredOp() => action == UserRemoval.discarded,
    final PendingOp op => switch ((entryViews(queue, now)[op.id]!, action)) {
      (EntryView(state: Claimed() || Accepted()), _) => false,
      (final view, UserRemoval.usedCloud) => _userMayReplace(view),
      (EntryView(state: ServerRefused()), _) => true,
      (EntryView(go: NeedsUser()), _) => true,
      (EntryView(state: AnswerUnknown(backoff: RetriesExhausted())), _) => true,
      (_, _) =>
        standing == Standing.deletedOnServer ||
            standing == Standing.editAccessLost,
    },
  };
  if (!allowed) return NotApplicable(NotInThatState(opId, 'not removable now'));
  edit.remove(opId, RemovedByUser(action, landingOf(queue, entry)));
  return edit.done();
}

Step _reissue(_Edit edit, Map<String, String> fresh, DateTime now) {
  if (fresh.isEmpty) return const NotApplicable(NothingToReissue());
  final views = entryViews(edit.original, now);
  final taken = <String>{};
  final renamedAt = <int, PendingOp>{};
  for (final MapEntry(key: opId, value: id) in fresh.entries) {
    final index = edit.indexOf(opId);
    final entry = index == -1 ? null : edit.entries[index];
    final view = views[opId];
    if (entry is! PendingOp || view == null) {
      return NotApplicable(NoSuchOp(opId));
    }
    if (view.go is! NeedsFreshId) {
      return NotApplicable(NotInThatState(opId, '${view.state}, ${view.go}'));
    }
    if (edit.indexOf(id) != -1 || !taken.add(id)) {
      return NotApplicable(OpIdTaken(id));
    }
    final Work work;
    switch (entry.work) {
      case OpWork(:final op):
        work = OpWork(renamed(op, id));
      case CheckedDelete(:final op, :final seen):
        work = CheckedDelete(
          PageDeleteOp(
            opId: id,
            pagePublicId: op.pagePublicId,
            expectedStrategyRevision: op.expectedStrategyRevision,
          ),
          seen,
        );
    }
    renamedAt[index] = entry.copyWith(
      work: work,
      answer: const NotAnswered(),
      policy: SendPolicy.checked,
      retriedAfter: edit.lastAttempt,
      memory: const Remembered(),
    );
  }
  for (final MapEntry(key: index, value: entry) in renamedAt.entries) {
    final old = edit.entries[index].id;
    edit.replaceAt(index, entry);
    edit.effects.add(OpRemoved(old, RetriedUnder(entry.id)));
  }
  return edit.done();
}
