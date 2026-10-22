import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/screenshot/page_screenshot.dart';
import 'package:icarus/screenshot/save_screenshots.dart';
import 'package:icarus/services/video_export/video_export_errors.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/dialogs/screenshot_dialog.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

const _strategyId = 'local-strategy';

class _OpenLocalStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: _strategyId,
        strategyName: 'Retakes',
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  Future<void> forceSaveNow(String id) async {}
}

/// [_OpenLocalStrategy] with its image files in [storageDirectory], counting
/// every save.
class _RecordingLocalStrategy extends _OpenLocalStrategy {
  _RecordingLocalStrategy(this.storageDirectory);

  final String storageDirectory;
  int saves = 0;

  @override
  StrategyState build() =>
      super.build().copyWith(storageDirectory: storageDirectory);

  @override
  Future<void> forceSaveNow(String id) async => saves++;
}

/// Answers the folder dialog by failing, as a broken platform picker does.
class _BrokenFolderPicker extends FilePicker {
  int opened = 0;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    opened++;
    throw PlatformException(code: 'unavailable');
  }
}

/// A page with [agents] Jetts along its top, so pages render differently.
StrategyPage _page(
  String id,
  String name,
  int sortIndex, {
  int agents = 0,
  List<PlacedImage> images = const [],
}) =>
    StrategyPage(
      id: id,
      name: name,
      drawingData: const [],
      agentData: [
        for (var i = 0; i < agents; i++)
          PlacedAgent(
            id: '$id-agent-$i',
            type: AgentType.jett,
            position: Offset(300.0 + i * 60, 300),
            isAlly: true,
          ),
      ],
      abilityData: const [],
      textData: const [],
      imageData: images,
      utilityData: const [],
      sortIndex: sortIndex,
      isAttack: true,
      settings: StrategySettings(),
    );

/// The test font draws every glyph a full em wide, so labels that fit in the
/// app overflow here; that is the font, not the panel. Anything else fails.
void ignoreTestFontOverflow(WidgetTester tester) {
  for (Object? error; (error = tester.takeException()) != null;) {
    expect('$error', contains('overflowed'));
  }
}

/// Answers the folder dialog with [folder].
class _FolderPicker extends FilePicker {
  _FolderPicker(this.folder);
  final String folder;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async =>
      folder;
}

/// Answers the save dialog at once, keeping the names it was offered.
class _NamingPicker extends FilePicker {
  final names = <String?>[];

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    names.add(fileName);
    return fileName;
  }
}

/// Draws no thumbnails: the real ones render offscreen in real time, which
/// these tests drive only where they mean to.
Future<void> _noThumbnails(
  WidgetRef ref, {
  required Set<String> pageIds,
  required void Function(String pageId, ui.Image image) onThumbnail,
  required void Function(Set<String> pageIds, Object error) onUnavailable,
  required bool Function() isCancelled,
}) async {}

