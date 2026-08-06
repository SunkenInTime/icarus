import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/shape_indicator_fade.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(800, 600));
  });

  testWidgets(
    'rotation handle only accepts input while the target is hovered',
    (tester) async {
      var handleDragStarted = false;

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: RotatableWidget(
                  rotation: 0,
                  origin: const Offset(50, 100),
                  isDragging: false,
                  onPanStart: (_) => handleDragStarted = true,
                  onPanUpdate: (_) {},
                  onPanEnd: (_) {},
                  child: const SizedBox(
                    key: ValueKey('rotation-target'),
                    width: 100,
                    height: 120,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      ShapeIndicatorFade indicator() =>
          tester.widget<ShapeIndicatorFade>(find.byType(ShapeIndicatorFade));

      expect(indicator().visible, isFalse);
      expect(
        tester
            .widget<IgnorePointer>(
              find.descendant(
                of: find.byType(ShapeIndicatorFade),
                matching: find.byType(IgnorePointer),
              ),
            )
            .ignoring,
        isTrue,
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(
          find.byKey(const ValueKey('rotation-target')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(indicator().visible, isTrue);

      final handleCenter = tester.getCenter(find.byType(ShapeIndicatorFade));
      await mouse.moveTo(handleCenter);
      await mouse.down(handleCenter);
      await mouse.moveBy(const Offset(10, 0));
      await tester.pump();

      expect(handleDragStarted, isTrue);

      await mouse.up();
      await mouse.moveTo(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(indicator().visible, isFalse);
    },
  );

  testWidgets('hover listener does not block target dragging', (tester) async {
    var targetDragStarted = false;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: RotatableWidget(
                rotation: 0,
                origin: const Offset(50, 100),
                isDragging: false,
                onPanStart: (_) {},
                onPanUpdate: (_) {},
                onPanEnd: (_) {},
                child: GestureDetector(
                  key: const ValueKey('draggable-rotation-target'),
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => targetDragStarted = true,
                  child: const SizedBox(width: 100, height: 120),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.dragFrom(
      tester.getCenter(find.byKey(const ValueKey('draggable-rotation-target'))),
      const Offset(20, 0),
    );

    expect(targetDragStarted, isTrue);
  });
}
