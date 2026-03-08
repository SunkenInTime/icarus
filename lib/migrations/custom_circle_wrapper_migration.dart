import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/strategy_page.dart';

class CustomCircleWrapperMigration {
  static const int version = 45;

  static List<StrategyPage> migratePages({
    required List<StrategyPage> pages,
    required MapValue map,
  }) {
    return [
      for (final page in pages) _migratePage(page: page, map: map),
    ];
  }

  static StrategyPage _migratePage({
    required StrategyPage page,
    required MapValue map,
  }) {
    var hasChanged = false;
    final migratedUtilities = [
      for (final utility in page.utilityData)
        _migrateUtility(
          utility: utility,
          map: map,
          onChanged: () => hasChanged = true,
        ),
    ];

    if (!hasChanged) {
      return page;
    }

    return page.copyWith(utilityData: migratedUtilities);
  }

  static PlacedUtility _migrateUtility({
    required PlacedUtility utility,
    required MapValue map,
    required void Function() onChanged,
  }) {
    if (utility.type != UtilityType.customCircle) {
      return utility;
    }

    final diameterMeters = utility.customDiameter;
    if (diameterMeters == null) {
      return utility;
    }

    final mapScale = Maps.mapScale[map] ?? 1.0;
    final actualDiameterVirtual = CustomCircleUtility.diameterInVirtual(
      diameterMeters: diameterMeters,
      mapScale: mapScale,
    );
    final maxDiameterVirtual =
        CustomCircleUtility.maxDiameterInVirtual(mapScale);
    final inset = (maxDiameterVirtual - actualDiameterVirtual) / 2;
    if (inset == 0) {
      return utility;
    }

    onChanged();
    final migrated = utility.deepCopy<PlacedUtility>();
    migrated.position = utility.position.translate(-inset, -inset);
    return migrated;
  }
}