PageScreenshot _shot(int number, String name) =>
    (number: number, name: name, png: Uint8List.fromList([number]));

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('icarus_page_shots');
    Hive.init(hiveDir.path);
    registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await MapThemeProfilesProvider.bootstrap();
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  testWidgets('captures the chosen pages in page order, numbered as listed',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    await tester.runAsync(
      () => Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
        _strategyId,
        StrategyData(
          id: _strategyId,
          name: 'Retakes',
          mapData: MapValue.ascent,
          versionNumber: 1,
          lastEdited: DateTime(2026),
          folderID: null,
          // Stored out of order: numbers come from the page order.
          pages: [
            _page('c', 'Post plant', 2, agents: 4),
            _page('a', 'Default', 0),
            _page('b', 'Fake', 1, agents: 2),
          ],
        ),
      ),
    );
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [strategyProvider.overrideWith(_OpenLocalStrategy.new)],
      child: Consumer(builder: (context, widgetRef, _) {
        ref = widgetRef;
        return const SizedBox.shrink();
      }),
    ));

    // On real time with the app's frames coming, as in the app.
    Object? outcome;
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        captureStrategyPages(
          ref,
          pageIds: {'c', 'a'},
          transparentBackground: true,
        )
            .then<void>((shots) => outcome = shots,
                onError: (Object error) => outcome = error)
            .whenComplete(() => done = true),
      );
    });
    while (!done) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump();
    }

    expect(outcome, isA<List<PageScreenshot>>());
    final shots = outcome! as List<PageScreenshot>;
    expect([
      for (final shot in shots) (shot.number, shot.name)
    ], [
      (1, 'Default'),
      (3, 'Post plant'),
    ]);
    // Each file holds its own page. Above the page names (drawn at the
    // bottom), the empty page and the page with agents must differ.
    final empty = img.decodePng(shots[0].png)!;
    final withAgents = img.decodePng(shots[1].png)!;
    var differing = 0;
    for (var y = 0; y < 1000; y++) {
      for (var x = 0; x < empty.width; x++) {
        if (empty.getPixel(x, y) != withAgents.getPixel(x, y)) differing++;
      }
    }
    expect(differing, greaterThan(500));
    for (final shot in shots) {
      final png = img.decodePng(shot.png)!;
      expect(png.width, CoordinateSystem.screenShotSize.width);
      expect(png.height, CoordinateSystem.screenShotSize.height);
      // Transparent around the map, as asked.
      expect(png.getPixel(2, 2).a, 0);
      expect(png.getPixel(png.width ~/ 2, png.height ~/ 2).a, 255);
    }
    expect(CoordinateSystem.instance.isScreenshot, isFalse);
  });

  testWidgets('thumbnails show the open page first, small and see-through',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    await tester.runAsync(
      () => Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
        _strategyId,
        StrategyData(
          id: _strategyId,
          name: 'Retakes',
          mapData: MapValue.ascent,
          versionNumber: 1,
          lastEdited: DateTime(2026),
          folderID: null,
          pages: [
            _page('a', 'Default', 0),
            _page('b', 'Fake', 1, agents: 2),
          ],
        ),
      ),
    );
    final container = ProviderContainer(
      overrides: [strategyProvider.overrideWith(_OpenLocalStrategy.new)],
    );
    addTearDown(container.dispose);
    container.read(strategyPageSessionProvider.notifier).setStateForTest(
          container
              .read(strategyPageSessionProvider)
              .copyWith(activePageId: 'b'),
        );
    late WidgetRef ref;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (context, widgetRef, _) {
        ref = widgetRef;
        return const SizedBox.shrink();
      }),
    ));

    final order = <String>[];
    final images = <ui.Image>[];
    final unavailable = <String>{};
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        renderPageThumbnails(
          ref,
          pageIds: {'a', 'b'},
          onThumbnail: (pageId, image) {
            order.add(pageId);
            images.add(image);
          },
          onUnavailable: (pageIds, _) => unavailable.addAll(pageIds),
          isCancelled: () => false,
        ).whenComplete(() => done = true),
      );
    });
    while (!done) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump();
    }
    addTearDown(() {
      for (final image in images) {
        image.dispose();
      }
    });

    expect(unavailable, isEmpty);
    expect(order, ['b', 'a']);
    for (final image in images) {
      expect(image.width, 384);
      expect(image.height, 216);
      // The dialog draws the background under it, or a checkerboard.
      final pixels = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      expect(pixels.getUint8(3), 0);
    }
    expect(CoordinateSystem.instance.isScreenshot, isFalse);
  });

  testWidgets(
      'thumbnails never save, and a broken image costs only its own page',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    final storage = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('icarus_thumb_images'),
    ))!;
    addTearDown(() => storage.deleteSync(recursive: true));
    await tester.runAsync(() async {
      // Bytes that are not an image: the page they are on can't be drawn.
      final broken = File(path.join(storage.path, 'images', 'broken.png'));
      await broken.parent.create(recursive: true);
      await broken.writeAsBytes([1, 2, 3]);
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
        _strategyId,
        StrategyData(
          id: _strategyId,
          name: 'Retakes',
          mapData: MapValue.ascent,
          versionNumber: 1,
          lastEdited: DateTime(2026),
          folderID: null,
          pages: [
            _page('a', 'Default', 0),
            _page('b', 'Fake', 1, images: [
              PlacedImage(
                position: const Offset(500, 500),
                id: 'broken',
                aspectRatio: 1,
                scale: 100,
                fileExtension: '.png',
              ),
            ]),
            _page('c', 'Post plant', 2, agents: 2),
          ],
        ),
      );
    });
    final strategy = _RecordingLocalStrategy(storage.path);
    final container = ProviderContainer(
      overrides: [strategyProvider.overrideWith(() => strategy)],
    );
    addTearDown(container.dispose);
    container.read(strategyPageSessionProvider.notifier).setStateForTest(
          container
              .read(strategyPageSessionProvider)
              .copyWith(activePageId: 'a'),
        );
    late WidgetRef ref;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (context, widgetRef, _) {
        ref = widgetRef;
        return const SizedBox.shrink();
      }),
    ));

    final drawn = <String>[];
    final images = <ui.Image>[];
    final unavailable = <String>{};
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        renderPageThumbnails(
          ref,
          pageIds: {'a', 'b', 'c'},
          onThumbnail: (pageId, image) {
            drawn.add(pageId);
            images.add(image);
          },
          onUnavailable: (pageIds, _) => unavailable.addAll(pageIds),
          isCancelled: () => false,
        ).whenComplete(() => done = true),
      );
    });
    while (!done) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump();
    }
    addTearDown(() {
      for (final image in images) {
        image.dispose();
      }
    });

    expect(drawn, ['a', 'c']);
    expect(unavailable, {'b'});
    // Looking is not saving.
    expect(strategy.saves, 0);
  });

  testWidgets('a cancelled capture stops before the next page', (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    await tester.runAsync(
      () => Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
        _strategyId,
        StrategyData(
          id: _strategyId,
          name: 'Retakes',
          mapData: MapValue.ascent,
          versionNumber: 1,
          lastEdited: DateTime(2026),
          folderID: null,
          pages: [_page('a', 'Default', 0), _page('b', 'Fake', 1)],
        ),
      ),
    );
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [strategyProvider.overrideWith(_OpenLocalStrategy.new)],
      child: Consumer(builder: (context, widgetRef, _) {
        ref = widgetRef;
        return const SizedBox.shrink();
      }),
    ));

    final started = <int>[];
    var cancelled = false;
    Object? outcome;
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        captureStrategyPages(
          ref,
          pageIds: {'a', 'b'},
          transparentBackground: false,
          onPage: (page, total) {
            started.add(page);
            // The user cancels as the first page starts, while its pictures
            // load.
            cancelled = true;
          },
          isCancelled: () => cancelled,
        )
            .then<void>((shots) => outcome = shots,
                onError: (Object error) => outcome = error)
            .whenComplete(() => done = true),
      );
    });
    while (!done) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump();
    }

    expect(outcome, isA<VideoExportCancelled>());
    expect(started, [1]);
    expect(CoordinateSystem.instance.isScreenshot, isFalse);
  });

  testWidgets('the camera shows every page, with the open one ticked',
      (tester) async {
    await tester.runAsync(
      () => Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
        _strategyId,
        StrategyData(
          id: _strategyId,
          name: 'Retakes',
          mapData: MapValue.ascent,
          versionNumber: 1,
          lastEdited: DateTime(2026),
          folderID: null,
          pages: [
            _page('a', 'Default', 0),
            _page('b', 'Fake', 1),
            _page('c', 'Post plant', 2),
          ],
        ),
      ),
    );
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_OpenLocalStrategy.new),
      pageThumbnailerProvider.overrideWithValue(_noThumbnails),
    ]);
    addTearDown(container.dispose);
    container.read(strategyPageSessionProvider.notifier).setStateForTest(
          container
              .read(strategyPageSessionProvider)
              .copyWith(activePageId: 'b'),
        );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShadApp(home: Scaffold(body: EditorToolbar())),
    ));

    await tester.tap(find.byIcon(LucideIcons.camera200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    bool ticked(String page) => tester
        .widget<ShadCheckbox>(find.descendant(
          // The tile: its thumbnail, with the checkbox, and its name.
          of: find
              .ancestor(
                  of: find.text(page), matching: find.byType(GestureDetector))
              .first,
          matching: find.byType(ShadCheckbox),
        ))
        .value;
    ignoreTestFontOverflow(tester);
    expect([ticked('Default'), ticked('Fake'), ticked('Post plant')],
        [false, true, false]);
    expect(find.text('Save screenshot'), findsOneWidget);

    await tester.tap(find.text('Select all'));
    await tester.pump();
    ignoreTestFontOverflow(tester);
    expect(find.text('Save 3 screenshots'), findsOneWidget);

    await tester.tap(find.text('Clear all'));
    await tester.pump();
    ignoreTestFontOverflow(tester);
    // Nothing to capture: the button can't be pressed.
    expect(
      tester
          .widget<ShadButton>(find.ancestor(
            of: find.text('Save screenshot'),
            matching: find.byType(ShadButton),
          ))
          .enabled,
      isFalse,
    );
  });

  testWidgets('a cancel during the last page still saves nothing',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    await tester.runAsync(
      () => Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
        _strategyId,
        StrategyData(
          id: _strategyId,
          name: 'Retakes',
          mapData: MapValue.ascent,
          versionNumber: 1,
          lastEdited: DateTime(2026),
          folderID: null,
          pages: [_page('a', 'Default', 0)],
        ),
      ),
    );
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [strategyProvider.overrideWith(_OpenLocalStrategy.new)],
      child: Consumer(builder: (context, widgetRef, _) {
        ref = widgetRef;
        return const SizedBox.shrink();
      }),
    ));

    var cancelled = false;
    Object? outcome;
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        captureStrategyPages(
          ref,
          pageIds: {'a'},
          transparentBackground: false,
          // Cancelled while the only page renders.
          onPage: (page, total) => cancelled = true,
          isCancelled: () => cancelled,
        )
            .then<void>((shots) => outcome = shots,
                onError: (Object error) => outcome = error)
            .whenComplete(() => done = true),
      );
    });
    while (!done) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump();
    }

    expect(outcome, isA<VideoExportCancelled>());
  });

  /// Opens a two-page local strategy in an editor route above the library,
  /// as in the app, and starts capturing both pages into a folder. Returns
  /// once the dialog says it is saving.
  Future<({Directory folder, GlobalKey<NavigatorState> navigator})>
      startTwoPageCapture(WidgetTester tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    final folder = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('icarus_shot_cancel'),
    ))!;
    addTearDown(() => folder.deleteSync(recursive: true));
    FilePicker.platform = _FolderPicker(folder.path);
    await tester.runAsync(
      () => Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
        _strategyId,
        StrategyData(
          id: _strategyId,
          name: 'Retakes',
          mapData: MapValue.ascent,
          versionNumber: 1,
          lastEdited: DateTime(2026),
          folderID: null,
          pages: [_page('a', 'Default', 0), _page('b', 'Fake', 1)],
        ),
      ),
    );
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_OpenLocalStrategy.new),
      pageThumbnailerProvider.overrideWithValue(_noThumbnails),
    ]);
    addTearDown(container.dispose);
    container.read(strategyPageSessionProvider.notifier).setStateForTest(
          container
              .read(strategyPageSessionProvider)
              .copyWith(activePageId: 'a'),
        );
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: ToastificationWrapper(
        child: ShadApp(
          navigatorKey: navigatorKey,
          home: const Text('Library'),
        ),
      ),
    ));
    unawaited(navigatorKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: EditorToolbar()),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(LucideIcons.camera200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Select all'));
    await tester.pump();
    ignoreTestFontOverflow(tester);
    await tester.runAsync(() => tester.tap(find.text('Save 2 screenshots')));
    // Real time, with frames, until the dialog is up.
    for (var i = 0;
        i < 200 && find.text('Saving screenshots').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump();
    }
    expect(find.text('Saving screenshots'), findsOneWidget);
    return (folder: folder, navigator: navigatorKey);
  }

  testWidgets('only Stop ends a capture, and the editor stays open',
      (tester) async {
    final (:folder, navigator: _) = await startTwoPageCapture(tester);

    // Nothing but Stop closes it: no X, no Cancel, and Escape does nothing.
    expect(find.byIcon(LucideIcons.x), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('Saving screenshots'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    // It stays up, saying so, until the capture has stopped.
    expect(find.text('Stopping…'), findsOneWidget);
    // The clock moves too, so the dialog's closing animation plays out.
    for (var i = 0;
        i < 400 && find.text('Saving screenshots').evaluate().isNotEmpty;
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Saving screenshots'), findsNothing);
    expect(find.byType(EditorToolbar), findsOneWidget);
    expect(find.text('Library'), findsNothing);
    expect(folder.listSync(), isEmpty);
    expect(find.text('Screenshots cancelled.'), findsOneWidget);
    ignoreTestFontOverflow(tester);
    // Let the toast leave.
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a finished capture closes only its own dialog', (tester) async {
    final (:folder, :navigator) = await startTwoPageCapture(tester);
    // Another dialog opens on top meanwhile, as the debug log (F12) does.
    unawaited(navigator.currentState!.push(DialogRoute<void>(
      context: navigator.currentContext!,
      builder: (_) => const Center(child: Text('Debug log')),
    )));
    await tester.pump();

    for (var i = 0;
        i < 600 && find.text('Saving screenshots').evaluate().isNotEmpty;
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump();
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Saving screenshots'), findsNothing);
    expect(find.text('Debug log'), findsOneWidget);
    expect(find.byType(EditorToolbar), findsOneWidget);
    expect(folder.listSync(), hasLength(2));
    ignoreTestFontOverflow(tester);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a folder picker that fails leaves Save working', (tester) async {
    final picker = _BrokenFolderPicker();
    FilePicker.platform = picker;
    await tester.runAsync(
      () => Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
        _strategyId,
        StrategyData(
          id: _strategyId,
          name: 'Retakes',
          mapData: MapValue.ascent,
          versionNumber: 1,
          lastEdited: DateTime(2026),
          folderID: null,
          pages: [_page('a', 'Default', 0), _page('b', 'Fake', 1)],
        ),
      ),
    );
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_OpenLocalStrategy.new),
      pageThumbnailerProvider.overrideWithValue(_noThumbnails),
    ]);
    addTearDown(container.dispose);
    appProviderContainer = container;
    container.read(strategyPageSessionProvider.notifier).setStateForTest(
          container
              .read(strategyPageSessionProvider)
              .copyWith(activePageId: 'a'),
        );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: ToastificationWrapper(
        child: ShadApp(home: const Scaffold(body: EditorToolbar())),
      ),
    ));

    await tester.tap(find.byIcon(LucideIcons.camera200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Select all'));
    await tester.pump();
    ignoreTestFontOverflow(tester);
    for (var attempt = 1; attempt <= 2; attempt++) {
      await tester.tap(find.text('Save 2 screenshots'));
      await tester.pump();
      ignoreTestFontOverflow(tester);
      expect(picker.opened, attempt);
    }
    // Nothing started: the dialog still asks.
    expect(find.text('Save screenshots'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    ignoreTestFontOverflow(tester);
  });

  testWidgets('a ticked page that has left the canvas is read as saved',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    final picker = _NamingPicker();
    FilePicker.platform = picker;
    await tester.runAsync(
      () => Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(
        _strategyId,
        StrategyData(
          id: _strategyId,
          name: 'Retakes',
          mapData: MapValue.ascent,
          versionNumber: 1,
          lastEdited: DateTime(2026),
          folderID: null,
          pages: [_page('a', 'Default', 0), _page('b', 'Fake', 1)],
        ),
      ),
    );
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(_OpenLocalStrategy.new),
      pageThumbnailerProvider.overrideWithValue(_noThumbnails),
    ]);
    addTearDown(container.dispose);
    final session = container.read(strategyPageSessionProvider.notifier);
    session.setStateForTest(
      container.read(strategyPageSessionProvider).copyWith(activePageId: 'a'),
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: ToastificationWrapper(
        child: ShadApp(home: const Scaffold(body: EditorToolbar())),
      ),
    ));
    await tester.tap(find.byIcon(LucideIcons.camera200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    ignoreTestFontOverflow(tester);

    // A teammate deletes Default while the dialog is up, and the editor
    // moves to Fake. Default is still the page ticked.
    session.setStateForTest(
      container.read(strategyPageSessionProvider).copyWith(activePageId: 'b'),
    );
    await tester.runAsync(() => tester.tap(find.text('Save screenshot')));
    for (var i = 0; i < 600 && picker.names.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 16)),
      );
      await tester.pump();
    }

    // Default, read as saved, not the canvas's Fake.
    expect(picker.names, ['Retakes - 01 Default.png']);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    ignoreTestFontOverflow(tester);
  });

  test('screenshots saved to a folder never replace a file already there',
      () async {
    final dir = await Directory.systemTemp.createTemp('icarus_shot_folder');
    addTearDown(() => dir.delete(recursive: true));
    final taken = path.join(dir.path, 'Retakes - 01 Default.png');
    await File(taken).writeAsString('already here');

    final written = await writeScreenshotsToFolder(dir.path, 'Retakes', [
      _shot(1, 'Default'),
      _shot(3, 'A/B split'),
    ]);

    expect([
      for (final file in written) path.basename(file)
    ], [
      'Retakes - 01 Default (2).png',
      'Retakes - 03 A_B split.png',
    ]);
    expect(await File(taken).readAsString(), 'already here');
    expect(await File(written.first).readAsBytes(), [1]);
  });

  test('the browser gets every screenshot in one .zip', () {
    final zip = zipScreenshots('Retakes', [
      _shot(1, 'Default'),
      _shot(2, 'Fake'),
    ]);

    final archive = ZipDecoder().decodeBytes(zip);
    expect([
      for (final file in archive.files) file.name
    ], [
      'Retakes - 01 Default.png',
      'Retakes - 02 Fake.png',
    ]);
    expect(archive.files.last.content, [2]);
  });
}
