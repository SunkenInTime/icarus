import 'dart:ui';

import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/strategy_page.dart';

// Migrations through version 103 must measure custom circles in the 40 m box
// they were placed in. Reading the live box would apply the version 104 move
// twice.
const double customCircleBoxMetersBeforeVersion104 = 40;

/// The stored anchor of [utility] as builds through data version 103 drew it
/// on a map at [mapScale]: custom circles in their 40 m box, everything else
/// as it is drawn now.
Offset utilityAnchorBeforeVersion104(PlacedUtility utility, double mapScale) {
  if (utility.type == UtilityType.customCircle) {
    final box = CustomCircleUtility.diameterInVirtual(
      diameterMeters: customCircleBoxMetersBeforeVersion104,
      mapScale: mapScale,
    );
    return Offset(box / 2, box / 2);
  }
  return UtilityData.utilityWidgets[utility.type]!.getAnchorPoint(
    id: utility.id,
    length: utility.length,
    rotation: utility.rotation,
    mapScale: mapScale,
    agentSize: Settings.agentSize,
    abilitySize: Settings.abilitySize,
    diameterMeters: utility.customDiameter,
    widthMeters: utility.customWidth,
    rectLengthMeters: utility.customLength,
  );
}

/// A custom circle is saved by the top-left of a box as wide as the largest
/// circle, so it can be resized without moving. That box grew from 40 m to
/// [CustomCircleUtility.maxDiameterMeters]; saved circles keep their centre
/// and their top-left moves out to the bigger box.
///
/// Circles around an agent need nothing: they are saved by the agent's own
/// position. Lineups hold no custom circles.
abstract final class CustomCircleBoxMigration {
  static const int version = 104;
  static const double _virtualToWorld = 1000 / 831;

  // Positions are canonical after version 97, including defense pages.
  // Returns [pages] itself when there is no custom circle to move.
  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
    required MapValue map,
  }) {
    final mapScale = Maps.mapScale[map] ?? 1.0;
    var moved = false;
    PlacedUtility migrate(PlacedUtility utility) {
      if (utility.type != UtilityType.customCircle) return utility;
      moved = true;
      return _utility(utility, mapScale);
    }

    final migrated = [
      for (final page in pages)
        page.copyWith(
          utilityData: [
            for (final utility in page.utilityData) migrate(utility)
          ],
        ),
    ];
    return moved ? migrated : pages;
  }

  /// One saved custom circle on [map], moved as [migratePages] moves it.
  static PlacedUtility migrateUtility(PlacedUtility utility, MapValue map) =>
      _utility(utility, Maps.mapScale[map] ?? 1.0);

  static PlacedUtility _utility(PlacedUtility utility, double mapScale) {
    final liveAnchor = UtilityData.utilityWidgets[utility.type]!
        .getAnchorPoint(mapScale: mapScale);
    final delta =
        (utilityAnchorBeforeVersion104(utility, mapScale) - liveAnchor) *
            _virtualToWorld;
    return utility.copyWith(position: utility.position + delta);
  }
}
