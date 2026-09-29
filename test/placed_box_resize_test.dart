import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/widgets/draggable_widgets/image/placed_image_builder.dart';
import 'package:icarus/widgets/draggable_widgets/image/scalable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/text/placed_text_builder.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_scale_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  const playArea = Size(1600, 900);
  const originalPosition = Offset(500, 400);

  Future<ProviderContainer> pumpBox(
    WidgetTester tester, {
    required Widget Function(WidgetRef ref, bool isAttack) builder,
    required ValueNotifier<bool> side,
    required void Function(ProviderContainer container) seed,
  }) async {
    tester.view.physicalSize = playArea;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    CoordinateSystem(playAreaSize: playArea);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    seed(container);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Consumer(
            builder: (context, ref, _) => ValueListenableBuilder<bool>(
              valueListenable: side,
              builder: (context, isAttack, _) =>
                  Stack(children: [builder(ref, isAttack)]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// Drags the resize handle right by [dx], checking at every step that the
  /// box's top-left stays where the user sees it.
  Future<void> dragHandleBy(
    WidgetTester tester, {
    required Finder box,
    required MouseCursor handleCursor,
    required double dx,
  }) async {
    final handle = find.byWidgetPredicate(
      (widget) => widget is MouseRegion && widget.cursor == handleCursor,
    );
    final start = tester.getRect(box);
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var moved = 0.0; moved < dx; moved += 20) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      expect(tester.getRect(box).topLeft, start.topLeft);
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  for (final isAttack in [true, false]) {
    final side = isAttack ? 'attack' : 'defense';

    testWidgets('resizing text on $side moves only its right edge',
        (tester) async {
      final container = await pumpBox(
        tester,
        seed: (container) => container.read(textProvider.notifier).fromHive([
          PlacedText(
            id: 'text-1',
            position: originalPosition,
            size: 200,
            sizeVersion: PlacedText.currentSizeVersion,
          )..text = 'Yo text boxes resize properly on both sides now',
        ]),
        side: ValueNotifier(isAttack),
        builder: (ref, isAttack) {
          final placedText = ref.watch(textProvider).single;
          return PlacedTextBuilder(
            key: ValueKey(placedText.id),
            size: placedText.size,
            placedText: placedText,
            isAttack: isAttack,
            onDragEnd: (_) {},
          );
        },
      );
      final box = find.byType(TextScaleController);
      final before = tester.getRect(box);

      await dragHandleBy(
        tester,
        box: box,
        handleCursor: SystemMouseCursors.resizeLeftRight,
        dx: 120,
      );

      // Once released, the stored position alone keeps the box in place.
      final after = tester.getRect(box);
      expect(after.topLeft, offsetMoreOrLessEquals(before.topLeft));
      expect(after.width, closeTo(before.width + 120, 10));
      expect(after.height, lessThan(before.height));

      final stored = container.read(textProvider).single;
      expect(stored.size, greaterThan(200));
      if (isAttack) {
        expect(stored.position, offsetMoreOrLessEquals(originalPosition));
      }
    });

    testWidgets('resizing an image on $side keeps its top-left in place',
        (tester) async {
      final container = await pumpBox(
        tester,
        seed: (container) =>
            container.read(placedImageProvider.notifier).fromHive([
          PlacedImage(
            id: 'image-1',
            position: originalPosition,
            aspectRatio: 16 / 9,
            scale: 200,
            fileExtension: null,
            sizeVersion: worldSizedMediaVersion,
          ),
        ]),
        side: ValueNotifier(isAttack),
        builder: (ref, isAttack) {
          final placedImage = ref.watch(placedImageProvider).images.single;
          return PlacedImageBuilder(
            key: ValueKey(placedImage.id),
            placedImage: placedImage,
            isAttack: isAttack,
            scale: placedImage.scale,
            onDragEnd: (_) {},
          );
        },
      );
      final box = find.byType(ImageScaleController);
      final before = tester.getRect(box);

      await dragHandleBy(
        tester,
        box: box,
        handleCursor: SystemMouseCursors.resizeDownRight,
        dx: 120,
      );

      final after = tester.getRect(box);
      expect(after.topLeft, offsetMoreOrLessEquals(before.topLeft));
      expect(after.width, greaterThan(before.width + 100));

      final stored = container.read(placedImageProvider).images.single;
      expect(stored.scale, greaterThan(200));
      if (isAttack) {
        expect(stored.position, offsetMoreOrLessEquals(originalPosition));
      }
    });
  }

  testWidgets('switching sides mid-resize keeps the pinned side placement',
      (tester) async {
    final side = ValueNotifier(false);
    final container = await pumpBox(
      tester,
      seed: (container) => container.read(textProvider.notifier).fromHive([
        PlacedText(
          id: 'text-1',
          position: originalPosition,
          size: 200,
          sizeVersion: PlacedText.currentSizeVersion,
        )..text = 'Yo text boxes resize properly on both sides now',
      ]),
      side: side,
      builder: (ref, isAttack) {
        final placedText = ref.watch(textProvider).single;
        return PlacedTextBuilder(
          key: ValueKey(placedText.id),
          size: placedText.size,
          placedText: placedText,
          isAttack: isAttack,
          onDragEnd: (_) {},
        );
      },
    );
    final box = find.byType(TextScaleController);
    final handle = find.byWidgetPredicate(
      (widget) =>
          widget is MouseRegion &&
          widget.cursor == SystemMouseCursors.resizeLeftRight,
    );

    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    final onDefense = tester.getRect(box);

    side.value = true;
    await tester.pump();
    // The box mirrors away from the held pointer, but keeps tracking its
    // movement rather than jumping to it.
    final widthAfterSwitch = tester.getRect(box).width;
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();
    expect(tester.getRect(box).width, closeTo(widthAfterSwitch + 10, 1));
    await gesture.moveBy(const Offset(-10, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    side.value = false;
    await tester.pumpAndSettle();
    expect(
        tester.getRect(box).topLeft, offsetMoreOrLessEquals(onDefense.topLeft));
    expect(container.read(textProvider).single.size, greaterThan(200));
  });

  testWidgets('a release before the next frame keeps its last movement',
      (tester) async {
    await pumpBox(
      tester,
      seed: (container) => container.read(textProvider.notifier).fromHive([
        PlacedText(
          id: 'text-1',
          position: originalPosition,
          size: 200,
          sizeVersion: PlacedText.currentSizeVersion,
        )..text = 'Yo text boxes resize properly on both sides now',
      ]),
      side: ValueNotifier(false),
      builder: (ref, isAttack) {
        final placedText = ref.watch(textProvider).single;
        return PlacedTextBuilder(
          key: ValueKey(placedText.id),
          size: placedText.size,
          placedText: placedText,
          isAttack: isAttack,
          onDragEnd: (_) {},
        );
      },
    );
    final box = find.byType(TextScaleController);
    final handle = find.byWidgetPredicate(
      (widget) =>
          widget is MouseRegion &&
          widget.cursor == SystemMouseCursors.resizeLeftRight,
    );

    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    final shown = tester.getRect(box);

    // A last move and the release arrive before the next frame draws it.
    await gesture.moveBy(const Offset(40, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tester.getRect(box).topLeft, offsetMoreOrLessEquals(shown.topLeft));
    expect(tester.getRect(box).width, closeTo(shown.width + 40, 1));
  });

  testWidgets('a page switch right after release keeps the resize on its page',
      (tester) async {
    final container = await pumpBox(
      tester,
      seed: (container) => container.read(textProvider.notifier).fromHive([
        PlacedText(
          id: 'text-1',
          position: originalPosition,
          size: 200,
          sizeVersion: PlacedText.currentSizeVersion,
        )..text = 'Yo text boxes resize properly on both sides now',
      ]),
      side: ValueNotifier(false),
      builder: (ref, isAttack) {
        final placedText = ref.watch(textProvider).single;
        return PlacedTextBuilder(
          key: ValueKey(placedText.id),
          size: placedText.size,
          placedText: placedText,
          isAttack: isAttack,
          onDragEnd: (_) {},
        );
      },
    );
    final handle = find.byWidgetPredicate(
      (widget) =>
          widget is MouseRegion &&
          widget.cursor == SystemMouseCursors.resizeLeftRight,
    );

    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    final resized = container.read(textProvider).single;
    await gesture.up();

    // Before the frame, the page is saved and the next page loads its copy
    // of the text. The save must already see the new width.
    expect(resized.size, greaterThan(200));
    final copy = PlacedText(
      id: 'text-1',
      position: const Offset(100, 100),
      size: 200,
      sizeVersion: PlacedText.currentSizeVersion,
    )..text = 'Yo text boxes resize properly on both sides now';
    container.read(textProvider.notifier).fromHive([copy]);
    await tester.pumpAndSettle();

    final loaded = container.read(textProvider).single;
    expect(loaded.size, 200);
    expect(loaded.position, const Offset(100, 100));
  });
}
