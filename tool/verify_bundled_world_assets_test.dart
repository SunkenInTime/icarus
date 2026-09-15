import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';

/// Run after the validated 13-map rollout is bundled. This gate deliberately
/// fails while rollout is disabled, instead of passing over an empty map set.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('all playable maps use bundled, validated world geometry', () async {
    expect(worldGeometryMaps, unorderedEquals(MapValue.values));
    for (final map in MapValue.values) {
      final navigation = await loadNavigationGeometry(map);
      final geometry = await loadWorldViewConeGeometry(map,
          binary: true, chunked: true, navigationGeometry: navigation.geometry);
      expect(geometry.map, map);
      expect(geometry.navigationGeometry, isNotNull);
      expect(geometry.worldData, isNotNull);
      expect(geometry.worldData!.planarized, isTrue);
      expect(geometry.worldData!.spatiallyOrdered, isTrue);
      expect(geometry.worldData!.projection, isNotNull);
      expect(geometry.worldData!.observerHeightCm, navigation.observerHeightCm);
      expect(geometry.worldData!.defaultFloorElevationCm,
          navigation.defaultFloorElevationCm);
      geometry.worldData!.validateAllChunks();
      for (final elevation in geometry.elevations) {
        final attack = geometry.layerFor(isAttack: true, elevation: elevation);
        final defense =
            geometry.layerFor(isAttack: false, elevation: elevation);
        expect(attack.elevation, elevation, reason: '${map.name} menu plane');
        expect(defense.elevation, elevation);
        expect(attack.boundary, isNull);
        expect(attack.metricLayer, same(defense.metricLayer));
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
