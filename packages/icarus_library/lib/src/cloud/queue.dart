import 'dart:collection';

import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import '../rows.dart';
import 'events.dart';
import 'fold.dart';
import 'op_facts.dart';
import 'pending.dart';
import 'sync.dart';

part 'derivation.dart';

final class ContentRead {
  ContentRead({
    required this.read,
    required this.readAt,
    required Map<SeenPart, String> digests,
    required Set<Target> present,
  }) : digests = Map.unmodifiable(digests),
       present = Set.unmodifiable(present);

  final int read;
  final DateTime readAt;
  final Map<SeenPart, String> digests;
  final Set<Target> present;

  @override
  bool operator ==(Object other) =>
      other is ContentRead &&
      other.read == read &&
      other.readAt == readAt &&
      sameSet(other.present, present) &&
      BaseFacts.canonical(other.digests) == BaseFacts.canonical(digests);

  @override
  int get hashCode => Object.hash(ContentRead, read, readAt);
}

final class HeaderListing {
  HeaderListing({
    required this.read,
    required this.readAt,
    required Set<String> pages,
    required Set<String> settings,
  }) : pages = Set.unmodifiable(pages),
       settings = Set.unmodifiable(settings);

  final int read;
  final DateTime readAt;
  final Set<String> pages;
  final Set<String> settings;

  @override
  bool operator ==(Object other) =>
      other is HeaderListing &&
      other.read == read &&
      other.readAt == readAt &&
      sameSet(other.pages, pages) &&
      sameSet(other.settings, settings);

  @override
  int get hashCode => Object.hash(HeaderListing, read, readAt);
}

final class BaseFacts {
  BaseFacts({
    required Map<Target, RowEvidence> sightings,
    required Map<String, ContentRead> pageContent,
    required this.header,
    required Map<String, RowAbsent> notFound,
  }) : sightings = Map.unmodifiable(sightings),
       pageContent = Map.unmodifiable(pageContent),
       notFound = Map.unmodifiable(notFound);

  static final none = BaseFacts(
    sightings: const {},
    pageContent: const {},
    header: null,
    notFound: const {},
  );

  final Map<Target, RowEvidence> sightings;
  final Map<String, ContentRead> pageContent;
  final HeaderListing? header;
  final Map<String, RowAbsent> notFound;

  RowEvidence? evidence(Target target, {String? authoredOn}) {
    final seen = sightings[target];
    RowEvidence? latest(Iterable<RowEvidence?> candidates) {
      RowEvidence? best;
      for (final candidate in candidates) {
        if (candidate != null && (best == null || candidate.read > best.read)) {
          best = candidate;
        }
      }
      return best;
    }

    RowAbsent? unlisted(bool listed) => switch (header) {
      final header? when !listed => RowAbsent(
        read: header.read,
        readAt: header.readAt,
      ),
      _ => null,
    };

    RowAbsent? missingFrom(String? page) => switch (pageContent[page]) {
      final content? when !content.present.contains(target) => RowAbsent(
        read: content.read,
        readAt: content.readAt,
      ),
      _ => null,
    };

    return switch (target) {
      StrategyTarget() => seen,
      PageTarget(:final pagePublicId) => latest([
        seen,
        unlisted(header?.pages.contains(pagePublicId) ?? true),
        notFound[pagePublicId],
      ]),
      SettingsTarget(:final pagePublicId) => latest([
        seen,
        unlisted(header?.settings.contains(pagePublicId) ?? true),
        notFound[pagePublicId],
      ]),
      ElementTarget() || LineupTarget() => switch (seen) {
        RowSeen(:final page) ||
        RowUnreadable(:final page) => latest([seen, missingFrom(page)]),
        RowAbsent() || null => missingFrom(authoredOn),
      },
    };
  }

  int get lastRead => [
    for (final evidence in sightings.values) evidence.read,
    for (final content in pageContent.values) content.read,
    for (final absent in notFound.values) absent.read,
    ?header?.read,
  ].fold(0, (last, read) => read > last ? read : last);

  bool pageGoneAfter(String pagePublicId, int read) =>
      switch (evidence(PageTarget(pagePublicId))) {
        RowSeen(life: Life.gone, read: final seen) ||
        RowAbsent(read: final seen) => seen > read,
        RowSeen() || RowUnreadable() || null => false,
      };

