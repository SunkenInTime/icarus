import '../apply.dart';
import '../ops.dart';
import '../outcome.dart';
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
  final (picked, _) = entriesForPages(queue, switch (pages) {
    AllPages() => null,
    SomePages(:final pages) => pages,
  });
  final entries = switch (pages) {
    AllPages() => picked,
    SomePages(:final pages) => {
      for (final entry in picked) entry.place: entry,
      for (final entry in entriesOnRows(queue, [
        for (final page in pages) ...[
          for (final row in base.elementsOn(page)) ElementTarget(row.publicId),
          for (final row in base.lineupGroupsOn(page))
            LineupTarget(row.publicId),
        ],
      ]))
        entry.place: entry,
    }.values.toList()..sort((a, b) => a.place.compareTo(b.place)),
  };
  for (final op in [
    for (final work in queue.landed)
      if (_visiblePage(work.op, pages) || _leaves(base, work.op, pages))
        work.op,
    for (final PendingOp(:op) in entries) op,
  ]) {
    final onTop = switch ((expectedOf(op), _visibleRevision(rows, op))) {
      (_?, final revision?) => rebased(op, revision),
      _ => op,
    };
    if (applyOp(rows, onTop) case final OpApplied done) {
      rows = rows.withRows(done.rows);
    }
  }
  return rows;
}

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
