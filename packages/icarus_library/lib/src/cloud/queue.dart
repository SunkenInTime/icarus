import '../ops.dart';
import '../rows.dart';
import 'events.dart';
import 'op_facts.dart';
import 'pending.dart';

final class CloudQueue {
  CloudQueue({
    required List<QueueEntry> entries,
    required Set<String> deletesCheckedThisSession,
  }) : entries = List.unmodifiable(entries),
       deletesCheckedThisSession = Set.unmodifiable(deletesCheckedThisSession);

  static final empty = CloudQueue(
    entries: const [],
    deletesCheckedThisSession: const {},
  );

  final List<QueueEntry> entries;
  final Set<String> deletesCheckedThisSession;

  QueueEntry? entry(String opId) {
    for (final entry in entries) {
      if (entry.opId == opId) return entry;
    }
    return null;
  }

  CloudQueue withEntries(List<QueueEntry> entries) => CloudQueue(
    entries: entries,
    deletesCheckedThisSession: deletesCheckedThisSession,
  );

  CloudQueue withChecks(Set<String> checked) =>
      CloudQueue(entries: entries, deletesCheckedThisSession: checked);
}

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

bool _isOpen(PendingState state) => switch (state) {
  Unsent() || Claimed() || ServerRefused() => true,
  Accepted() => false,
};

