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

  Authored get authored;
}

final class PlainEdit extends Edit {
  const PlainEdit._(this.op, this.scope, this.authored);

  @override
  final StrategyOp op;
  @override
  final Scope scope;
  @override
  final Authored authored;
}

final class PageDeleteEdit extends Edit {
  const PageDeleteEdit(this.op, this.seen, this.authored);

  @override
  final PageDeleteOp op;
  final SeenPage seen;
  @override
  final Authored authored;

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

final class NeedsFieldBase extends EditMaking {
  const NeedsFieldBase(this.op);

  final StrategyOp op;
}

final class CopyMustBeExpanded extends EditMaking {
  const CopyMustBeExpanded(this.op);

  final PageAddOp op;
}

final class NeedsPageDeleteEdit extends EditMaking {
  const NeedsPageDeleteEdit(this.op);

  final PageDeleteOp op;
}

EditMaking editOf(
  StrategyOp op, {
  required Authored authored,
  String? rowPage,
}) => switch ((op, rowPage)) {
  (
    ElementPatchOp(merge: FieldMerge(base: null)) ||
        LineupGroupPatchOp(merge: FieldMerge(base: null)),
    _,
  ) =>
    NeedsFieldBase(op),
  (final PageAddOp copy && PageAddOp(copyContentFromPagePublicId: _?), _) =>
    CopyMustBeExpanded(copy),
  (StrategyPatchOp(), _) => EditMade(
    PlainEdit._(op, const StrategyWide(), authored),
  ),
  (final PageDeleteOp delete, _) => NeedsPageDeleteEdit(delete),
  (
    PageAddOp(:final pagePublicId) ||
        PagePatchOp(:final pagePublicId) ||
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
    EditMade(PlainEdit._(op, OnPage(pagePublicId), authored)),
  (
    ElementPatchOp(pagePublicId: final to) ||
        LineupGroupPatchOp(pagePublicId: final to),
    final from?,
  ) =>
    EditMade(
      PlainEdit._(
        op,
        to == null || to == from ? OnPage(from) : Moving(from: from, to: to),
        authored,
      ),
    ),
  (ElementPatchOp() || LineupGroupPatchOp(), null) => NeedsRowPage(op),
};

final class BatchClaimed extends QueueEvent {
  BatchClaimed({
    required this.clientId,
    required List<String> opIds,
    required this.at,
  }) : opIds = List.unmodifiable(opIds);

  final String clientId;
  final List<String> opIds;
  final DateTime at;
}

final class ClaimReleased extends QueueEvent {
  const ClaimReleased(this.attempt);

  final int attempt;
}

final class OpAnswered extends QueueEvent {
  const OpAnswered(this.attempt, this.answer);

  final int attempt;
  final OpAnswer answer;
}

final class TransportFailed extends QueueEvent {
  const TransportFailed(this.attempt, this.failure, {required this.at});

  final int attempt;
  final TransportFailure failure;
  final DateTime at;
}

final class BatchRefused extends QueueEvent {
  const BatchRefused(this.attempt, this.refusal);

  final int attempt;
  final BatchRefusal refusal;
}

final class AppRestarted extends QueueEvent {
  const AppRestarted({required this.build});

  final String build;
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
  const EditAccessConfirmed({required this.afterAttempt});

  final int afterAttempt;
}

sealed class UserAction extends QueueEvent {
  const UserAction(this.opId);

  final String opId;
}

final class UserRetried extends UserAction {
  const UserRetried(super.opId);
}

final class UserKeptMine extends UserAction {
  const UserKeptMine(super.opId, this.replacement, {required this.authored});

  final StrategyOp replacement;
  final Authored authored;
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
  const BaseArrived(this.base, {required this.session});

  final ArrivedBase base;
  final int session;
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
    required List<ElementRow> elements,
    required List<LineupGroupRow> lineupGroups,
  }) : elements = List.unmodifiable(elements),
       lineupGroups = List.unmodifiable(lineupGroups);

  final PageRow page;
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
