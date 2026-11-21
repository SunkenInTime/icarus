import '../json.dart';
import '../ops.dart';
import '../outcome.dart';
import '../rows.dart';
import 'events.dart';
import 'fold.dart';
import 'op_facts.dart';
import 'pending.dart';

enum Standing { good, editAccessLost, upgradeRequired, deletedOnServer }

final class QueueSession {
  QueueSession({
    required this.connected,
    required Map<String, SeenPage> deleteChecks,
  }) : deleteChecks = Map.unmodifiable(deleteChecks);

  static final atStart = QueueSession(connected: false, deleteChecks: const {});

  final bool connected;
  final Map<String, SeenPage> deleteChecks;
}

final class CloudQueue {
  CloudQueue({
    required List<QueueEntry> entries,
    required this.standing,
    required this.session,
  }) : entries = List.unmodifiable(entries);

  static final empty = CloudQueue(
    entries: const [],
    standing: Standing.good,
    session: QueueSession.atStart,
  );

  final List<QueueEntry> entries;
  final Standing standing;
  final QueueSession session;

  QueueEntry? entry(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }
}

Set<String> pagesOf(PendingOp entry) => {
  if (entry.scope case OnPage(:final pagePublicId)) pagePublicId,
  ...pagesNeeded(entry.op),
};

sealed class Hold {
  const Hold();
}

final class BehindPageAdd extends Hold {
  const BehindPageAdd(this.opId, this.pagePublicId);

  final String opId;
  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is BehindPageAdd &&
      other.opId == opId &&
      other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(BehindPageAdd, opId, pagePublicId);

  @override
  String toString() => 'BehindPageAdd($opId)';
}

final class BehindPageDelete extends Hold {
  const BehindPageDelete(this.opId, this.pagePublicId);

  final String opId;
  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is BehindPageDelete &&
      other.opId == opId &&
      other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(BehindPageDelete, opId, pagePublicId);

  @override
  String toString() => 'BehindPageDelete($opId)';
}

final class BehindPageCopy extends Hold {
  const BehindPageCopy(this.opId, this.pagePublicId);

  final String opId;
  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is BehindPageCopy &&
      other.opId == opId &&
      other.pagePublicId == pagePublicId;

  @override
  int get hashCode => Object.hash(BehindPageCopy, opId, pagePublicId);

  @override
  String toString() => 'BehindPageCopy($opId)';
}

final class BehindPageWork extends Hold {
  BehindPageWork(this.pagePublicId, List<String> opIds)
    : opIds = List.unmodifiable(opIds);

  final String pagePublicId;
  final List<String> opIds;

  @override
  bool operator ==(Object other) =>
      other is BehindPageWork &&
      other.pagePublicId == pagePublicId &&
      other.opIds.join('\u0000') == opIds.join('\u0000');

  @override
  int get hashCode => Object.hash(BehindPageWork, pagePublicId, opIds.length);

  @override
  String toString() => 'BehindPageWork($pagePublicId, $opIds)';
}

final class BehindPageChange extends Hold {
  const BehindPageChange(this.opId);

  final String opId;

  @override
  bool operator ==(Object other) =>
      other is BehindPageChange && other.opId == opId;

  @override
  int get hashCode => Object.hash(BehindPageChange, opId);

  @override
  String toString() => 'BehindPageChange($opId)';
}

final class BehindStrategyChange extends Hold {
  const BehindStrategyChange(this.opId);

  final String opId;

  @override
  bool operator ==(Object other) =>
      other is BehindStrategyChange && other.opId == opId;

  @override
  int get hashCode => Object.hash(BehindStrategyChange, opId);

  @override
  String toString() => 'BehindStrategyChange($opId)';
}

final class BehindEarlierEdit extends Hold {
  const BehindEarlierEdit(this.opId);

  final String opId;

  @override
  bool operator ==(Object other) =>
      other is BehindEarlierEdit && other.opId == opId;

  @override
  int get hashCode => Object.hash(BehindEarlierEdit, opId);

  @override
  String toString() => 'BehindEarlierEdit($opId)';
}

final class UntilRetryTime extends Hold {
  const UntilRetryTime(this.at);

  final DateTime at;

  @override
  bool operator ==(Object other) => other is UntilRetryTime && other.at == at;

  @override
  int get hashCode => Object.hash(UntilRetryTime, at);

  @override
  String toString() => 'UntilRetryTime(${at.toIso8601String()})';
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
  String toString() => 'AwaitingPageRead($pagePublicId)';
}

final class AwaitingCloudVersion extends Hold {
  const AwaitingCloudVersion(this.revision);

  final int revision;

  @override
  bool operator ==(Object other) =>
      other is AwaitingCloudVersion && other.revision == revision;

  @override
  int get hashCode => Object.hash(AwaitingCloudVersion, revision);

  @override
  String toString() => 'AwaitingCloudVersion($revision)';
}

bool _isOpen(PendingState state) => switch (state) {
  Unsent() || Claimed() || ServerRefused() => true,
  Accepted() => false,
};

