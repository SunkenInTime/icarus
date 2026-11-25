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

  StrategyImage of(StrategyData strategy) {
    final rows = strategyToRows(strategy);
    final StrategyRowsMade made;
    switch (rows) {
      case StrategyRowsRefused():
        return StrategyImage(
          rows,
          const ReadsBackDifferently('the converter refuses it'),
        );
      case final StrategyRowsMade madeRows:
        made = madeRows;
    }
    try {
      return StrategyImage(made, _readBack(strategy, made.rows));
    } on Object catch (error) {
      return StrategyImage(
        made,
        ReadsBackDifferently('it cannot be compared: $error'),
      );
    }
  }

  void forget(String strategyId) => _pagesReadingBackEqual.remove(strategyId);

  ReadBack _readBack(StrategyData strategy, StrategyRowSet rows) {
    final known = _pagesReadingBackEqual[strategy.id] ?? const {};
    final equal = <String, String>{};
    var allEqual = _outlineReadsBackEqual(strategy, rows);
    for (final page in strategy.pages) {
      final text = _pageText(strategy, page);
      if (known[page.id] == text || _pageReadBack(rows, page.id) == text) {
        equal[page.id] = text;
      } else {
        allEqual = false;
      }
    }
    _pagesReadingBackEqual[strategy.id] = equal;
    return allEqual ? const ReadsBackEqual() : _wholeReadBack(strategy, rows);
  }
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

ReadBack _wholeReadBack(StrategyData strategy, StrategyRowSet rows) {
  final StrategyDataMade back;
  switch (strategyFromRows(rows)) {
    case StrategyDataRefused(:final problems):
      return ReadsBackDifferently(
        'its rows are refused: ${problems.join('; ')}',
      );
    case final StrategyDataMade madeBack:
      back = madeBack;
  }
  if (back.unreadable.isNotEmpty) {
    return const ReadsBackDifferently('rows it cannot read');
  }
  if (back.notInStrategy.isNotEmpty) {
    return const ReadsBackDifferently('rows outside the strategy');
  }
  if (jsonEncode(strategyFingerprint(strategy)) ==
      jsonEncode(strategyFingerprint(back.strategy))) {
    return const ReadsBackEqual();
  }
  final differences = strategyDifferences(strategy, back.strategy);
  if (differences.isEmpty) return const ReadsBackEqual();
  return ReadsBackDifferently([
    ...differences.take(3).map((difference) => '$difference'),
    if (differences.length > 3) '${differences.length - 3} more',
  ].join(', '));
}
