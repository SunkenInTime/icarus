import '../ops.dart';
import '../outcome.dart';
import '../rows.dart';
import 'pending.dart';

sealed class QueueEvent {
  const QueueEvent();
}

final class UserEdited extends QueueEvent {
  const UserEdited(this.edit, {required this.clientId});

  final Edit edit;
  final String clientId;
}

sealed class Edit {
  const Edit();

  StrategyOp get op;
}

final class PlainEdit extends Edit {
  const PlainEdit(this.op);

  @override
  final StrategyOp op;
}

final class PageDeleteEdit extends Edit {
  const PageDeleteEdit(this.op, this.seen);

  @override
  final PageDeleteOp op;
  final SeenPage seen;
}

final class BatchClaimed extends QueueEvent {
  BatchClaimed(List<String> opIds) : opIds = List.unmodifiable(opIds);

  final List<String> opIds;
}

final class ClaimReleased extends QueueEvent {
  ClaimReleased(List<String> opIds) : opIds = List.unmodifiable(opIds);

  final List<String> opIds;
}

final class OpAnswered extends QueueEvent {
  const OpAnswered(this.answer);

  final OpAnswer answer;
}

final class TransportFailed extends QueueEvent {
  TransportFailed(List<String> opIds, this.failure, {required this.at})
    : opIds = List.unmodifiable(opIds);

  final List<String> opIds;
  final TransportFailure failure;
  final DateTime at;
}

final class BatchRefused extends QueueEvent {
  BatchRefused(List<String> opIds, this.refusal)
    : opIds = List.unmodifiable(opIds);

  final List<String> opIds;
  final BatchRefusal refusal;
}

enum BatchRefusal {
  upgradeRequired,
  unauthenticated,
  editAccessRemoved,
  strategyDeleted,
}

final class AppRestarted extends QueueEvent {
  const AppRestarted();
}

final class ConnectionLost extends QueueEvent {
  const ConnectionLost();
}

final class ConnectionReturned extends QueueEvent {
  const ConnectionReturned();
}

final class AccountChanged extends QueueEvent {
  const AccountChanged();
}

sealed class UserAction extends QueueEvent {
  const UserAction(this.opId);

  final String opId;
}

final class UserRetried extends UserAction {
  const UserRetried(super.opId);
}

final class UserKeptMine extends UserAction {
  const UserKeptMine(super.opId, this.replacement);

  final StrategyOp replacement;
}

final class UserUsedCloud extends UserAction {
  const UserUsedCloud(super.opId);
}

final class UserDeletedAnyway extends UserAction {
  const UserDeletedAnyway(super.opId);
}

final class UserDiscarded extends UserAction {
  const UserDiscarded(super.opId);
}

final class BaseArrived extends QueueEvent {
  const BaseArrived(this.base);

  final ArrivedBase base;
}

final class WorkNoLongerFits extends QueueEvent {
  const WorkNoLongerFits(this.opId, {required this.serverRevision});

  final String opId;
  final int serverRevision;
}

sealed class OpAnswer {
  const OpAnswer(this.opId);

  final String opId;
}

final class AppliedAnswer extends OpAnswer {
  const AppliedAnswer(super.opId, {required this.revision});

  final int revision;
}

final class NoopAnswer extends OpAnswer {
  const NoopAnswer(super.opId, {required this.revision, required this.replay});

  final int revision;
  final NoopReplay replay;
}

enum NoopReplay { appliedWhenFirstReceived, notApplied }

final class NoopWithoutRevision extends OpAnswer {
  const NoopWithoutRevision(super.opId);
}

final class RejectedAnswer extends OpAnswer {
  const RejectedAnswer(super.opId, this.reason, this.current);

  final RejectionReason reason;
  final ServerCopy current;
}

final class FailedAnswer extends OpAnswer {
  const FailedAnswer(super.opId, this.code, this.message);

  final ServerFailure code;
  final String message;
}

sealed class ArrivedBase {
  const ArrivedBase();
}

final class HeaderRead extends ArrivedBase {
  HeaderRead({
    required this.strategy,
    required List<PageRow> pages,
    required List<PageSettingsRow> settings,
  }) : pages = List.unmodifiable(pages),
       settings = List.unmodifiable(settings);

  final StrategyRow strategy;
  final List<PageRow> pages;
  final List<PageSettingsRow> settings;
}

final class PageRead extends ArrivedBase {
  PageRead({
    required this.page,
    required this.settings,
    required List<ElementRow> elements,
    required List<LineupGroupRow> lineupGroups,
  }) : elements = List.unmodifiable(elements),
       lineupGroups = List.unmodifiable(lineupGroups);

  final PageRow page;
  final PageSettingsRow settings;
  final List<ElementRow> elements;
  final List<LineupGroupRow> lineupGroups;
}

final class PageGone extends ArrivedBase {
  const PageGone(this.pagePublicId);

  final String pagePublicId;
}

final class StrategyGone extends ArrivedBase {
  const StrategyGone();
}