Map<String, List<Hold>> holdsOf(CloudQueue queue, DateTime now) {
  final holds = <String, List<Hold>>{};
  final openByTarget = <Target, String>{};
  final openPageAdd = <String, String>{};
  final openPageDelete = <String, String>{};
  final openCopyFrom = <String, String>{};
  final openOnPage = <String, List<String>>{};
  String? openRenumbering;
  String? openPagePatch;
  for (final entry in queue.entries) {
    if (entry is! PendingOp) continue;
    final op = entry.op;
    final target = targetOf(op);
    final pages = pagesOf(entry);
    if (entry.state case Unsent(:final delivery)) {
      final found = <Hold>[];
      if (openByTarget[target] case final earlier?) {
        found.add(switch (target) {
          StrategyTarget() => BehindStrategyChange(earlier),
          PageTarget() => BehindPageChange(earlier),
          SettingsTarget() ||
          ElementTarget() ||
          LineupTarget() => BehindEarlierEdit(earlier),
        });
      }
      if (target is PageTarget && openRenumbering != null) {
        found.add(BehindPageChange(openRenumbering));
      }
      if (renumbersPages(op) && openPagePatch != null) {
        found.add(BehindPageChange(openPagePatch));
      }
      final ownPage = switch (op) {
        PageAddOp(:final pagePublicId) ||
        PageDeleteOp(:final pagePublicId) => pagePublicId,
        _ => null,
      };
      for (final page in pages) {
        if (page == ownPage) continue;
        if (openPageAdd[page] case final add?) {
          found.add(BehindPageAdd(add, page));
        }
        if (openPageDelete[page] case final delete?) {
          found.add(BehindPageDelete(delete, page));
        }
        if (openCopyFrom[page] case final copy?) {
          found.add(BehindPageCopy(copy, page));
        }
      }
      final workPage = switch (op) {
        PageDeleteOp(:final pagePublicId) => pagePublicId,
        PageAddOp(:final copyContentFromPagePublicId?) =>
          copyContentFromPagePublicId,
        _ => null,
      };
      if (workPage != null) {
        if (openOnPage[workPage] case final work? when work.isNotEmpty) {
          found.add(BehindPageWork(workPage, work));
        }
      }
      if (delivery case AnswerUnknown(
        retry: RetryAfter(:final at),
      ) when at.isAfter(now)) {
        found.add(UntilRetryTime(at));
      }
      if (entry.work case CheckedDelete(
        op: PageDeleteOp(:final pagePublicId),
        :final seen,
        verdict: AwaitingCheck(),
      ) when queue.session.deleteChecks[entry.id] != seen) {
        found.add(AwaitingPageRead(pagePublicId));
      }
      if (entry.wait case UntilBaseShows(:final revision)) {
        found.add(AwaitingCloudVersion(revision));
      }
      if (found.isNotEmpty) holds[entry.id] = found;
    }
    if (_isOpen(entry.state)) {
      openByTarget[target] = entry.id;
      for (final page in pages) {
        (openOnPage[page] ??= []).add(entry.id);
      }
      switch (op) {
        case PageAddOp(:final pagePublicId, :final copyContentFromPagePublicId):
          openPageAdd[pagePublicId] = entry.id;
          if (copyContentFromPagePublicId case final source?) {
            openCopyFrom[source] = entry.id;
          }
          openRenumbering = entry.id;
        case PageDeleteOp(:final pagePublicId):
          openPageDelete[pagePublicId] = entry.id;
          openRenumbering = entry.id;
        case PageReorderOp():
          openRenumbering = entry.id;
        case PagePatchOp():
          openPagePatch = entry.id;
        case _:
          break;
      }
    }
  }
  return holds;
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

final class OpRebased extends QueueEffect {
  const OpRebased(this.opId, this.revision);

  final String opId;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is OpRebased && other.opId == opId && other.revision == revision;

  @override
  int get hashCode => Object.hash(OpRebased, opId, revision);

  @override
  String toString() => 'OpRebased($opId, $revision)';
}

final class WorkOnDeletedPage extends QueueEffect {
  WorkOnDeletedPage(this.pagePublicId, List<String> opIds)
    : opIds = List.unmodifiable(opIds);

  final String pagePublicId;
  final List<String> opIds;

  @override
  bool operator ==(Object other) =>
      other is WorkOnDeletedPage &&
      other.pagePublicId == pagePublicId &&
      other.opIds.join('\u0000') == opIds.join('\u0000');

  @override
  int get hashCode => Object.hash(WorkOnDeletedPage, pagePublicId);

  @override
  String toString() => 'WorkOnDeletedPage($pagePublicId, $opIds)';
}

final class ReportUnauthenticated extends QueueEffect {
  const ReportUnauthenticated();

  @override
  bool operator ==(Object other) => other is ReportUnauthenticated;

  @override
  int get hashCode => (ReportUnauthenticated).hashCode;

  @override
  String toString() => 'ReportUnauthenticated';
}

final class HoldSendingForUpgrade extends QueueEffect {
  const HoldSendingForUpgrade();

  @override
  bool operator ==(Object other) => other is HoldSendingForUpgrade;

  @override
  int get hashCode => (HoldSendingForUpgrade).hashCode;

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
  const NotInThatState(this.entry);

  final QueueEntry entry;

  @override
  String toString() => 'NotInThatState($entry)';
}

final class HeldBack extends Inapplicable {
  HeldBack(this.opId, List<Hold> holds) : holds = List.unmodifiable(holds);

  final String opId;
  final List<Hold> holds;

  @override
  String toString() => 'HeldBack($opId, $holds)';
}

final class NoneClaimed extends Inapplicable {
  const NoneClaimed(this.attemptId);

  final String attemptId;

  @override
  String toString() => 'NoneClaimed($attemptId)';
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

final class AttemptTaken extends Inapplicable {
  const AttemptTaken(this.attemptId);

  final String attemptId;

  @override
  String toString() => 'AttemptTaken($attemptId)';
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

final class OtherRow extends Inapplicable {
  const OtherRow(this.opId);

  final String opId;

  @override
  String toString() => 'OtherRow($opId)';
}

final class NoFreshId extends Inapplicable {
  const NoFreshId(this.opId);

  final String opId;

  @override
  String toString() => 'NoFreshId($opId)';
}

Landing landingOf(QueueEntry entry) => switch (entry) {
  RetiredOp(:final landing) => landing,
  UnreadableEntry() => Landing.mayHaveLanded,
  PendingOp(state: Unsent(delivery: NeverSent())) => Landing.notLanded,
  PendingOp(state: Unsent(delivery: AnswerUnknown()) || Claimed()) =>
    Landing.mayHaveLanded,
  PendingOp(state: ServerRefused()) => Landing.notLanded,
  PendingOp(state: Accepted()) => Landing.mayHaveLanded,
};

Go _goFor(StrategyOp op) => exceedsSizePolicy(op.toJson())
    ? const NeedsUser(Oversized())
    : const Free();

final class _Edit {
  _Edit(CloudQueue queue)
    : entries = [...queue.entries],
      standing = queue.standing,
      connected = queue.session.connected,
      checks = {...queue.session.deleteChecks};

  final List<QueueEntry> entries;
  Standing standing;
  bool connected;
  final Map<String, SeenPage> checks;
  final effects = <QueueEffect>[];

  int indexOf(String id) => entries.indexWhere((e) => e.id == id);

  QueueEntry? operator [](String id) => switch (indexOf(id)) {
    -1 => null,
    final index => entries[index],
  };

  void put(PendingOp entry) => entries[indexOf(entry.id)] = entry;

  void remove(String id, RemovalCause cause) {
    entries.removeAt(indexOf(id));
    checks.remove(id);
    effects.add(OpRemoved(id, cause));
  }

  int get nextPlace => entries.isEmpty ? 0 : entries.last.place + 1;

  void downgradeAll() {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] case final PendingOp entry
          when entry.policy == SendPolicy.live) {
        entries[i] = entry.copyWith(policy: SendPolicy.checked);
      }
    }
  }

  CloudQueue get queue => CloudQueue(
    entries: entries,
    standing: standing,
    session: QueueSession(connected: connected, deleteChecks: checks),
  );

  Stepped get done => Stepped(queue, effects);
}

