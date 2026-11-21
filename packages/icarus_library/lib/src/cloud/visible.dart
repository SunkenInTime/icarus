import '../apply.dart';
import '../ops.dart';
import '../outcome.dart';
import '../page_copy.dart';
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

final class Visible {
  Visible(this.rows, {required this.applied, required List<String> skipped})
    : skipped = List.unmodifiable(skipped);

  final StrategyRowSet rows;
  final int applied;
  final List<String> skipped;
}

sealed class _Use {
  const _Use();
}

final class _Skip extends _Use {
  const _Skip();
}

final class _Apply extends _Use {
  const _Apply(this.op);

  final StrategyOp op;
}

final class _PreviewCopy extends _Use {
  const _PreviewCopy(this.add, this.source);

  final PageAddOp add;
  final String source;
}

_Use _useOf(CloudQueue queue, StrategyRows rows, PendingOp entry) =>
    switch ((entry.op, entry.answer)) {
      (
        PageAddOp(:final pagePublicId, copyContentFromPagePublicId: final _?),
        AnsweredApplied(),
      )
          when queue.base.pageContent.containsKey(pagePublicId) =>
        const _Skip(),
      (
        final PageAddOp add &&
            PageAddOp(
              :final pagePublicId,
              copyContentFromPagePublicId: final source?,
            ),
        AnsweredApplied(),
      )
          when rows.page(pagePublicId) != null =>
        _PreviewCopy(add, source),
      _ => _Apply(entry.op),
    };

bool _headerWide(StrategyOp op) => switch (targetOf(op)) {
  StrategyTarget() || PageTarget() => true,
  SettingsTarget() || ElementTarget() || LineupTarget() => false,
};

Set<String> _pagesNeededToApply(PendingOp entry) => {
  ...pagesOf(entry),
  if (entry.op case PageAddOp(
    :final pagePublicId,
    copyContentFromPagePublicId: final _?,
  ))
    pagePublicId,
};

Set<String> pagesToLoad(CloudQueue queue, Pages pages) {
  switch (pages) {
    case AllPages():
      return {
        for (final entry in queue.entries)
          if (entry is PendingOp) ..._pagesNeededToApply(entry),
      };
    case SomePages(:final pages):
      final wanted = {...pages};
      var grew = true;
      while (grew) {
        grew = false;
        for (final entry in queue.entries) {
          if (entry is! PendingOp) continue;
          final needs = _pagesNeededToApply(entry);
          final relevant =
              needs.any(wanted.contains) ||
              (_headerWide(entry.op) && needs.isNotEmpty);
          if (relevant && !wanted.containsAll(needs)) {
            wanted.addAll(needs);
            grew = true;
          }
        }
      }
      return wanted;
  }
}

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

Visible visibleOver(StrategyRowSet base, CloudQueue queue, Pages pages) {
  var rows = base;
  var applied = 0;
  final skipped = <String>[];
  final wanted = switch (pages) {
    AllPages() => null,
    SomePages() => pagesToLoad(queue, pages),
  };
  for (final entry in queue.entries) {
    if (entry is! PendingOp) continue;
    if (wanted != null &&
        !_headerWide(entry.op) &&
        !_pagesNeededToApply(entry).any(wanted.contains)) {
      continue;
    }
    switch (_useOf(queue, rows, entry)) {
      case _Skip():
        break;
      case _PreviewCopy(:final add, :final source):
        applied++;
        rows = rows.withRows(
          PageCopy(add.opId, rows).content(
            rows.elementsOn(source),
            rows.lineupGroupsOn(source),
            add.pagePublicId,
          ),
        );
      case _Apply(:final op):
        applied++;
        final onTop = switch ((expectedOf(op), _visibleRevision(rows, op))) {
          (_?, final revision?) => rebased(op, revision),
          _ => op,
        };
        switch (applyOp(rows, onTop)) {
          case final OpApplied done:
            rows = rows.withRows(done.rows);
          case OpUnchanged():
            break;
          case OpRefused():
            skipped.add(entry.id);
        }
    }
  }
  return Visible(rows, applied: applied, skipped: skipped);
}
