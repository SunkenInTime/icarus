import 'dart:convert';

import 'package:icarus/const/maps.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

sealed class ReadBack {
  const ReadBack();
}

final class ReadsBackEqual extends ReadBack {
  const ReadsBackEqual();
}

final class ReadsBackDifferently extends ReadBack {
  const ReadsBackDifferently(this.words);

  final String words;
}

final class StrategyImage {
  const StrategyImage(this.rows, this.readBack);

  final StrategyToRows rows;
  final ReadBack readBack;
}

final class StrategyImages {
  final _pagesReadingBackEqual = <String, Map<String, String>>{};

  StrategyImage of(StrategyData strategy) => switch (_made(strategy)) {
        (final made?, null) => StrategyImage(
            made,
            _settled(() => _steps(strategy, made.rows).last!),
          ),
        (_, final refused?) => refused,
        _ => throw StateError('unreachable'),
      };

  Future<StrategyImage> between(
    StrategyData strategy,
    Future<void> Function() breathe,
  ) async {
    final StrategyRowsMade made;
    switch (_made(strategy)) {
      case (final madeRows?, null):
        made = madeRows;
      case (_, final refused?):
        return refused;
      default:
        throw StateError('unreachable');
    }
    await breathe();
    ReadBack? readBack;
    try {
      for (final step in _steps(strategy, made.rows)) {
        if (step != null) {
          readBack = step;
        } else {
          await breathe();
        }
      }
    } on Object catch (error) {
      readBack = ReadsBackDifferently('it cannot be compared: $error');
    }
    return StrategyImage(made, readBack!);
  }

  void forget(String strategyId) => _pagesReadingBackEqual.remove(strategyId);

  (StrategyRowsMade?, StrategyImage?) _made(StrategyData strategy) {
    final rows = strategyToRows(strategy);
    return switch (rows) {
      StrategyRowsRefused() => (
          null,
          StrategyImage(
            rows,
            const ReadsBackDifferently('the converter refuses it'),
          ),
        ),
      final StrategyRowsMade made => (made, null),
    };
  }

  static ReadBack _settled(ReadBack Function() check) {
    try {
      return check();
    } on Object catch (error) {
      return ReadsBackDifferently('it cannot be compared: $error');
    }
  }

  Iterable<ReadBack?> _steps(StrategyData strategy, StrategyRowSet rows) sync* {
    final known = _pagesReadingBackEqual[strategy.id] ?? const {};
    final equal = <String, String>{};
    final outlineEqual = _outlineReadsBackEqual(strategy, rows);
    String? differing;
    for (final page in strategy.pages) {
      yield null;
      final text = _pageText(strategy, page);
      if (known[page.id] == text || _pageReadBack(rows, page.id) == text) {
        equal[page.id] = text;
      } else {
        differing ??= page.id;
      }
    }
    _pagesReadingBackEqual[strategy.id] = equal;
    if (!outlineEqual) {
      yield const ReadsBackDifferently(
        'its fields, page order or positions read back differently',
      );
      return;
    }
    if (differing == null) {
      yield const ReadsBackEqual();
      return;
    }
    yield null;
    yield _pageDifferences(strategy, rows, differing);
  }
}

ReadBack _pageDifferences(
  StrategyData strategy,
  StrategyRowSet rows,
  String pageId,
) {
  final page = strategy.pages.firstWhere((page) => page.id == pageId);
  final back = strategyFromRows(StrategyRowSet(
    strategy: rows.strategy,
    pages: [if (rows.page(pageId) case final row?) row],
    settings: [if (rows.settingsOf(pageId) case final settings?) settings],
    elements: rows.elementsOn(pageId),
    lineupGroups: rows.lineupGroupsOn(pageId),
  ));
  final differences = switch (back) {
    StrategyDataMade(strategy: final made) when made.pages.length == 1 =>
      strategyDifferences(strategy.copyWith(pages: [page]), made),
    _ => const <StrategyDifference>[],
  };
  if (differences.isEmpty) {
    return ReadsBackDifferently('page $pageId reads back differently');
  }
  return ReadsBackDifferently([
    ...differences.take(3).map((difference) => '$difference'),
    if (differences.length > 3) '${differences.length - 3} more',
  ].join(', '));
}

String _outline(StrategyData strategy) => jsonEncode([
      strategyFieldsFingerprint(strategy),
      [
        for (final page in strategy.pages) [page.id, page.sortIndex],
      ],
    ]);

String _pageText(StrategyData strategy, StrategyPage page) => jsonEncode([
      Maps.mapNames[strategy.mapData],
      pageFingerprint(page, strategy.id),
      pagePictureFileNames(page)..sort(),
    ]);

bool _everyRowOnAPage(StrategyRowSet rows) => [
      for (final row in rows.elements) row.pagePublicId,
      for (final row in rows.lineupGroups) row.pagePublicId,
    ].every((pageId) => rows.page(pageId) != null);

bool _outlineReadsBackEqual(StrategyData strategy, StrategyRowSet rows) =>
    _everyRowOnAPage(rows) &&
    switch (strategyFromRows(StrategyRowSet(
      strategy: rows.strategy,
      pages: rows.pages,
      settings: rows.settings,
    ))) {
      StrategyDataMade(
        strategy: final back,
        :final unreadable,
        :final notInStrategy,
      )
          when unreadable.isEmpty && notInStrategy.isEmpty =>
        _outline(strategy) == _outline(back),
      StrategyDataMade() || StrategyDataRefused() => false,
    };

String? _pageReadBack(StrategyRowSet rows, String pageId) =>
    switch (strategyFromRows(StrategyRowSet(
      strategy: rows.strategy,
      pages: [if (rows.page(pageId) case final page?) page],
      settings: [if (rows.settingsOf(pageId) case final settings?) settings],
      elements: rows.elementsOn(pageId),
      lineupGroups: rows.lineupGroupsOn(pageId),
    ))) {
      StrategyDataMade(
        strategy: final back,
        :final unreadable,
        :final notInStrategy,
      )
          when unreadable.isEmpty &&
              notInStrategy.isEmpty &&
              back.pages.length == 1 =>
        _pageText(back, back.pages.single),
      StrategyDataMade() || StrategyDataRefused() => null,
    };
