import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/agents.dart';
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
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:shadcn_ui/shadcn_ui.dart';

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

/// A page with [agents] Jetts along its top, so pages render differently.
StrategyPage _page(
  String id,
  String name,
  int sortIndex, {
  int agents = 0,
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
      imageData: const [],
      utilityData: const [],
      sortIndex: sortIndex,
      isAttack: true,
      settings: StrategySettings(),
    );

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
    // Each file holds its own page: the page with agents draws more.
    int drawn(Uint8List png) =>
        img.decodePng(png)!.where((pixel) => pixel.a > 0).length;
    expect(drawn(shots[1].png), greaterThan(drawn(shots[0].png)));
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
            // The user cancels while the first page renders.
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

  testWidgets('the camera offers every page, with the open one ticked',
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
    final container = ProviderContainer(
      overrides: [strategyProvider.overrideWith(_OpenLocalStrategy.new)],
    );
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
          of: find
              .ancestor(of: find.text(page), matching: find.byType(Row))
              .first,
          matching: find.byType(ShadCheckbox),
        ))
        .value;
    // The test font draws every glyph a full em wide, so labels that fit in
    // the app overflow here; that is the font, not the panel.
    void ignoreTestFontOverflow() {
      for (Object? error; (error = tester.takeException()) != null;) {
        expect('$error', contains('overflowed'));
      }
    }

    ignoreTestFontOverflow();
    expect([ticked('Default'), ticked('Fake'), ticked('Post plant')],
        [false, true, false]);
    expect(find.text('Save screenshot'), findsOneWidget);

    await tester.tap(find.text('Select all'));
    await tester.pump();
    ignoreTestFontOverflow();
    expect(find.text('Save 3 screenshots'), findsOneWidget);

    await tester.tap(find.text('Clear all'));
    await tester.pump();
    ignoreTestFontOverflow();
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
