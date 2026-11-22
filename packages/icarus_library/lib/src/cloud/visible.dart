import '../apply.dart';
import '../ops.dart';
import '../outcome.dart';
import '../rows.dart';
import '../strategy_rows.dart';
import 'op_facts.dart';
import 'pending.dart';
import 'queue.dart';

sealed class Pages {
  const Pages();
}

final class AllPages extends Pages {
  const AllPages();
}

final class SomePages extends Pages {
  SomePages(Iterable<String> pages) : pages = Set.unmodifiable(pages);

  final Set<String> pages;
}

Set<String> pagesToLoad(CloudQueue queue, Pages pages) => {
  ...entriesForPages(queue, switch (pages) {
    AllPages() => null,
    SomePages(:final pages) => pages,
  }).$2,
  if (pages case SomePages(:final pages))
    for (final work in queue.landed)
      if (pagesNeeded(work.op).any(pages.contains))
        ?queue.shown.rows[targetOf(work.op)]?.page,
};

int? _visibleRevision(StrategyRows rows, StrategyOp op) {
  final row = switch (targetOf(op)) {
    StrategyTarget() => rows.strategy,
    PageTarget(:final pagePublicId) => rows.page(pagePublicId),
    SettingsTarget(:final pagePublicId) => rows.settingsOf(pagePublicId),
    ElementTarget(:final elementPublicId) => rows.element(elementPublicId),
    LineupTarget(:final lineupPublicId) => rows.lineupGroup(lineupPublicId),
  };
  return row == null ? null : revisionOfRow(row);
}

StrategyRowSet visibleOver(StrategyRowSet base, CloudQueue queue, Pages pages) {
  var rows = base;
  StrategyRowSet onTop(StrategyRowSet rows, StrategyOp op) {
    final rebasedOp = switch ((expectedOf(op), _visibleRevision(rows, op))) {
      (_?, final revision?) => rebased(op, revision),
      _ => op,
    };
    return switch (applyOp(rows, rebasedOp)) {
      final OpApplied done => rows.withRows(done.rows),
      _ => rows,
    };
  }

  final (picked, _) = entriesForPages(queue, switch (pages) {
    AllPages() => null,
    SomePages(:final pages) => pages,
  });
  final followed = {
    for (final op in [
      for (final PendingOp(:op) in picked) op,
      for (final work in queue.landed)
        if (_visiblePage(work.op, pages)) work.op,
    ])
      if (targetOf(op) case final ElementTarget target)
        target
      else if (targetOf(op) case final LineupTarget target)
        target,
  };
  for (final work in queue.landed) {
    if (_visiblePage(work.op, pages) ||
        _leaves(rows, work.op, pages) ||
        followed.contains(targetOf(work.op))) {
      rows = _strategyAtLeast(
        onTop(
          _withMovedRow(rows, work.op, work.movedRow, work.revision),
          work.op,
        ),
        work,
      );
    }
  }
  final entries = switch (pages) {
    AllPages() => picked,
    SomePages(:final pages) => {
      for (final entry in picked) entry.place: entry,
      for (final entry in entriesOnRows(queue, {
        ...followed,
        for (final page in pages) ...[
          for (final row in rows.elementsOn(page)) ElementTarget(row.publicId),
          for (final row in rows.lineupGroupsOn(page))
            LineupTarget(row.publicId),
        ],
      }))
        entry.place: entry,
    }.values.toList()..sort((a, b) => a.place.compareTo(b.place)),
  };
  for (final PendingOp(:op, :authored) in entries) {
    final moved = switch (authored) {
      AuthoredRow(:final movedRow?) => movedRow,
      _ => null,
    };
    rows = onTop(
      moved == null
          ? rows
          : _withMovedRow(rows, op, moved, revisionOfRow(moved) ?? 0),
      op,
    );
  }
  return rows;
}

Set<String> pagesShowing(CloudQueue queue, Target target) => {
  ?queue.shown.rows[target]?.page,
  for (final entry in queue.entries)
    if (entry is PendingOp && targetOf(entry.op) == target) ...pagesOf(entry),
  for (final work in queue.landed)
    if (targetOf(work.op) == target) ...pagesNeeded(work.op),
};

bool _visiblePage(StrategyOp op, Pages pages) => switch (pages) {
  AllPages() => true,
  SomePages(:final pages) => switch (targetOf(op)) {
    StrategyTarget() || PageTarget() || SettingsTarget() => true,
    ElementTarget() || LineupTarget() => pagesNeeded(op).every(pages.contains),
  },
};

bool _leaves(StrategyRows rows, StrategyOp op, Pages pages) =>
    switch ((pages, targetOf(op))) {
      (SomePages(:final pages), ElementTarget(:final elementPublicId)) =>
        pages.contains(rows.element(elementPublicId)?.pagePublicId),
      (SomePages(:final pages), LineupTarget(:final lineupPublicId)) =>
        pages.contains(rows.lineupGroup(lineupPublicId)?.pagePublicId),
      _ => false,
    };

StrategyRowSet _strategyAtLeast(StrategyRowSet rows, LandedWork work) =>
    switch (targetOf(work.op)) {
      StrategyTarget() when rows.strategy.revision < work.revision =>
        rows.withRows([rows.strategy.rewritten(revision: work.revision)]),
      _ => rows,
    };

StrategyRowSet _withMovedRow(
  StrategyRowSet rows,
  StrategyOp op,
  Row? moved,
  int revision,
) => switch ((op, moved)) {
  (
    ElementPatchOp(
      :final elementPublicId,
      pagePublicId: final page?,
      :final payload,
      :final sortIndex,
    ),
    _,
  )
      when rows.element(elementPublicId) == null && rows.page(page) != null =>
    switch (payload ?? (moved is LiveElement ? moved.payload : null)) {
      final payload? => rows.withRows([
        LiveElement(
          publicId: elementPublicId,
          pagePublicId: page,
          payload: payload,
          sortIndex: sortIndex ?? (moved is LiveElement ? moved.sortIndex : 0),
          revision: revision,
        ),
      ]),
      null => rows,
    },
  (
    LineupGroupPatchOp(
      :final lineupPublicId,
      pagePublicId: final page?,
      :final payload,
      :final sortIndex,
    ),
    final LiveLineupGroup moved,
  )
      when rows.lineupGroup(lineupPublicId) == null &&
          rows.page(page) != null =>
    rows.withRows([
      LiveLineupGroup(
        publicId: lineupPublicId,
        strategyPublicId: moved.strategyPublicId,
        pagePublicId: page,
        payload: payload ?? moved.payload,
        sortIndex: sortIndex ?? moved.sortIndex,
        revision: revision,
      ),
    ]),
  _ => rows,
};