Map<String, List<Hold>> holdsOf(CloudQueue queue, DateTime now) {
  final holds = <String, List<Hold>>{};
  final openByTarget = <Target, String>{};
  final openPageAdd = <String, String>{};
  final openPageDelete = <String, String>{};
  String? openRenumbering;
  String? openPagePatch;
  for (final entry in queue.entries) {
    if (entry is! PendingOp) continue;
    final op = entry.op;
    final target = targetOf(op);
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
      for (final page in pagesNeeded(op)) {
        if (openPageAdd[page] case final add?) {
          found.add(BehindPageAdd(add, page));
        }
        if (op is! PageDeleteOp) {
          if (openPageDelete[page] case final delete?) {
            found.add(BehindPageDelete(delete, page));
          }
        }
      }
      if (delivery case AnswerUnknown(
        retryAt: RetryAfter(:final at),
      ) when at.isAfter(now)) {
        found.add(UntilRetryTime(at));
      }
      if ((op, entry.check) case (
        PageDeleteOp(:final pagePublicId),
        CheckAgainst(),
      ) when !queue.deletesCheckedThisSession.contains(entry.opId)) {
        found.add(AwaitingPageRead(pagePublicId));
      }
      if (found.isNotEmpty) holds[entry.opId] = found;
    }
    if (_isOpen(entry.state)) {
      openByTarget[target] = entry.opId;
      switch (op) {
        case PageAddOp(:final pagePublicId):
          openPageAdd[pagePublicId] = entry.opId;
          openRenumbering = entry.opId;
        case PageDeleteOp(:final pagePublicId):
          openPageDelete[pagePublicId] = entry.opId;
          openRenumbering = entry.opId;
        case PageReorderOp():
          openRenumbering = entry.opId;
        case PagePatchOp():
          openPagePatch = entry.opId;
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

final class LandedBeforeStrategyDeleted extends RemovalCause {
  const LandedBeforeStrategyDeleted();

  @override
  bool operator ==(Object other) => other is LandedBeforeStrategyDeleted;

  @override
  int get hashCode => (LandedBeforeStrategyDeleted).hashCode;

  @override
  String toString() => 'LandedBeforeStrategyDeleted';
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

enum Landing { notLanded, mayHaveLanded }

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
  NoneClaimed(List<String> opIds) : opIds = List.unmodifiable(opIds);

  final List<String> opIds;

  @override
  String toString() => 'NoneClaimed($opIds)';
}

final class OpIdTaken extends Inapplicable {
  const OpIdTaken(this.opId);

  final String opId;

  @override
  String toString() => 'OpIdTaken($opId)';
}

Landing landingOf(QueueEntry entry) => switch (entry) {
  RetiredOp() => Landing.notLanded,
  PendingOp(state: Unsent(delivery: NeverSent())) => Landing.notLanded,
  PendingOp(state: Unsent(delivery: AnswerUnknown()) || Claimed()) =>
    Landing.mayHaveLanded,
  PendingOp(state: ServerRefused()) => Landing.notLanded,
  PendingOp(state: Accepted()) => Landing.mayHaveLanded,
};

Go _goFor(StrategyOp op) => switch (cloudSizeOf(op)) {
  WithinPolicy() => const Free(),
  OverPolicy() => const NeedsUser(Oversized()),
};

AnswerUnknown _cut(Unclaimed before, SendCut cause, int added, RetryAt at) =>
    switch (before) {
      NeverSent() => AnswerUnknown(failures: added, retryAt: at, cause: cause),
      AnswerUnknown(:final failures) => AnswerUnknown(
        failures: failures + added,
        retryAt: at,
        cause: cause,
      ),
    };

final class _Edit {
  _Edit(CloudQueue queue)
    : entries = [...queue.entries],
      checked = {...queue.deletesCheckedThisSession};

  final List<QueueEntry> entries;
  final Set<String> checked;
  final effects = <QueueEffect>[];

  int indexOf(String opId) => entries.indexWhere((e) => e.opId == opId);

  QueueEntry? operator [](String opId) => switch (indexOf(opId)) {
    -1 => null,
    final index => entries[index],
  };

  void put(PendingOp entry) => entries[indexOf(entry.opId)] = entry;

  void remove(String opId, RemovalCause cause) {
    entries.removeAt(indexOf(opId));
    checked.remove(opId);
    effects.add(OpRemoved(opId, cause));
  }

  CloudQueue get queue =>
      CloudQueue(entries: entries, deletesCheckedThisSession: checked);

  Stepped get done => Stepped(queue, effects);
}

Step transition(CloudQueue queue, QueueEvent event, {required DateTime now}) {
  final edit = _Edit(queue);
  switch (event) {
    case UserEdited(edit: final change, :final clientId):
      if (queue.entry(change.op.opId) != null) {
        return NotApplicable(OpIdTaken(change.op.opId));
      }
      return Stepped(
        queue.withEntries([
          ...queue.entries,
          PendingOp(
            op: change.op,
            clientId: clientId,
            check: switch (change) {
              PlainEdit() => const NoCheck(),
              PageDeleteEdit(:final seen) => CheckAgainst(seen),
            },
            state: Unsent(const NeverSent(), _goFor(change.op)),
          ),
        ]),
        const [],
      );
    case BatchClaimed(:final opIds):
      final holds = holdsOf(queue, now);
      for (final opId in opIds) {
        switch (edit[opId]) {
          case null:
            return NotApplicable(NoSuchOp(opId));
          case PendingOp(state: Unsent(:final delivery, go: Free())) &&
              final PendingOp entry:
            if (holds[opId] case final held?) {
              return NotApplicable(HeldBack(opId, held));
            }
            edit.put(entry.copyWith(state: Claimed(delivery)));
          case final entry:
            return NotApplicable(NotInThatState(entry));
        }
      }
      return edit.done;
    case ClaimReleased(:final opIds):
      return _eachClaimed(
        edit,
        opIds,
        (entry, before) => entry.copyWith(state: Unsent(before, const Free())),
      );
    case TransportFailed(:final opIds, :final failure, :final at):
      return _eachClaimed(edit, opIds, (entry, before) {
        final cut = _cut(before, TransportCut(failure), 1, const RetryNow());
        final retried = AnswerUnknown(
          failures: cut.failures,
          retryAt: RetryAfter(retryTimeAfter(at, cut.failures)),
          cause: cut.cause,
        );
        return entry.copyWith(
          state: Unsent(
            retried,
            retried.failures >= retriesBeforePause
                ? const Paused(PauseReason.retriesExhausted)
                : const Free(),
          ),
        );
      });
    case BatchRefused(:final opIds, :final refusal):
      final back = _eachClaimed(
        edit,
        opIds,
        (entry, before) => entry.copyWith(
          state: Unsent(before, switch (refusal) {
            BatchRefusal.upgradeRequired => const Paused(
              PauseReason.upgradeRequired,
            ),
            BatchRefusal.editAccessRemoved => const Paused(
              PauseReason.editAccessRemoved,
            ),
            BatchRefusal.unauthenticated ||
            BatchRefusal.strategyDeleted => const Free(),
          }),
        ),
      );
      if (back is NotApplicable) return back;
      switch (refusal) {
        case BatchRefusal.upgradeRequired:
          edit.effects.add(const HoldSendingForUpgrade());
        case BatchRefusal.unauthenticated:
          edit.effects.add(const ReportUnauthenticated());
        case BatchRefusal.editAccessRemoved:
          _pauseAll(edit, PauseReason.editAccessRemoved);
        case BatchRefusal.strategyDeleted:
          _strategyGone(edit);
      }
      return edit.done;
    case OpAnswered(:final answer):
      return _answered(edit, answer);
    case AppRestarted():
      for (final entry in [...edit.entries]) {
        switch (entry) {
          case PendingOp(state: Claimed(:final before)):
            edit.put(
              entry.copyWith(
                state: Unsent(
                  _cut(
                    before,
                    const AppClosedWhileSending(),
                    0,
                    const RetryNow(),
                  ),
                  const Free(),
                ),
              ),
            );
          case PendingOp(
            state: Unsent(
              :final delivery,
              go: Paused(reason: PauseReason.upgradeRequired),
            ),
          ):
            edit.put(entry.copyWith(state: Unsent(delivery, const Free())));
          case _:
            break;
        }
      }
      edit.checked.clear();
      return edit.done;
    case ConnectionLost() || AccountChanged():
      edit.checked.clear();
      return edit.done;
    case ConnectionReturned():
      return edit.done;
    case UserRetried(:final opId):
      return switch (edit[opId]) {
        null => NotApplicable(NoSuchOp(opId)),
        PendingOp(state: Unsent(:final delivery, go: Paused())) &&
            final PendingOp entry =>
          (edit..put(
                entry.copyWith(
                  state: Unsent(switch (delivery) {
                    NeverSent() => delivery,
                    AnswerUnknown(:final cause) => AnswerUnknown(
                      failures: 0,
                      retryAt: const RetryNow(),
                      cause: cause,
                    ),
                  }, const Free()),
                ),
              ))
              .done,
        final entry => NotApplicable(NotInThatState(entry)),
      };
    case UserKeptMine(:final opId, :final replacement):
      final entry = edit[opId];
      if (entry == null) return NotApplicable(NoSuchOp(opId));
      if (!_userMayReplace(entry)) return NotApplicable(NotInThatState(entry));
      if (edit[replacement.opId] != null) {
        return NotApplicable(OpIdTaken(replacement.opId));
      }
      edit.entries[edit.indexOf(opId)] = PendingOp(
        op: replacement,
        clientId: entry.clientId,
        check: const NoCheck(),
        state: Unsent(const NeverSent(), _goFor(replacement)),
      );
      edit.checked.remove(opId);
      edit.effects.add(
        OpRemoved(
          opId,
          RemovedByUser(UserRemoval.replacedByKeepMine, landingOf(entry)),
        ),
      );
      return edit.done;
    case UserUsedCloud(:final opId):
      final entry = edit[opId];
      if (entry == null) return NotApplicable(NoSuchOp(opId));
      if (!_userMayReplace(entry)) return NotApplicable(NotInThatState(entry));
      edit.remove(opId, RemovedByUser(UserRemoval.usedCloud, landingOf(entry)));
      return edit.done;
    case UserDeletedAnyway(:final opId):
      return switch (edit[opId]) {
        null => NotApplicable(NoSuchOp(opId)),
        PendingOp(
              state: Unsent(
                :final delivery,
                go: NeedsUser(reason: HeldPageDelete()),
              ),
            ) &&
            final PendingOp entry =>
          (edit..put(
                entry.copyWith(
                  check: const NoCheck(),
                  state: Unsent(delivery, const Free()),
                ),
              ))
              .done,
        final entry => NotApplicable(NotInThatState(entry)),
      };
    case UserDiscarded(:final opId):
      final entry = edit[opId];
      if (entry == null) return NotApplicable(NoSuchOp(opId));
      final discardable = switch (entry) {
        RetiredOp() => true,
        PendingOp(state: Unsent(go: Paused() || NeedsUser())) => true,
        PendingOp(state: ServerRefused()) => true,
        PendingOp(state: Unsent(go: Free()) || Claimed() || Accepted()) =>
          false,
      };
      if (!discardable) return NotApplicable(NotInThatState(entry));
      edit.remove(opId, RemovedByUser(UserRemoval.discarded, landingOf(entry)));
      return edit.done;
    case WorkNoLongerFits(:final opId, :final serverRevision):
      return switch (edit[opId]) {
        null => NotApplicable(NoSuchOp(opId)),
        PendingOp(
              state: Unsent(delivery: NeverSent(), go: Free() || Paused()),
            ) &&
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

bool _userMayReplace(QueueEntry entry) => switch (entry) {
  PendingOp(state: ServerRefused()) => true,
  PendingOp(
    state: Unsent(delivery: NeverSent(), go: NeedsUser(reason: NoLongerFits())),
  ) =>
    true,
  _ => false,
};

Step _eachClaimed(
  _Edit edit,
  List<String> opIds,
  PendingOp Function(PendingOp entry, Unclaimed before) next,
) {
  var claimed = 0;
  for (final opId in opIds) {
    if (edit[opId]
        case PendingOp(state: Claimed(:final before)) &&
            final PendingOp entry) {
      edit.put(next(entry, before));
      claimed++;
    }
  }
  return claimed == 0 ? NotApplicable(NoneClaimed(opIds)) : edit.done;
}

void _pauseAll(_Edit edit, PauseReason reason) {
  for (final entry in [...edit.entries]) {
    if (entry case PendingOp(state: Unsent(:final delivery, go: Free()))) {
      edit.put(entry.copyWith(state: Unsent(delivery, Paused(reason))));
    }
  }
}

void _strategyGone(_Edit edit) {
  for (final entry in [...edit.entries]) {
    switch (entry) {
      case PendingOp(state: Accepted()):
        edit.remove(entry.opId, const LandedBeforeStrategyDeleted());
      case PendingOp(state: Unsent(:final delivery)):
        edit.put(
          entry.copyWith(
            state: Unsent(delivery, const NeedsUser(StrategyDeleted())),
          ),
        );
      case PendingOp(state: Claimed() || ServerRefused()) || RetiredOp():
        break;
    }
  }
}

Step _answered(_Edit edit, OpAnswer answer) {
  final entry = edit[answer.opId];
  switch (entry) {
    case null:
      return NotApplicable(NoSuchOp(answer.opId));
    case PendingOp(state: Claimed() || Unsent(delivery: AnswerUnknown())):
      break;
    case _:
      return NotApplicable(NotInThatState(entry));
  }
  switch (answer) {
    case AppliedAnswer(:final revision) ||
        NoopAnswer(
          :final revision,
          replay: NoopReplay.appliedWhenFirstReceived,
        ):
      edit.put(entry.copyWith(state: Accepted(revision)));
      _rebaseFollower(edit, entry, revision);
      _advanceSeen(edit, entry.op, revision);
    case NoopAnswer(:final revision, replay: NoopReplay.notApplied):
      edit.put(entry.copyWith(state: Accepted(revision)));
    case NoopWithoutRevision():
      edit.remove(entry.opId, const NothingToWaitFor());
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

void _rebaseFollower(_Edit edit, PendingOp landed, int revision) {
  final target = targetOf(landed.op);
  for (final entry in edit.entries.skip(edit.indexOf(landed.opId) + 1)) {
    if (entry is! PendingOp || targetOf(entry.op) != target) continue;
    if (entry.state case Unsent(delivery: NeverSent())) {
      final moved = rebased(entry.op, revision);
      if (moved != entry.op) {
        edit.put(entry.copyWith(op: moved));
        edit.effects.add(OpRebased(entry.opId, revision));
      }
    }
    return;
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
  StrategyOp op,
  int revision,
) {
  if (op case PagePatchOp(:final pagePublicId, :final name, :final isAttack)) {
    if (pagePublicId != deletedPage) return seen;
    return SeenPage(
      name: name ?? seen.name,
      isAttack: isAttack ?? seen.isAttack,
      content: seen.content,
    );
  }
  final part = _partOf(op);
  final content = seen.content;
  if (part == null || content is! ContentSeen) return seen;
  if (part is SeenSettings && !pagesNeeded(op).contains(deletedPage)) {
    return seen;
  }
  final before = content.revisions[part];
  final isNew =
      before == null &&
      (op is ElementAddOp || op is LineupGroupAddOp) &&
      pagesNeeded(op).contains(deletedPage);
  if (before != revision - 1 && !isNew) return seen;
  return SeenPage(
    name: seen.name,
    isAttack: seen.isAttack,
    content: ContentSeen({
      for (final entry in content.revisions.entries)
        if (entry.key != part) entry.key: entry.value,
      if (op is! ElementDeleteOp && op is! LineupGroupDeleteOp) part: revision,
    }),
  );
}

void _advanceSeen(_Edit edit, StrategyOp op, int revision) {
  for (final entry in [...edit.entries]) {
    if (entry case PendingOp(
      op: PageDeleteOp(:final pagePublicId),
      check: CheckAgainst(:final seen),
    )) {
      final after = _seenAfter(seen, pagePublicId, op, revision);
      if (after != seen) edit.put(entry.copyWith(check: CheckAgainst(after)));
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

R? _first<R extends Row>(Iterable<R> rows, bool Function(R row) match) {
  for (final row in rows) {
    if (match(row)) return row;
  }
  return null;
}

Row? _shownRow(ArrivedBase base, Target target) => switch ((base, target)) {
  (HeaderRead(:final strategy), StrategyTarget()) => strategy,
  (HeaderRead(:final pages), PageTarget(:final pagePublicId)) =>
    _first<PageRow>(pages, (row) => row.publicId == pagePublicId),
  (HeaderRead(:final settings), SettingsTarget(:final pagePublicId)) =>
    _first<PageSettingsRow>(
      settings,
      (row) => row.pagePublicId == pagePublicId,
    ),
  (PageRead(:final page), PageTarget(:final pagePublicId))
      when page.publicId == pagePublicId =>
    page,
  (PageRead(:final settings), SettingsTarget(:final pagePublicId))
      when settings.pagePublicId == pagePublicId =>
    settings,
  (PageRead(:final elements), ElementTarget(:final elementPublicId)) =>
    _first<ElementRow>(elements, (row) => row.publicId == elementPublicId),
  (PageRead(:final lineupGroups), LineupTarget(:final lineupPublicId)) =>
    _first<LineupGroupRow>(
      lineupGroups,
      (row) => row.publicId == lineupPublicId,
    ),
  _ => null,
};

bool _acknowledges(ArrivedBase base, StrategyOp op, int revision) =>
    switch (_shownRow(base, targetOf(op))) {
      final row? => switch (_revisionOf(row)) {
        final shown? => shown >= revision,
        null => false,
      },
      null => false,
    };

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

void _baseArrived(_Edit edit, ArrivedBase base) {
  if (base is StrategyGone) {
    _strategyGone(edit);
    return;
  }
  for (final entry in [...edit.entries]) {
    if (entry is! PendingOp) continue;
    switch (entry.state) {
      case Accepted(:final revision)
          when _acknowledges(base, entry.op, revision):
        edit.remove(entry.opId, const SeenInBase());
      case Unsent(:final delivery, go: Free() || Paused()):
        switch ((entry.op, entry.check, base)) {
          case (
                PageDeleteOp(:final pagePublicId),
                CheckAgainst(:final seen),
                final PageRead read,
              )
              when read.page.publicId == pagePublicId:
            switch (_checkDelete(seen, read)) {
              case _Unchanged():
                edit.checked.add(entry.opId);
              case _Held(:final cause):
                edit.checked.remove(entry.opId);
                edit.put(
                  entry.copyWith(
                    state: Unsent(delivery, NeedsUser(HeldPageDelete(cause))),
                  ),
                );
            }
          case (
                PageDeleteOp(:final pagePublicId),
                CheckAgainst(),
                PageGone(pagePublicId: final gone),
              )
              when gone == pagePublicId:
            edit.checked.add(entry.opId);
          case _:
            break;
        }
      case _:
        break;
    }
  }
}
