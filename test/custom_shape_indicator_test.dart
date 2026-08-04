import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_circle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_rectangle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/placed_custom_circle_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/placed_custom_rectangle_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/shape_indicator_fade.dart';

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

  testWidgets('circle hover reveals indicators without blocking drag',
      (tester) async {
    var dragEnded = false;
    final utility = _circle();
    final container = _containerWith(utility);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _harness(
        container: container,
        child: PlacedCustomCircleWidget(
          utility: utility,
          id: utility.id,
          onDragEnd: (_) => dragEnded = true,
        ),
      ),
    );

    expect(
      tester
          .widget<ShapeIndicatorFade>(find.byType(ShapeIndicatorFade))
          .visible,
      isFalse,
    );

    final circleCenter =
        tester.getCenter(find.byType(CustomCircleUtilityWidget).first);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: circleCenter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      tester
          .widget<ShapeIndicatorFade>(find.byType(ShapeIndicatorFade))
          .visible,
      isTrue,
    );

    await mouse.down(circleCenter);
    await mouse.moveBy(const Offset(40, 0));
    await tester.pump();
    await mouse.up();
    await tester.pump();

    expect(dragEnded, isTrue);
  });

  testWidgets('circle screenshot removes center marker immediately',
      (tester) async {
    final utility = _circle();
    final container = _containerWith(utility);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _harness(
        container: container,
        child: PlacedCustomCircleWidget(
          utility: utility,
          id: utility.id,
          onDragEnd: (_) {},
        ),
      ),
    );
    expect(
      tester
          .widget<CustomCircleUtilityWidget>(
            find.byType(CustomCircleUtilityWidget).first,
          )
          .showCenterMarker,
      isTrue,
    );

    container.read(screenshotProvider.notifier).setIsScreenShot(true);
    await tester.pump();

    expect(
      tester
          .widget<CustomCircleUtilityWidget>(
            find.byType(CustomCircleUtilityWidget).first,
          )
          .showCenterMarker,
      isFalse,
    );
  });

  testWidgets('rectangle screenshot removes center marker immediately',
      (tester) async {
    final utility = _rectangle();
    final container = _containerWith(utility);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _harness(
        container: container,
        child: PlacedCustomRectangleWidget(
          utility: utility,
          id: utility.id,
          onDragEnd: (_) {},
        ),
      ),
    );
    expect(
      tester
          .widget<CustomRectangleUtilityWidget>(
            find.byType(CustomRectangleUtilityWidget).first,
          )
          .showCenterMarker,
      isTrue,
    );

    container.read(screenshotProvider.notifier).setIsScreenShot(true);
    await tester.pump();

    expect(
      tester
          .widget<CustomRectangleUtilityWidget>(
            find.byType(CustomRectangleUtilityWidget).first,
          )
          .showCenterMarker,
      isFalse,
    );
  });
}

ProviderContainer _containerWith(PlacedUtility utility) {
  final container = ProviderContainer(
    overrides: [mapProvider.overrideWith(_FixedMapProvider.new)],
  );
  container.read(utilityProvider.notifier).fromHive([utility]);
  return container;
}

Widget _harness({
  required ProviderContainer container,
  required Widget child,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(home: Scaffold(body: Center(child: child))),
  );
}

PlacedUtility _circle() => PlacedUtility(
      id: 'circle',
      type: UtilityType.customCircle,
      position: const Offset(400, 300),
      customDiameter: 12,
      customColorValue: 0xff8b5cf6,
      customOpacityPercent: 40,
    );

PlacedUtility _rectangle() => PlacedUtility(
      id: 'rectangle',
      type: UtilityType.customRectangle,
      position: const Offset(400, 300),
      customWidth: 8,
      customLength: 16,
      customColorValue: 0xff8b5cf6,
      customOpacityPercent: 40,
    );
