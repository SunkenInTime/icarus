import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_rows/strategy_comparison.dart';
import 'package:icarus/strategy/strategy_models.dart';

sealed class RoundTrip {
  const RoundTrip();
}

final class RoundTripSame extends RoundTrip {
  const RoundTripSame(this.made);

  final StrategyRowsMade made;
}

final class RoundTripDiffers extends RoundTrip {
  const RoundTripDiffers(this.made, this.back, this.differences);

  final StrategyRowsMade made;
  final StrategyDataMade back;
  final List<StrategyDifference> differences;
}

final class RoundTripRefusedToRows extends RoundTrip {
  const RoundTripRefusedToRows(this.refused);

  final StrategyRowsRefused refused;
}

final class RoundTripRefusedFromRows extends RoundTrip {
  const RoundTripRefusedFromRows(this.made, this.refused);

  final StrategyRowsMade made;
  final StrategyDataRefused refused;
}

RoundTrip roundTrip(StrategyData strategy) {
  switch (strategyToRows(strategy)) {
    case StrategyRowsRefused() && final refused:
      return RoundTripRefusedToRows(refused);
    case StrategyRowsMade() && final made:
      switch (strategyFromRows(made.rows)) {
        case StrategyDataRefused() && final refused:
          return RoundTripRefusedFromRows(made, refused);
        case StrategyDataMade() && final back:
          final differences = strategyDifferences(strategy, back.strategy);
          return differences.isEmpty &&
                  back.unreadable.isEmpty &&
                  back.notInStrategy.isEmpty
              ? RoundTripSame(made)
              : RoundTripDiffers(made, back, differences);
      }
  }
}