Step transition(CloudQueue queue, QueueEvent event, {required DateTime now}) {
  final edit = _Edit(queue);
  _forgetStaleAnswers(edit, now);
  switch (event) {
    case UserEdited(edit: final change):
      return _userEdited(edit, change);
    case BatchClaimed(:final attempt, :final opIds):
      return _claim(edit, attempt, opIds, now);
    case ClaimReleased(:final attemptId):
      return _eachClaimed(
        edit,
        attemptId,
        (entry, claim) =>
            entry.copyWith(state: Unsent(claim.before, const Free())),
      );
    case TransportFailed(:final attemptId, :final failure, :final at):
      return _eachClaimed(edit, attemptId, (entry, claim) {
        final failed = switch (claim.before) {
          NeverSent() => AnswerUnknown(
            clientId: claim.attempt.clientId,
            firstSentAt: claim.attempt.at,
            failures: 1,
            retry: const RetryNow(),
            cause: TransportCut(failure),
          ),
          final AnswerUnknown before => before.copyWith(
            failures: before.failures + 1,
            cause: TransportCut(failure),
          ),
        };
        return entry.copyWith(
          policy: SendPolicy.checked,
          state: Unsent(
            failed.copyWith(
              retry: failed.failures >= retriesBeforePause
                  ? const RetriesExhausted()
                  : RetryAfter(retryTimeAfter(at, failed.failures)),
            ),
            const Free(),
          ),
        );
      });
    case BatchRefused(:final attemptId, :final refusal):
      final back = _eachClaimed(
        edit,
        attemptId,
        (entry, claim) =>
            entry.copyWith(state: Unsent(claim.before, const Free())),
      );
      if (back is NotApplicable) return back;
      switch (refusal) {
        case BatchRefusal.upgradeRequired:
          edit.standing = Standing.upgradeRequired;
          edit.effects.add(const HoldSendingForUpgrade());
        case BatchRefusal.unauthenticated:
          edit.effects.add(const ReportUnauthenticated());
        case BatchRefusal.editAccessRemoved:
          edit.standing = Standing.editAccessLost;
        case BatchRefusal.strategyDeleted:
          _strategyGone(edit);
      }
      return edit.done;
    case OpAnswered(:final attempt, :final answer, :final base):
      return _answered(edit, attempt, answer, base);
    case AppRestarted():
      for (var i = 0; i < edit.entries.length; i++) {
        if (edit.entries[i]
            case PendingOp(state: Claimed(:final attempt, :final before)) &&
                final PendingOp entry) {
          edit.entries[i] = entry.copyWith(
            state: Unsent(switch (before) {
              NeverSent() => AnswerUnknown(
                clientId: attempt.clientId,
                firstSentAt: attempt.at,
                failures: 0,
                retry: const RetryNow(),
                cause: const AppClosedWhileSending(),
              ),
              final AnswerUnknown unknown => unknown.copyWith(
                retry: const RetryNow(),
                cause: const AppClosedWhileSending(),
              ),
            }, const Free()),
          );
        }
      }
      edit.downgradeAll();
      if (edit.standing == Standing.upgradeRequired) {
        edit.standing = Standing.good;
      }
      edit.connected = false;
      edit.checks.clear();
      return edit.done;
    case ConnectionLost():
      edit.downgradeAll();
      edit.connected = false;
      edit.checks.clear();
      return edit.done;
    case AccountChanged():
      edit.downgradeAll();
      edit.checks.clear();
      return edit.done;
    case ConnectionReturned():
      edit.connected = true;
      return edit.done;
    case EditAccessConfirmed():
      if (edit.standing == Standing.editAccessLost) {
        edit.standing = Standing.good;
      }
      return edit.done;
    case UserRetried(:final opId):
      return switch (edit[opId]) {
        null => NotApplicable(NoSuchOp(opId)),
        PendingOp(
              state: Unsent(
                delivery: AnswerUnknown(retry: RetriesExhausted()) &&
                    final AnswerUnknown unknown,
                :final go,
              ),
            ) &&
            final PendingOp entry =>
          (edit..put(
                entry.copyWith(
                  state: Unsent(
                    unknown.copyWith(failures: 0, retry: const RetryNow()),
                    go,
                  ),
                ),
              ))
              .done,
        final entry => NotApplicable(NotInThatState(entry)),
      };
    case UserKeptMine(:final opId, :final replacement):
      return _keepMine(edit, opId, replacement);
    case UserUsedCloud(:final opId):
      final entry = edit[opId];
      if (entry == null) return NotApplicable(NoSuchOp(opId));
      if (entry is! PendingOp || !_userMayReplace(entry)) {
        return NotApplicable(NotInThatState(entry));
      }
      _removeByUser(edit, entry, UserRemoval.usedCloud);
      return edit.done;
    case UserDeletedAnyway(:final opId):
      return switch (edit[opId]) {
        null => NotApplicable(NoSuchOp(opId)),
        PendingOp(work: CheckedDelete(:final op, verdict: HeldForUser())) &&
            final PendingOp entry =>
          (edit..put(entry.copyWith(work: OpWork(op)))).done,
        final entry => NotApplicable(NotInThatState(entry)),
      };
    case UserDiscarded(:final opId):
      final entry = edit[opId];
      if (entry == null) return NotApplicable(NoSuchOp(opId));
      if (!_discardable(entry, edit.standing)) {
        return NotApplicable(NotInThatState(entry));
      }
      switch (entry) {
        case final PendingOp pending:
          _removeByUser(edit, pending, UserRemoval.discarded);
        case RetiredOp() || UnreadableEntry():
          edit.remove(
            opId,
            RemovedByUser(UserRemoval.discarded, landingOf(entry)),
          );
      }
      return edit.done;
    case PageRestored(:final pagePublicId, :final freshOpIds):
      return _pageRestored(edit, pagePublicId, freshOpIds);
    case WorkNoLongerFits(:final opId, :final serverRevision):
      return switch (edit[opId]) {
        null => NotApplicable(NoSuchOp(opId)),
        PendingOp(state: Unsent(delivery: NeverSent(), go: Free())) &&
            final PendingOp entry =>
          (edit..put(
                entry.copyWith(
                  state: Unsent(
                    const NeverSent(),
                    NeedsUser(NoLongerFits(serverRevision)),
                  ),
                ),
              ))
              .done,
        final entry => NotApplicable(NotInThatState(entry)),
      };
    case BaseArrived(:final base):
      _baseArrived(edit, base);
      return edit.done;
  }
}

