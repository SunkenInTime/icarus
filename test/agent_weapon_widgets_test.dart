import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/page_transition/transition_planner.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_weapon_badge.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/weapon_icon.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:icarus/widgets/line_up_placer.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _viewport = Size(1200, 800);
const _captureKey = ValueKey('weapon-test-capture');

class _TestStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => StrategyState(
        isSaved: true,
        stratName: null,
        id: 'weapon-widget-test',
        storageDirectory: null,
        activePageId: null,
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

class _TestMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

ProviderContainer _container() => ProviderContainer(overrides: [
      strategyProvider.overrideWith(_TestStrategyProvider.new),
      mapProvider.overrideWith(_TestMapProvider.new),
    ]);

PlacedAgentNode _agent(String kind, {WeaponType weapon = WeaponType.none}) {
  const position = Offset(600, 400);
  return switch (kind) {
    'cone' => PlacedViewConeAgent(
        id: kind,
        type: AgentType.sova,
        position: position,
        presetType: UtilityType.viewCone90,
        rotation: 0.75,
        length: 60,
        weapon: weapon,
      ),
    'circle' => PlacedCircleAgent(
        id: kind,
        type: AgentType.sova,
        position: position,
        diameterMeters: 12,
        weapon: weapon,
      ),
    _ => PlacedAgent(
        id: kind,
        type: AgentType.sova,
        position: position,
        weapon: weapon,
      ),
  };
}

Widget _harness(ProviderContainer container,
        {Widget? child, double zoom = 1}) =>
    UncontrolledProviderScope(
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
            body: Transform.scale(
              scale: zoom,
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(
                size: _viewport,
                child: child ?? const PlacedWidgetBuilder(),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _dispose(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  container.dispose();
}

/// Right-clicks the agent and opens the Weapon submenu.
Future<void> _openWeaponMenu(WidgetTester tester, TestGesture mouse) async {
  await tester.tapAt(tester.getCenter(find.byType(AgentWidget).first),
      buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
  await tester.pumpAndSettle();
  await mouse.moveTo(tester.getCenter(find.text('Weapon')));
  await tester.pumpAndSettle();
}

/// Opens the Weapon submenu, then the given category inside it.
Future<void> _openCategory(
    WidgetTester tester, TestGesture mouse, String category) async {
  await _openWeaponMenu(tester, mouse);
  await mouse.moveTo(tester.getCenter(find.text(category)));
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['ICARUS_WEAPON_TEST_ARTIFACT_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: _viewport);
    CoordinateSystem.instance.setIsScreenshot(false);
  });

  for (final kind in ['plain', 'cone', 'circle']) {
    testWidgets('$kind agent selects, changes and removes a firearm by menu',
        (tester) async {
      tester.view
        ..physicalSize = _viewport
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = _container();
      addTearDown(() => _dispose(tester, container));
      container.read(agentProvider.notifier).fromHive([_agent(kind)]);
      await tester.pumpWidget(_harness(container));
      await tester.pumpAndSettle();
      final originalRect = tester.getRect(find.byType(AgentWidget));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 10));
      addTearDown(mouse.removePointer);

      await _openCategory(tester, mouse, 'Sidearms');
      for (final weapon in WeaponCategory.sidearms.weapons) {
        expect(find.text(weapon.displayName), findsOneWidget);
      }
      await _capture(tester, '$kind-sidearms-menu');
      await tester.tap(find.text('Bandit'));
      await tester.pumpAndSettle();
      expect(container.read(agentProvider).single.weapon, WeaponType.bandit);
      expect(tester.getRect(find.byType(AgentWidget)), originalRect);
      expect(tester.widget<WeaponIcon>(find.byType(WeaponIcon)).weapon,
          WeaponType.bandit);

      await _openCategory(tester, mouse, 'Rifles');
      await tester.tap(find.text('Vandal'));
      await tester.pumpAndSettle();
      expect(container.read(agentProvider).single.weapon, WeaponType.vandal);
      expect(tester.getRect(find.byType(AgentWidget)), originalRect);
      await _capture(tester, '$kind-vandal-badge');

      await _openWeaponMenu(tester, mouse);
      await tester.tap(find.text('None'));
      await tester.pumpAndSettle();
      expect(container.read(agentProvider).single.weapon, WeaponType.none);
      expect(find.byType(AgentWeaponBadge), findsNothing);
      expect(tester.getRect(find.byType(AgentWidget)), originalRect);
      container.read(actionProvider.notifier).undoAction();
      await tester.pumpAndSettle();
      expect(tester.widget<WeaponIcon>(find.byType(WeaponIcon)).weapon,
          WeaponType.vandal);
    });

    testWidgets(
        '$kind firearm preserves drag anchor at different sizes and zooms',
        (tester) async {
      tester.view
        ..physicalSize = _viewport
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = _container();
      addTearDown(() => _dispose(tester, container));
      for (final size in [Settings.agentSizeMin, Settings.agentSizeMax]) {
        for (final zoom in [1.0, 1.4]) {
          container
              .read(strategySettingsProvider.notifier)
              .updateAgentSize(size);
          container.read(screenZoomProvider.notifier).updateZoom(zoom);
          container.read(agentProvider.notifier).fromHive([
            _agent(kind, weapon: WeaponType.operator),
          ]);
          await tester.pumpWidget(_harness(container, zoom: zoom));
          await tester.pumpAndSettle();
          final before = tester.getTopLeft(find.byType(AgentWidget));
          final start =
              tester.getCenter(find.byType(AgentWidget)) - const Offset(2, 2);
          final gesture =
              await tester.startGesture(start, kind: PointerDeviceKind.mouse);
          const delta = Offset(65, 45);
          await gesture.moveBy(delta);
          await tester.pumpAndSettle();
          expect(tester.widget<AgentWidget>(find.byType(AgentWidget)).weapon,
              WeaponType.operator);
          final feedback = tester.getTopLeft(find.byType(AgentWidget));
          expect((feedback - before - delta).distance, lessThan(0.01));
          await gesture.up();
          await tester.pumpAndSettle();
          final after = tester.getTopLeft(find.byType(AgentWidget));
          expect((after - before - delta).distance, lessThan(0.01));
          expect(
              container.read(agentProvider).single.weapon, WeaponType.operator);
        }
      }
    });
  }

  testWidgets('gun overhang paints outside the portrait and has no hit target',
      (tester) async {
    tester.view
      ..physicalSize = _viewport
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = _container();
    addTearDown(() => _dispose(tester, container));
    container.read(agentProvider.notifier).fromHive([
      _agent('plain', weapon: WeaponType.classic),
    ]);
    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();
    final agentRect = tester.getRect(find.byType(AgentWidget));
    final badgeRect = tester.getRect(find.byType(AgentWeaponBadge));
    expect(badgeRect.right, greaterThan(agentRect.right));
    expect(badgeRect.bottom, greaterThan(agentRect.bottom));

    // A filtered run starts with a cold image cache. Wait for the actual asset
    // before inspecting pixels instead of relying on earlier menu tests.
    await tester.runAsync(() => precacheImage(
          AssetImage(WeaponType.classic.iconPath),
          tester.element(find.byType(AgentWeaponBadge)),
        ));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: agentRect.center);
    await tester.pumpAndSettle();
    expect(container.read(hoveredDeleteTargetProvider)?.id, 'plain');
    await mouse.moveTo(Offset(agentRect.right + 1, badgeRect.center.dy));
    await tester.pumpAndSettle();
    expect(container.read(hoveredDeleteTargetProvider), isNull);
    await tester.tapAt(Offset(agentRect.right + 1, badgeRect.center.dy),
        buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('Weapon'), findsNothing);
    await mouse.removePointer();

    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      var whitePixelsOutside = 0;
      for (var y = badgeRect.top.floor(); y < badgeRect.bottom.ceil(); y++) {
        for (var x = badgeRect.left.floor(); x < badgeRect.right.ceil(); x++) {
          if (agentRect.contains(Offset(x.toDouble(), y.toDouble()))) continue;
          final offset = (y * image.width + x) * 4;
          if (pixels!.getUint8(offset) > 220 &&
              pixels.getUint8(offset + 1) > 220 &&
              pixels.getUint8(offset + 2) > 220) {
            whitePixelsOutside++;
          }
        }
      }
      image.dispose();
      expect(whitePixelsOutside, greaterThan(0));
    });
  });

  testWidgets('lineup origin offers the same firearm menu', (tester) async {
    tester.view
      ..physicalSize = _viewport
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = _container();
    addTearDown(() => _dispose(tester, container));
    container.read(lineUpProvider.notifier).fromHive(LineUpGraph(
          origins: [
            LineUpOrigin(id: 'origin', agent: _agent('plain') as PlacedAgent)
          ],
          landings: [
            LineUpLanding(
              id: 'landing',
              ability: PlacedAbility(
                id: 'ability',
                data: AgentData.agents[AgentType.sova]!.abilities.first,
                position: const Offset(900, 500),
              ),
            ),
          ],
          links: [
            LineUpLink(id: 'link', originId: 'origin', landingId: 'landing')
          ],
        ));
    await tester.pumpWidget(_harness(container));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    addTearDown(mouse.removePointer);
    await _openCategory(tester, mouse, 'Heavies');
    await tester.tap(find.text('Odin'));
    await tester.pumpAndSettle();
    expect(container.read(lineUpProvider).origins.single.agent.weapon,
        WeaponType.odin);
    expect(tester.widget<AgentWidget>(find.byType(AgentWidget)).weapon,
        WeaponType.odin);
  });

  testWidgets('lineup draft firearm edits do not change the source agent',
      (tester) async {
    tester.view
      ..physicalSize = _viewport
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = _container();
    addTearDown(() => _dispose(tester, container));
    final source = _agent('plain', weapon: WeaponType.vandal) as PlacedAgent;
    container.read(agentProvider.notifier).fromHive([source]);
    final lineups = container.read(lineUpProvider.notifier);
    lineups.startFresh();
    lineups.setDraftAgent(source);
    await tester
        .pumpWidget(_harness(container, child: const LineupPositionWidget()));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 10));
    addTearDown(mouse.removePointer);
    await _openCategory(tester, mouse, 'Shotguns');
    await tester.tap(find.text('Judge'));
    await tester.pumpAndSettle();
    expect(container.read(lineUpProvider).placement!.draftAgent!.weapon,
        WeaponType.judge);
    expect(container.read(agentProvider).single.weapon, WeaponType.vandal);
    expect(tester.widget<AgentWidget>(find.byType(AgentWidget)).weapon,
        WeaponType.judge);
  });

  testWidgets(
      'shared page and video renderer fades weapon changes at one anchor',
      (tester) async {
    tester.view
      ..physicalSize = _viewport
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = _container();
    addTearDown(() => _dispose(tester, container));
    for (final kind in ['plain', 'cone', 'circle']) {
      final from = _agent(kind, weapon: WeaponType.classic);
      final to = _agent(kind, weapon: WeaponType.vandal);
      final entries = TransitionPlanner.diff({kind: from}, {kind: to});
      expect(entries.single.kind, TransitionKind.move);
      Rect? firstRect;
      for (final t in [0.0, 0.5, 1.0]) {
        await tester.pumpWidget(_harness(container,
            child: TransitionEntriesLayer(
              entries: entries,
              agentPaths: const {},
              t: t,
              direction: PageTransitionDirection.forward,
              agentSize: Settings.agentSize,
              abilitySize: Settings.abilitySize,
            )));
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byType(AgentWidget));
        firstRect ??= rect;
        expect(rect, firstRect);
        final visible = tester
            .widgetList<WeaponIcon>(find.byType(WeaponIcon))
            .map((icon) => icon.weapon)
            .toList();
        expect(
            visible,
            t == 0
                ? [WeaponType.classic]
                : t == 1
                    ? [WeaponType.vandal]
                    : [WeaponType.classic, WeaponType.vandal]);
      }
    }
  });

  testWidgets('every bundled firearm renders beside an unchanged portrait',
      (tester) async {
    tester.view
      ..physicalSize = _viewport
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = _container();
    addTearDown(() => _dispose(tester, container));
    await tester.pumpWidget(_harness(container,
        child: GridView.count(
          crossAxisCount: 5,
          childAspectRatio: 1.5,
          children: [
            for (final weapon in WeaponType.values)
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AgentWidget(
                    agent: AgentData.agents[AgentType.sova]!,
                    id: null,
                    isAlly: true,
                    isInteractive: false,
                    forcedAgentSize: 60,
                    weapon: weapon,
                  ),
                  const SizedBox(height: 16),
                  Text(weapon.displayName),
                ],
              ),
          ],
        )));
    await tester.pumpAndSettle();
    // Asset decoding can finish after pumpAndSettle on the software test engine.
    // Await every image before inspecting or capturing the full catalogue.
    await tester.runAsync(() async {
      final context = tester.element(find.byType(Scaffold));
      for (final weapon
          in WeaponType.values.where((w) => w != WeaponType.none)) {
        await precacheImage(AssetImage(weapon.iconPath), context);
      }
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(WeaponIcon), findsNWidgets(19));
    final sizes = tester
        .elementList(find.byType(AgentWidget))
        .map(
          (element) => (element.renderObject! as RenderBox).size,
        )
        .toSet();
    expect(sizes, hasLength(1));
    await _capture(tester, 'all-firearms');
  });
}
