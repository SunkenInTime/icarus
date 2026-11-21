import '../ops.dart';
import '../outcome.dart';
import '../rows.dart';
import 'pending.dart';

sealed class QueueEvent {
  const QueueEvent();
}

final class UserEdited extends QueueEvent {
  const UserEdited(this.edit);

  final Edit edit;
}

sealed class Edit {
  const Edit();

  StrategyOp get op;

  Scope get scope;
}

final class PlainEdit extends Edit {
  const PlainEdit._(this.op, this.scope);

  @override
  final StrategyOp op;
  @override
  final Scope scope;
}

final class PageDeleteEdit extends Edit {
  const PageDeleteEdit(this.op, this.seen);

  @override
  final PageDeleteOp op;
  final SeenPage seen;

  @override
  Scope get scope => OnPage(op.pagePublicId);
}

sealed class EditMaking {
  const EditMaking();
}

final class EditMade extends EditMaking {
  const EditMade(this.edit);

  final PlainEdit edit;
}

final class NeedsRowPage extends EditMaking {
  const NeedsRowPage(this.op);

  final StrategyOp op;
}

EditMaking editOf(StrategyOp op, {String? rowPage}) => switch ((op, rowPage)) {
  (StrategyPatchOp(), _) => EditMade(PlainEdit._(op, const StrategyWide())),
  (
    PageAddOp(:final pagePublicId) ||
        PagePatchOp(:final pagePublicId) ||
        PageDeleteOp(:final pagePublicId) ||
        PageReorderOp(:final pagePublicId) ||
        PageSettingsPatchOp(:final pagePublicId) ||
        ElementAddOp(:final pagePublicId) ||
        ElementDeleteOp(:final pagePublicId) ||
        ElementReorderOp(:final pagePublicId) ||
        LineupGroupAddOp(:final pagePublicId) ||
        LineupGroupDeleteOp(:final pagePublicId) ||
        LineupGroupReorderOp(:final pagePublicId),
    _,
  ) =>
    EditMade(PlainEdit._(op, OnPage(pagePublicId))),
  (ElementPatchOp() || LineupGroupPatchOp(), final page?) => EditMade(
    PlainEdit._(op, OnPage(page)),
  ),
  (ElementPatchOp() || LineupGroupPatchOp(), null) => NeedsRowPage(op),
};

final class BatchClaimed extends QueueEvent {
  BatchClaimed(this.attempt, List<String> opIds)
    : opIds = List.unmodifiable(opIds);

  final Attempt attempt;
  final List<String> opIds;
}

final class ClaimReleased extends QueueEvent {
  const ClaimReleased(this.attemptId);

  final String attemptId;
}

final class OpAnswered extends QueueEvent {
  const OpAnswered(this.attempt, this.answer, {required this.base});

  final Attempt attempt;
  final OpAnswer answer;
  final BaseRow base;
}

sealed class BaseRow {
  const BaseRow();
}

final class BaseHolds extends BaseRow {
  const BaseHolds(this.revision);

  final int revision;
}

final class BaseLacks extends BaseRow {
  const BaseLacks();
}

final class TransportFailed extends QueueEvent {
  const TransportFailed(this.attemptId, this.failure, {required this.at});

  final String attemptId;
  final TransportFailure failure;
  final DateTime at;
}

final class BatchRefused extends QueueEvent {
  const BatchRefused(this.attemptId, this.refusal);

  final String attemptId;
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

final class EditAccessConfirmed extends QueueEvent {
  const EditAccessConfirmed();
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

final class PageRestored extends QueueEvent {
  PageRestored(this.pagePublicId, Map<String, String> freshOpIds)
    : freshOpIds = Map.unmodifiable(freshOpIds);

  final String pagePublicId;
  final Map<String, String> freshOpIds;
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
