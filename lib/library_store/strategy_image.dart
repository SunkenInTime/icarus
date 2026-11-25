import 'package:icarus/library_rows/round_trip.dart';
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
  final RoundTrip trip;
  try {
    trip = roundTrip(strategy);
  } on Object catch (error) {
    return StrategyImage(
      strategyToRows(strategy),
      ReadsBackDifferently('it cannot be compared: $error'),
    );
  }
  return _imageOf(trip);
}

StrategyImage _imageOf(RoundTrip trip) => switch (trip) {
      RoundTripSame(:final made) => StrategyImage(made, const ReadsBackEqual()),
      RoundTripDiffers(:final made, :final differences, :final back) =>
        StrategyImage(
          made,
          ReadsBackDifferently([
            ...differences.take(3).map((difference) => '$difference'),
            if (differences.length > 3) '${differences.length - 3} more',
            if (back.unreadable.isNotEmpty) 'rows it cannot read',
            if (back.notInStrategy.isNotEmpty) 'rows outside the strategy',
          ].join(', ')),
        ),
      RoundTripRefusedFromRows(:final made, :final refused) => StrategyImage(
          made,
          ReadsBackDifferently(
            'its rows are refused: ${refused.problems.join('; ')}',
          ),
        ),
      RoundTripRefusedToRows(:final refused) => StrategyImage(
          refused,
          const ReadsBackDifferently('the converter refuses it'),
        ),
    };
