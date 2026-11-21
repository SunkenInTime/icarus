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

sealed class _Merging {
  const _Merging();
}

final class _Merged extends _Merging {
  const _Merged(this.merge);

  final FieldMerge? merge;
}

final class _CannotMerge extends _Merging {
  const _CannotMerge();
}

_Merging _union(FieldMerge? first, FieldMerge? second) =>
    switch ((first, second)) {
      (null, _) || (_, null) => const _Merged(null),
      (final a?, final b?) when (a.base == null) != (b.base == null) =>
        const _CannotMerge(),
      (final a?, final b?) => _Merged(
        FieldMerge(
          fields: [
            ...a.fields,
            for (final field in b.fields)
              if (!a.fields.contains(field)) field,
          ],
          base: switch ((a.base, b.base)) {
            (final baseA?, final baseB?) => {
              for (final MapEntry(:key, :value) in baseB.entries)
                if (!a.fields.contains(key)) key: value,
              ...baseA,
            },
            _ => null,
          },
        ),
      ),
    };

_Merging _withPlace(FieldMerge? merge) => switch (merge) {
  null => const _Merged(null),
  FieldMerge(:final fields) when fields.contains(placeField) => _Merged(merge),
  FieldMerge(base: null, :final fields) => _Merged(
    FieldMerge(fields: [...fields, placeField]),
  ),
  FieldMerge() => const _CannotMerge(),
};

