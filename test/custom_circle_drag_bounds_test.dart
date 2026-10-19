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
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_circle_utility_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _AscentAttack extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

class _OpenStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        isSaved: true,
        stratName: null,
        id: 'circle-bounds',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

const _viewport = Size(1200, 675);

/// A 12 m circle centred at [centreWorld], dragged by [by] with the mouse.
/// Returns the circles still on the page.
Future<List<PlacedUtility>> _dragCircle(
  WidgetTester tester, {
  required Offset centreWorld,
  required Offset by,
}) async {
  tester.view
    ..physicalSize = _viewport
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  CoordinateSystem(playAreaSize: _viewport);
  final container = ProviderContainer(overrides: [
    mapProvider.overrideWith(_AscentAttack.new),
    strategyProvider.overrideWith(_OpenStrategy.new),
  ]);
  addTearDown(container.dispose);
  final anchor = UtilityData.utilityWidgets[UtilityType.customCircle]!
      .getAnchorPoint(mapScale: Maps.mapScale[MapValue.ascent]!);
  container.read(utilityProvider.notifier).fromHive([
    PlacedUtility(
      id: 'circle',
      type: UtilityType.customCircle,
      position: centreWorld - CoordinateSystem.virtualToWorld(anchor),
      customDiameter: 12,
      customColorValue: 0xff8b5cf6,
      customOpacityPercent: 40,
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
  await tester.pumpAndSettle();

  final centre = tester.getCenter(find.byType(CustomCircleUtilityWidget).first);
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: centre);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await mouse.down(centre);
  await mouse.moveBy(by);
  await tester.pump();
  await mouse.up();
  await tester.pumpAndSettle();
  await mouse.removePointer();
  return container
      .read(utilityProvider)
      .where((utility) => !utility.isDeleted)
      .toList();
}

void main() {
  // The box a circle is placed by is 110 m wide, so its anchor is far larger
  // in drawing units than in saved-position units. Measured in the wrong
  // ones, a circle near the top of the map read as off it.
  testWidgets('a circle near the top of the map survives a drag',
      (tester) async {
    final remaining = await _dragCircle(
      tester,
      centreWorld: const Offset(888, 100),
      by: const Offset(20, 0),
    );
    expect(remaining, hasLength(1));
  });

  testWidgets('a circle dropped off the map is removed', (tester) async {
    final remaining = await _dragCircle(
      tester,
      centreWorld: const Offset(888, 100),
      by: const Offset(0, -120),
    );
    expect(remaining, isEmpty);
  });
}