void _forgetStaleAnswers(_Edit edit, DateTime now) {
  final cutoff = now.subtract(serverRemembersAnswersFor);
  for (var i = 0; i < edit.entries.length; i++) {
    if (edit.entries[i]
        case PendingOp(
              state: Unsent(
                delivery: AnswerUnknown(
                      :final firstSentAt,
                      retry: RetryNow() || RetryAfter() || RetriesExhausted(),
                    ) &&
                    final delivery,
                :final go,
              ),
            ) &&
            final PendingOp entry
        when firstSentAt.isBefore(cutoff) &&
            !serverChecks(sendForm(entry.op, entry.policy))) {
      edit.entries[i] = entry.copyWith(
        state: Unsent(delivery.copyWith(retry: const ServerForgotAnswer()), go),
      );
    }
  }
}

Step _userEdited(_Edit edit, Edit change) {
  final op = change.op;
  if (!isJson(op.toJson())) return NotApplicable(NotJson(op.opId));
  if (edit[op.opId] != null) return NotApplicable(OpIdTaken(op.opId));
  final target = targetOf(op);
  final policy = edit.connected ? SendPolicy.live : SendPolicy.checked;
  final at = edit.entries.lastIndexWhere(
    (entry) => entry is PendingOp && targetOf(entry.op) == target,
  );
  final Against against = switch (at) {
    -1 => OnBase(expectedOf(op)),
    _ => StackedOn(edit.entries[at].id, expectedOf(op)),
  };
  if (change is PlainEdit && at >= 0) {
    final last = edit.entries[at] as PendingOp;
    final later = edit.entries.skip(at + 1);
    final nothingDependsOnPlace = switch (target) {
      StrategyTarget() => later.isEmpty,
      _ => !later.any(
        (entry) => entry is PendingOp && renumbersPages(entry.op),
      ),
    };
    if (last case PendingOp(
      work: OpWork(),
      state: Unsent(delivery: NeverSent(), go: Free()),
      wait: NoWait(),
    ) when nothingDependsOnPlace) {
      switch (fold(last.op, op)) {
        case FoldedOp(op: final folded):
          edit.entries[at] = last.copyWith(
            work: OpWork(folded),
            policy: policy == SendPolicy.checked ? policy : last.policy,
            state: Unsent(const NeverSent(), _goFor(folded)),
          );
          _restack(edit, last.id, folded.opId);
          edit.effects.add(OpRemoved(last.id, FoldedInto(folded.opId)));
          return edit.done;
        case CancelsOut():
          edit.remove(last.id, CancelledBy(op.opId));
          return edit.done;
        case KeptApart():
          break;
      }
    }
  }
  edit.entries.add(
    PendingOp(
      place: edit.nextPlace,
      work: switch (change) {
        PlainEdit() => OpWork(op),
        PageDeleteEdit(:final op, :final seen) => CheckedDelete(
          op,
          seen,
          const AwaitingCheck(),
        ),
      },
      scope: change.scope,
      against: against,
      policy: policy,
      wait: const NoWait(),
      state: Unsent(const NeverSent(), _goFor(op)),
    ),
  );
  return edit.done;
}

