import 'dart:io';

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
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/widgets/strategy_view_skeleton.dart';
import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

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

class _RecordingImages extends PlacedImageProvider {
  final added = <String>[];

  @override
  Future<void> addImage({
    required Uint8List imageBytes,
    required String? strategyId,
    required StrategySource? strategySource,
    required String fileExtension,
    Offset? position,
    double? aspectRatio,
    int? tagColorValue,
  }) async =>
      added.add(fileExtension);
}

const _viewport = Size(1300, 675);
const _canvasLeft = 100.0;
const _jett = ValueKey('jett-in-the-side-bar');
const _field = ValueKey('a-text-field-on-the-canvas');

Future<ProviderContainer> _editor(
  WidgetTester tester, {
  bool opening = false,
}) async {
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
  if (opening) _beginOpen(container);
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
      'a pointer pressed on a picture in the same frame an open starts, '
      'before the editor rebuilds, moves nothing', (tester) async {
    final container = await _editor(tester);
    final from = tester.getCenter(find.byType(ImageWidget).first);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: from);
    await tester.pump(const Duration(milliseconds: 200));

    _beginOpen(container);
    await mouse.down(from);
    for (var step = 1; step <= 10; step++) {
      await mouse.moveTo(from + const Offset(6, 4) * step.toDouble());
      await tester.pump();
    }
    await mouse.up();
    await tester.pump();
    await mouse.removePointer();

    expect(
      container.read(placedImageProvider).images.single.position,
      const Offset(800, 400),
    );
  });

  testWidgets(
      'Ctrl+Z pressed in the same frame an open starts, before the editor '
      'rebuilds, undoes nothing', (tester) async {
    final container = await _editor(tester);
    container.read(agentProvider.notifier).addAgent(PlacedAgent(
          id: 'placed-before',
          type: AgentType.jett,
          position: const Offset(300, 300),
        ));
    await tester.pump();

    _beginOpen(container);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(container.read(agentProvider), hasLength(1));
  });

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
      'a loading view mounted while an open runs shows after 0.5 s from its '
      'mount and is gone once the open ends', (tester) async {
    final container = await _editor(tester, opening: true);

    await tester.pump(const Duration(milliseconds: 490));
    expect(_skeletonOpacity(tester), isNull);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_skeletonOpacity(tester), 1);

    container
        .read(strategyOpeningProvider.notifier)
        .settle(container.read(strategyOpeningProvider)!.attempt);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(_skeletonOpacity(tester), isNull);
  });

  group('a file dragged from the desktop', () {
    late ProviderContainer container;
    late _RecordingImages images;
    late DropTarget target;
    late Finder overlay;
    final over = DropEventDetails(
      localPosition: const Offset(200, 200),
      globalPosition: const Offset(200, 200),
    );

    Future<void> mount(WidgetTester tester) async {
      container = ProviderContainer(overrides: [
        strategyProvider.overrideWith(_OpenStrategy.new),
        platformPolicyProvider.overrideWithValue(PlatformPolicy.desktop),
        placedImageProvider.overrideWith(_RecordingImages.new),
      ]);
      addTearDown(container.dispose);
      images = container.read(placedImageProvider.notifier) as _RecordingImages;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: ImageDropTarget(child: SizedBox.expand())),
        ),
      ));
      target = tester.widget<DropTarget>(find.byType(DropTarget));
      overlay = find.text(
        lookupAppLocalizations(const Locale('en')).imageDropOverlayLabel,
      );
    }

    Future<void> drop(WidgetTester tester) async {
      final folder = Directory.systemTemp.createTempSync('icarus-drop-');
      addTearDown(() => folder.deleteSync(recursive: true));
      final file = File('${folder.path}/smokes.png')
        ..writeAsBytesSync(const [137, 80, 78, 71, 13, 10, 26, 10]);
      await tester.runAsync(() async {
        target.onDragDone!(DropDoneDetails(
          files: [DropItemFile(file.path)],
          localPosition: const Offset(200, 200),
          globalPosition: const Offset(200, 200),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }

    testWidgets(
        'held over the map while an open runs shows no overlay, and shows '
        'it once the open ends', (tester) async {
      await mount(tester);
      final attempt = _beginOpen(container);
      await tester.pump();

      target.onDragEntered!(over);
      await tester.pump();
      expect(overlay, findsNothing);

      container.read(strategyOpeningProvider.notifier).settle(attempt);
      await tester.pump();
      expect(overlay, findsOneWidget);

      target.onDragExited!(over);
      await tester.pump();
      expect(overlay, findsNothing);
    });

    testWidgets(
        'dropped while an open runs imports nothing and leaves no overlay; '
        'dropped after it, it is imported', (tester) async {
      await mount(tester);
      target.onDragEntered!(over);
      await tester.pump();
      final attempt = _beginOpen(container);
      await tester.pump();

      await drop(tester);
      expect(images.added, isEmpty);
      expect(overlay, findsNothing);

      container.read(strategyOpeningProvider.notifier).settle(attempt);
      await tester.pump();
      expect(overlay, findsNothing);
      await drop(tester);
      expect(images.added, ['.png']);
    });
  });

  testWidgets(
      'when an open is replaced while its loading view shows, the view shows '
      'the strategy now being opened at once', (tester) async {
    late Directory folder;
    await tester.runAsync(() async {
      folder = await openUnitHive();
      final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      for (final (id, map) in [
        ('look-a', MapValue.bind),
        ('look-b', MapValue.lotus),
      ]) {
        await box.put(
          id,
          generatedStrategy(Optionals.unset)
              .copyWith(id: id, name: 'Look $id', mapData: map),
        );
      }
    });
    addTearDown(() => tester.runAsync(() async {
          await Hive.close();
          await folder.delete(recursive: true);
        }));
    final container = await _editor(tester);
    String? shownName() => tester
        .widget<StrategyViewSkeleton>(find.byType(StrategyViewSkeleton))
        .strategyName;
    final opens = container.read(strategyOpeningProvider.notifier);

    opens.begin('look-a', source: StrategySource.local);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(shownName(), 'Look look-a');

    final attempt = opens.begin('look-b', source: StrategySource.local);
    await tester.pump();
    expect(shownName(), 'Look look-b');
    opens.settle(attempt);
    await tester.pump(const Duration(milliseconds: 200));
  });
}
