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
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _viewport = Size(1200, 800);
const _captureKey = ValueKey('copy-to-page-capture');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('icarus-copy-menu-');
    Hive.init(hiveDir.path);
    registerIcarusAdapters(Hive);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    if (_artifactDir != null) await _loadFonts();
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    CoordinateSystem(playAreaSize: _viewport);
    CoordinateSystem.instance.setIsScreenshot(false);
  });

  final jett = PlacedAgent(
    id: 'jett',
    type: AgentType.jett,
    position: const Offset(600, 400),
  );

  /// Opens a three-page strategy on its middle page, which holds [jett], and
  /// right-clicks her.
  Future<ProviderContainer> openMenu(
    WidgetTester tester, {
    required List<PlacedAgentNode> nextPage,
  }) async {
    tester.view
      ..physicalSize = _viewport
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final pages = [
      _page('page-1', 0, const []),
      _page('page-2', 1, [jett]),
      _page('page-3', 2, nextPage),
    ];
    final strategy = StrategyData(
      id: 'copy-menu',
      name: 'Copy menu',
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.utc(2026),
      folderID: null,
      pages: pages,
    );
    await tester.runAsync(() => Hive.box<StrategyData>(
          HiveBoxNames.strategiesBox,
        ).put(strategy.id, strategy));

    final container = ProviderContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
    container.read(mapProvider.notifier).fromHive(MapValue.ascent, true);
    container.read(agentProvider.notifier).fromHive(pages[1].agentData);
    container.read(strategyProvider.notifier)
      ..setFromState(StrategyState(
        isSaved: true,
        stratName: strategy.name,
        id: strategy.id,
        storageDirectory: null,
        activePageId: 'page-2',
      ))
      ..activePageID = 'page-2';

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: _captureKey,
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: Scaffold(
            backgroundColor: Settings.tacticalVioletTheme.background,
            body: SizedBox.fromSize(
              size: _viewport,
              child: const PlacedWidgetBuilder(),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tapAt(
      tester.getCenter(find.byType(AgentWidget)),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('the menu offers both neighbouring pages', (tester) async {
    await openMenu(tester, nextPage: const []);
    await _capture(tester, 'both-pages');

    expect(find.text('Copy to previous page'), findsOneWidget);
    expect(find.text('Copy to next page'), findsOneWidget);
  });

  testWidgets('the menu leaves out a page that already has the item',
      (tester) async {
    await openMenu(tester, nextPage: [jett]);
    await _capture(tester, 'next-page-has-it');

    expect(find.text('Copy to previous page'), findsOneWidget);
    expect(find.text('Copy to next page'), findsNothing);
  });
}

StrategyPage _page(String id, int sortIndex, List<PlacedAgentNode> agents) {
  return StrategyPage(
    id: id,
    name: 'Page ${sortIndex + 1}',
    isAutoNamed: true,
    sortIndex: sortIndex,
    drawingData: const [],
    agentData: agents,
    abilityData: const [],
    textData: const [],
    imageData: const [],
    utilityData: const [],
    isAttack: true,
    settings: StrategySettings(),
  );
}

final _artifactDir = Platform.environment['ICARUS_COPY_MENU_ARTIFACT_DIR'];

/// The app's fonts, so a capture shows words rather than the test font's
/// boxes.
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

/// Saves the screen to $ICARUS_COPY_MENU_ARTIFACT_DIR/[name].png when set.
Future<void> _capture(WidgetTester tester, String name) async {
  final directory = _artifactDir;
  if (directory == null) return;
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
