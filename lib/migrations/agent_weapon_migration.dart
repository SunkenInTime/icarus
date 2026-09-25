import 'package:icarus/providers/strategy_provider.dart';

/// Version 100 adds an optional firearm to every kind of placed agent,
/// including lineup origins. Hive and JSON readers supply WeaponType.none
/// when the field is absent. No positions, sizes, or lineup links change.
class AgentWeaponMigration {
  static const int version = 100;

  static StrategyData migrate(StrategyData strategy) {
    if (strategy.versionNumber >= version) return strategy;
    return strategy.copyWith(versionNumber: version);
  }
}
