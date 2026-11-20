import 'ops.dart';
import 'rows.dart';

sealed class ApplyResult {
  const ApplyResult();
}

final class OpApplied extends ApplyResult {
  OpApplied({required List<RowWrite> writes, required this.undo})
    : writes = List.unmodifiable(writes);

  final List<RowWrite> writes;
  final Undo undo;

  Iterable<Row> get rows => writes.map((write) => write.after);
}

final class OpUnchanged extends ApplyResult {
  const OpUnchanged();
}

final class OpRefused extends ApplyResult {
  const OpRefused(this.refusal);

  final Refusal refusal;
}

sealed class RowWrite {
  const RowWrite();

  Row get after;

  RowKey get key => after.key;
}

final class RowAdded extends RowWrite {
  const RowAdded(this.after);

  @override
  final Row after;
}

final class RowChanged extends RowWrite {
  RowChanged({
    required this.before,
    required this.after,
    required Set<RowField> fields,
    Set<String> dataFields = const {},
  }) : fields = Set.unmodifiable(fields),
       dataFields = Set.unmodifiable(dataFields);

  final Row before;
  @override
  final Row after;
  final Set<RowField> fields;
  final Set<String> dataFields;
}

enum RowField {
  name,
  mapData,
  themeProfileId,
  themeOverridePalette,
  isAutoNamed,
  isAttack,
  sortIndex,
  deleted,
  settings,
  page,
  kind,
  payloadVersion,
}

sealed class Undo {
  const Undo();
}

final class UndoWithOp extends Undo {
  const UndoWithOp(this.op);

  final StrategyOp op;

  @override
  bool operator ==(Object other) => other is UndoWithOp && other.op == op;

  @override
  int get hashCode => op.hashCode;
}

final class UndoByRestoringPage extends Undo {
  const UndoByRestoringPage(this.pagePublicId);

  final String pagePublicId;

  @override
  bool operator ==(Object other) =>
      other is UndoByRestoringPage && other.pagePublicId == pagePublicId;

  @override
  int get hashCode => pagePublicId.hashCode;
}

final class UndoUnavailable extends Undo {
  const UndoUnavailable();
}

sealed class Refusal {
  const Refusal();
}

final class Rejected extends Refusal {
  const Rejected(this.reason);

  final RejectionReason reason;

  @override
  bool operator ==(Object other) => other is Rejected && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'Rejected(${reason.wireName})';
}

final class Failed extends Refusal {
  const Failed(this.code);

  final FailureCode code;

  @override
  bool operator ==(Object other) => other is Failed && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'Failed(${code.wireName})';
}

final class UnreadableTarget extends Refusal {
  const UnreadableTarget(this.elementPublicId);

  final String elementPublicId;

  @override
  bool operator ==(Object other) =>
      other is UnreadableTarget && other.elementPublicId == elementPublicId;

  @override
  int get hashCode => elementPublicId.hashCode;

  @override
  String toString() => 'UnreadableTarget($elementPublicId)';
}

enum RejectionReason {
  alreadyExists('already_exists'),
  deleted('deleted'),
  elementStrategyMismatch('element_strategy_mismatch'),
  lineupStrategyMismatch('lineup_strategy_mismatch'),
  missingExpectedRevision('missing_expected_revision'),
  notFound('not_found'),
  pageStrategyMismatch('page_strategy_mismatch'),
  revisionMismatch('revision_mismatch'),
  fieldConflict('field_conflict'),
  mergeInvalid('merge_invalid');

  const RejectionReason(this.wireName);

  final String wireName;
}

enum FailureCode {
  elementTypePayloadKindMismatch('ELEMENT_TYPE_PAYLOAD_KIND_MISMATCH'),
  invalidLineupPayloadData('INVALID_LINEUP_PAYLOAD_DATA'),
  invalidLineupPayloadVersion('INVALID_LINEUP_PAYLOAD_VERSION'),
  invalidOp('INVALID_OP'),
  invalidPageContentCount('INVALID_PAGE_CONTENT_COUNT'),
  invalidPayload('INVALID_PAYLOAD'),
  lineupPageMismatch('LINEUP_PAGE_MISMATCH'),
  pageDeleted('PAGE_DELETED'),
  pageStrategyMismatch('PAGE_STRATEGY_MISMATCH');

  const FailureCode(this.wireName);

  final String wireName;
}
