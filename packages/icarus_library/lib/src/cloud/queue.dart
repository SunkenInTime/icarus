import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import '../rows.dart';
import 'events.dart';
import 'fold.dart';
import 'op_facts.dart';
import 'pending.dart';

final class BaseFacts {
  BaseFacts({
    required Map<Target, RowFact> rows,
    required Map<String, Map<SeenPart, String>> pageContent,
    required Set<String> contentRead,
    required Set<String> notFound,
  }) : rows = Map.unmodifiable(rows),
       pageContent = Map.unmodifiable({
         for (final MapEntry(:key, :value) in pageContent.entries)
           key: Map<SeenPart, String>.unmodifiable(value),
       }),
       contentRead = Set.unmodifiable(contentRead),
       notFound = Set.unmodifiable(notFound);

  static final none = BaseFacts(
    rows: const {},
    pageContent: const {},
    contentRead: const {},
    notFound: const {},
  );

  final Map<Target, RowFact> rows;
  final Map<String, Map<SeenPart, String>> pageContent;
  final Set<String> contentRead;
  final Set<String> notFound;

  bool pageGone(String pagePublicId) =>
      notFound.contains(pagePublicId) &&
      rows[PageTarget(pagePublicId)]?.life == Life.gone;

  @override
  bool operator ==(Object other) =>
      other is BaseFacts &&
      sameMap(other.rows, rows) &&
      sameMap(
        other.pageContent.map((k, v) => MapEntry(k, canonical(v))),
        pageContent.map((k, v) => MapEntry(k, canonical(v))),
      ) &&
      sameSet(other.contentRead, contentRead) &&
      sameSet(other.notFound, notFound);

  @override
  int get hashCode => Object.hash(hashMap(rows), hashSet(contentRead));

  static String canonical(Map<SeenPart, String> digests) => canonicalJson({
    for (final MapEntry(:key, :value) in digests.entries) '$key': value,
  });
}

final class QueueSession {
  QueueSession({
    required this.connected,
    required this.build,
    required Set<String> pagesReadThisSession,
  }) : pagesReadThisSession = Set.unmodifiable(pagesReadThisSession);

  factory QueueSession.start(String build) => QueueSession(
    connected: false,
    build: build,
    pagesReadThisSession: const {},
  );

  final bool connected;
  final String build;
  final Set<String> pagesReadThisSession;

  @override
  bool operator ==(Object other) =>
      other is QueueSession &&
      other.connected == connected &&
      other.build == build &&
      sameSet(other.pagesReadThisSession, pagesReadThisSession);

  @override
  int get hashCode => Object.hash(connected, build);
}

final class CloudQueue {
  CloudQueue({
    required List<QueueEntry> entries,
    required Map<int, AttemptFact> attempts,
    required this.nextAttempt,
    required this.base,
    required this.strategy,
    required this.session,
  }) : entries = List.unmodifiable(entries),
       attempts = Map.unmodifiable(attempts);

  factory CloudQueue.start({required String build, BaseFacts? base}) =>
      CloudQueue(
        entries: const [],
        attempts: const {},
        nextAttempt: 1,
        base: base ?? BaseFacts.none,
        strategy: StrategyFacts.fresh,
        session: QueueSession.start(build),
      );

  final List<QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  final int nextAttempt;
  final BaseFacts base;
  final StrategyFacts strategy;
  final QueueSession session;

  QueueEntry? entry(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CloudQueue &&
      _sameEntries(other.entries, entries) &&
      sameMap(other.attempts, attempts) &&
      other.nextAttempt == nextAttempt &&
      other.base == base &&
      other.strategy == strategy &&
      other.session == session;

  @override
  int get hashCode => Object.hash(entries.length, nextAttempt, strategy);

  static bool _sameEntries(List<QueueEntry> a, List<QueueEntry> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
}

enum Standing { good, editAccessLost, upgradeRequired, deletedOnServer }

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
  String toString() => 'never sent';
}

final class Claimed extends PendingState {
  const Claimed(this.attempt);

  final int attempt;

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
  String toString() => 'answer unknown ($failures failures, $backoff)';
}

final class Accepted extends PendingState {
  const Accepted(this.revision);

  final int revision;

  @override
  String toString() => 'accepted at $revision';
}

final class ServerRefused extends PendingState {
  const ServerRefused(this.refusal);

  final ServerRefusal refusal;

