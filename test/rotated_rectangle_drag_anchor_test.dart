import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_rectangle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/placed_custom_rectangle_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(800, 600));
    CoordinateSystem.instance.setIsScreenshot(false);
  });

  testWidgets(
      'drag feedback keeps the grabbed point under the cursor '
      'on a 90-degree rotated rectangle', (tester) async {
    final utility = PlacedUtility(
      id: 'rectangle',
      type: UtilityType.customRectangle,
      position: const Offset(400, 300),
      customWidth: 8,
      customLength: 16,
      customColorValue: 0xff8b5cf6,
      customOpacityPercent: 40,
    )..rotation = math.pi / 2;
    final container = ProviderContainer(
      overrides: [mapProvider.overrideWith(_FixedMapProvider.new)],
    );
    addTearDown(container.dispose);
    container.read(utilityProvider.notifier).fromHive([utility]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: Scaffold(
            body: Center(
              child: PlacedCustomRectangleWidget(
                utility: utility,
                id: utility.id,
                isAttack: true,
                onDragEnd: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    // The shape body ignores pointers; drags start only from the center
    // marker. Grab near the marker's edge so the grab point is off the
    // rotation center — that offset is what the drag anchor must compensate.
    final shapeFinder = find.byType(CustomRectangleUtilityWidget);
    final shapeBox = tester.renderObject<RenderBox>(shapeFinder);
    final markerRadius =
        CoordinateSystem.instance.scale(Settings.utilityIconSize) * 0.4;
    final grabLocal = shapeBox.size.center(Offset.zero) +
        Offset(markerRadius * 0.7, markerRadius * 0.3);
    final grabGlobal = shapeBox.localToGlobal(grabLocal);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: grabGlobal);
    await tester.pump();
    await mouse.down(grabGlobal);
    const dragDelta = Offset(25, 10);
    await mouse.moveBy(dragDelta);
    await tester.pump();

    // While dragging, childWhenDragging shrinks the original, so the only
    // live rectangle widget must be the overlay feedback (id: null). This
    // also guards against the drag silently failing to start.
    final draggedWidget =
        tester.widget<CustomRectangleUtilityWidget>(shapeFinder);
    expect(draggedWidget.id, isNull,
        reason: 'Drag did not start: still seeing the placed widget.');

    final feedbackBox = tester.renderObject<RenderBox>(shapeFinder);
    final renderedGrabPoint = feedbackBox.localToGlobal(grabLocal);
    final pointer = grabGlobal + dragDelta;
    final misalignment = (renderedGrabPoint - pointer).distance;

    await mouse.up();
    await tester.pump();

    expect(
      misalignment,
      lessThan(0.1),
      reason: 'Grabbed point rendered ${misalignment.toStringAsFixed(2)}px '
          'away from the cursor.',
    );
  });
}
