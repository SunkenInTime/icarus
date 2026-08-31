import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_cursors.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/color_library_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_circle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_rectangle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/placed_custom_circle_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/placed_custom_rectangle_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/shape_indicator_fade.dart';
import 'package:icarus/widgets/mouse_watch.dart';
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
          isAttack: true,
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

  testWidgets('rectangle rotation handle communicates hover and active states',
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
          isAttack: true,
          onDragEnd: (_) {},
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(find.byType(CustomRectangleUtilityWidget)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      tester
          .widgetList<ShapeIndicatorFade>(find.byType(ShapeIndicatorFade))
          .every((indicator) => indicator.visible),
      isTrue,
    );
    expect(find.byIcon(Icons.rotate_right_rounded), findsOneWidget);

    final handle = find.byKey(
      const ValueKey('custom-rectangle-rotate-top-center'),
    );
    final handleMouseRegion =
        find.ancestor(of: handle, matching: find.byType(MouseRegion)).first;
    expect(
      tester.widget<MouseRegion>(handleMouseRegion).cursor,
      shapeRotationMouseCursor(active: false),
    );

    final handleCenter = tester.getCenter(handle);
    await mouse.moveTo(handleCenter);
    await mouse.down(handleCenter);
    await mouse.moveBy(const Offset(30, 8));
    await tester.pump();

    expect(
      tester.widgetList<MouseRegion>(find.byType(MouseRegion)).any(
            (region) => region.cursor == shapeRotationMouseCursor(active: true),
          ),
      isTrue,
    );
    final activeBadgeIcon = tester.widget<Icon>(
      find.descendant(
        of: handle,
        matching: find.byIcon(Icons.rotate_right_rounded),
      ),
    );
    expect(
      activeBadgeIcon.color,
      Settings.tacticalVioletTheme.primary,
    );

    await mouse.up();
    await tester.pump();

    expect(container.read(utilityProvider).single.rotation, greaterThan(0));
  });

  testWidgets(
      'defense rectangle projects rotation and stores rotation edits canonically',
      (tester) async {
    const canonicalRotation = 0.3;
    final utility = _rectangle()..rotation = canonicalRotation;
    final container = _containerWith(utility);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _harness(
        container: container,
        child: PlacedCustomRectangleWidget(
          utility: utility,
          id: utility.id,
          isAttack: false,
          onDragEnd: (_) {},
        ),
      ),
    );

    final rotationTransform = tester.widget<Transform>(
      find.byKey(const ValueKey('custom-rectangle-rotation')),
    );
    const displayedRotation = canonicalRotation + math.pi;
    expect(
      rotationTransform.transform.storage[0],
      closeTo(math.cos(displayedRotation), 0.0001),
    );
    expect(
      rotationTransform.transform.storage[1],
      closeTo(math.sin(displayedRotation), 0.0001),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(find.byType(CustomRectangleUtilityWidget)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final handle = find.byKey(
      const ValueKey('custom-rectangle-rotate-top-center'),
    );
    final handleCenter = tester.getCenter(handle);
    await mouse.moveTo(handleCenter);
    await mouse.down(handleCenter);
    await mouse.moveBy(const Offset(30, 8));
    await tester.pump();
    await mouse.up();
    await tester.pump();

    final storedRotation = container.read(utilityProvider).single.rotation;
    expect(storedRotation, isNot(closeTo(canonicalRotation, 0.0001)));
    expect(
      (storedRotation - canonicalRotation).abs(),
      lessThan(math.pi / 2),
      reason: 'The defense display half-turn must not be saved as canonical.',
    );
  });

  testWidgets('shape center menu changes the placed shape color',
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

    await _openShapeColorSubmenu(tester);
    await tester.tap(find.text('Red'));
    await tester.pumpAndSettle();

    expect(
      container.read(utilityProvider).single.customColorValue,
      Colors.red.toARGB32(),
    );
    expect(container.read(actionProvider), hasLength(1));

    await _openShapeColorSubmenu(tester);
    final selectedRedItem = tester
        .widgetList<ShadContextMenuItem>(find.byType(ShadContextMenuItem))
        .firstWhere(
          (item) => item.child is Text && (item.child as Text).data == 'Red',
        );
    expect(selectedRedItem.trailing, isA<Icon>());

    await tester.tap(find.text('Custom color…'));
    await tester.pumpAndSettle();

    expect(find.text('Custom color'), findsOneWidget);
    expect(find.text('Apply'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '120');
    await tester.enterText(find.byType(TextField).at(1), '100');
    await tester.enterText(find.byType(TextField).at(2), '100');
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(
      container.read(utilityProvider).single.customColorValue,
      const Color(0xFF00FF00).toARGB32(),
    );
    expect(container.read(actionProvider), hasLength(2));
  });
}

Future<void> _openShapeColorSubmenu(WidgetTester tester) async {
  final centerHandle = find.byType(MouseWatch).first;
  await tester.tapAt(
    tester.getCenter(centerHandle),
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();

  final colorItem = find.text('Color');
  expect(colorItem, findsOneWidget);
  await tester.sendEventToBinding(
    PointerHoverEvent(position: tester.getCenter(colorItem)),
  );
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pumpAndSettle();
}

ProviderContainer _containerWith(PlacedUtility utility) {
  final container = ProviderContainer(
    overrides: [
      mapProvider.overrideWith(_FixedMapProvider.new),
      colorLibraryProvider.overrideWith(
        (ref) => const [
          ColorLibraryEntry(color: Colors.white, isCustom: false),
          ColorLibraryEntry(color: Colors.red, isCustom: false),
        ],
      ),
    ],
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
    child: ShadApp(
      themeMode: ThemeMode.dark,
      darkTheme: ShadThemeData(
        brightness: Brightness.dark,
        colorScheme: Settings.tacticalVioletTheme,
      ),
      home: Scaffold(body: Center(child: child)),
    ),
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
