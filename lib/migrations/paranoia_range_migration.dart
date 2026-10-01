import 'dart:ui';

import 'package:flutter/material.dart' show Colors;
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/strategy_page.dart';

// Migrations through version 103 must reconstruct Paranoia at its old size.
// Reading the live size would apply the version 104 correction twice.
Ability? abilityDataBeforeVersion104(AbilityInfo info) {
  if (!ParanoiaRangeMigration.isParanoia(info)) return info.abilityData;
  return SquareAbility(
    width: 4.3 * AgentData.inGameMetersDiameter,
    height: 25 * AgentData.inGameMeters,
    iconPath: info.iconPath,
    color: Colors.deepPurple,
  );
}

/// Paranoia grew from 25 m by 8.6 m to Riot's 28 m by 9 m minimap indicator.
/// Saved Paranoias keep their anchor, the end at Omen, and grow away from it.
abstract final class ParanoiaRangeMigration {
  static const int version = 104;
  static const double _virtualToWorld = 1000 / 831;

  static bool isParanoia(AbilityInfo info) =>
      info.type == AgentType.omen && info.index == 1;

  // Positions are canonical after version 97, including defense pages.
  // Returns [pages] itself when there is no Paranoia to move.
  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
    required MapValue map,
  }) {
    final mapScale = Maps.mapScale[map] ?? 1.0;
    var moved = false;
    PlacedAbility migrate(PlacedAbility ability) {
      if (!isParanoia(ability.data)) return ability;
      moved = true;
      return _ability(ability, mapScale);
    }

    final migrated = [
      for (final page in pages)
        page.copyWith(
          abilityData: [
            for (final ability in page.abilityData) migrate(ability)
          ],
          lineUpGraph: page.lineUpGraph.mapNodes(ability: migrate),
        ),
    ];
    return moved ? migrated : pages;
  }

  static PlacedAbility _ability(PlacedAbility ability, double mapScale) {
    Offset anchor(Ability data) => data.getAnchorPoint(
          mapScale: mapScale,
          abilitySize: Settings.abilitySize,
        );
    final delta = (anchor(abilityDataBeforeVersion104(ability.data)!) -
            anchor(ability.data.abilityData!)) *
        _virtualToWorld;
    return ability.copyWith(position: ability.position + delta)
      ..isDeleted = ability.isDeleted;
  }
}