void _restack(_Edit edit, String from, String to) {
  for (var i = 0; i < edit.entries.length; i++) {
    if (edit.entries[i]
        case PendingOp(against: StackedOn(:final opId, :final revision)) &&
            final PendingOp entry when opId == from) {
      edit.entries[i] = entry.copyWith(against: StackedOn(to, revision));
    }
  }
}

bool _sendable(PendingOp entry) => switch (entry) {
  PendingOp(work: CheckedDelete(verdict: HeldForUser())) => false,
  PendingOp(
    state: Unsent(
      delivery: AnswerUnknown(
        retry: RetriesExhausted() || ServerForgotAnswer(),
      ),
    ),
  ) =>
    false,
  PendingOp(state: Unsent(go: Free())) => true,
  PendingOp() => false,
};

Step _claim(_Edit edit, Attempt attempt, List<String> opIds, DateTime now) {
  if (edit.standing != Standing.good) {
    return NotApplicable(StandingBlocks(edit.standing));
  }
  for (final entry in edit.entries) {
    if (entry case PendingOp(
      state: Claimed(attempt: Attempt(:final id)),
    ) when id == attempt.id) {
      return NotApplicable(AttemptTaken(attempt.id));
    }
  }
  var previous = -1;
  for (final opId in opIds) {
    final index = edit.indexOf(opId);
    if (index == -1) return NotApplicable(NoSuchOp(opId));
    if (index <= previous) return NotApplicable(OutOfOrder(opId));
    previous = index;
  }
  final holds = holdsOf(edit.queue, now);
  final inBatch = <String>{};
  for (final opId in opIds) {
    final index = edit.indexOf(opId);
    final entry = edit.entries[index];
    if (entry is! PendingOp || !_sendable(entry)) {
      return NotApplicable(NotInThatState(entry));
    }
    final delivery = (entry.state as Unsent).delivery;
    if (delivery case AnswerUnknown(
      :final clientId,
    ) when clientId != attempt.clientId) {
      return NotApplicable(OtherClient(opId, clientId));
    }
    final blocking = [
      for (final hold in holds[opId] ?? const <Hold>[])
        if (!(hold is BehindPageWork && hold.opIds.every(inBatch.contains)))
          hold,
    ];
    if (blocking.isNotEmpty) return NotApplicable(HeldBack(opId, blocking));
    edit.entries[index] = entry.copyWith(state: Claimed(attempt, delivery));
    inBatch.add(opId);
  }
  return edit.done;
}

Step _eachClaimed(
  _Edit edit,
  String attemptId,
  PendingOp Function(PendingOp entry, Claimed claim) next,
) {
  var claimed = 0;
  for (var i = 0; i < edit.entries.length; i++) {
    if (edit.entries[i]
        case PendingOp(state: final Claimed claim) && final PendingOp entry
        when claim.attempt.id == attemptId) {
      edit.entries[i] = next(entry, claim);
      claimed++;
    }
  }
  return claimed == 0 ? NotApplicable(NoneClaimed(attemptId)) : edit.done;
}

void _strategyGone(_Edit edit) {
  edit.standing = Standing.deletedOnServer;
  for (final entry in [...edit.entries]) {
    if (entry case PendingOp(state: Accepted())) {
      edit.remove(entry.id, const SettledByRemoval());
    }
  }
}

bool _userMayReplace(PendingOp entry) => switch (entry.state) {
  ServerRefused() => true,
  Unsent(delivery: NeverSent(), go: NeedsUser(reason: NoLongerFits())) => true,
  _ => false,
};

bool _discardable(QueueEntry entry, Standing standing) => switch (entry) {
  RetiredOp() || UnreadableEntry() => true,
  PendingOp(state: Claimed() || Accepted()) => false,
  PendingOp(state: ServerRefused()) => true,
  PendingOp(state: Unsent(go: NeedsUser())) => true,
  PendingOp(work: CheckedDelete(verdict: HeldForUser())) => true,
  PendingOp(
    state: Unsent(
      delivery: AnswerUnknown(
        retry: RetriesExhausted() || ServerForgotAnswer(),
      ),
    ),
  ) =>
    true,
  PendingOp(state: Unsent()) =>
    standing == Standing.deletedOnServer || standing == Standing.editAccessLost,
};

