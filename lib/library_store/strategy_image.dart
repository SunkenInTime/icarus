import 'dart:convert';

import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/strategy/strategy_models.dart';

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

StrategyImage imageOf(StrategyData strategy) {
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
    return StrategyImage(made, _readBack(strategy, made));
  } on Object catch (error) {
    return StrategyImage(
      made,
      ReadsBackDifferently('it cannot be compared: $error'),
    );
  }
}

ReadBack _readBack(StrategyData strategy, StrategyRowsMade made) {
  final StrategyDataMade back;
  switch (strategyFromRows(made.rows)) {
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
