import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/keep_on_map_key_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/canvas_selection_layer.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_circle_utility_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _AscentAttack extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

class _AscentDefense extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: false);
}

class _OpenStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'keep-on-map',
        strategyName: null,
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  void setUnsaved() {}
}

const _map = Size(1600, 900);
const _agentAt = Offset(800, 500);

Future<ProviderContainer> _pumpCanvas(
  WidgetTester tester, {
  bool defense = false,
  Rect Function()? view,
  void Function(ProviderContainer container)? fill,
}) async {
  tester.view
    ..physicalSize = _map
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  CoordinateSystem(playAreaSize: _map);
  final container = ProviderContainer(overrides: [
    mapProvider.overrideWith(defense ? _AscentDefense.new : _AscentAttack.new),
    strategyProvider.overrideWith(_OpenStrategy.new),
  ]);
  addTearDown(container.dispose);
  if (fill != null) {
    fill(container);
  } else {
    container.read(agentProvider.notifier).fromHive([
      PlacedAgent(
        id: 'jett',
        type: AgentType.jett,
        position: _agentAt,
        isAlly: true,
      ),
    ]);
  }
  bool forward(KeyEvent event) {
    container.read(keepOnMapKeyProvider.notifier).handleKeyEvent(event);
    return false;
  }

  HardwareKeyboard.instance.addHandler(forward);
  addTearDown(() => HardwareKeyboard.instance.removeHandler(forward));
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: ShadApp(
      themeMode: ThemeMode.dark,
      darkTheme: ShadThemeData(
        brightness: Brightness.dark,
        colorScheme: Settings.tacticalVioletTheme,
      ),
      home: Scaffold(
        body: SizedBox(
          width: 1600,
          height: 900,
          child: CanvasSelectionLayer(
            enabled: true,
            view: view,
            child: const PlacedWidgetBuilder(),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return container;
}

/// Presses the mouse on [at] and moves it past the slop that starts a drag.
Future<TestGesture> _startDrag(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  await tester.pump();
  await mouse.down(at);
  await tester.pump();
  await mouse.moveBy(const Offset(30, 0));
  await tester.pump();
  return mouse;
}

Future<void> _drop(WidgetTester tester, TestGesture mouse) async {
  await mouse.up();
  await tester.pumpAndSettle();
  await mouse.removePointer();
}

Offset _agentCentre(WidgetTester tester) =>
    tester.getCenter(find.byType(AgentWidget).first);

/// What the map's limit comes to in canvas pixels: outlines stop this far in.
double get _inset => CoordinateSystem.instance
    .coordinateToScreen(const Offset(CoordinateSystem.dropEdge + 2, 0))
    .dx;

void main() {
  testWidgets('Alt holds an item at the edge, and the drop keeps it', (
    tester,
  ) async {
    final container = await _pumpCanvas(tester);
    final box = tester.getSize(find.byType(AgentWidget).first);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final mouse = await _startDrag(tester, _agentCentre(tester));
    await mouse.moveTo(const Offset(-500, -500));
    await tester.pump();
    await _drop(tester, mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    expect(container.read(agentProvider), hasLength(1));
    final drawn = tester.getTopLeft(find.byType(AgentWidget).first);
    expect(drawn.dx, closeTo(_inset, 1));
    expect(drawn.dy, closeTo(_inset, 1));
    expect(box, tester.getSize(find.byType(AgentWidget).first));
  });

  testWidgets('the item stops at what is on screen, not at the canvas edge', (
    tester,
  ) async {
    // The canvas runs on past the window and under the sidebar.
    const view = Rect.fromLTRB(100, 0, 1200, 900);
    await _pumpCanvas(tester, view: () => view);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    var mouse = await _startDrag(tester, _agentCentre(tester));
    await mouse.moveTo(const Offset(1590, 400));
    await tester.pump();
    await _drop(tester, mouse);
    expect(
      tester.getTopRight(find.byType(AgentWidget).first).dx,
      closeTo(view.right - _inset, 1),
    );

    mouse = await _startDrag(tester, _agentCentre(tester));
    await mouse.moveTo(const Offset(5, 400));
    await tester.pump();
    await _drop(tester, mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(
      tester.getTopLeft(find.byType(AgentWidget).first).dx,
      closeTo(view.left + _inset, 1),
    );
  });

  testWidgets('without Alt the same drag still deletes the item', (
    tester,
  ) async {
    final container = await _pumpCanvas(tester);

    final mouse = await _startDrag(tester, _agentCentre(tester));
    await mouse.moveTo(const Offset(-500, -500));
    await tester.pump();
    await _drop(tester, mouse);

    expect(container.read(agentProvider), isEmpty);
  });

  testWidgets('the item slides along the edge after the pointer', (
    tester,
  ) async {
    await _pumpCanvas(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final at = _agentCentre(tester);
    final mouse = await _startDrag(tester, at);
    await mouse.moveTo(Offset(300, _map.height + 400));
    await tester.pump();
    await _drop(tester, mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    final drawn = tester.getRect(find.byType(AgentWidget).first);
    expect(drawn.bottom, closeTo(_map.height - _inset, 1));
    expect(drawn.center.dx, closeTo(300, 1));
  });

  testWidgets('Alt moves the item with the pointer still', (tester) async {
    final container = await _pumpCanvas(tester);

    final mouse = await _startDrag(tester, _agentCentre(tester));
    await mouse.moveTo(const Offset(-500, 300));
    await tester.pump();

    // Pressed past the edge, the item comes back to it...
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    final preview = find.byType(AgentWidget).last;
    expect(tester.getTopLeft(preview).dx, closeTo(_inset, 1));

    // ...and let go, it goes back to the pointer.
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(tester.getTopLeft(preview).dx, lessThan(0));

    await _drop(tester, mouse);
    expect(container.read(agentProvider), isEmpty);
  });

  testWidgets('an item already past the line can stay there', (tester) async {
    final container = await _pumpCanvas(
      tester,
      fill: (container) => container.read(agentProvider.notifier).fromHive([
        PlacedAgent(
          id: 'jett',
          type: AgentType.jett,
          position: const Offset(0, 400),
          isAlly: true,
        ),
      ]),
    );
    final before = tester.getTopLeft(find.byType(AgentWidget).first);
    expect(before.dx, lessThan(_inset));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final mouse = await _startDrag(tester, _agentCentre(tester));
    await mouse.moveBy(const Offset(-30, 20));
    await tester.pump();
    await _drop(tester, mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    expect(container.read(agentProvider), hasLength(1));
    final after = tester.getTopLeft(find.byType(AgentWidget).first);
    expect(after.dx, closeTo(before.dx, 1));
    expect(after.dy, closeTo(before.dy + 20, 1));
  });

  testWidgets('on the defense side the drawn edge is the one that holds', (
    tester,
  ) async {
    final container = await _pumpCanvas(tester, defense: true);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final mouse = await _startDrag(tester, _agentCentre(tester));
    await mouse.moveTo(const Offset(-500, 300));
    await tester.pump();
    await _drop(tester, mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    expect(container.read(agentProvider), hasLength(1));
    final drawn = tester.getTopLeft(find.byType(AgentWidget).first);
    expect(drawn.dx, closeTo(_inset, 1));
  });

  testWidgets('a circle goes by what it draws, not the box it is placed by', (
    tester,
  ) async {
    late ProviderContainer held;
    final anchor = UtilityData.utilityWidgets[UtilityType.customCircle]!
        .getAnchorPoint(mapScale: Maps.mapScale[MapValue.ascent]!);
    await _pumpCanvas(
      tester,
      fill: (container) {
        held = container;
        container.read(utilityProvider.notifier).fromHive([
          PlacedUtility(
            id: 'circle',
            type: UtilityType.customCircle,
            position: const Offset(800, 500) -
                CoordinateSystem.virtualToWorld(anchor),
            customDiameter: 12,
            customColorValue: 0xff8b5cf6,
            customOpacityPercent: 40,
          ),
        ]);
      },
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    final mouse = await _startDrag(
      tester,
      tester.getCenter(find.byType(CustomCircleUtilityWidget).first),
    );
    await mouse.moveTo(Offset(_map.width / 2, -600));
    await tester.pump();
    await _drop(tester, mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();

    final remaining =
        held.read(utilityProvider).where((utility) => !utility.isDeleted);
    expect(remaining, hasLength(1));
  });

  testWidgets('leaving the window lets go of Alt', (tester) async {
    final container = await _pumpCanvas(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    expect(container.read(keepOnMapKeyProvider), isTrue);

    container.read(keepOnMapKeyProvider.notifier).clear();
    expect(container.read(keepOnMapKeyProvider), isFalse);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  });
}