Step _keepMine(_Edit edit, String opId, StrategyOp replacement) {
  final entry = edit[opId];
  if (entry == null) return NotApplicable(NoSuchOp(opId));
  if (entry is! PendingOp || !_userMayReplace(entry)) {
    return NotApplicable(NotInThatState(entry));
  }
  if (targetOf(replacement) != targetOf(entry.op)) {
    return NotApplicable(OtherRow(replacement.opId));
  }
  if (!isJson(replacement.toJson())) {
    return NotApplicable(NotJson(replacement.opId));
  }
  if (edit[replacement.opId] != null) {
    return NotApplicable(OpIdTaken(replacement.opId));
  }
  edit.entries[edit.indexOf(opId)] = PendingOp(
    place: entry.place,
    work: OpWork(replacement),
    scope: entry.scope,
    against: OnBase(expectedOf(replacement)),
    policy: SendPolicy.checked,
    wait: const NoWait(),
    state: Unsent(const NeverSent(), _goFor(replacement)),
  );
  edit.checks.remove(opId);
  _restack(edit, opId, replacement.opId);
  edit.effects.add(
    OpRemoved(
      opId,
      RemovedByUser(UserRemoval.replacedByKeepMine, landingOf(entry)),
    ),
  );
  return edit.done;
}

void _removeByUser(_Edit edit, PendingOp entry, UserRemoval action) {
  final at = edit.indexOf(entry.id);
  final target = targetOf(entry.op);
  edit.remove(entry.id, RemovedByUser(action, landingOf(entry)));
  if (entry.state case ServerRefused(
    refusal: RejectedByServer(current: ServerSnapshot(:final revision)),
  )) {
    for (final follower in edit.entries.skip(at)) {
      if (follower is! PendingOp || targetOf(follower.op) != target) continue;
      if (follower.state case Unsent(delivery: NeverSent())) {
        edit.put(follower.copyWith(wait: UntilBaseShows(revision)));
      }
      return;
    }
  }
}

Step _pageRestored(_Edit edit, String page, Map<String, String> fresh) {
  for (var i = 0; i < edit.entries.length; i++) {
    final entry = edit.entries[i];
    if (entry is! PendingOp || !pagesOf(entry).contains(page)) continue;
    switch (entry.state) {
      case Unsent(
            :final delivery,
            go: NeedsUser(reason: OnDeletedPage(:final pagePublicId)),
          )
          when pagePublicId == page:
        edit.entries[i] = entry.copyWith(state: Unsent(delivery, const Free()));
      case ServerRefused(
        refusal: FailedOnServer(
          code: KnownFailure(code: FailureCode.pageDeleted),
        ),
      ):
        final id = fresh[entry.id];
        if (id == null) return NotApplicable(NoFreshId(entry.id));
        if (edit[id] != null) return NotApplicable(OpIdTaken(id));
        final op = renamed(entry.op, id);
        edit.entries[i] = PendingOp(
          place: entry.place,
          work: OpWork(op),
          scope: entry.scope,
          against: entry.against,
          policy: SendPolicy.checked,
          wait: const NoWait(),
          state: Unsent(const NeverSent(), _goFor(op)),
        );
        _restack(edit, entry.id, id);
        edit.effects.add(OpRemoved(entry.id, RetriedUnder(id)));
      case _:
        break;
    }
  }
  return edit.done;
}

bool _landedExactly(PendingOp landed, OpAnswer answer, int revision) =>
    switch (answer) {
      NoopAnswer(replay: NoopReplay.notApplied) => writesWhole(landed.op),
      _ => switch (expectedOf(landed.op)) {
        null => true,
        final expected => revision == expected + 1,
      },
    };

Step _answered(_Edit edit, Attempt attempt, OpAnswer answer, BaseRow base) {
  final entry = edit[answer.opId];
  if (entry == null) return NotApplicable(NoSuchOp(answer.opId));
  if (entry is! PendingOp) return NotApplicable(NotInThatState(entry));
  final clientId = switch (entry.state) {
    Claimed(attempt: Attempt(:final clientId)) => clientId,
    Unsent(delivery: AnswerUnknown(:final clientId)) => clientId,
    Unsent(delivery: NeverSent()) || Accepted() || ServerRefused() => null,
  };
  if (clientId == null) return NotApplicable(NotInThatState(entry));
  if (clientId != attempt.clientId) {
    return NotApplicable(OtherClient(entry.id, attempt.clientId));
  }
  switch (answer) {
    case AppliedAnswer(:final revision) || NoopAnswer(:final revision):
      final own = switch (answer) {
        NoopAnswer(replay: NoopReplay.notApplied) => false,
        _ => true,
      };
      if (_landedExactly(entry, answer, revision)) {
        _advanceFollower(edit, entry, revision);
      }
      if (own) _advanceSeen(edit, entry.op, revision);
      _deletedPageStops(edit, entry);
      final shown = switch (base) {
        BaseHolds(revision: final at) => at >= revision,
        BaseLacks() => false,
      };
      switch ((entry.op, shown)) {
        case (PageAddOp(copyContentFromPagePublicId: _?), _):
          edit.put(
            entry.copyWith(
              state: Accepted(
                revision,
                awaiting: AwaitingCopy(
                  shown ? CopySeen.strategyOnly : CopySeen.neither,
                ),
              ),
            ),
          );
        case (_, true):
          edit.remove(entry.id, const SeenInBase());
        case (_, false):
          edit.put(entry.copyWith(state: Accepted(revision)));
      }
    case NoopWithoutRevision():
      edit.remove(entry.id, const NothingToWaitFor());
    case RejectedAnswer(:final reason, :final current):
      edit.put(
        entry.copyWith(state: ServerRefused(RejectedByServer(reason, current))),
      );
    case FailedAnswer(:final code, :final message):
      edit.put(
        entry.copyWith(state: ServerRefused(FailedOnServer(code, message))),
      );
  }
  return edit.done;
}