Folding fold(StrategyOp first, StrategyOp then) {
  final opId = then.opId;
  switch ((first, then)) {
    case (final ElementAddOp a, final ElementPatchOp b):
      return FoldedOp(
        ElementAddOp(
          opId: opId,
          elementPublicId: a.elementPublicId,
          pagePublicId: b.pagePublicId ?? a.pagePublicId,
          payload: b.payload ?? a.payload,
          sortIndex: b.sortIndex ?? a.sortIndex,
          expectedElementRevision: a.expectedElementRevision,
        ),
      );
    case (final ElementAddOp a, final ElementReorderOp b):
      return FoldedOp(
        ElementAddOp(
          opId: opId,
          elementPublicId: a.elementPublicId,
          pagePublicId: b.pagePublicId,
          payload: a.payload,
          sortIndex: b.sortIndex,
          expectedElementRevision: a.expectedElementRevision,
        ),
      );
    case (ElementAddOp(), ElementDeleteOp()):
      return const CancelsOut();
    case (final ElementPatchOp a, final ElementPatchOp b):
      return switch (_union(a.merge, b.merge)) {
        _Merged(:final merge) => FoldedOp(
          ElementPatchOp(
            opId: opId,
            elementPublicId: a.elementPublicId,
            expectedElementRevision: a.expectedElementRevision,
            pagePublicId: b.pagePublicId ?? a.pagePublicId,
            payload: b.payload ?? a.payload,
            sortIndex: b.sortIndex ?? a.sortIndex,
            merge: merge,
          ),
        ),
        _CannotMerge() => const KeptApart(),
      };
    case (final ElementPatchOp a, final ElementReorderOp b):
      return switch (_withPlace(a.merge)) {
        _Merged(:final merge) => FoldedOp(
          ElementPatchOp(
            opId: opId,
            elementPublicId: a.elementPublicId,
            expectedElementRevision: a.expectedElementRevision,
            pagePublicId: b.pagePublicId,
            payload: a.payload,
            sortIndex: b.sortIndex,
            merge: merge,
          ),
        ),
        _CannotMerge() => const KeptApart(),
      };
    case (final ElementReorderOp a, final ElementPatchOp b):
      return switch (_withPlace(b.merge)) {
        _Merged(:final merge) => FoldedOp(
          ElementPatchOp(
            opId: opId,
            elementPublicId: a.elementPublicId,
            expectedElementRevision: a.expectedElementRevision,
            pagePublicId: b.pagePublicId ?? a.pagePublicId,
            payload: b.payload,
            sortIndex: b.sortIndex ?? a.sortIndex,
            merge: merge,
          ),
        ),
        _CannotMerge() => const KeptApart(),
      };
    case (final ElementReorderOp a, final ElementReorderOp b):
      return FoldedOp(
        ElementReorderOp(
          opId: opId,
          elementPublicId: a.elementPublicId,
          pagePublicId: b.pagePublicId,
          sortIndex: b.sortIndex,
          expectedElementRevision: a.expectedElementRevision,
        ),
      );
    case (final ElementPatchOp a, final ElementDeleteOp b):
      return FoldedOp(
        ElementDeleteOp(
          opId: opId,
          elementPublicId: a.elementPublicId,
          pagePublicId: b.pagePublicId,
          expectedElementRevision: a.expectedElementRevision,
          lastWriterWins: b.lastWriterWins,
        ),
      );
    case (final ElementReorderOp a, final ElementDeleteOp b):
      return FoldedOp(
        ElementDeleteOp(
          opId: opId,
          elementPublicId: a.elementPublicId,
          pagePublicId: b.pagePublicId,
          expectedElementRevision: a.expectedElementRevision,
          lastWriterWins: b.lastWriterWins,
        ),
      );
    case (final LineupGroupAddOp a, final LineupGroupPatchOp b):
      return FoldedOp(
        LineupGroupAddOp(
          opId: opId,
          lineupPublicId: a.lineupPublicId,
          pagePublicId: b.pagePublicId ?? a.pagePublicId,
          payload: b.payload ?? a.payload,
          sortIndex: b.sortIndex ?? a.sortIndex,
          expectedLineupRevision: a.expectedLineupRevision,
        ),
      );
    case (final LineupGroupAddOp a, final LineupGroupReorderOp b):
      return FoldedOp(
        LineupGroupAddOp(
          opId: opId,
          lineupPublicId: a.lineupPublicId,
          pagePublicId: b.pagePublicId,
          payload: a.payload,
          sortIndex: b.sortIndex,
          expectedLineupRevision: a.expectedLineupRevision,
        ),
      );
    case (LineupGroupAddOp(), LineupGroupDeleteOp()):
      return const CancelsOut();
    case (final LineupGroupPatchOp a, final LineupGroupPatchOp b):
      return switch (_union(a.merge, b.merge)) {
        _Merged(:final merge) => FoldedOp(
          LineupGroupPatchOp(
            opId: opId,
            lineupPublicId: a.lineupPublicId,
            expectedLineupRevision: a.expectedLineupRevision,
            pagePublicId: b.pagePublicId ?? a.pagePublicId,
            payload: b.payload ?? a.payload,
            sortIndex: b.sortIndex ?? a.sortIndex,
            merge: merge,
          ),
        ),
        _CannotMerge() => const KeptApart(),
      };
    case (final LineupGroupPatchOp a, final LineupGroupReorderOp b):
      return switch (_withPlace(a.merge)) {
        _Merged(:final merge) => FoldedOp(
          LineupGroupPatchOp(
            opId: opId,
            lineupPublicId: a.lineupPublicId,
            expectedLineupRevision: a.expectedLineupRevision,
            pagePublicId: b.pagePublicId,
            payload: a.payload,
            sortIndex: b.sortIndex,
            merge: merge,
          ),
        ),
        _CannotMerge() => const KeptApart(),
      };
    case (final LineupGroupReorderOp a, final LineupGroupPatchOp b):
      return switch (_withPlace(b.merge)) {
        _Merged(:final merge) => FoldedOp(
          LineupGroupPatchOp(
            opId: opId,
            lineupPublicId: a.lineupPublicId,
            expectedLineupRevision: a.expectedLineupRevision,
            pagePublicId: b.pagePublicId ?? a.pagePublicId,
            payload: b.payload,
            sortIndex: b.sortIndex ?? a.sortIndex,
            merge: merge,
          ),
        ),
        _CannotMerge() => const KeptApart(),
      };
    case (final LineupGroupReorderOp a, final LineupGroupReorderOp b):
      return FoldedOp(
        LineupGroupReorderOp(
          opId: opId,
          lineupPublicId: a.lineupPublicId,
          pagePublicId: b.pagePublicId,
          sortIndex: b.sortIndex,
          expectedLineupRevision: a.expectedLineupRevision,
        ),
      );
    case (final LineupGroupPatchOp a, final LineupGroupDeleteOp b):
      return FoldedOp(
        LineupGroupDeleteOp(
          opId: opId,
          lineupPublicId: a.lineupPublicId,
          pagePublicId: b.pagePublicId,
          expectedLineupRevision: a.expectedLineupRevision,
          lastWriterWins: b.lastWriterWins,
        ),
      );
    case (final LineupGroupReorderOp a, final LineupGroupDeleteOp b):
      return FoldedOp(
        LineupGroupDeleteOp(
          opId: opId,
          lineupPublicId: a.lineupPublicId,
          pagePublicId: b.pagePublicId,
          expectedLineupRevision: a.expectedLineupRevision,
          lastWriterWins: b.lastWriterWins,
        ),
      );
    case (final PageSettingsPatchOp a, final PageSettingsPatchOp b):
      return FoldedOp(
        PageSettingsPatchOp(
          opId: opId,
          pagePublicId: a.pagePublicId,
          settings: b.settings,
          expectedPageSettingsRevision: a.expectedPageSettingsRevision,
        ),
      );
    case (final PagePatchOp a, final PagePatchOp b):
      return FoldedOp(
        PagePatchOp(
          opId: opId,
          pagePublicId: a.pagePublicId,
          expectedPageRevision: a.expectedPageRevision,
          name: b.name ?? a.name,
          isAutoNamed: b.isAutoNamed ?? a.isAutoNamed,
          isAttack: b.isAttack ?? a.isAttack,
        ),
      );
    case (final StrategyPatchOp a, final StrategyPatchOp b):
      return FoldedOp(
        StrategyPatchOp(
          opId: opId,
          expectedStrategyRevision: a.expectedStrategyRevision,
          name: b.name ?? a.name,
          mapData: b.mapData ?? a.mapData,
          themeProfile: switch (b.themeProfile) {
            KeepValue() => a.themeProfile,
            final edit => edit,
          },
          themeOverridePalette: switch (b.themeOverridePalette) {
            KeepValue() => a.themeOverridePalette,
            final edit => edit,
          },
        ),
      );
    case (final PageReorderOp a, final PageReorderOp b)
        when a.pagePublicId == b.pagePublicId:
      return FoldedOp(
        PageReorderOp(
          opId: opId,
          pagePublicId: a.pagePublicId,
          sortIndex: b.sortIndex,
          expectedStrategyRevision: a.expectedStrategyRevision,
        ),
      );
    case (final PageAddOp a, final PageReorderOp b)
        when a.pagePublicId == b.pagePublicId &&
            a.copyContentFromPagePublicId == null:
      return FoldedOp(
        PageAddOp(
          opId: opId,
          pagePublicId: a.pagePublicId,
          sortIndex: b.sortIndex,
          expectedStrategyRevision: a.expectedStrategyRevision,
          name: a.name,
          isAutoNamed: a.isAutoNamed,
          isAttack: a.isAttack,
          settings: a.settings,
        ),
      );
    case _:
      return const KeptApart();
  }
}
