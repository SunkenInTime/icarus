
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
