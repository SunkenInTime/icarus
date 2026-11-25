import 'dart:async';
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
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/canvas_selection_layer.dart';
import 'package:icarus/widgets/editor_input_gate.dart';
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

var _handleMoves = 0;

/// An item drawn as a 20 px square with its top-left at [at], the way the
/// canvas draws one: in its own layer, marking what it draws. With
/// [handle], a 6 px handle in its top-right corner takes drags of its own,
/// as a resize or rotate handle does.
Widget _item(
  String id,
  Offset at, {
  bool handle = false,
  SelectableKind kind = SelectableKind.agent,
}) =>
    EditorEntityLayer(
      id: id,
      kind: kind,
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

var _insidePresses = 0;

Widget _gatedIf(bool gated, Widget layer) => gated
    ? Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            child: TextButton(
              key: const ValueKey('strip-button'),
              onPressed: () {},
              child: const Text('Library'),
            ),
          ),
          EditorInputGate(
            child: Stack(
              children: [
                layer,
                const Positioned(
                  left: 600,
                  top: 400,
                  width: 150,
                  child: Material(child: TextField(key: ValueKey('field'))),
                ),
                Positioned(
                  left: 600,
                  top: 20,
                  child: Material(
                    child: TextButton(
                      onPressed: () => _insidePresses++,
                      child: const Text('Inside'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      )
    : layer;

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

  Future<void> pumpCanvas(
    WidgetTester tester, {
    bool lineUp = false,
    bool gated = false,
    bool opening = false,
  }) async {
    container = ProviderContainer(
      overrides: [strategyProvider.overrideWith(_NoopStrategyProvider.new)],
    );
    addTearDown(container.dispose);
    if (opening) {
      container
          .read(strategyOpeningProvider.notifier)
          .begin('opened', source: StrategySource.local);
    }
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
            child: _gatedIf(
              gated,
              CanvasSelectionLayer(
                enabled: true,
                child: SizedBox(
                  width: 800,
                  height: 450,
                  child: Stack(
                    children: [
                      // As a lineup mode puts the page out of reach.
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: lineUp,
                          child: Stack(
                            children: [
                              _item('a', const Offset(100, 100), handle: true),
                              _item('b', const Offset(200, 100)),
                              _item('c', const Offset(400, 300)),
                            ],
                          ),
                        ),
                      ),
                      if (lineUp) ...[
                        _item(
                          'draft-agent',
                          const Offset(150, 100),
                          kind: SelectableKind.lineupEnd,
                        ),
                        _item(
                          'draft-ability',
                          const Offset(150, 150),
                          kind: SelectableKind.lineupEnd,
                        ),
                      ],
                    ],
                  ),
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

  testWidgets('a box selects the items it covers', (tester) async {
    await pumpCanvas(tester);

    // Covers a (100, 100 to 120, 120) and b (200, 100 to 220, 120), not c.
    await mouseDrag(tester, const Offset(50, 50), const Offset(250, 200));

    expect(container.read(canvasSelectionProvider), {_a, _b});
  });

  testWidgets('a box that clips a corner of an item selects it', (
    tester,
  ) async {
    await pumpCanvas(tester);

    // c is drawn from (400, 300) to (420, 320); its middle stays outside.
    await mouseDrag(tester, const Offset(415, 315), const Offset(500, 400));

    expect(container.read(canvasSelectionProvider), {_c});
  });

  testWidgets('a box that stops short of an item selects nothing', (
    tester,
  ) async {
    await pumpCanvas(tester);

    await mouseDrag(tester, const Offset(425, 325), const Offset(500, 400));

    expect(container.read(canvasSelectionProvider), isEmpty);
  });

  group('in a lineup mode', () {
    const draftAgent = (kind: SelectableKind.lineupEnd, id: 'draft-agent');
    const draftAbility = (kind: SelectableKind.lineupEnd, id: 'draft-ability');

    Future<void> pumpLineUp(WidgetTester tester) async {
      await pumpCanvas(tester, lineUp: true);
      container
          .read(interactionStateProvider.notifier)
          .update(InteractionState.lineUpPlacing);
      final lineUps = container.read(lineUpProvider.notifier);
      lineUps.setDraftAgent(
        PlacedAgent(
          id: 'draft-agent',
          type: AgentType.jett,
          position: const Offset(100, 100),
        ),
      );
      lineUps.setDraftAbility(
        PlacedAbility(
          id: 'draft-ability',
          data: AgentData.agents[AgentType.jett]!.abilities.first,
          position: const Offset(200, 200),
        ),
      );
      await tester.pump();
    }

    testWidgets('a box takes the ends being placed, not the page', (
      tester,
    ) async {
      await pumpLineUp(tester);

      // Covers both drafts and the page's a and b.
      await mouseDrag(tester, const Offset(50, 50), const Offset(250, 200));

      expect(
        container.read(canvasSelectionProvider),
        {draftAgent, draftAbility},
      );
    });

    testWidgets('dragging the selected ends moves them both as it goes', (
      tester,
    ) async {
      await pumpLineUp(tester);
      await mouseDrag(tester, const Offset(50, 50), const Offset(250, 200));

      final gesture = await tester.startGesture(
        const Offset(160, 110),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(Offset(160 + i * 5, 110 + i * 2));
        await tester.pump();
      }

      final placement = container.read(lineUpProvider).placement!;
      final moved = placement.draftAgent!.position - const Offset(100, 100);
      expect(moved.dx, greaterThan(0));
      expect(moved.dy, greaterThan(0));
      expect(
        placement.draftAbility!.position - const Offset(200, 200),
        moved,
      );

      await gesture.up();
      await tester.pump();
      expect(container.read(agentProvider).first.position, Offset.zero);
      expect(
        container.read(canvasSelectionProvider),
        {draftAgent, draftAbility},
      );
    });

    testWidgets('Escape during the drag puts the ends back', (tester) async {
      await pumpLineUp(tester);
      await mouseDrag(tester, const Offset(50, 50), const Offset(250, 200));

      final gesture = await tester.startGesture(
        const Offset(160, 110),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(Offset(160 + i * 5, 110));
        await tester.pump();
      }
      expect(
        container.read(lineUpProvider).placement!.draftAgent!.position,
        isNot(const Offset(100, 100)),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await gesture.up();
      await tester.pump();

      final placement = container.read(lineUpProvider).placement!;
      expect(placement.draftAgent!.position, const Offset(100, 100));
      expect(placement.draftAbility!.position, const Offset(200, 200));
    });
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

  group('while a strategy opens', () {
    int beginOpen() => container
        .read(strategyOpeningProvider.notifier)
        .begin('opened', source: StrategySource.local);

    Future<void> selectAllThenDelete(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
    }

    Offset canvasPoint(WidgetTester tester) =>
        tester.getTopLeft(find.byType(CanvasSelectionLayer)) +
        const Offset(300, 300);

    void backButtonDown(WidgetTester tester) {
      tester.binding.handlePointerEvent(PointerDownEvent(
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
        position: canvasPoint(tester),
      ));
    }

    testWidgets(
        'Ctrl+A then Delete on a focused canvas, in the frame the open '
        'starts, change nothing', (tester) async {
      await pumpCanvas(tester, gated: true);
      await tester.tapAt(canvasPoint(tester));
      await tester.pump();

      beginOpen();
      await selectAllThenDelete(tester);

      expect(container.read(agentProvider), hasLength(3));
    });

    testWidgets(
        'mouse back on the canvas asking for focus before the open starts, '
        'then Ctrl+A and Delete in that frame, change nothing', (tester) async {
      await pumpCanvas(tester, gated: true);
      backButtonDown(tester);
      await Future<void>.microtask(() {});

      beginOpen();
      await selectAllThenDelete(tester);

      expect(container.read(agentProvider), hasLength(3));
    });

    testWidgets(
        'mouse back on the canvas asking for focus after the open starts, '
        'then Ctrl+A and Delete in that frame, change nothing', (tester) async {
      await pumpCanvas(tester, gated: true);
      backButtonDown(tester);
      beginOpen();
      await Future<void>.microtask(() {});

      await selectAllThenDelete(tester);

      expect(container.read(agentProvider), hasLength(3));
    });

    testWidgets(
        'with focus on a top-strip button, a canvas focus request queued '
        'before the open starts never lands: Ctrl+A and Delete change '
        'nothing', (tester) async {
      await pumpCanvas(tester, gated: true);
      final button = Focus.of(tester.element(find.text('Library')));
      button.requestFocus();
      await tester.pump();

      backButtonDown(tester);
      await Future<void>.microtask(() {});
      beginOpen();
      await tester.pump();
      await selectAllThenDelete(tester);

      expect(container.read(agentProvider), hasLength(3));
    });

    testWidgets(
        'an open ending under a dialog with nothing focused leaves the canvas '
        'without the keyboard; once the dialog closes, a click gives it back',
        (tester) async {
      await pumpCanvas(tester, gated: true);
      final attempt = beginOpen();
      await tester.pump();
      unawaited(showDialog<void>(
        context: tester.element(find.byType(CanvasSelectionLayer)),
        builder: (_) => const Dialog(child: SizedBox.square(dimension: 80)),
      ));
      await tester.pumpAndSettle();

      container.read(strategyOpeningProvider.notifier).settle(attempt);
      await tester.pump();
      await tester.pump();
      await selectAllThenDelete(tester);
      expect(container.read(agentProvider), hasLength(3));

      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();
      await tester.tapAt(canvasPoint(tester));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(container.read(canvasSelectionProvider), {_a, _b, _c});
    });

    testWidgets(
        "a screen reader's tap on a button inside the editor does nothing "
        'once the open has started', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpCanvas(tester, gated: true);
      _insidePresses = 0;
      tester.semantics.tap(find.semantics.byLabel('Inside'));
      await tester.pump();
      expect(_insidePresses, 1);

      beginOpen();
      await tester.pump();
      expect(
        () => tester.semantics.tap(find.semantics.byLabel('Inside')),
        throwsA(anything),
        reason: 'the button offers no tap while the open runs',
      );
      await tester.pump();
      expect(_insidePresses, 1);
      semantics.dispose();
    });

    testWidgets(
        'a gate mounted while an open runs refuses clicks and focus from the '
        'start, and takes both once the open ends', (tester) async {
      await pumpCanvas(tester, gated: true, opening: true);
      final field = tester
          .widget<EditableText>(find.descendant(
            of: find.byKey(const ValueKey('field')),
            matching: find.byType(EditableText),
          ))
          .focusNode;
      _insidePresses = 0;

      await tester.tap(find.text('Inside'), warnIfMissed: false);
      field.requestFocus();
      await tester.pump();
      expect(_insidePresses, 0);
      expect(field.hasFocus, isFalse);

      container
          .read(strategyOpeningProvider.notifier)
          .settle(container.read(strategyOpeningProvider)!.attempt);
      await tester.pump();
      await tester.tap(find.text('Inside'));
      field.requestFocus();
      await tester.pump();
      expect(_insidePresses, 1);
      expect(field.hasFocus, isTrue);
    });

    testWidgets('Tab reaches nothing in the editor', (tester) async {
      await pumpCanvas(tester, gated: true);
      beginOpen();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      final field = tester
          .widget<EditableText>(find.descendant(
            of: find.byKey(const ValueKey('field')),
            matching: find.byType(EditableText),
          ))
          .focusNode;
      expect(field.hasFocus, isFalse);
    });

    testWidgets('focus on a top-strip button stays there when it ends',
        (tester) async {
      await pumpCanvas(tester, gated: true);
      final attempt = beginOpen();
      await tester.pump();
      final button = Focus.of(tester.element(find.text('Library')));
      button.requestFocus();
      await tester.pump();
      expect(button.hasFocus, isTrue);

      container.read(strategyOpeningProvider.notifier).settle(attempt);
      await tester.pump();
      await tester.pump();

      expect(button.hasFocus, isTrue);
    });

    testWidgets('once it has opened, Ctrl+A works with no click',
        (tester) async {
      await pumpCanvas(tester, gated: true);
      final attempt = beginOpen();
      await tester.pump();
      container.read(strategyOpeningProvider.notifier).settle(attempt);
      await tester.pump();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(container.read(canvasSelectionProvider), {_a, _b, _c});
    });
  });

  testWidgets('a copy replaces what the system clipboard held', (tester) async {
    final written = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') written.add(call.arguments);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pumpCanvas(tester);

    // Nothing selected: nothing is copied, and the clipboard stays.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(written, isEmpty);

    await mouseDrag(tester, const Offset(50, 50), const Offset(250, 200));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(written, [
      {'text': ''},
    ]);
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
