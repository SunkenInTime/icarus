import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/replay_capture_record.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/replay_capture_queue_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/replay/replay_capture.dart';
import 'package:icarus/replay/replay_decoder.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_drawing.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:icarus/replay/replay_frame.dart';
import 'package:icarus/replay/replay_map_projection.dart';
import 'package:icarus/replay/replay_playback.dart';
import 'package:icarus/replay_view.dart';
import 'package:icarus/widgets/drawing_painter.dart';
import 'package:icarus/widgets/replay/replay_canvas.dart';
import 'package:icarus/widgets/replay/replay_drawing_layer.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'replay_test_support.dart';

const _mapPath = '/Game/Maps/Juliett/Juliett';

ReplayPlayback _playback() => ReplayPlayback(
      document: ReplayDocument.fromBytes(icrp(sampleJson())),
      projection: ReplayMapProjection.forMapPath(_mapPath)!,
      perspective: ReplayTeam.red,
    );

/// Serves one decoded replay from the cache, so opening it needs no
/// native decoder.
class _CachedReplay extends ReplayFiles {
  _CachedReplay(this.bytes, Directory support)
      : super(supportDirectory: () async => support);

  final Uint8List bytes;

  @override
  Future<Uint8List?> readCache(ReplayFile file, String decoderVersion) async =>
      bytes;

  @override
  Future<Set<String>> localSubjects() async => const {};
}

/// A capture queue with nothing in it that never sends.
class _IdleQueue extends ReplayCaptureQueue {
  @override
  ReplayCaptureQueueState build() => const ReplayCaptureQueueState();
}

