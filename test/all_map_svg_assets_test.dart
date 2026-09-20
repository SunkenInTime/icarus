import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every map ships SVG sightlines and independent navigation', () async {
    expect(svgHeightMapRegistrations.keys, unorderedEquals(MapValue.values));
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets();
    expect(assets.where((path) => path.endsWith('.height.bin.gz')), isEmpty);
    for (final map in MapValue.values) {
      final registration = svgHeightMapRegistrations[map]!;
      expect(
          assets,
          containsAll([
            registration.attackModelAsset,
            registration.defenseModelAsset,
            registration.attackArtworkAsset,
            registration.defenseArtworkAsset,
            'assets/maps/world/${map.name}_navigation.json.gz',
          ]));
      final container = ProviderContainer();
      final subscription =
          container.listen(svgHeightRuntimeProvider(map), (_, __) {});
      try {
        // The production loader checks side, schema, view box and artwork hash.
        final runtime =
            await container.read(svgHeightRuntimeProvider(map).future);
        expect(runtime, isNotNull, reason: map.name);
        for (final model in [runtime!.attack, runtime.defense]) {
          expect(model.walls, isNotEmpty, reason: map.name);
          expect(model.walls.any((wall) => wall.unknownHeight), isFalse);
          expect(model.receivers, hasLength(1));
          expect(model.ground, isNotNull);
          expect(
              model.supports.any((support) => support.automaticStandingAllowed),
              isTrue,
              reason: '${map.name} needs reviewed automatic standing surfaces');
        }
        // Navigation must load without any old 3D visibility pack in the bundle.
        await loadNavigationGeometry(map);
      } finally {
        subscription.close();
        container.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
