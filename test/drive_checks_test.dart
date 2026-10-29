import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/dev/drive/drive_checks.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/line_up_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

class _EmptyDrawingProvider extends DrawingProvider {
  @override
  DrawingState build() => DrawingState(elements: const []);

  @override
  void rebuildAllPaths(CoordinateSystem coordinateSystem) {}
}

class _FixedPenProvider extends PenProvider {
  @override
  PenState build() => PenState(
        listOfColors: const [],
        color: Colors.white,
        hasArrow: false,
        isDotted: false,
        opacity: 1,
        thickness: 1,
        penMode: PenMode.freeDraw,
        traversalTimeEnabled: false,
        activeTraversalSpeedProfile: TraversalSpeedProfile.running,
        drawingCursor: null,
        erasingCursor: null,
      );
}

void main() {
  late Directory tempDir;

  setUpAll(() => registerIcarusAdapters(Hive));

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-drive-checks-');
    Hive.init(tempDir.path);
    await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await MapThemeProfilesProvider.bootstrap();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  testWidgets('items drawn with the wrong coordinates are misplaced',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Disposed after the widgets: the agent icons' hover cleanup reads it
    // the frame after they go.
    final container = ProviderContainer(
      overrides: [
        mapProvider.overrideWith(_FixedMapProvider.new),
        drawingProvider.overrideWith(_EmptyDrawingProvider.new),
        penProvider.overrideWith(_FixedPenProvider.new),
        effectiveMapThemePaletteProvider.overrideWith(
          (ref) => MapThemeProfilesProvider.immutableDefaultPalette,
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(height: 40),
                Expanded(child: InteractiveMap()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    container.read(agentProvider.notifier).addAgent(PlacedAgent(
          id: 'jett',
          type: AgentType.jett,
          position: const Offset(700, 400),
          isAlly: true,
        ));
    container.read(lineUpProvider.notifier).addRecovered(LineUpGraph(
          origins: [
            LineUpOrigin(
              id: 'origin',
              agent: PlacedAgent(
                id: 'origin',
                type: AgentType.brimstone,
                position: const Offset(650, 700),
                isAlly: true,
                lineUpID: 'origin',
              ),
            ),
          ],
          landings: [
            LineUpLanding(
              id: 'landing',
              ability: PlacedAbility(
                id: 'landing',
                data: AgentData.agents[AgentType.brimstone]!.abilities[2],
                position: const Offset(760, 560),
                isAlly: true,
                lineUpID: 'landing',
              ),
            ),
          ],
          links: [
            LineUpLink(
              id: 'link',
              originId: 'origin',
              landingId: 'landing',
              name: 'Smoke',
              images: const [],
            ),
          ],
        ));
    await tester.pumpAndSettle();
    expect(misplacedItems(container), isEmpty);

    // The library under the editor did this in #405: the next rebuild draws
    // every item with coordinates for a smaller canvas.
    CoordinateSystem(playAreaSize: const Size(1440, 810));
    for (final type in [
      PlacedWidgetBuilder,
      LineUpOriginAgentWidget,
      LineUpLandingAbilityWidget,
    ]) {
      tester.element(find.byType(type)).markNeedsBuild();
    }
    await tester.pump();
    // The canvas reports it too.
    expect(tester.takeException(), isA<FlutterError>());

    final misplaced = misplacedItems(container);
    expect(misplaced, hasLength(3));
    expect(
      misplaced,
      containsAll([
        startsWith('jett drawn at'),
        startsWith('origin drawn at'),
        startsWith('landing drawn at'),
      ]),
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
