import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';

abstract interface class ExportStrategyReads {
  Future<StrategyData?> read(String strategyId);
}

final class HiveExportReads implements ExportStrategyReads {
  const HiveExportReads();

  @override
  Future<StrategyData?> read(String strategyId) =>
      SynchronousFuture(const LocalLibrary().storedStrategy(strategyId));
}

final exportStrategyReadsProvider = Provider<ExportStrategyReads>(
  (ref) => const HiveExportReads(),
);
