import '../json.dart';
import '../ops.dart';
import '../payloads.dart';

sealed class Folding {
  const Folding();
}

final class FoldedOp extends Folding {
  const FoldedOp(this.op);

  final StrategyOp op;
}

final class CancelsOut extends Folding {
  const CancelsOut();
}

final class KeptApart extends Folding {
  const KeptApart();
}

int? _placeOf(int? first, int? then, FieldMerge? merge) =>
    merge != null && !merge.fields.contains(placeField) ? first : then ?? first;

Map<String, Object?> _named(
  JsonObject into,
  JsonObject from,
  Iterable<String> fields,
) {
  final data = into.toJson();
  for (final field in fields) {
    if (field == placeField) continue;
    if (from.containsKey(field)) {
      data[field] = plainJson(from[field]);
    } else {
      data.remove(field);
    }
  }
  return data;
}

ElementPayload _elementPayload(
  ElementPayload into,
  ElementPayload from,
  FieldMerge? merge,
) => merge == null
    ? from
    : into.withData(_named(into.data, from.data, merge.fields));

LineupGroupPayload _lineupPayload(
  LineupGroupPayload into,
  LineupGroupPayload from,
  FieldMerge? merge,
) => merge == null
    ? from
    : into.withData(_named(into.data, from.data, merge.fields));

Folding fold(StrategyOp first, StrategyOp then) {
  final opId = then.opId;
  switch ((first, then)) {
    case (final ElementAddOp a, final ElementPatchOp b)
        when b.payload != null && b.pagePublicId == null:
      return FoldedOp(
        ElementAddOp(
          opId: opId,
          elementPublicId: a.elementPublicId,
          pagePublicId: a.pagePublicId,
          payload: _elementPayload(a.payload, b.payload!, b.merge),
          sortIndex: _placeOf(a.sortIndex, b.sortIndex, b.merge)!,
          expectedElementRevision: a.expectedElementRevision,
        ),
      );
    case (final ElementAddOp a, ElementDeleteOp())
        when a.expectedElementRevision == null:
      return const CancelsOut();
    case (final ElementPatchOp a, final ElementPatchOp b)
        when a.merge == null &&
            b.merge == null &&
            b.payload != null &&
            a.pagePublicId == null &&
            b.pagePublicId == null:
      return FoldedOp(
        ElementPatchOp(
          opId: opId,
          elementPublicId: a.elementPublicId,
          expectedElementRevision: a.expectedElementRevision,
          payload: b.payload,
          sortIndex: b.sortIndex ?? a.sortIndex,
        ),
      );
    case (final ElementPatchOp a, final ElementPatchOp b)
        when a.merge != null &&
            b.merge != null &&
            (a.merge!.base == null) == (b.merge!.base == null) &&
            a.merge!.fields.toSet().containsAll(b.merge!.fields) &&
            b.payload != null &&
            a.pagePublicId == null &&
            b.pagePublicId == null:
      return FoldedOp(
        ElementPatchOp(
          opId: opId,
          elementPublicId: a.elementPublicId,
          expectedElementRevision: a.expectedElementRevision,
          payload: a.payload == null
              ? b.payload
              : _elementPayload(a.payload!, b.payload!, b.merge),
          sortIndex: b.merge!.fields.contains(placeField)
              ? b.sortIndex ?? a.sortIndex
              : a.sortIndex,
          merge: a.merge,
        ),
      );
    case (final LineupGroupAddOp a, final LineupGroupPatchOp b)
        when b.merge == null && b.payload != null && b.pagePublicId == null:
      return FoldedOp(
        LineupGroupAddOp(
          opId: opId,
          lineupPublicId: a.lineupPublicId,
          pagePublicId: a.pagePublicId,
          payload: _lineupPayload(a.payload, b.payload!, b.merge),
          sortIndex: b.sortIndex ?? a.sortIndex,
          expectedLineupRevision: a.expectedLineupRevision,
        ),
      );
    case (final LineupGroupAddOp a, LineupGroupDeleteOp())
        when a.expectedLineupRevision == null:
      return const CancelsOut();
    case (final LineupGroupPatchOp a, final LineupGroupPatchOp b)
        when a.merge == null &&
            b.merge == null &&
            b.payload != null &&
            a.pagePublicId == null &&
            b.pagePublicId == null:
      return FoldedOp(
        LineupGroupPatchOp(
          opId: opId,
          lineupPublicId: a.lineupPublicId,
          expectedLineupRevision: a.expectedLineupRevision,
          payload: b.payload,
          sortIndex: b.sortIndex ?? a.sortIndex,
        ),
      );
    case _:
      return const KeptApart();
  }
}