  @override
  String toString() => 'refused: $refusal';
}

sealed class Backoff {
  const Backoff();
}

final class RetryNow extends Backoff {
  const RetryNow();

  @override
  String toString() => 'retry now';
}

final class RetryAfter extends Backoff {
  const RetryAfter(this.at);

  final DateTime at;

  @override
  String toString() => 'retry after ${at.toIso8601String()}';
}

final class RetriesExhausted extends Backoff {
  const RetriesExhausted();

  @override
  String toString() => 'retries exhausted';
}

sealed class Go {
  const Go();
}

final class Free extends Go {
  const Free();

  @override
  String toString() => 'free';
}

final class NeedsUser extends Go {
  const NeedsUser(this.reason);

  final UserReason reason;

  @override
  String toString() => 'needs user: $reason';
}

sealed class UserReason {
  const UserReason();
}

final class Oversized extends UserReason {
  const Oversized();

  @override
  String toString() => 'oversized';
}

final class ChangedUnseen extends UserReason {
  const ChangedUnseen();

  @override
  String toString() => 'changed by someone else since the user saw it';
}

final class ServerForgotAnswer extends UserReason {
  const ServerForgotAnswer();

  @override
  String toString() => 'the server forgot whether it landed';
}

final class OnDeletedPage extends UserReason {
  const OnDeletedPage(this.pagePublicId);

  final String pagePublicId;

  @override
  String toString() => 'on deleted page $pagePublicId';
}

final class DeleteHeld extends UserReason {
  const DeleteHeld(this.cause);

  final HeldDeleteCause cause;

  @override
  String toString() => 'page delete held (${cause.name})';
}

enum HeldDeleteCause { pageChanged, contentNeverRead }

final class IncompleteCopy extends UserReason {
  const IncompleteCopy(this.pagePublicId);

  final String pagePublicId;