void main() {
  late Directory temp;
  late Box<StrategyData> box;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    temp = await Directory.systemTemp.createTemp('icarus-replay-drawing');
    Hive.init(temp.path);
    registerIcarusAdapters(Hive);
    // The canvas draws in the user's default map theme.
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await _loadFonts();
  });

  setUp(() async {
    box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await box.clear();
  });

  tearDownAll(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });

  group('drawing over the replay', () {
    final coordinates = CoordinateSystem(playAreaSize: const Size(1600, 900));

    /// Draws a freehand stroke across the canvas.
    void stroke(ReplayDrawing drawing) {
      drawing.begin(
        const Offset(100, 100),
        coordinates,
        color: Colors.white,
        thickness: 5,
      );
      for (var x = 120.0; x <= 300; x += 20) {
        drawing.extend(Offset(x, 100), coordinates);
      }
      drawing.end(coordinates);
    }

    test('taking the pen out pauses playback', () {
      final playback = _playback()..play();
      final drawing = ReplayDrawing(playback)..toggle();
      expect(drawing.active, isTrue);
      expect(playback.playing, isFalse);
      drawing.toggle();
      expect(drawing.active, isFalse);
    });

    test('playing clears the strokes and puts the pen away', () {
      final playback = _playback();
      final drawing = ReplayDrawing(playback)..start();
      stroke(drawing);
      expect(drawing.strokes, hasLength(1));
      playback.play();
      expect(drawing.strokes, isEmpty);
      expect(drawing.active, isFalse);
    });

    test('moving the clock clears the strokes; the pen stays out', () {
      final playback = _playback();
      final drawing = ReplayDrawing(playback)..start();
      stroke(drawing);
      playback.seek(playback.timeMs + 5000);
      expect(drawing.strokes, isEmpty);
      expect(drawing.active, isTrue);

      stroke(drawing);
      playback.nextRound();
      expect(drawing.strokes, isEmpty);
    });

    test('anything else the replay changes leaves the strokes alone', () {
      final playback = _playback();
      final drawing = ReplayDrawing(playback)..start();
      stroke(drawing);
      playback
        ..perspective = ReplayTeam.blue
        ..speed = 2
        ..coneCutArrived();
      expect(drawing.strokes, hasLength(1));
      drawing.stop();
      expect(drawing.strokes, hasLength(1), reason: 'the pen put away');
    });

    test('a click that never moves draws nothing', () {
      final drawing = ReplayDrawing(_playback())..start();
      for (final tool in ReplayDrawingTool.values) {
        drawing
          ..tool = tool
          ..begin(
            const Offset(50, 50),
            coordinates,
            color: Colors.white,
            thickness: 5,
          )
          ..end(coordinates);
      }
      expect(drawing.strokes, isEmpty);
    });

    test('the arrow is a straight line with an arrowhead', () {
      final drawing = ReplayDrawing(_playback())
        ..start()
        ..tool = ReplayDrawingTool.arrow
        ..begin(
          const Offset(100, 100),
          coordinates,
          color: Colors.white,
          thickness: 5,
        )
        ..extend(const Offset(150, 200), coordinates)
        ..extend(const Offset(400, 300), coordinates)
        ..end(coordinates);
      final line = drawing.strokes.single as Line;
      expect(line.hasArrow, isTrue);
      expect(line.lineStart,
          coordinates.screenToCoordinate(const Offset(100, 100)));
      expect(
          line.lineEnd, coordinates.screenToCoordinate(const Offset(400, 300)));
    });

    test('a capture copies the strokes, sharing nothing with the screen', () {
      final drawing = ReplayDrawing(_playback())..start();
      stroke(drawing);
      final copy = drawing.forCapture().single as FreeDrawing;
      final shown = drawing.strokes.single as FreeDrawing;
      expect(copy.listOfPoints, shown.listOfPoints);
      expect(identical(copy, shown), isFalse);
      expect(identical(copy.listOfPoints, shown.listOfPoints), isFalse);
    });
  });

  group('the replay screen', () {
    const viewport = Size(1600, 900);

    Future<void> openReplay(WidgetTester tester) async {
      tester.view
        ..physicalSize = viewport
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final files = _CachedReplay(icrp(sampleJson()), temp);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          replayFilesProvider.overrideWithValue(files),
          svgHeightRuntimeProvider.overrideWith((ref, map) async => null),
          replayCaptureQueueProvider.overrideWith(_IdleQueue.new),
          replayCaptureStoreProvider.overrideWithValue(
            () => LocalReplayCaptureStore(createBlankStrategy),
          ),
        ],
        child: ShadApp(
          home: ReplayView(
            file: ReplayFile(
              path: '${temp.path}/match.vrf',
              source: ReplaySource.icarus,
              sizeBytes: 0,
              modified: DateTime(2026),
            ),
            probe: const ReplayProbe(
              matchId: 'match',
              mapPath: _mapPath,
              build: 'test',
              durationMs: 100000,
              supported: true,
              decoderVersion: 'test',
              agentIds: [],
            ),
          ),
        ),
      ));
      // The document is read on another isolate.
      for (var i = 0;
          i < 50 && find.byType(ReplayCanvas).evaluate().isEmpty;
          i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byType(ReplayCanvas), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 16));
    }

    ReplayCanvas canvas(WidgetTester tester) =>
        tester.widget<ReplayCanvas>(find.byType(ReplayCanvas));

    Matrix4 view(WidgetTester tester) => tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!
        .value
        .clone();

    /// Drags with the mouse across the middle of the map.
    Future<void> drag(WidgetTester tester) async {
      final from = tester.getCenter(find.byType(ReplayDrawingLayer));
      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(20, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
    }

    testWidgets(
        "The editor's Draw key (Q) and the pen button take the pen out and "
        'pause; Esc and Q put it away', (tester) async {
      await openReplay(tester);
      final playback = canvas(tester).playback;
      final drawing = canvas(tester).drawing;

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(playback.playing, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pump();
      expect(drawing.active, isTrue);
      expect(playback.playing, isFalse);
      // The pen's tools show while it is out; Clear only once something is
      // drawn.
      expect(find.byIcon(LucideIcons.lineSquiggle), findsOneWidget);
      expect(find.byIcon(LucideIcons.moveUpRight), findsOneWidget);
      expect(find.text('Clear'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(drawing.active, isFalse);
      expect(find.byIcon(LucideIcons.lineSquiggle), findsNothing);

      await tester.tap(find.byIcon(LucideIcons.pencil));
      await tester.pump();
      expect(drawing.active, isTrue);
      await tester.tap(find.byIcon(LucideIcons.pencil));
      await tester.pump();
      expect(drawing.active, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      expect(drawing.active, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      expect(drawing.active, isFalse);
      // D is the editor's Next page, not the pen.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      expect(drawing.active, isFalse);
      // Esc with the pen away is left to whoever else wants it.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(drawing.active, isFalse);
      await tester.pump(const Duration(milliseconds: 16));
    });

    testWidgets(
        'with the pen out a drag draws and does not pan; the wheel '
        'still zooms', (tester) async {
      await openReplay(tester);
      final drawing = canvas(tester).drawing;

      // Without the pen, the same drag pans the map.
      final resting = view(tester);
      await drag(tester);
      expect(view(tester), isNot(resting));
      expect(drawing.strokes, isEmpty);

      drawing.start();
      await tester.pump();
      final before = view(tester);
      await drag(tester);
      expect(view(tester), before, reason: 'a drag draws instead of panning');
      final stroke = drawing.strokes.single as FreeDrawing;
      expect(stroke.listOfPoints.length, greaterThan(5));
      expect(find.text('Clear'), findsOneWidget);

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final center = tester.getCenter(find.byType(ReplayDrawingLayer));
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -200)));
      await tester.pump();
      expect(view(tester).getMaxScaleOnAxis(),
          greaterThan(before.getMaxScaleOnAxis()));
      expect(drawing.strokes, hasLength(1));

      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(drawing.strokes, isEmpty);
      expect(find.text('Clear'), findsNothing);
    });

    testWidgets('strokes clear when playback resumes or the time changes',
        (tester) async {
      await openReplay(tester);
      final drawing = canvas(tester).drawing;

      drawing.start();
      await tester.pump();
      await drag(tester);
      expect(drawing.strokes, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(drawing.strokes, isEmpty);
      expect(drawing.active, isTrue);

      await drag(tester);
      expect(drawing.strokes, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 16));
      expect(drawing.strokes, isEmpty);
      expect(drawing.active, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 16));
    });

    for (final defense in [false, true]) {
      final side = defense ? 'defense' : 'attack';
      testWidgets(
          'on $side, a capture saves the strokes as page drawings the '
          'editor draws where they were drawn', (tester) async {
        await openReplay(tester);
        final playback = canvas(tester).playback;
        final drawing = canvas(tester).drawing;
        if (defense) playback.perspective = ReplayTeam.blue;
        await tester.pump();
        expect(playback.frame.isAttack, !defense);

        drawing.start();
        await tester.pump();
        final layer = find.byType(ReplayDrawingLayer);
        final world = tester.getRect(layer);
        final from = world.center - const Offset(100, 0);
        final gesture =
            await tester.startGesture(from, kind: PointerDeviceKind.mouse);
        for (var i = 0; i < 10; i++) {
          await gesture.moveBy(const Offset(20, 0));
          await tester.pump();
        }
        await gesture.up();
        await tester.pump();
        // A point along the stroke, where the user drew it, as a fraction
        // of the world.
        final drawn = from + const Offset(100, 0);
        final fraction = Offset(
          (drawn.dx - world.left) / world.width,
          (drawn.dy - world.top) / world.height,
        );

        // On screen, the stroke is drawn there, over everything.
        final shown = await _pixel(
          tester,
          find
              .ancestor(
                of: find.byType(ReplayCanvas),
                matching: find.byType(RepaintBoundary),
              )
              .first,
          drawn,
        );
        expect(shown, Colors.white);

        await tester.runAsync(() async {
          await tester.tap(find.text('Capture'));
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        // The write runs on Hive's real clock: the blank page the new
        // strategy starts with is replaced by the capture once it lands.
        bool captured() =>
            box.values.singleOrNull?.pages.single.name != 'Page 1' &&
            box.isNotEmpty;
        for (var i = 0; i < 50 && !captured(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        final page = box.values.single.pages.single;
        expect(page.isAttack, !defense);
        final saved = page.drawingData.single as FreeDrawing;
        final onScreen = drawing.strokes.single as FreeDrawing;
        expect(saved.listOfPoints, onScreen.listOfPoints);
        expect(identical(saved, onScreen), isFalse);
        // Stored in the attack-side world, like everything placed.
        final coordinates = CoordinateSystem.instance;
        final expected = coordinates.screenToCoordinate(Offset(
          (defense ? 1 - fraction.dx : fraction.dx) * world.width,
          (defense ? 1 - fraction.dy : fraction.dy) * world.height,
        ));
        expect(
          saved.listOfPoints.any((point) => (point - expected).distance < 0.01),
          isTrue,
        );

        // The editor, at another size, draws the page's drawings at the
        // same place in its world.
        await tester.pumpWidget(const SizedBox());
        await _expectEditorDraws(
          tester,
          page,
          at: fraction,
        );
      });
    }
  });

  group('cloud capture', () {
    test('carries the strokes in the page payload, unchanged', () async {
      await Hive.openBox<String>(HiveBoxNames.replayCapturesBox);
      final container = ProviderContainer(overrides: [
        replayCaptureQueueProvider.overrideWith(_HeldQueue.new),
      ]);
      addTearDown(container.dispose);
      final coordinates = CoordinateSystem(playAreaSize: const Size(1600, 900));
      final drawing = ReplayDrawing(_playback())..start();
      drawing.begin(
        const Offset(100, 100),
        coordinates,
        color: Colors.white,
        thickness: 5,
      );
      for (var x = 120.0; x <= 300; x += 20) {
        drawing.extend(Offset(x, 140), coordinates);
      }
      drawing
        ..end(coordinates)
        ..tool = ReplayDrawingTool.arrow
        ..begin(
          const Offset(400, 400),
          coordinates,
          color: Colors.white,
          thickness: 5,
        )
        ..extend(const Offset(500, 300), coordinates)
        ..end(coordinates);

      final store = CloudReplayCaptureStore(
        queue: container.read(replayCaptureQueueProvider.notifier),
        queueState: () => container.read(replayCaptureQueueProvider),
        accountId: 'account-1',
        folderId: null,
        settings: StrategySettings(),
        themeProfileId: null,
      );
      await ReplayCapture(
        newStore: () => store,
        map: MapValue.sunset,
        name: 'r',
      ).capture(
        const ReplayFrame(
          timeMs: 0,
          round: null,
          isAttack: false,
          agents: [],
          abilities: [],
          utilities: [],
        ),
        pageName: 'one',
        drawings: drawing.forCapture(),
      );

      // As the outbox keeps it across a restart.
      final record = ReplayCaptureRecord.decode(
        container.read(replayCaptureQueueProvider).captures.single.encode(),
      );
      final payloads = [
        for (final op in record.items)
          if (op is ElementAddOp &&
              cloudPayloadData(op.payload)['elementType'] == 'drawing')
            op,
      ];
      expect(payloads, hasLength(2));
      // Read back as a cloud page reads its drawings.
      final read = [
        for (final op in payloads)
          DrawingProvider.fromJson(
            jsonEncode([cloudPayloadData(op.payload)]),
          ).single,
      ];
      final free = read.whereType<FreeDrawing>().single;
      final line = read.whereType<Line>().single;
      final drawn = drawing.strokes;
      expect(free.listOfPoints, (drawn[0] as FreeDrawing).listOfPoints);
      expect(line.lineStart, (drawn[1] as Line).lineStart);
      expect(line.lineEnd, (drawn[1] as Line).lineEnd);
      expect(line.hasArrow, isTrue);
      for (final op in payloads) {
        expect(op.pagePublicId, record.pageId);
        expect(op.elementPublicId, isNot(anyOf(drawn[0].id, drawn[1].id)),
            reason: 'cloud items get fresh ids');
      }
    });
  });
}

/// The app's fonts, so the screen lays out as it does in the app rather
/// than in the test font's wide boxes.
Future<void> _loadFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

/// A capture queue that keeps what it is given and never sends.
class _HeldQueue extends ReplayCaptureQueue {
  final _held = <ReplayCaptureRecord>[];

  @override
  ReplayCaptureQueueState build() => ReplayCaptureQueueState(captures: _held);

  @override
  Future<void> add(ReplayCaptureRecord capture) async {
    _held.add(capture);
    state = ReplayCaptureQueueState(captures: [..._held]);
  }
}

/// The colour [finder]'s picture has at the global point [at].
Future<Color> _pixel(WidgetTester tester, Finder finder, Offset at) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  final origin = boundary.localToGlobal(Offset.zero);
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final width = image.width;
    image.dispose();
    return (data!, width);
  });
  final (data, width) = bytes!;
  final x = (at.dx - origin.dx).round();
  final y = (at.dy - origin.dy).round();
  final i = (y * width + x) * 4;
  return Color.fromARGB(
    data.getUint8(i + 3),
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
  );
}

/// Opens [page]'s drawings the way the editor's canvas does (its drawing
/// layer, flipped on defense) in a world of another size, and checks a
/// stroke is drawn at [at], a fraction of the world, and nothing far off.
Future<void> _expectEditorDraws(
  WidgetTester tester,
  StrategyPage page, {
  required Offset at,
}) async {
  const world = Size(1280, 720);
  final coordinates = CoordinateSystem(playAreaSize: world);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(drawingProvider.notifier).fromHive(page.drawingData);
  final boundary = GlobalKey();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: boundary,
          child: SizedBox.fromSize(
            size: world,
            child: Transform.flip(
              flipX: !page.isAttack,
              flipY: !page.isAttack,
              child: const InteractivePainter(),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  expect(CoordinateSystem.instance.effectiveSize, coordinates.effectiveSize);
  final point = Offset(at.dx * world.width, at.dy * world.height);
  final finder = find.byKey(boundary);
  expect(await _pixel(tester, finder, point), Colors.white);
  expect(
    (await _pixel(tester, finder, point + const Offset(0, 40))).a,
    0,
    reason: 'nothing drawn away from the stroke',
  );
}