void _advanceFollower(_Edit edit, PendingOp landed, int landedAt) {
  for (final entry in edit.entries.skip(edit.indexOf(landed.id) + 1)) {
    if (entry case PendingOp(
      against: StackedOn(:final opId, :final revision),
      state: Unsent(delivery: NeverSent()),
    ) when opId == landed.id) {
      final predicted = switch (expectedOf(landed.op)) {
        final expected? => expected + 1,
        null => 1,
      };
      if (revision != predicted) return;
      final moved = rebased(entry.op, landedAt);
      edit.put(
        entry.copyWith(
          work: switch ((entry.work, moved)) {
            (
              CheckedDelete(:final seen, :final verdict),
              final PageDeleteOp op,
            ) =>
              CheckedDelete(op, seen, verdict),
            _ => OpWork(moved),
          },
          against: StackedOn(landed.id, landedAt),
        ),
      );
      if (moved != entry.op) edit.effects.add(OpRebased(entry.id, landedAt));
      return;
    }
  }
}

void _deletedPageStops(_Edit edit, PendingOp landed) {
  if (landed.op case PageDeleteOp(:final pagePublicId)) {
    final stopped = <String>[];
    for (final entry in [...edit.entries.skip(edit.indexOf(landed.id) + 1)]) {
      if (entry case PendingOp(
        state: Unsent(:final delivery, go: Free()),
      ) when pagesOf(entry).contains(pagePublicId)) {
        edit.put(
          entry.copyWith(
            state: Unsent(delivery, NeedsUser(OnDeletedPage(pagePublicId))),
          ),
        );
        stopped.add(entry.id);
      }
    }
    if (stopped.isNotEmpty) {
      edit.effects.add(WorkOnDeletedPage(pagePublicId, stopped));
    }
  }
}

SeenPart? _partOf(StrategyOp op) => switch (op) {
  PageSettingsPatchOp() => const SeenSettings(),
  ElementAddOp(:final elementPublicId) ||
  ElementPatchOp(:final elementPublicId) ||
  ElementDeleteOp(:final elementPublicId) ||
  ElementReorderOp(:final elementPublicId) => SeenElement(elementPublicId),
  LineupGroupAddOp(:final lineupPublicId) ||
  LineupGroupPatchOp(:final lineupPublicId) ||
  LineupGroupDeleteOp(:final lineupPublicId) ||
  LineupGroupReorderOp(
    :final lineupPublicId,
  ) => SeenLineupGroup(lineupPublicId),
  StrategyPatchOp() ||
  PageAddOp() ||
  PagePatchOp() ||
  PageDeleteOp() ||
  PageReorderOp() => null,
};

SeenPage _seenAfter(
  SeenPage seen,
  String deletedPage,
  StrategyOp landed,
  int revision,
) {
  if (landed case PagePatchOp(
    :final pagePublicId,
    :final name,
    :final isAttack,
  )) {
    if (pagePublicId != deletedPage) return seen;
    return SeenPage(
      name: name ?? seen.name,
      isAttack: isAttack ?? seen.isAttack,
      content: seen.content,
    );
  }
  final part = _partOf(landed);
  final content = seen.content;
  if (part == null || content is! ContentSeen) return seen;
  if (part is SeenSettings && !pagesNeeded(landed).contains(deletedPage)) {
    return seen;
  }
  final before = content.revisions[part];
  final isNew =
      before == null &&
      (landed is ElementAddOp || landed is LineupGroupAddOp) &&
      pagesNeeded(landed).contains(deletedPage);
  if (before != revision - 1 && !isNew) return seen;
  return SeenPage(
    name: seen.name,
    isAttack: seen.isAttack,
    content: ContentSeen({
      for (final entry in content.revisions.entries)
        if (entry.key != part) entry.key: entry.value,
      if (landed is! ElementDeleteOp && landed is! LineupGroupDeleteOp)
        part: revision,
    }),
  );
}

void _advanceSeen(_Edit edit, StrategyOp landed, int revision) {
  for (final entry in [...edit.entries]) {
    if (entry case PendingOp(
      work: CheckedDelete(:final op, :final seen, :final verdict),
    )) {
      final after = _seenAfter(seen, op.pagePublicId, landed, revision);
      if (after != seen) {
        edit.put(entry.copyWith(work: CheckedDelete(op, after, verdict)));
      }
    }
  }
}

int? _revisionOf(Row row) => switch (row) {
  ReadableStrategy(:final revision) ||
  ReadablePageRow(:final revision) ||
  ReadablePageSettings(:final revision) ||
  ReadableElementRow(:final revision) ||
  ReadableLineupGroupRow(:final revision) => revision,
  UnreadableStrategy(:final stored) ||
  UnreadablePage(:final stored) ||
  UnreadablePageSettings(:final stored) ||
  UnreadableElement(:final stored) ||
  UnreadableLineupGroup(:final stored) => switch (stored) {
    {'revision': final int revision} => revision,
    _ => null,
  },
  FolderRow() => null,
};

