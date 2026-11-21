import '../ops.dart';

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

Folding fold(StrategyOp first, StrategyOp then) {
  final opId = then.opId;
  switch ((first, then)) {
    case (final ElementAddOp a, final ElementPatchOp b)
        when (b.merge == null || b.merge!.base == null) &&
            b.payload != null &&
            b.pagePublicId == null:
      return FoldedOp(
        ElementAddOp(
          opId: opId,
          elementPublicId: a.elementPublicId,
          pagePublicId: a.pagePublicId,
          payload: b.payload!,
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
            b.payload != null &&
            a.pagePublicId == null &&
            b.pagePublicId == null:
      return FoldedOp(
        ElementPatchOp(
          opId: opId,
          elementPublicId: a.elementPublicId,
          expectedElementRevision: a.expectedElementRevision,
          payload: b.payload,
          sortIndex: switch ((a.merge, b.merge)) {
            (final first?, final then?)
                when !first.fields.contains(placeField) &&
                    !then.fields.contains(placeField) =>
              b.sortIndex ?? a.sortIndex,
            (final first?, _) when first.fields.contains(placeField) =>
              _placeOf(a.sortIndex, b.sortIndex, b.merge),
            _ => b.sortIndex ?? a.sortIndex,
          },
          merge: FieldMerge(
            fields: {...a.merge!.fields, ...b.merge!.fields}.toList(),
            base: switch ((a.merge!.base, b.merge!.base)) {
              (final first?, final then?) => {
                for (final MapEntry(:key, :value) in then.entries)
                  if (!a.merge!.fields.contains(key)) key: value,
                ...first.toJson(),
              },
              _ => null,
            },
          ),
        ),
      );
    case (final LineupGroupAddOp a, final LineupGroupPatchOp b)
        when b.merge == null && b.payload != null && b.pagePublicId == null:
      return FoldedOp(
        LineupGroupAddOp(
          opId: opId,
          lineupPublicId: a.lineupPublicId,
          pagePublicId: a.pagePublicId,
          payload: b.payload!,
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