  bool pageLiveAfter(String pagePublicId, int read) =>
      switch (evidence(PageTarget(pagePublicId))) {
        RowSeen(life: Life.live, read: final seen) ||
        RowUnreadable(read: final seen) => seen > read,
        RowSeen() || RowAbsent() || null => false,
      };

  @override
  bool operator ==(Object other) =>
      other is BaseFacts &&
      sameMap(other.sightings, sightings) &&
      sameMap(other.pageContent, pageContent) &&
      other.header == header &&
      sameMap(other.notFound, notFound);

  @override
  int get hashCode => Object.hash(hashMap(sightings), pageContent.length);

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
  factory CloudQueue({
    required List<QueueEntry> entries,
    required Map<int, AttemptFact> attempts,
    required int nextAttempt,
    required int nextRead,
    required BaseFacts base,
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
    base: BaseFacts.none,
    strategy: StrategyFacts.fresh,
    session: QueueSession.start(build),
    index: _Index.empty,
    lineage: null,
  );

  final List<QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  final int nextAttempt;
  final int nextRead;
  final BaseFacts base;
  final StrategyFacts strategy;
  final QueueSession session;
  final _Index _index;
  _Lineage? _lineage;
  _Derivation? _derived;

  QueueEntry? entry(String id) => _index.byId[id];

  static String? _problemWith(
    List<QueueEntry> entries,
    Map<int, AttemptFact> attempts,
    int nextAttempt,
    int nextRead,
    BaseFacts base,
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

final class IncompleteCopy extends UserReason {
  const IncompleteCopy(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is IncompleteCopy && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(IncompleteCopy, pagePublicId);

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

String? _evidencePage(RowEvidence? evidence) => switch (evidence) {
  RowSeen(:final page) || RowUnreadable(:final page) => page,
  RowAbsent() || null => null,
};

enum _Comparison { same, differs, unknown }

_Comparison _compare(Authored authored, RowEvidence? evidence) =>
    switch ((authored, evidence)) {
      (AuthoredUnreadable(), _) => _Comparison.differs,
      (_, null) => _Comparison.unknown,
      (AuthoredRow(:final digest), RowSeen(digest: final seen)) =>
        seen == digest ? _Comparison.same : _Comparison.differs,
      (AuthoredRow(), RowUnreadable() || RowAbsent()) => _Comparison.differs,
      (AuthoredNoRow(), RowAbsent() || RowSeen(life: Life.gone)) =>
        _Comparison.same,
      (AuthoredNoRow(), RowSeen() || RowUnreadable()) => _Comparison.differs,
    };

bool _sameRevision(Authored authored, RowEvidence evidence) =>
    switch ((authored, evidence)) {
      (AuthoredRow(:final revision), RowSeen(revision: final seen)) =>
        seen == revision,
      (AuthoredNoRow(), _) => true,
      _ => false,
    };

Go _checked(
  CloudQueue queue,
  PendingOp entry,
  PendingState state,
  DateTime now,
  String? acceptedSameRow,
  bool Function(String page) acceptedOnPage,
  List<Hold> holds,
) {
  final target = targetOf(entry.op);
  final evidence = queue.base.evidence(
    target,
    authoredOn: _authoredPage(entry.scope),
  );
  if (state case AnswerUnknown(:final firstSentAt)) {
    final forgottenAt = firstSentAt.add(serverRemembersAnswersFor);
    if (!now.isAfter(forgottenAt)) return const Free();
    if (checkKindOf(sendForm(entry.op, SendPolicy.checked)) !=
        CheckKind.revision) {
      return const NeedsUser(ServerForgotAnswer());
    }
    if (evidence == null || !evidence.readAt.isAfter(forgottenAt)) {
      holds.add(AwaitingBase(target));
      return const Free();
    }
    return _compare(entry.authored, evidence) == _Comparison.same &&
            _sameRevision(entry.authored, evidence)
        ? const NeedsFreshId(ServerForgot())
        : const NeedsUser(ServerForgotAnswer());
  }
  if (target case ElementTarget() || LineupTarget()) {
    final page = _evidencePage(evidence);
    final gone = entry.authored is AuthoredRow && evidence is RowAbsent;
    if (gone || (page != null && page != _authoredPage(entry.scope))) {
      if (acceptedSameRow != null) {
        holds.add(AwaitingBase(target));
        return const Free();
      }
      return const NeedsUser(ChangedUnseen());
    }
  }
  if (checkKindOf(sendForm(entry.op, entry.policy)) == CheckKind.revision) {
    if (acceptedSameRow != null) {
      holds.add(AwaitingBase(target));
      return const Free();
    }
    switch (_compare(entry.authored, evidence)) {
      case _Comparison.same:
        break;
      case _Comparison.differs:
        return const NeedsUser(ChangedUnseen());
      case _Comparison.unknown:
        holds.add(AwaitingBase(target));
        return const Free();
    }
  }
  if (entry.work case CheckedDelete(:final op, :final seen)) {
    final page = op.pagePublicId;
    final content = seen.content;
    if (content is! ContentSeen) {
      return const NeedsUser(DeleteHeld(HeldDeleteCause.contentNeverRead));
    }
    final current = {
      ...?queue.base.pageContent[page]?.digests,
      if (queue.base.evidence(SettingsTarget(page)) case RowSeen(:final digest))
        const SeenSettings(): digest,
    };
    final pageDigest = switch (queue.base.evidence(PageTarget(page))) {
      RowSeen(:final digest) => digest,
      RowUnreadable() || RowAbsent() || null => null,
    };
    final same =
        sameMap(current, content.digests) && pageDigest == seen.pageDigest;
    if (!same) {
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

final class NoSuchRead extends Inapplicable {
  const NoSuchRead(this.read);

  final int read;

  @override
  String toString() => 'NoSuchRead($read)';
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
  _Edit(this.original)
    : entries = [...original.entries],
      attempts = {...original.attempts},
      nextAttempt = original.nextAttempt,
      nextRead = original.nextRead,
      base = original.base,
      strategy = original.strategy,
      session = original.session,
      index = _IndexEdit(original._index);

  final CloudQueue original;
  final List<QueueEntry> entries;
  final Map<int, AttemptFact> attempts;
  int nextAttempt;
  int nextRead;
  BaseFacts base;
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

void _settle(_Edit edit) {
  final answered = edit.index.answered;
  final all =
      edit.change.everything ||
      (edit.strategy.presence == Presence.gone &&
          edit.original.strategy.presence != Presence.gone);
  final subjects =
      edit.change.pages.isNotEmpty || edit.change.targets.isNotEmpty;
  final candidates = <PendingOp>[];
  for (final id in all || subjects ? answered : edit.change.touched) {
    derivationWork.visits++;
    if (!answered.contains(id)) continue;
    final entry = edit.index.byId[id];
    if (entry is! PendingOp) continue;
    if (all ||
        edit.change.touched.contains(id) ||
        edit.change.targets.contains(targetOf(entry.op)) ||
        _pagesOf(entry).any(edit.change.pages.contains)) {
      candidates.add(entry);
    }
  }
  candidates.sort((a, b) => a.place.compareTo(b.place));
  final settled = <String>{};
  for (final entry in candidates) {
    final cause = switch (entry.answer) {
      AnsweredNothingToDo() => const NothingToWaitFor(),
      AnsweredApplied(:final revision, :final afterRead) => _settledAt(
        edit.base,
        edit.strategy,
        entry,
        revision,
        afterRead,
      ),
      NotAnswered() || AnsweredRefused() => null,
    };
    if (cause != null) {
      edit.remove(entry.id, cause);
      settled.add(entry.id);
    }
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

RemovalCause? _settledAt(
  BaseFacts base,
  StrategyFacts strategy,
  PendingOp entry,
  int revision,
  int afterRead,
) {
  final gone =
      strategy.presence == Presence.gone ||
      _pagesOf(entry).any((page) => base.pageGoneAfter(page, afterRead));
  final shown = switch (base.evidence(
    targetOf(entry.op),
    authoredOn: _authoredPage(entry.scope),
  )) {
    RowSeen(revision: final at, :final read) =>
      at >= revision || read > afterRead,
    RowUnreadable(:final read) || RowAbsent(:final read) => read > afterRead,
    null => false,
  };
  final copyRead = switch (entry.op) {
    PageAddOp(:final pagePublicId, copyContentFromPagePublicId: _?) =>
      base.pageContent.containsKey(pagePublicId),
    _ => true,
  };
  return gone || (shown && copyRead) ? const SeenInBase() : null;
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
  final revision = switch (queue.base.evidence(target)) {
    RowSeen(:final revision) => revision,
    RowUnreadable() ||
    RowAbsent() ||
    null => _acceptedRevisionBefore(queue, entry, target),
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

BaseFacts _withBase(
  BaseFacts base,
  ArrivedBase arrived,
  int read,
  DateTime startedAt,
) {
  final sightings = {...base.sightings};
  final pageContent = {...base.pageContent};
  final notFound = {...base.notFound};
  var header = base.header;
  void seen(Target target, Row row, {String? page, String? digest}) {
    if ((sightings[target]?.read ?? 0) > read) return;
    sightings[target] = switch (revisionOfRow(row)) {
      final revision? => RowSeen(
        read: read,
        readAt: startedAt,
        revision: revision,
        digest: digest ?? rowDigest(row),
        page: page,
        life: lifeOfRow(row),
      ),
      null => RowUnreadable(read: read, readAt: startedAt, page: page),
    };
  }

  switch (arrived) {
    case HeaderRead(:final strategy, :final pages, :final settings):
      seen(
        const StrategyTarget(),
        strategy,
        digest: strategyDigest(strategy, pages),
      );
      for (final page in pages) {
        seen(PageTarget(page.publicId), page);
      }
      for (final row in settings) {
        seen(SettingsTarget(row.pagePublicId), row, page: row.pagePublicId);
      }
      if ((header?.read ?? 0) <= read) {
        header = HeaderListing(
          read: read,
          readAt: startedAt,
          pages: {for (final page in pages) page.publicId},
          settings: {for (final row in settings) row.pagePublicId},
        );
      }
    case PageRead(:final page, :final elements, :final lineupGroups):
      final id = page.publicId;
      for (final row in elements) {
        seen(ElementTarget(row.publicId), row, page: id);
      }
      for (final row in lineupGroups) {
        seen(LineupTarget(row.publicId), row, page: id);
      }
      if ((pageContent[id]?.read ?? 0) <= read) {
        pageContent[id] = ContentRead(
          read: read,
          readAt: startedAt,
          digests: liveContentOn([...elements, ...lineupGroups], id),
          present: {
            for (final row in elements) ElementTarget(row.publicId),
            for (final row in lineupGroups) LineupTarget(row.publicId),
          },
        );
      }
    case PageGone(:final pagePublicId):
      if ((notFound[pagePublicId]?.read ?? 0) <= read) {
        notFound[pagePublicId] = RowAbsent(read: read, readAt: startedAt);
      }
    case StrategyGone():
      break;
  }
  return BaseFacts(
    sightings: sightings,
    pageContent: pageContent,
    header: header,
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
          edit.setAttempt(
            attempt.withOutcome(
              AttemptFailed(const AppClosedWhileSending(), now),
            ),
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
    case Reissue(:final freshOpIds):
      return _reissue(edit, freshOpIds, now);
    case ReadStarted():
      edit.effects.add(ReadNumbered(edit.nextRead++));
      return edit.done();
    case BaseArrived(:final base, :final read, :final startedAt):
      if (read < 1 || read >= edit.nextRead) {
        return NotApplicable(NoSuchRead(read));
      }
      edit.base = _withBase(edit.base, base, read, startedAt);
      switch (base) {
        case HeaderRead():
          edit.change.everything = true;
        case PageRead(:final page, :final elements, :final lineupGroups):
          edit.change.pages.add(page.publicId);
          edit.change.targets.addAll([
            for (final row in elements) ElementTarget(row.publicId),
            for (final row in lineupGroups) LineupTarget(row.publicId),
          ]);
          edit.session = QueueSession(
            connected: edit.session.connected,
            build: edit.session.build,
            pagesReadThisSession: {
              ...edit.session.pagesReadThisSession,
              page.publicId,
            },
          );
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
      final othersOnRow = onRow.length > 1;
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
        case CancelsOut() when !othersOnRow:
          edit.remove(last.id, CancelledBy(op.opId));
          return edit.done();
        case CancelsOut() || KeptApart():
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
  BehindEntry() || AwaitingPageRead() || AwaitingBase() => false,
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
      case ImportedIncompleteCopy():
        return NotApplicable(NotInThatState(opId, 'an incomplete copy'));
    }
    renamedAt[index] = entry.copyWith(
      work: work,
      answer: const NotAnswered(),
      policy: SendPolicy.checked,
      retriedAfter: edit.lastAttempt,
    );
  }
  for (final MapEntry(key: index, value: entry) in renamedAt.entries) {
    final old = edit.entries[index].id;
    edit.replaceAt(index, entry);
    edit.effects.add(OpRemoved(old, RetriedUnder(entry.id)));
  }
  return edit.done();
}