final class _Shown {
  _Shown(ArrivedBase base) {
    switch (base) {
      case HeaderRead(:final strategy, :final pages, :final settings):
        rows[const StrategyTarget()] = strategy;
        for (final page in pages) {
          rows[PageTarget(page.publicId)] = page;
        }
        for (final row in settings) {
          rows[SettingsTarget(row.pagePublicId)] = row;
        }
      case PageRead(:final elements, :final lineupGroups):
        for (final row in elements) {
          rows[ElementTarget(row.publicId)] = row;
        }
        for (final row in lineupGroups) {
          rows[LineupTarget(row.publicId)] = row;
        }
      case PageGone() || StrategyGone():
        break;
    }
  }

  final rows = <Target, Row>{};

  int? revisionAt(Target target) => switch (rows[target]) {
    final row? => _revisionOf(row),
    null => null,
  };
}

sealed class _Check {
  const _Check();
}

final class _Unchanged extends _Check {
  const _Unchanged();
}

final class _Held extends _Check {
  const _Held(this.cause);

  final HeldDeleteCause cause;
}

_Check _checkDelete(SeenPage seen, PageRead read) {
  final rows = <Row>[
    read.page,
    read.settings,
    ...read.elements,
    ...read.lineupGroups,
  ];
  if (rows.any(
    (row) =>
        row is UnreadablePage ||
        row is UnreadablePageSettings ||
        row is UnreadableElement ||
        row is UnreadableLineupGroup,
  )) {
    return const _Held(HeldDeleteCause.pageUnreadable);
  }
  final page = read.page;
  if (page is TrashedPage) return const _Unchanged();
  final content = seen.content;
  if (content is! ContentSeen) {
    return const _Held(HeldDeleteCause.contentNeverRead);
  }
  final now = <SeenPart, int>{
    if (read.settings case ReadablePageSettings(:final revision))
      const SeenSettings(): revision,
    for (final element in read.elements)
      if (element case LiveElement(:final publicId, :final revision))
        SeenElement(publicId): revision,
    for (final group in read.lineupGroups)
      if (group case LiveLineupGroup(:final publicId, :final revision))
        SeenLineupGroup(publicId): revision,
  };
  final same =
      page is LivePage &&
      page.name == seen.name &&
      page.isAttack == seen.isAttack &&
      ContentSeen(now) == content;
  return same ? const _Unchanged() : const _Held(HeldDeleteCause.pageChanged);
}

bool _earlierOpenWorkOn(_Edit edit, PendingOp entry, String page) {
  for (final earlier in edit.entries) {
    if (earlier.id == entry.id) return false;
    if (earlier case PendingOp(
      :final state,
    ) when _isOpen(state) && pagesOf(earlier).contains(page)) {
      return true;
    }
  }
  return false;
}

void _baseArrived(_Edit edit, ArrivedBase base) {
  if (base is StrategyGone) {
    _strategyGone(edit);
    return;
  }
  final shown = _Shown(base);
  for (final entry in [...edit.entries]) {
    if (entry is! PendingOp) continue;
    final target = targetOf(entry.op);
    var current = entry;
    if (current.wait case UntilBaseShows(:final revision)) {
      if (shown.revisionAt(target) case final at? when at >= revision) {
        current = current.copyWith(wait: const NoWait());
        edit.put(current);
      }
    }
    switch (current.state) {
      case Accepted(:final revision, :final awaiting):
        if (base case PageGone(
          :final pagePublicId,
        ) when pagesOf(current).contains(pagePublicId)) {
          edit.remove(current.id, const SettledByRemoval());
          continue;
        }
        final rowShown = switch (shown.revisionAt(target)) {
          final at? => at >= revision,
          null => false,
        };
        final contentShown = switch ((current.op, base)) {
          (PageAddOp(:final pagePublicId), PageRead(:final page)) =>
            page.publicId == pagePublicId,
          _ => false,
        };
        final next = switch ((awaiting, rowShown, contentShown)) {
          (AwaitingRow(), true, _) => null,
          (AwaitingRow(), false, _) => awaiting,
          (AwaitingCopy(seen: CopySeen.neither), true, _) => const AwaitingCopy(
            CopySeen.strategyOnly,
          ),
          (AwaitingCopy(seen: CopySeen.strategyOnly), _, true) => null,
          (AwaitingCopy(), _, _) => awaiting,
        };
        switch (next) {
          case null:
            edit.remove(current.id, const SeenInBase());
          case final still when still != awaiting:
            edit.put(
              current.copyWith(state: Accepted(revision, awaiting: still)),
            );
          case _:
            break;
        }
      case Unsent(go: Free()):
        switch ((current.work, base)) {
          case (
                CheckedDelete(:final op, :final seen, verdict: AwaitingCheck()),
                final PageRead read,
              )
              when read.page.publicId == op.pagePublicId &&
                  !_earlierOpenWorkOn(edit, current, op.pagePublicId):
            switch (_checkDelete(seen, read)) {
              case _Unchanged():
                edit.checks[current.id] = seen;
              case _Held(:final cause):
                edit.checks.remove(current.id);
                edit.put(
                  current.copyWith(
                    work: CheckedDelete(op, seen, HeldForUser(cause)),
                  ),
                );
            }
          case (
                CheckedDelete(:final op, :final seen, verdict: AwaitingCheck()),
                PageGone(:final pagePublicId),
              )
              when pagePublicId == op.pagePublicId:
            edit.checks[current.id] = seen;
          case _:
            break;
        }
      case _:
        break;
    }
  }
}
