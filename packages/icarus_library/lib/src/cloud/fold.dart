import '../field_merge.dart';
import '../ops.dart';

sealed class Folding {
  const Folding();
}

final class FoldedOp extends Folding {
  const FoldedOp(this.op);

  final StrategyOp op;
}

final class KeptApart extends Folding {
  const KeptApart();
}

bool _sameFields(FieldMerge first, FieldMerge then) =>
    first.fields.toSet().containsAll(then.fields) &&
    then.fields.toSet().containsAll(first.fields) &&
    (first.base == null) == (then.base == null);

Folding fold(StrategyOp first, StrategyOp then) => switch ((first, then)) {
  (
    final ElementPatchOp a &&
        ElementPatchOp(merge: final am?, payload: final into?),
    final ElementPatchOp b &&
        ElementPatchOp(merge: final bm?, payload: final from?),
  )
      when _sameFields(am, bm) &&
          a.elementPublicId == b.elementPublicId &&
          a.pagePublicId == null &&
          b.pagePublicId == null =>
    FoldedOp(
      ElementPatchOp(
        opId: b.opId,
        elementPublicId: a.elementPublicId,
        expectedElementRevision: a.expectedElementRevision,
        payload: elementWithNamedFields(into, from, am),
        sortIndex: am.fields.contains(placeField) ? b.sortIndex : a.sortIndex,
        merge: am,
      ),
    ),
  (
    final LineupGroupPatchOp a &&
        LineupGroupPatchOp(merge: final am?, payload: final into?),
    final LineupGroupPatchOp b &&
        LineupGroupPatchOp(merge: final bm?, payload: final from?),
  )
      when _sameFields(am, bm) &&
          a.lineupPublicId == b.lineupPublicId &&
          a.pagePublicId == null &&
          b.pagePublicId == null =>
    switch (lineupWithNamedFields(into, from, am)) {
      Merged(value: final payload) => FoldedOp(
        LineupGroupPatchOp(
          opId: b.opId,
          lineupPublicId: a.lineupPublicId,
          expectedLineupRevision: a.expectedLineupRevision,
          payload: payload,
          sortIndex: am.fields.contains(placeField) ? b.sortIndex : a.sortIndex,
          merge: am,
        ),
      ),
      WriteWhole() || MergeConflict() => const KeptApart(),
    },
  _ => const KeptApart(),
};
