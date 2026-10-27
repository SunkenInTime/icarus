import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/canvas_selection_layer.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';

class _NoopStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() {
    return const StrategyState(
      strategyId: 'test-strategy',
      strategyName: null,
      source: StrategySource.local,
      storageDirectory: null,
      isOpen: true,
    );
  }

  @override
  void setUnsaved() {}
}

/// How often the handle on item a has been dragged.
var _handleMoves = 0;

/// An item drawn as a 20 px square with its top-left at [at], the way the
/// canvas draws one: in its own layer, marking what it draws. With
/// [handle], a 6 px handle in its top-right corner takes drags of its own,
/// as a resize or rotate handle does.
Widget _item(String id, Offset at, {bool handle = false}) => EditorEntityLayer(
      id: id,
      kind: SelectableKind.agent,
      child: Positioned(
        left: at.dx,
        top: at.dy,
        child: SizedBox.square(
          dimension: 20,
          child: Stack(
            children: [
              const EditorItemOutline(
                child: SizedBox.square(
                  dimension: 20,
                  child: ColoredBox(color: Colors.white),
                ),
              ),
              if (handle)
                Positioned(
                  right: 0,
                  top: 0,
                  child: GestureDetector(
                    onPanUpdate: (_) => _handleMoves++,
                    child: const SizedBox.square(
                      dimension: 6,
                      child: ColoredBox(color: Colors.black),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

const _a = (kind: SelectableKind.agent, id: 'a');
const _b = (kind: SelectableKind.agent, id: 'b');
const _c = (kind: SelectableKind.agent, id: 'c');

void main() {
  late ProviderContainer container;
  late Directory tempDir;

  setUpAll(() {
    registerIcarusAdapters(Hive);
    CoordinateSystem(playAreaSize: const Size(800, 450));
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-selection-');
    Hive.init(tempDir.path);
    // Told already: the first-open hint would write preferences mid-test.
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox).then(
      (box) => box.put(
        MapThemeProfilesProvider.appPreferencesSingletonKey,
        AppPreferences(
          defaultThemeProfileIdForNewStrategies:
              MapThemeProfilesProvider.immutableDefaultProfile.id,
          canvasSelectionHintSeen: true,
        ),
      ),
    );
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  Future<void> pumpCanvas(WidgetTester tester) async {
    container = ProviderContainer(
      overrides: [strategyProvider.overrideWith(_NoopStrategyProvider.new)],
    );
    addTearDown(container.dispose);
    container.read(agentProvider.notifier).fromHive([
      for (final id in ['a', 'b', 'c'])
        PlacedAgent(id: id, type: AgentType.jett, position: Offset.zero),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: CanvasSelectionLayer(
              enabled: true,
              child: SizedBox(
                width: 800,
                height: 450,
                child: Stack(
                  children: [
                    _item('a', const Offset(100, 100), handle: true),
                    _item('b', const Offset(200, 100)),
                    _item('c', const Offset(400, 300)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> mouseDrag(WidgetTester tester, Offset from, Offset to) async {
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
  }

  testWidgets('a box selects the items whose middle it covers', (
    tester,
  ) async {
    await pumpCanvas(tester);

    // Covers a's middle (110, 110) and b's (210, 110), not c's.
    await mouseDrag(tester, const Offset(50, 50), const Offset(250, 200));

    expect(container.read(canvasSelectionProvider), {_a, _b});
  });

  testWidgets('a touch drag draws no box: touch still moves the map', (
    tester,
  ) async {
    await pumpCanvas(tester);

    final gesture = await tester.startGesture(
      const Offset(50, 50),
      kind: PointerDeviceKind.touch,
    );
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(
        Offset.lerp(const Offset(50, 50), const Offset(250, 200), i / 10)!,
      );
      await tester.pump();
    }
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint &&
            widget.painter.runtimeType.toString() == '_SelectionBoxPainter',
      ),
      findsNothing,
    );
    await gesture.up();
    await tester.pump();

    expect(container.read(canvasSelectionProvider), isEmpty);
  });

  testWidgets('a box drawn up and to the left selects the same', (
    tester,
  ) async {
    await pumpCanvas(tester);

    await mouseDrag(tester, const Offset(250, 200), const Offset(50, 50));

    expect(container.read(canvasSelectionProvider), {_a, _b});
  });

  testWidgets('Shift adds with a click, a click on nothing clears', (
    tester,
  ) async {
    await pumpCanvas(tester);

    await tester.tapAt(const Offset(110, 110), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(container.read(canvasSelectionProvider), {_a});

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(const Offset(410, 310), kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(container.read(canvasSelectionProvider), {_a, _c});

    await tester.tapAt(const Offset(600, 50), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(container.read(canvasSelectionProvider), isEmpty);
  });

  testWidgets('with Space held a drag selects nothing', (tester) async {
    await pumpCanvas(tester);
    // The canvas has the keyboard once it is pressed.
    await tester.tapAt(const Offset(600, 50), kind: PointerDeviceKind.mouse);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await mouseDrag(tester, const Offset(50, 50), const Offset(250, 200));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);

    expect(container.read(canvasSelectionProvider), isEmpty);
    expect(container.read(canvasPanKeyHeldProvider), isFalse);
  });

  testWidgets('Escape clears the selection, select all takes the page', (
    tester,
  ) async {
    await pumpCanvas(tester);
    await mouseDrag(tester, const Offset(50, 50), const Offset(250, 200));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(container.read(canvasSelectionProvider), isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(container.read(canvasSelectionProvider), {_a, _b, _c});
  });

  Offset positionOf(String id) => container
      .read(agentProvider)
      .firstWhere((agent) => agent.id == id)
      .position;

  Future<TestGesture> dragFrom(
    WidgetTester tester,
    Offset from,
    Offset to,
  ) async {
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump();
    }
    return gesture;
  }

  testWidgets('dragging a selected item moves the selection in one step', (
    tester,
  ) async {
    await pumpCanvas(tester);
    container.read(canvasSelectionProvider.notifier).select([_a, _b]);
    await tester.pump();

    final gesture = await dragFrom(
      tester,
      const Offset(110, 110),
      const Offset(160, 130),
    );
    // Drawn where the drag has carried them, saved where they were.
    expect(container.read(canvasGroupDragProvider)?.by, const Offset(50, 20));
    expect(positionOf('a'), Offset.zero);
    await gesture.up();
    await tester.pump();

    final moved = CoordinateSystem.instance.screenToCoordinate(
      const Offset(50, 20),
    );
    expect(positionOf('a'), moved);
    expect(positionOf('b'), moved);
    expect(positionOf('c'), Offset.zero);
    expect(container.read(canvasGroupDragProvider), isNull);
    expect(container.read(canvasSelectionProvider), {_a, _b});

    container.read(actionProvider.notifier).undoAction();
    expect(positionOf('a'), Offset.zero);
    expect(positionOf('b'), Offset.zero);
  });

  testWidgets('Escape during a drag leaves everything where it was', (
    tester,
  ) async {
    await pumpCanvas(tester);
    container.read(canvasSelectionProvider.notifier).select([_a, _b]);
    await tester.pump();

    final gesture = await dragFrom(
      tester,
      const Offset(110, 110),
      const Offset(160, 130),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await gesture.up();
    await tester.pump();

    expect(positionOf('a'), Offset.zero);
    expect(positionOf('b'), Offset.zero);
    expect(container.read(canvasGroupDragProvider), isNull);
    expect(container.read(canvasSelectionProvider), {_a, _b});
  });

  testWidgets('a drag stops where the selection would leave the map', (
    tester,
  ) async {
    await pumpCanvas(tester);
    container.read(canvasSelectionProvider.notifier).select([_a, _c]);
    await tester.pump();

    final gesture = await dragFrom(
      tester,
      const Offset(410, 310),
      const Offset(410, 900),
    );
    await gesture.up();
    await tester.pump();

    // c's middle (410, 310) stops short of the bottom edge; a moves as far.
    final margin =
        CoordinateSystem.instance.coordinateToScreen(const Offset(20, 0)).dx;
    final moved = CoordinateSystem.instance.screenToCoordinate(
      Offset(0, 450 - margin - 310),
    );
    expect(positionOf('c').dy, closeTo(moved.dy, 0.001));
    expect(positionOf('a'), positionOf('c'));
  });

  testWidgets('selecting more mid-drag moves only what the drag began with', (
    tester,
  ) async {
    await pumpCanvas(tester);
    container.read(canvasSelectionProvider.notifier).select([_a, _b]);
    await tester.pump();

    final gesture = await dragFrom(
      tester,
      const Offset(110, 110),
      const Offset(110, 300),
    );
    container.read(canvasSelectionProvider.notifier).selectAll();
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(positionOf('a'), isNot(Offset.zero));
    expect(positionOf('c'), Offset.zero);
  });

  testWidgets('a click on one of the selection selects that one', (
    tester,
  ) async {
    await pumpCanvas(tester);
    container.read(canvasSelectionProvider.notifier).select([_a, _b]);
    await tester.pump();

    await tester.tapAt(const Offset(210, 110), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(container.read(canvasSelectionProvider), {_b});

    container.read(canvasSelectionProvider.notifier).select([_a, _b]);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(const Offset(210, 110), kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(container.read(canvasSelectionProvider), {_a});
  });

  testWidgets("a selected item's handle keeps its own drag", (tester) async {
    await pumpCanvas(tester);
    container.read(canvasSelectionProvider.notifier).select([_a, _b]);
    await tester.pump();
    _handleMoves = 0;

    final gesture = await dragFrom(
      tester,
      const Offset(117, 103),
      const Offset(160, 103),
    );
    await gesture.up();
    await tester.pump();

    expect(_handleMoves, greaterThan(0));
    expect(positionOf('a'), Offset.zero);
    expect(positionOf('b'), Offset.zero);
  });

  testWidgets('Space pressed mid-drag still ends the drag', (tester) async {
    await pumpCanvas(tester);
    container.read(canvasSelectionProvider.notifier).select([_a, _b]);
    await tester.pump();

    final gesture = await dragFrom(
      tester,
      const Offset(110, 110),
      const Offset(160, 130),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(container.read(canvasGroupDragProvider), isNull);
    expect(positionOf('a'), positionOf('b'));
    expect(positionOf('a'), isNot(Offset.zero));
  });
}
