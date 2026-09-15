import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'all paired SVG bounds and source registrations use canonical side flips',
      () {
    final catalog = jsonDecode(File('assets/maps/world/height_catalog.json')
        .readAsStringSync())['maps'] as Map<String, dynamic>;
    expect(CanonicalMapArtwork.defenseOffsetSvg.keys.toSet(),
        MapValue.values.toSet());
    for (final map in MapValue.values) {
      final attack = WorldReceiverMask.parse(
          File('assets/maps/${map.name}_map.svg').readAsStringSync());
      final defense = WorldReceiverMask.parse(
          File('assets/maps/${map.name}_map_defense.svg').readAsStringSync());
      expect(attack.viewBox, defense.viewBox, reason: map.name);
      expect(attack.viewBox.size, Maps.mapViewBox[map]);
      final entry = HeightAssetEntry.fromJson(map, catalog[map.name]);
      final delta = CanonicalMapArtwork.defenseOffsetSvg[map]!;
      expect((entry.defenseOffsetSvg - delta).distance, lessThan(1e-9),
          reason: '${map.name} presentation and query registration disagree');

      Rect bounds(WorldReceiverMask receiver) => receiver.fills
          .map((fill) => fill.copyPath().getBounds())
          .reduce((a, b) => a.expandToInclude(b));
      final a = bounds(attack), d = bounds(defense).shift(-delta);
      final center = attack.viewBox.center;
      final expected = Rect.fromLTRB(
          2 * center.dx - a.right,
          2 * center.dy - a.bottom,
          2 * center.dx - a.left,
          2 * center.dy - a.top);
      for (final pair in [
        (d.left, expected.left),
        (d.top, expected.top),
        (d.right, expected.right),
        (d.bottom, expected.bottom)
      ]) {
        // Authored path coordinates are independently rounded to .001 SVG.
        // The measured pre-existing residual is at most .000756 SVG.
        expect(pair.$1, closeTo(pair.$2, .001),
            reason: '${map.name} actual SVG fill bounds');
      }

      final assets = HeightAssets(folder: '', entry: entry);
      final shift = CanonicalMapArtwork.translation(map, const Size(1240, 1000),
          isAttack: false);
      final rawDefense = assets.defenseProjection;
      expect(
          (rawDefense.origin + shift - assets.projection.defense.origin)
              .distance,
          lessThan(1e-9));
      for (final point in [
        const Offset(300, 250),
        const Offset(700, 500),
        const Offset(1100, 750)
      ]) {
        final reflected = const Offset(1000 * 16 / 9, 1000) - point;
        final attackSource = assets.projection.toMeters(point);
        // Undo only the artwork presentation, then use its raw registered frame.
        final defenseSource = rawDefense.toMeters(reflected - shift);
        expect((attackSource - defenseSource).distance, lessThan(1e-9),
            reason: '${map.name} side flip changed the physical observer');
      }
    }
  });

  testWidgets('presentation translation preserves fit size at every viewport',
      (tester) async {
    const key = Key('artwork');
    for (final viewport in [
      const Size(620, 500),
      const Size(200, 600),
      const Size(700, 180)
    ]) {
      for (final attack in [true, false]) {
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(
                  size: viewport,
                  child: CanonicalMapArtwork(
                      map: MapValue.split,
                      isAttack: attack,
                      child: const SizedBox.expand(key: key)))),
        ));
        expect(tester.getSize(find.byKey(key)), viewport);
        final expected = CanonicalMapArtwork.translation(
            MapValue.split, viewport,
            isAttack: attack);
        expect((tester.getTopLeft(find.byKey(key)) - expected).distance,
            lessThan(1e-9));
      }
    }
  });
}