  @override
  String toString() => 'incomplete copy of $pagePublicId';
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

final class AwaitingPageRead extends Hold {
  const AwaitingPageRead(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is AwaitingPageRead && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(AwaitingPageRead, pagePublicId);

  @override
  String toString() => 'awaiting a read of $pagePublicId';
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

  bool get sendable =>
      holds.isEmpty &&
      go is Free &&
      switch (state) {
        NeverSent() => true,
        AnswerUnknown(backoff: RetryNow() || RetryAfter()) => true,
        _ => false,
      };
}

PendingState stateOf(CloudQueue queue, PendingOp entry) {
  switch (entry.answer) {
    case AnsweredApplied(:final revision):
      return Accepted(revision);
    case AnsweredRefused(:final refusal):
      return ServerRefused(refusal);
    case AnsweredNothingToDo():
      return const Accepted(0);
    case NoAnswer():
      break;
  }
  final attempts = [
    for (final attempt in queue.attempts.values)
      if (attempt.opIds.contains(entry.id)) attempt,
  ]..sort((a, b) => a.number.compareTo(b.number));
  for (final attempt in attempts) {
    if (attempt.outcome is AttemptOpen) return Claimed(attempt.number);
  }
  final failed = [
    for (final attempt in attempts)
      if (attempt.outcome case AttemptFailed(:final at)) (attempt, at),
  ];
  if (failed.isEmpty) return const NeverSent();
  final counted = failed
      .where((f) => f.$1.number > entry.retriedAfter)
      .toList();
  final failures = counted.length;
  final lastAt = failed.last.$2;
  return AnswerUnknown(
    clientId: failed.first.$1.clientId,
    firstSentAt: failed.first.$1.at,
    failures: failures,
    backoff: switch (failures) {
      0 => const RetryNow(),
      _ when failures >= retriesBeforePause => const RetriesExhausted(),
      _ => RetryAfter(retryTimeAfter(lastAt, failures)),
    },
  );
}

bool _open(PendingState state) => switch (state) {
  Accepted() => false,
  NeverSent() || Claimed() || AnswerUnknown() || ServerRefused() => true,
};

Map<String, EntryView> entryViews(CloudQueue queue, DateTime now) {
  final views = <String, EntryView>{};
  final states = {
    for (final entry in queue.entries)
      if (entry is PendingOp) entry.id: stateOf(queue, entry),
  };
  final lastByTarget = <Target, String>{};
  final acceptedByTarget = <Target, String>{};
  final pageAdd = <String, String>{};
  final pageDelete = <String, PendingOp>{};
  final copyFrom = <String, String>{};
  final onPage = <String, List<String>>{};
  final acceptedOnPage = <String, List<String>>{};
  String? renumbering;
  String? acceptedRenumbering;
  String? pagePatch;
  final cutoff = now.subtract(serverRemembersAnswersFor);
  for (final entry in queue.entries) {
    if (entry is! PendingOp) continue;
    final op = entry.op;
    final target = targetOf(op);
    final pages = pagesOf(entry);
    final state = states[entry.id]!;
    final holds = <Hold>[];
    Go go = const Free();
    void behind(String? id, Dependency why) {
      if (id != null && _open(states[id]!)) holds.add(BehindEntry(id, why));
    }

    if (state case NeverSent() || AnswerUnknown()) {
      behind(lastByTarget[target], switch (target) {
        StrategyTarget() => Dependency.strategyChange,
        PageTarget() => Dependency.pageChange,
        SettingsTarget() ||
        ElementTarget() ||
        LineupTarget() => Dependency.sameRow,
      });
      if (target is PageTarget) behind(renumbering, Dependency.pageChange);
      if (renumbersPages(op)) behind(pagePatch, Dependency.pageChange);
      final ownPage = switch (op) {
        PageAddOp(:final pagePublicId) ||
        PageDeleteOp(:final pagePublicId) => pagePublicId,
        _ => null,
      };
      for (final page in pages) {
        if (page == ownPage) continue;
        behind(pageAdd[page], Dependency.pageAdd);
        behind(copyFrom[page], Dependency.pageCopy);
        if (queue.base.rows[PageTarget(page)]?.life == Life.gone) {
          go = NeedsUser(OnDeletedPage(page));
        } else if (pageDelete[page] case final delete?) {
          if (_open(states[delete.id]!)) {
            holds.add(BehindEntry(delete.id, Dependency.pageDelete));
          } else if (!_restoredSince(queue, delete, page)) {
            holds.add(AwaitingBase(PageTarget(page)));
          }
        }
      }
      final workPage = switch (op) {
        PageDeleteOp(:final pagePublicId) => pagePublicId,
        PageAddOp(:final copyContentFromPagePublicId?) =>
          copyContentFromPagePublicId,
        _ => null,
      };
      if (workPage != null) {
        for (final id in onPage[workPage] ?? const <String>[]) {
          behind(id, Dependency.pageWork);
        }
      }
      if (state case AnswerUnknown(
        backoff: RetryAfter(:final at),
      ) when at.isAfter(now)) {
        holds.add(UntilRetryTime(at));
      }
      if (entry.work case CheckedDelete(
        :final op,
      ) when !queue.session.pagesReadThisSession.contains(op.pagePublicId)) {
        holds.add(AwaitingPageRead(op.pagePublicId));
      }
      if (exceedsSizePolicy(op.toJson())) go = const NeedsUser(Oversized());
      if (entry.work case ImportedIncompleteCopy(:final op)) {
        go = NeedsUser(IncompleteCopy(op.pagePublicId));
      }
      if (holds.isEmpty && go is Free) {
        go = _checked(
          queue,
          entry,
          state,
          cutoff,
          acceptedByTarget[target] ??
              (target is PageTarget ? acceptedRenumbering : null),
          acceptedOnPage,
          holds,
        );
      }
    }
    views[entry.id] = EntryView(state, go, holds);
    lastByTarget[target] = entry.id;
    if (state is Accepted) {
      acceptedByTarget[target] = entry.id;
      if (target is PageTarget) {
        acceptedByTarget[const StrategyTarget()] = entry.id;
      }
      if (renumbersPages(op)) acceptedRenumbering = entry.id;
      for (final page in pages) {
        (acceptedOnPage[page] ??= []).add(entry.id);
      }
    }
    for (final page in pages) {
      (onPage[page] ??= []).add(entry.id);
    }
    switch (op) {
      case PageAddOp(:final pagePublicId, :final copyContentFromPagePublicId):
        pageAdd[pagePublicId] = entry.id;
        if (copyContentFromPagePublicId case final source?) {
          copyFrom[source] = entry.id;
        }
        renumbering = entry.id;
      case PageDeleteOp(:final pagePublicId):
        pageDelete[pagePublicId] = entry;
        renumbering = entry.id;
      case PageReorderOp():
        renumbering = entry.id;
      case PagePatchOp():
        pagePatch = entry.id;
      case _:
        break;
    }
  }
  return views;
}

bool _restoredSince(CloudQueue queue, PendingOp delete, String page) {
  final before = switch (delete.work) {
    CheckedDelete(:final seen) => seen.pageRevision,
    OpWork() || ImportedIncompleteCopy() => null,
  };
  return switch (queue.base.rows[PageTarget(page)]) {
    RowFact(:final revision) when before != null => revision > before,
    _ => false,
  };
}

Go _checked(
  CloudQueue queue,
  PendingOp entry,
  PendingState state,
  DateTime cutoff,
  String? acceptedSameRow,
  Map<String, List<String>> acceptedOnPage,
  List<Hold> holds,
) {
  final target = targetOf(entry.op);
  final fact = queue.base.rows[target];
  final sent = sendForm(entry.op, entry.policy);
  final pastMemory = switch (state) {
    AnswerUnknown(:final firstSentAt) => firstSentAt.isBefore(cutoff),
    _ => false,
  };
  if (pastMemory) {
    return switch ((entry.authored, fact)) {
      (AuthoredRow(:final revision, :final digest), final RowFact fact?)
          when fact.revision == revision && fact.digest == digest =>
        const Free(),
      _ => const NeedsUser(ServerForgotAnswer()),
    };
  }
  if (state is AnswerUnknown) return const Free();
  if (checkKindOf(sent) == CheckKind.revision) {
    if (acceptedSameRow != null) {
      holds.add(AwaitingBase(target));
      return const Free();
    }
    final matches = switch ((entry.authored, fact)) {
      (AuthoredRow(:final digest), final RowFact fact?) =>
        fact.digest == digest,
      (AuthoredNoRow(), null) => true,
      (AuthoredNoRow(), RowFact(life: Life.gone)) => true,
      _ => false,
    };
    if (!matches) return const NeedsUser(ChangedUnseen());
  }
  if (entry.work case CheckedDelete(:final op, :final seen)) {
    final page = op.pagePublicId;
    final content = seen.content;
    if (content is! ContentSeen) {
      return const NeedsUser(DeleteHeld(HeldDeleteCause.contentNeverRead));
    }
    final now = {
      ...?queue.base.pageContent[page],
      if (queue.base.rows[SettingsTarget(page)] case final settings?)
        const SeenSettings(): settings.digest,
    };
    final pageFact = queue.base.rows[PageTarget(page)];
    final same =
        sameMap(now, content.digests) && pageFact?.digest == seen.pageDigest;
    if (!same) {
      if ((acceptedOnPage[page] ?? const []).isNotEmpty) {
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

final class SettledByRemoval extends RemovalCause {
  const SettledByRemoval();

  @override
  bool operator ==(Object other) => other is SettledByRemoval;

  @override
  int get hashCode => (SettledByRemoval).hashCode;

  @override
  String toString() => 'SettledByRemoval';
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

final class CancelledBy extends RemovalCause {
  const CancelledBy(this.opId);

  final String opId;

  @override
  bool operator ==(Object other) => other is CancelledBy && other.opId == opId;

  @override
  int get hashCode => Object.hash(CancelledBy, opId);

  @override
  String toString() => 'CancelledBy($opId)';
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

final class NoFreshId extends Inapplicable {
  const NoFreshId(this.opId);

  final String opId;

  @override
  String toString() => 'NoFreshId($opId)';
}

Landing landingOf(CloudQueue queue, QueueEntry entry) => switch (entry) {
  RetiredOp(:final landing) => landing,
  UnreadableEntry() => Landing.mayHaveLanded,
  final PendingOp op => switch (stateOf(queue, op)) {
    NeverSent() || ServerRefused() => Landing.notLanded,
    Claimed() || AnswerUnknown() || Accepted() => Landing.mayHaveLanded,
  },
};

final class _Edit {
  _Edit(CloudQueue queue)
    : entries = [...queue.entries],
      attempts = {...queue.attempts},
      nextAttempt = queue.nextAttempt,
      base = queue.base,
      strategy = queue.strategy,
      session = queue.session;

  final List<QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  int nextAttempt;
  BaseFacts base;
  StrategyFacts strategy;
  QueueSession session;
  final effects = <QueueEffect>[];

  CloudQueue get queue => CloudQueue(
    entries: entries,
    attempts: attempts,
    nextAttempt: nextAttempt,
    base: base,
    strategy: strategy,
    session: session,
  );

  int indexOf(String id) => entries.indexWhere((e) => e.id == id);

  void put(PendingOp entry) => entries[indexOf(entry.id)] = entry;

  void remove(String id, RemovalCause cause) {
    entries.removeAt(indexOf(id));
    effects.add(OpRemoved(id, cause));
  }

  void downgradeAll() {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] case final PendingOp entry
          when entry.policy == SendPolicy.live) {
        entries[i] = entry.copyWith(policy: SendPolicy.checked);
      }
    }
  }

  int get lastAttempt => nextAttempt - 1;

  Stepped done() {
    _settle(this);
    return Stepped(queue, effects);
  }
}

void _settle(_Edit edit) {
  final queue = edit.queue;
  for (final entry in [...edit.entries]) {
    if (entry is! PendingOp) continue;
    final cause = switch (entry.answer) {
      AnsweredNothingToDo() => const NothingToWaitFor(),
      AnsweredApplied(:final revision) => _settledAt(queue, entry, revision),
      NoAnswer() || AnsweredRefused() => null,
    };
    if (cause != null) edit.remove(entry.id, cause);
  }
  final live = {
    for (final entry in edit.entries)
      if (entry case PendingOp(answer: NoAnswer())) entry.id,
  };
  edit.attempts.removeWhere((_, attempt) => !attempt.opIds.any(live.contains));
}

RemovalCause? _settledAt(CloudQueue queue, PendingOp entry, int revision) {
  if (queue.strategy.presence == Presence.gone) return const SettledByRemoval();
  if (pagesOf(entry).any(queue.base.pageGone)) return const SettledByRemoval();
  final shown = switch (queue.base.rows[targetOf(entry.op)]) {
    RowFact(revision: final at) => at >= revision,
    null => false,
  };
  final copyRead = switch (entry.op) {
    PageAddOp(:final pagePublicId, copyContentFromPagePublicId: _?) =>
      queue.base.contentRead.contains(pagePublicId),
    _ => true,
  };
  return shown && copyRead ? const SeenInBase() : null;
}

StrategyOp sendable(CloudQueue queue, PendingOp entry) {
  final earlier = [
    for (final attempt in queue.attempts.values)
      if (attempt.outcome is AttemptFailed)
        for (final op in attempt.ops)
          if (op.opId == entry.id) (attempt.number, op),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  if (earlier.isNotEmpty) return earlier.first.$2;
  final sent = sendForm(entry.op, entry.policy);
  final target = targetOf(sent);
  final revision = switch (queue.base.rows[target]) {
    RowFact(:final revision) => revision,
    null => _acceptedRevisionBefore(queue, entry, target),
  };
  return revision == null ? sent : rebased(sent, revision);
}

int? _acceptedRevisionBefore(CloudQueue queue, PendingOp entry, Target target) {
  int? found;
  for (final earlier in queue.entries) {
    if (earlier.id == entry.id) break;
    if (earlier case PendingOp(
      answer: AnsweredApplied(:final revision),
    ) when targetOf(earlier.op) == target) {
      found = revision;
    }
  }
  return found;
}

BaseFacts _withBase(BaseFacts base, ArrivedBase arrived) {
  final rows = {...base.rows};
  void keep(Target target, Row row, {String? page, String? digest}) {
    final revision = revisionOfRow(row);
    if (revision == null) return;
    final existing = rows[target];
    if (existing != null && existing.revision > revision) return;
    rows[target] = RowFact(
      revision: revision,
      digest: digest ?? rowDigest(row),
      page: page,
      life: lifeOfRow(row),
    );
  }

  final pageContent = {...base.pageContent};
  final contentRead = {...base.contentRead};
  final notFound = {...base.notFound};
  switch (arrived) {
    case HeaderRead(:final strategy, :final pages, :final settings):
      keep(
        const StrategyTarget(),
        strategy,
        digest: strategyDigest(strategy, pages),
      );
      for (final page in pages) {
        keep(PageTarget(page.publicId), page);
      }
      for (final row in settings) {
        keep(SettingsTarget(row.pagePublicId), row, page: row.pagePublicId);
      }
    case PageRead(
      :final page,
      :final settings,
      :final elements,
      :final lineupGroups,
    ):
      final id = page.publicId;
      keep(PageTarget(id), page);
      keep(SettingsTarget(id), settings, page: id);
      for (final row in elements) {
        keep(ElementTarget(row.publicId), row, page: id);
      }
      for (final row in lineupGroups) {
        keep(LineupTarget(row.publicId), row, page: id);
      }
      pageContent[id] = liveContentOn([...elements, ...lineupGroups], id);
      contentRead.add(id);
    case PageGone(:final pagePublicId):
      notFound.add(pagePublicId);
    case StrategyGone():
      break;
  }
  return BaseFacts(
    rows: rows,
    pageContent: pageContent,
    contentRead: contentRead,
    notFound: notFound,
  );
}

Step transition(CloudQueue queue, QueueEvent event, {required DateTime now}) {
  final edit = _Edit(queue);
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
        edit.attempts[attempt] = fact.withOutcome(AttemptRefusedWhole(refusal));
      }
      switch (refusal) {
        case BatchRefusal.upgradeRequired:
          edit.strategy = edit.strategy.copyWith(
            upgradeTold: UpgradeToldTo(fact.build),
          );
          edit.effects.add(const HoldSendingForUpgrade());
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
          edit.attempts[attempt.number] = attempt.withOutcome(
            AttemptFailed(const AppClosedWhileSending(), now),
          );
        }
      }
      edit.downgradeAll();
      edit.session = QueueSession.start(build);
      return edit.done();
    case ConnectionLost():
      edit.downgradeAll();
      edit.session = QueueSession(
        connected: false,
        build: edit.session.build,
        pagesReadThisSession: const {},
      );
      return edit.done();
    case AccountChanged():
      edit.downgradeAll();
      edit.session = QueueSession(
        connected: edit.session.connected,
        build: edit.session.build,
        pagesReadThisSession: const {},
      );
      return edit.done();
    case ConnectionReturned():
      edit.session = QueueSession(
        connected: true,
        build: edit.session.build,
        pagesReadThisSession: edit.session.pagesReadThisSession,
      );
      return edit.done();
    case EditAccessConfirmed(:final afterAttempt):
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
    case PageRestored(:final pagePublicId, :final freshOpIds):
      return _pageRestored(edit, pagePublicId, freshOpIds);
    case BaseArrived(:final base):
      edit.base = _withBase(edit.base, base);
      switch (base) {
        case PageRead(:final page):
          edit.session = QueueSession(
            connected: edit.session.connected,
            build: edit.session.build,
            pagesReadThisSession: {
              ...edit.session.pagesReadThisSession,
              page.publicId,
            },
          );
        case StrategyGone():
          edit.strategy = edit.strategy.copyWith(presence: Presence.gone);
        case HeaderRead() || PageGone():
          break;
      }
      return edit.done();
  }
}

Step _closeAttempt(_Edit edit, int attempt, AttemptOutcome outcome) {
  final fact = edit.attempts[attempt];
  if (fact == null) return NotApplicable(NoSuchAttempt(attempt));
  if (fact.outcome is AttemptOpen) {
    edit.attempts[attempt] = fact.withOutcome(outcome);
  }
  return edit.done();
}

Step _userEdited(_Edit edit, Edit change, DateTime now) {
  final op = change.op;
  if (!isJson(op.toJson())) return NotApplicable(NotJson(op.opId));
  if (edit.indexOf(op.opId) != -1) return NotApplicable(OpIdTaken(op.opId));
  final queue = edit.queue;
  final policy = queue.session.connected ? SendPolicy.live : SendPolicy.checked;
  final target = targetOf(op);
  final at = edit.entries.lastIndexWhere(
    (entry) => entry is PendingOp && targetOf(entry.op) == target,
  );
  if (change is PlainEdit && at >= 0) {
    final last = edit.entries[at] as PendingOp;
    final views = entryViews(queue, now);
    final view = views[last.id]!;
    final later = edit.entries.skip(at + 1).whereType<PendingOp>();
    final lastPages = pagesOf(last);
    final alone = !later.any(
      (entry) =>
          pagesOf(entry).any(lastPages.contains) ||
          targetOf(entry.op) is StrategyTarget ||
          targetOf(entry.op) is PageTarget,
    );
    if (alone &&
        last.work is OpWork &&
        last.scope == change.scope &&
        view.state is NeverSent &&
        view.go is Free &&
        view.holds.isEmpty) {
      final othersOnRow = edit.entries.whereType<PendingOp>().any(
        (entry) => entry.id != last.id && targetOf(entry.op) == target,
      );
      switch (fold(last.op, op)) {
        case FoldedOp(op: final folded):
          edit.entries[at] = last.copyWith(
            work: OpWork(folded),
            policy: policy == SendPolicy.checked ? policy : last.policy,
          );
          edit.effects.add(OpRemoved(last.id, FoldedInto(folded.opId)));
          return edit.done();
        case CancelsOut() when !othersOnRow:
          edit.remove(last.id, CancelledBy(op.opId));
          return edit.done();
        case CancelsOut() || KeptApart():
          break;
      }
    }
  }
  edit.entries.add(
    PendingOp(
      place: edit.entries.isEmpty ? 0 : edit.entries.last.place + 1,
      work: switch (change) {
        PlainEdit() => OpWork(op),
        PageDeleteEdit(:final op, :final seen) => CheckedDelete(op, seen),
      },
      scope: change.scope,
      authored: change.authored,
      policy: policy,
      answer: const NoAnswer(),
      retriedAfter: edit.lastAttempt,
    ),
  );
  return edit.done();
}

Step _claim(
  _Edit edit,
  String clientId,
  List<String> opIds,
  DateTime at,
  DateTime now,
) {
  final queue = edit.queue;
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
  edit.attempts[number] = AttemptFact(
    number: number,
    clientId: clientId,
    build: queue.session.build,
    at: at,
    ops: ops,
    outcome: const AttemptOpen(),
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
  if (entry.answer is! NoAnswer) return edit.done();
  edit.put(
    entry.copyWith(
      answer: switch (answer) {
        AppliedAnswer(:final revision) => AnsweredApplied(
          revision,
          AppliedBy.thisClient,
        ),
        NoopAnswer(
          :final revision,
          replay: NoopReplay.appliedWhenFirstReceived,
        ) =>
          AnsweredApplied(revision, AppliedBy.thisClient),
        NoopAnswer(:final revision, replay: NoopReplay.notApplied) =>
          AnsweredApplied(revision, AppliedBy.alreadyThere),
        NoopWithoutRevision() => const AnsweredNothingToDo(),
        RejectedAnswer(:final reason, :final current) => AnsweredRefused(
          RejectedByServer(reason, current),
        ),
        FailedAnswer(:final code, :final message) => AnsweredRefused(
          FailedOnServer(code, message),
        ),
      },
    ),
  );
  return edit.done();
}

Step _userRetried(_Edit edit, String opId, DateTime now) {
  final queue = edit.queue;
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
  final queue = edit.queue;
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
  edit.entries[edit.indexOf(opId)] = PendingOp(
    place: entry.place,
    work: switch (entry.work) {
      CheckedDelete(:final seen) when replacement is PageDeleteOp =>
        CheckedDelete(replacement, seen),
      _ => OpWork(replacement),
    },
    scope: entry.scope,
    authored: authored,
    policy: SendPolicy.checked,
    answer: const NoAnswer(),
    retriedAfter: edit.lastAttempt,
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
  final queue = edit.queue;
  final entry = queue.entry(opId);
  if (entry == null) return NotApplicable(NoSuchOp(opId));
  final standing = standingOf(queue);
  final allowed = switch (entry) {
    RetiredOp() || UnreadableEntry() => action == UserRemoval.discarded,
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

Step _pageRestored(_Edit edit, String page, Map<String, String> fresh) {
  for (var i = 0; i < edit.entries.length; i++) {
    final entry = edit.entries[i];
    if (entry case PendingOp(
      answer: AnsweredRefused(
        refusal: FailedOnServer(
          code: KnownFailure(code: FailureCode.pageDeleted),
        ),
      ),
    ) when pagesOf(entry).contains(page)) {
      final id = fresh[entry.id];
      if (id == null) return NotApplicable(NoFreshId(entry.id));
      if (edit.indexOf(id) != -1) return NotApplicable(OpIdTaken(id));
      edit.entries[i] = entry.copyWith(
        work: OpWork(renamed(entry.op, id)),
        answer: const NoAnswer(),
        policy: SendPolicy.checked,
        retriedAfter: edit.lastAttempt,
      );
      edit.effects.add(OpRemoved(entry.id, RetriedUnder(id)));
    }
  }
  return edit.done();
}
