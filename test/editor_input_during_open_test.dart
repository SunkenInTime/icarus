import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/caption_card_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/editor_input_gate.dart';
import 'package:icarus/widgets/global_shortcuts.dart';
import 'package:icarus/widgets/image_drop_target.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _Ascent extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

class _OpenStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'leaving',
        strategyName: 'Leaving',
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

const _viewport = Size(1300, 675);
const _canvasLeft = 100.0;
const _jett = ValueKey('jett-in-the-side-bar');
const _field = ValueKey('a-text-field-on-the-canvas');

Future<ProviderContainer> _editor(WidgetTester tester) async {
  tester.view
    ..physicalSize = _viewport
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  CoordinateSystem(playAreaSize: const Size(1200, 675));
  final container = ProviderContainer(overrides: [
    mapProvider.overrideWith(_Ascent.new),
    strategyProvider.overrideWith(_OpenStrategy.new),
  ]);
  addTearDown(container.dispose);
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  container.read(placedImageProvider.notifier).fromHive([
    PlacedImage(
      id: 'picture',
      position: const Offset(800, 400),
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
      builder: (context, child) => GlobalShortcuts(child: child!),
      home: Scaffold(
        body: Stack(
          children: [
            Row(
              children: [
                SizedBox(
                  width: _canvasLeft,
                  height: 675,
                  child: Center(
                    child: Draggable<DraggableData>(
                      data: AgentData.agents[AgentType.jett]!,
                      feedback: const SizedBox(width: 40, height: 40),
                      child: const SizedBox(
                        key: _jett,
                        width: 40,
                        height: 40,
                        child: ColoredBox(color: Color(0xFF00FF00)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(
                  width: 1200,
                  height: 675,
                  child: EditorInputGate(
                    child: Stack(
                      children: [
                        PlacedWidgetBuilder(),
                        Positioned(
                          left: 20,
                          bottom: 20,
                          width: 200,
                          child: Material(child: TextField(key: _field)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const Positioned.fill(
              child: EditorOpeningSkeleton(leading: SizedBox()),
            ),
          ],
        ),
      ),
    ),
  ));
  await tester.pump();
  return container;
}

int _beginOpen(ProviderContainer container) => container
    .read(strategyOpeningProvider.notifier)
    .begin('opened', source: StrategySource.local);

double? _skeletonOpacity(WidgetTester tester) {
  final fade = find.descendant(
    of: find.byType(EditorOpeningSkeleton),
    matching: find.byType(FadeTransition),
  );
  if (fade.evaluate().isEmpty) return null;
  return tester.widget<FadeTransition>(fade.first).opacity.value;
}

Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: from);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await mouse.down(from);
  await tester.pump();
  for (var step = 1; step <= 10; step++) {
    await mouse.moveTo(Offset.lerp(from, to, step / 10)!);
    await tester.pump();
  }
  await mouse.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await mouse.removePointer();
}

Future<void> _pressUndo(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  for (final opening in [false, true]) {
    final when = opening ? 'while an open runs' : 'with no open running';

    testWidgets(
        'an agent dropped on the canvas $when: '
        '${opening ? 'nothing lands' : 'it lands'}', (tester) async {
      final container = await _editor(tester);
      if (opening) _beginOpen(container);
      await tester.pump();

      await _drag(
        tester,
        tester.getCenter(find.byKey(_jett)),
        const Offset(_canvasLeft + 600, 300),
      );

      expect(container.read(agentProvider), hasLength(opening ? 0 : 1));
      expect(container.read(strategyProvider).isSaved, opening);
    });

    testWidgets(
        'a picture dragged on the canvas $when: '
        '${opening ? 'it stays put' : 'it moves'}', (tester) async {
      final container = await _editor(tester);
      if (opening) _beginOpen(container);
      await tester.pump();
      final drawn = tester.getRect(find.byType(ImageWidget).first);

      await _drag(tester, drawn.center, drawn.center + const Offset(60, 40));

      expect(
        container.read(placedImageProvider).images.single.position,
        opening ? const Offset(800, 400) : isNot(const Offset(800, 400)),
      );
      expect(container.read(strategyProvider).isSaved, opening);
    });

    testWidgets(
        'Ctrl+Z $when: '
        '${opening ? 'nothing is undone' : 'the last edit is undone'}',
        (tester) async {
      final container = await _editor(tester);
      container.read(agentProvider.notifier).addAgent(PlacedAgent(
            id: 'placed-before',
            type: AgentType.jett,
            position: const Offset(300, 300),
          ));
      if (opening) _beginOpen(container);
      await tester.pump();

      await _pressUndo(tester);

      expect(container.read(agentProvider), hasLength(opening ? 1 : 0));
    });
  }

  testWidgets(
      'an open starting takes focus from a field on the canvas and closes '
      'a caption being read; the canvas takes input again once it ends',
      (tester) async {
    final container = await _editor(tester);
    await tester.tap(find.byKey(_field));
    await tester.pump();
    final focused = tester
        .widget<EditableText>(
          find.descendant(
            of: find.byKey(_field),
            matching: find.byType(EditableText),
          ),
        )
        .focusNode;
    expect(focused.hasFocus, isTrue);
    container.read(agentProvider.notifier).fromHive([
      PlacedAgent(
        id: 'captioned',
        type: AgentType.sova,
        position: const Offset(500, 200),
      )..caption = 'Smoke here first',
    ]);
    container.read(captionCardProvider.notifier).openNow('captioned');
    expect(container.read(captionCardProvider), isNotNull);

    final attempt = _beginOpen(container);
    await tester.pump();

    expect(focused.hasFocus, isFalse);
    expect(container.read(captionCardProvider), isNull);
    container.read(strategyOpeningProvider.notifier).settle(attempt);
    await tester.pump();
    await _drag(
      tester,
      tester.getCenter(find.byKey(_jett)),
      const Offset(_canvasLeft + 600, 300),
    );
    expect(container.read(agentProvider), hasLength(2));
  });

  testWidgets(
      'the skeleton is never seen for an open shorter than 0.5 s; a longer '
      'one fades it fully in, and it is gone once the open ends',
      (tester) async {
    final container = await _editor(tester);

    final quick = _beginOpen(container);
    await tester.pump(const Duration(milliseconds: 450));
    container.read(strategyOpeningProvider.notifier).settle(quick);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_skeletonOpacity(tester), isNull);

    final slow = _beginOpen(container);
    await tester.pump(const Duration(milliseconds: 490));
    expect(_skeletonOpacity(tester), isNull);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_skeletonOpacity(tester), 1);
    container.read(strategyOpeningProvider.notifier).settle(slow);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_skeletonOpacity(tester), isNull);
  });

  testWidgets(
      'a file dragged over the map while an open runs shows no drop overlay, '
      'and one dragged before it never leaves the overlay behind',
      (tester) async {
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_OpenStrategy.new),
      platformPolicyProvider.overrideWithValue(PlatformPolicy.desktop),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShadApp(
        home: Scaffold(body: ImageDropTarget(child: SizedBox.expand())),
      ),
    ));
    final target = tester.widget<DropTarget>(find.byType(DropTarget));
    final over = DropEventDetails(
      localPosition: const Offset(200, 200),
      globalPosition: const Offset(200, 200),
    );
    final label = find.text(
      lookupAppLocalizations(const Locale('en')).imageDropOverlayLabel,
    );

    target.onDragEntered!(over);
    await tester.pump();
    expect(label, findsOneWidget);
    final attempt = _beginOpen(container);
    await tester.pump();
    target.onDragExited!(over);
    await tester.pump();
    expect(label, findsNothing, reason: 'left while the open ran');

    target.onDragEntered!(over);
    await tester.pump();
    expect(label, findsNothing, reason: 'entered while the open ran');
    container.read(strategyOpeningProvider.notifier).settle(attempt);
    await tester.pump();

    target.onDragEntered!(over);
    await tester.pump();
    expect(label, findsOneWidget);
    _beginOpen(container);
    await tester.pump();
    target.onDragDone!(const DropDoneDetails(
      files: [],
      localPosition: Offset(200, 200),
      globalPosition: Offset(200, 200),
    ));
    await tester.pump();
    expect(label, findsNothing, reason: 'dropped while the open ran');
  });
}
