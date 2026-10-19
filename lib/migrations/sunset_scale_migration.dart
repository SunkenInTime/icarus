import 'dart:ui';

import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/migrations/custom_circle_box_migration.dart';
import 'package:icarus/migrations/paranoia_range_migration.dart';
import 'package:icarus/providers/strategy_page.dart';

abstract final class SunsetScaleMigration {
  static const int version = 98;
  static const double _oldScale = 0.9502102049421427;
  static const double _newScale = 1.06;
  static const double _virtualToWorld = 1000 / 831;

  // Positions are canonical after version 97, including defense pages.
  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
    required MapValue map,
  }) {
    if (map != MapValue.sunset) return pages;
    return [
      for (final page in pages)
        page.copyWith(
          abilityData: [
            for (final ability in page.abilityData) _ability(ability),
          ],
          utilityData: [
            for (final utility in page.utilityData) _utility(utility),
          ],
          lineUpGraph: page.lineUpGraph.mapNodes(ability: _ability),
        ),
    ];
  }

  static PlacedAbility _ability(PlacedAbility ability) {
    final data = abilityDataBeforeVersion104(ability.data);
    if (data == null) return ability;
    final delta = (data.getAnchorPoint(
              mapScale: _oldScale,
              abilitySize: Settings.abilitySize,
            ) -
            data.getAnchorPoint(
              mapScale: _newScale,
              abilitySize: Settings.abilitySize,
            )) *
        _virtualToWorld;
    if (delta == Offset.zero) return ability;
    return ability.copyWith(position: ability.position + delta)
      ..isDeleted = ability.isDeleted;
  }

  static PlacedUtility _utility(PlacedUtility utility) {
    Offset anchor(double scale) =>
        utilityAnchorBeforeVersion104(utility, scale);
    final delta = (anchor(_oldScale) - anchor(_newScale)) * _virtualToWorld;
    if (delta == Offset.zero) return utility;
    return utility.copyWith(position: utility.position + delta);
  }
}
