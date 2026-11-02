import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _Ascent extends MapProvider {
  _Ascent(this.isAttack);

  final bool isAttack;

  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: isAttack);
}

class _OpenStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        isSaved: true,
        stratName: null,
        id: 'picture-drop',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

const _viewport = Size(1200, 675);

Future<({ProviderContainer container, Rect drawn})> _picture(
  WidgetTester tester, {
  required Offset at,
  required bool isAttack,
}) async {
  tester.view
    ..physicalSize = _viewport
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  CoordinateSystem(playAreaSize: _viewport);
  final container = ProviderContainer(overrides: [
    mapProvider.overrideWith(() => _Ascent(isAttack)),
    strategyProvider.overrideWith(_OpenStrategy.new),
  ]);
  addTearDown(container.dispose);
  container.read(placedImageProvider.notifier).fromHive([
    PlacedImage(
      id: 'picture',
      position: at,
      aspectRatio: 1,
      scale: 300,
      fileExtension: '.png',
    ),
  ]);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: ShadApp(
      themeMode: ThemeMode.dark,
      darkTheme: ShadThemeData(
        brightness: Brightness.dark,
        colorScheme: Settings.tacticalVioletTheme,
      ),
      home: const Scaffold(
        body: SizedBox(
          width: 1200,
          height: 675,
          child: PlacedWidgetBuilder(),
        ),
      ),
    ),
  ));
  await tester.pump();
  return (
    container: container,
    drawn: tester.getRect(find.byType(ImageWidget).first),
  );
}

Future<void> _drag(WidgetTester tester, Offset from, Offset by) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: from);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await mouse.down(from);
  await mouse.moveBy(by);
  await tester.pump();
  await mouse.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await mouse.removePointer();
}

void main() {
  for (final isAttack in [true, false]) {
    final side = isAttack ? 'attack' : 'defense';

    testWidgets('a picture lands where it is dropped on $side', (tester) async {
      final (:container, :drawn) = await _picture(
        tester,
        at: const Offset(800, 400),
        isAttack: isAttack,
      );
      const by = Offset(60, 40);

      await _drag(tester, drawn.center, by);

      expect(container.read(placedImageProvider).images, hasLength(1));
      final after = tester.getRect(find.byType(ImageWidget).first);
      expect((after.topLeft - (drawn.topLeft + by)).distance, lessThan(1));
    });

    testWidgets('a picture hanging off the map survives on $side',
        (tester) async {
      final (:container, :drawn) = await _picture(
        tester,
        at: const Offset(800, 400),
        isAttack: isAttack,
      );

      // Most of it stays on the canvas, whichever side is on screen.
      await _drag(tester, drawn.center, Offset(0, 40 - drawn.top));
      await _drag(
        tester,
        tester.getCenter(find.byType(ImageWidget).first),
        const Offset(0, -80),
      );

      expect(container.read(placedImageProvider).images, hasLength(1));
    });
  }

  testWidgets('a picture dragged off the map is removed', (tester) async {
    final (:container, :drawn) = await _picture(
      tester,
      at: const Offset(800, 100),
      isAttack: true,
    );

    await _drag(tester, drawn.center, Offset(0, -drawn.bottom));

    expect(container.read(placedImageProvider).images, isEmpty);
  });
}
