import 'package:icarus/strategy/strategy_models.dart';

DateTime _asHiveStoresIt(DateTime time) =>
    DateTime.fromMillisecondsSinceEpoch(time.millisecondsSinceEpoch);

StrategyData strategyAsHiveHoldsIt(StrategyData strategy) => strategy.copyWith(
      createdAt: _asHiveStoresIt(strategy.createdAt),
      lastEdited: _asHiveStoresIt(strategy.lastEdited),
    );
