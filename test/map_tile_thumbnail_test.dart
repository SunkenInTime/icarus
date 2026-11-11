import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/map_tile.dart';

/// The map tile paints its softened thumbnail once instead of blurring and
/// fading it on every frame. It must still look as it did.
void main() {
  for (final ratio in [1.0, 2.0]) {
    testWidgets(
        'a map tile looks as it did when it blurred every frame '
        '(${ratio}x)', (tester) async {
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Material(
              color: const Color(0xFF18181B),
              child: Column(
                children: [
                  // A card in the map list, the picker's own card, and the
                  // tile's own size.
                  for (final (name, size) in [
                    ('ascent', const Size(248, 65)),
                    ('sunset', const Size(180, 55)),
                    ('corrode', const Size(MapTile.width, MapTile.height)),
                  ])
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RepaintBoundary(
                          child: SizedBox.fromSize(
                            size: size,
                            child: _BlurredEveryFrame(name),
                          ),
                        ),
                        RepaintBoundary(
                          child: SizedBox.fromSize(
                            size: size,
                            child: MapTile(name: name, onTap: () {}),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      // The thumbnails decode and paint off the test's fake clock.
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }

      final rows = tester.widgetList<Row>(find.byType(Row)).length;
      expect(rows, 3);
      for (var row = 0; row < rows; row++) {
        final boundaries = find.descendant(
          of: find.byType(Row).at(row),
          matching: find.byType(RepaintBoundary),
        );
        final old = await _pixels(tester, boundaries.at(0), ratio);
        final now = await _pixels(tester, boundaries.at(1), ratio);
        expect(now.length, old.length);
        var worst = 0;
        var painted = 0;
        for (var i = 0; i < old.length; i++) {
          final diff = (old[i] - now[i]).abs();
          if (diff > worst) worst = diff;
          if (i % 4 != 3 && now[i] > 40) painted++;
        }
        // The thumbnail is there, not an empty tile.
        expect(painted, greaterThan(old.length ~/ 8));
        expect(worst, lessThanOrEqualTo(3), reason: 'row $row');
      }
    });
  }

  testWidgets('a thumbnail that fails to load is not kept', (tester) async {
    final cache = PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Material(child: MapTile(name: 'nowhere', onTap: () {})),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    // Kept, the failed load would answer every later open of the picker,
    // and the tile would stay blank until the app restarted.
    expect(cache.pendingImageCount, 0);
  });
}

Future<List<int>> _pixels(
  WidgetTester tester,
  Finder boundary,
  double ratio,
) async {
  final render = tester.renderObject<RenderRepaintBoundary>(boundary);
  final bytes = await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: ratio);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

/// The tile as it drew before: the thumbnail blurred and faded as it was
/// drawn, every frame.
class _BlurredEveryFrame extends StatelessWidget {
  const _BlurredEveryFrame(this.name);

  final String name;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(10)),
      child: SizedBox(
        width: MapTile.width,
        height: MapTile.height,
        child: Stack(
          children: [
            Positioned.fill(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1),
                child: Opacity(
                  opacity: .8,
                  child: Image.asset(
                    cacheWidth: 180,
                    cacheHeight: 53,
                    'assets/maps/thumbnails/${name}_thumbnail.webp',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.center,
              child: Text(
                name.toUpperCase(),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      color: Colors.black,
                      blurRadius: 2,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
