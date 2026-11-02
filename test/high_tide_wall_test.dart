import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/wall_path.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/hovered_delete_target_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/widgets/canvas_draggable.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_wall.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _mapScale = 1.24;

class _TestActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    poppedItems = [];
    state = [...state, action];
  }
}

class _FixedMapProvider extends MapProvider {
  _FixedMapProvider(this.isAttack);

  final bool isAttack;

  @override
  MapState build() => MapState(currentMap: MapValue.lotus, isAttack: isAttack);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

AbilityInfo get _tideInfo => AgentData.agents[AgentType.harbor]!.abilities[1];

/// High Tide as it was before abilities had walls.
AbilityInfo _plainIcon() => AbilityInfo(
      type: AgentType.harbor,
      index: 1,
      name: 'High Tide',
      iconPath: _tideInfo.iconPath,
      abilityData: BaseAbility(iconPath: _tideInfo.iconPath),
    );

PlacedAbility _tide(List<Offset>? wallPath, {AbilityInfo? data}) =>
    PlacedAbility(
      id: 'tide',
      data: data ?? _tideInfo,
      position: const Offset(600, 500),
      wallPath: wallPath,
    );

class _TestStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => StrategyState(
        isSaved: true,
        stratName: null,
        id: 'wall-test',
        storageDirectory: null,
        activePageId: 'page-1',
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);

  void turnPage() => state = state.copyWith(activePageId: 'page-2');
}

ProviderContainer _container(WidgetTester tester, {bool isAttack = true}) {
  final container = ProviderContainer(overrides: [
    actionProvider.overrideWith(_TestActionProvider.new),
    mapProvider.overrideWith(() => _FixedMapProvider(isAttack)),
    strategyProvider.overrideWith(_TestStrategyProvider.new),
  ]);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the wall through its points', () {
    const points = [
      Offset.zero,
      Offset(10, -100),
      Offset(12, -110),
      Offset(200, -120),
    ];

    test('passes through every point', () {
      final line = smoothWallLine(points);
      for (final point in points) {
        final nearest = line
            .map((p) => (p - point).distance)
            .reduce((a, b) => a < b ? a : b);
        expect(nearest, lessThan(1e-6), reason: '$point');
      }
    });

    test("doesn't overshoot beside points close together", () {
      for (final point in smoothWallLine(points)) {
        expect(point.dy, greaterThan(-125), reason: '$point');
        expect(point.dx, greaterThan(-5), reason: '$point');
      }
    });

    test('two points are a straight line', () {
      expect(smoothWallLine(const [Offset.zero, Offset(0, -50)]), hasLength(2));
      expect(wallPathLength(const [Offset(0, -50)]), 50);
    });

    test('a pale dot sits in the middle of its stretch, on the wall', () {
      final middles = wallStretchMiddles(points);
      expect(middles, hasLength(3));
      final line = smoothWallLine(points);
      for (final middle in middles) {
        expect(line, contains(middle));
        expect(points, isNot(contains(middle)));
      }
      expect(
        wallStretchMiddles(const [Offset.zero, Offset(0, -50)]),
        const [Offset(0, -25)],
      );
    });

    test('a point added to a curved wall never takes it past the limit', () {
      final random = math.Random(7);
      var lengthened = 0;
      for (var wall = 0; wall < 300; wall++) {
        final path = <Offset>[];
        var at = Offset.zero;
        for (var i = 0; i < 4; i++) {
          at += Offset.fromDirection(
            random.nextDouble() * 2 * math.pi,
            40 + random.nextDouble() * 200,
          );
          path.add(at);
        }
        final limit = wallPathLength(path);
        final points = [Offset.zero, ...path];
        for (final (index, middle) in wallStretchMiddles(points).indexed) {
          final raw = [...path]..insert(index, middle);
          if (wallPathLength(raw) > limit + 0.01) lengthened++;
          final added = wallPathWithPoint(path, index, middle, limit: limit);
          expect(added, hasLength(path.length + 1));
          expect(wallPathLength(added), lessThanOrEqualTo(limit + 1e-6));
        }
      }
      expect(lengthened, greaterThan(0), reason: 'the case this guards');
    });

    test('a point on a short wall goes in where it was put', () {
      expect(
        wallPathWithPoint(
          const [Offset(0, -100)],
          0,
          const Offset(20, -50),
          limit: 1000,
        ),
        const [Offset(20, -50), Offset(0, -100)],
      );
    });

    test('resampling keeps the ends and spaces points evenly', () {
      final even = resampleWallLine(smoothWallLine(points), 9);
      expect(even, hasLength(9));
      expect((even.first - points.first).distance, lessThan(1e-6));
      expect((even.last - points.last).distance, lessThan(1e-6));
      final steps = [
        for (var i = 0; i + 1 < even.length; i++)
          (even[i + 1] - even[i]).distance,
      ];
      for (final step in steps) {
        expect(step, closeTo(steps.first, steps.first * 0.1));
      }
    });
  });

  group('a new wall', () {
    setUp(() => CoordinateSystem(playAreaSize: const Size(1600, 900)));

    test('is 30 m, straight up the screen, on either side', () {
      final meter = wallWorldPerMeter(_mapScale);
      expect(
        defaultWallPath(_tideInfo.abilityData,
                mapScale: _mapScale, isAttack: true)!
            .single,
        Offset(0, -30 * meter),
      );
      expect(
        defaultWallPath(_tideInfo.abilityData,
                mapScale: _mapScale, isAttack: false)!
            .single,
        Offset(0, 30 * meter),
      );
    });

    test('only High Tide gets one', () {
      expect(
        defaultWallPath(
          AgentData.agents[AgentType.jett]!.abilities.first.abilityData,
          mapScale: _mapScale,
          isAttack: true,
        ),
        isNull,
      );
    });

    test('a wall changes a page transition, an empty one is no wall', () {
      expect(
        PageTransitionEntry.visualsDiffer(
          _tide(null),
          _tide(const [Offset(1, 1)]),
        ),
        isTrue,
      );
      expect(
        PageTransitionEntry.visualsDiffer(_tide(null), _tide(const [])),
        isFalse,
      );
    });
  });

  group('a saved High Tide', () {
    const canvasKey = ValueKey('saved-canvas');

    Future<({Rect icon, List<int> pixels})> render(
      WidgetTester tester,
      AbilityInfo data, {
      bool isAttack = true,
    }) async {
      CoordinateSystem(playAreaSize: const Size(1600, 900));
      final container = _container(tester, isAttack: isAttack);
      final saved = _tide(null, data: data);
      container.read(abilityProvider.notifier).fromHive([saved]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ShadApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: canvasKey,
                child: SizedBox(
                  width: 1600,
                  height: 900,
                  child: Stack(
                    children: [
                      const PlacedWallList(),
                      PlacedAbilityWidget(
                        ability: saved,
                        onDragEnd: (_, __) {},
                        id: saved.id,
                        data: saved,
                        rotation: saved.rotation,
                        length: saved.length,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final icon = tester.getRect(find.byType(CanvasDraggable<PlacedWidget>));
      final pixels = await tester.runAsync(() async {
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(canvasKey));
        final image = await boundary.toImage();
        final bytes = await image.toByteData();
        return bytes!.buffer.asUint8List().toList();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      return (icon: icon, pixels: pixels!);
    }

    test('keeps the box it was placed in', () {
      const abilitySize = 42.0;
      final plain = _plainIcon().abilityData!;
      final tide = _tideInfo.abilityData!;
      expect(tide, isA<GuidedWallAbility>());
      for (final size in [abilitySize, 25.0]) {
        expect(
          tide.getAnchorPoint(mapScale: _mapScale, abilitySize: size),
          plain.getAnchorPoint(mapScale: _mapScale, abilitySize: size),
        );
        expect(
          tide.getSize(mapScale: _mapScale, abilitySize: size),
          plain.getSize(mapScale: _mapScale, abilitySize: size),
        );
      }
      expect(
        storedAbilityAnchor(ability: tide, mapScale: _mapScale),
        storedAbilityAnchor(ability: plain, mapScale: _mapScale),
      );
    });

    for (final isAttack in [true, false]) {
      testWidgets(
          'draws the same pixels on the ${isAttack ? 'attack' : 'defense'} side',
          (tester) async {
        tester.view
          ..physicalSize = const Size(1600, 900)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        // Decode the icon first so both renders draw it.
        await render(tester, _plainIcon(), isAttack: isAttack);
        final before = await render(tester, _plainIcon(), isAttack: isAttack);
        final after = await render(tester, _tideInfo, isAttack: isAttack);

        expect(after.icon, before.icon);
        expect(after.pixels, before.pixels);
      });
    }
  });

  testWidgets('a wall is drawn from its icon, turned to the defending side',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    final scale = CoordinateSystem.instance.worldHeightToScreen(1);
    final attack = WallOnScreen.of(
      _tide(null),
      mapScale: _mapScale,
      abilitySize: 25,
      isAttack: true,
    );
    final defense = WallOnScreen.of(
      _tide(null),
      mapScale: _mapScale,
      abilitySize: 25,
      isAttack: false,
    );
    const saved = Offset(40, -100);

    expect(attack.point(saved) - attack.center, saved * scale);
    expect(defense.point(saved) - defense.center, saved * -scale);
    expect((attack.saved(attack.point(saved)) - saved).distance, lessThan(1e-9));
    expect(
      (defense.saved(defense.point(saved)) - saved).distance,
      lessThan(1e-9),
    );
  });

  testWidgets('an icon drag the ability goes out from under unhides its wall',
      (tester) async {
    tester.view
      ..physicalSize = const Size(1600, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    CoordinateSystem(playAreaSize: const Size(1600, 900));
    final container = _container(tester);
    container
        .read(abilityProvider.notifier)
        .fromHive([_tide(const [Offset(0, -300)])]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: SizedBox(
            width: 1600,
            height: 900,
            child: Consumer(
              builder: (context, ref, _) => Stack(
                children: [
                  for (final ability in ref.watch(abilityProvider))
                    PlacedAbilityWidget(
                      key: ValueKey(ability.id),
                      ability: ability,
                      onDragEnd: (_, __) {},
                      id: ability.id,
                      data: ability,
                      rotation: ability.rotation,
                      length: ability.length,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final finger = await tester.startGesture(
      tester.getCenter(find.byType(CanvasDraggable<PlacedWidget>)),
    );
    await finger.moveBy(const Offset(40, 40));
    await tester.pump();
    await finger.moveBy(const Offset(40, 40));
    await tester.pump();
    expect(container.read(wallCarriedProvider), 'tide');

    container.read(abilityProvider.notifier).fromHive(const []);
    await tester.pump();
    await tester.pump();

    expect(container.read(wallCarriedProvider), isNull);
    await finger.up();
    await tester.pump();
  });

  group('in a page transition', () {
    Future<List<Offset>> wallLine(
      WidgetTester tester,
      PageTransitionEntry entry, {
      required double t,
      PageTransitionDirection direction = PageTransitionDirection.forward,
    }) async {
      tester.view
        ..physicalSize = const Size(1600, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      CoordinateSystem(playAreaSize: const Size(1600, 900));
      final container = _container(tester);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ShadApp(
            home: SizedBox(
              width: 1600,
              height: 900,
              child: TransitionEntriesLayer(
                entries: [entry],
                agentPaths: const {},
                t: t,
                direction: direction,
                agentSize: 35,
                abilitySize: 25,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final paint = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is WallPainter,
        ),
      );
      return (paint.painter! as WallPainter).line;
    }

    testWidgets('a wall alone on one page slides with its icon', (tester) async {
      final tide = _tide(const [Offset(0, -300)]);
      final at = WallOnScreen.of(
        tide,
        mapScale: _mapScale,
        abilitySize: 25,
        isAttack: true,
      ).center;
      final slide = CoordinateSystem.instance.scale(28);

      final appearing = await wallLine(
        tester,
        PageTransitionEntry.appear(to: tide),
        t: 0.5,
      );
      expect((appearing.first - (at + Offset(slide / 2, 0))).distance,
          lessThan(0.5));

      final leaving = await wallLine(
        tester,
        PageTransitionEntry.disappear(from: tide),
        t: 0.5,
      );
      expect((leaving.first - (at - Offset(slide / 2, 0))).distance,
          lessThan(0.5));
    });
  });

  group('hit testing', () {
    final painter = WallPainter(
      line: const [Offset(100, 100), Offset(300, 100)],
      team: Colors.green,
      width: 6,
      edge: 2,
    );

    test('takes the wall, not what lies beside it', () {
      expect(painter.hitTest(const Offset(200, 108)), isTrue);
      expect(painter.hitTest(const Offset(200, 125)), isFalse);
      expect(painter.hitTest(const Offset(330, 100)), isFalse);
    });
  });

  group('shaping a wall', () {
    Future<ProviderContainer> pumpWall(
      WidgetTester tester,
      List<Offset>? path, {
      bool isAttack = true,
    }) async {
      tester.view
        ..physicalSize = const Size(1600, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      CoordinateSystem(playAreaSize: const Size(1600, 900));
      final container = _container(tester, isAttack: isAttack);
      container.read(abilityProvider.notifier).fromHive([_tide(path)]);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ShadApp(
            home: SizedBox(
              width: 1600,
              height: 900,
              child: Stack(
                children: [PlacedWallList(), PlacedWallHandleList()],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return container;
    }

    Future<TestGesture> hoverWall(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      final ability = container.read(abilityProvider).single;
      final wall = WallOnScreen.of(
        ability,
        mapScale: _mapScale,
        abilitySize: 25,
        isAttack: container.read(mapProvider).isAttack,
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(5, 5));
      await mouse.moveTo(wall.point(ability.wallPath!.first * 0.5));
      await tester.pump();
      return mouse;
    }

    /// Lets the frame after a change run, and the hover grace it may start.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    Finder dot(int index) => find.byKey(ValueKey('wall-dot-point-$index'));
    Finder pale(int index) => find.byKey(ValueKey('wall-dot-pale-$index'));

    double meters(ProviderContainer container) =>
        wallPathLength(container.read(abilityProvider).single.wallPath!) /
        wallWorldPerMeter(_mapScale);

    testWidgets('its dots show on hover and go when the pointer leaves',
        (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      expect(dot(0), findsNothing);

      final mouse = await hoverWall(tester, container);
      expect(dot(0), findsOneWidget);
      expect(pale(0), findsOneWidget);

      await mouse.moveTo(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 100));
      expect(dot(0), findsOneWidget, reason: 'time to reach a dot');
      await tester.pump(const Duration(milliseconds: 200));
      expect(dot(0), findsNothing);
    });

    testWidgets('the wall and its dots both aim the delete key at it',
        (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      final mouse = await hoverWall(tester, container);
      expect(container.read(hoveredDeleteTargetProvider)?.id, 'tide');

      await mouse.moveTo(tester.getCenter(dot(0)));
      await tester.pump();
      expect(container.read(hoveredDeleteTargetProvider)?.id, 'tide');

      await mouse.moveTo(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(hoveredDeleteTargetProvider), isNull);
    });

    testWidgets('a wall taken away under the pointer disarms the delete key',
        (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      await hoverWall(tester, container);
      expect(container.read(hoveredDeleteTargetProvider)?.id, 'tide');

      container.read(abilityProvider.notifier).setWallPath('tide', const []);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(container.read(hoveredDeleteTargetProvider), isNull);
      expect(dot(0), findsNothing);
    });

    testWidgets('a dot right-clicked away lets go of the pointer',
        (tester) async {
      final container = await pumpWall(tester, const [
        Offset(0, -150),
        Offset(0, -300),
      ]);
      final mouse = await hoverWall(tester, container);
      await mouse.moveTo(tester.getCenter(dot(1)));
      await tester.pump();

      await tester.tap(dot(1), buttons: kSecondaryButton);
      await tester.pump(const Duration(milliseconds: 300));

      expect(container.read(hoveredDeleteTargetProvider), isNull);
      expect(container.read(wallHoverProvider), isNull);
    });

    testWidgets('selecting the icon shows its dots, for touch', (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      expect(dot(0), findsNothing);

      container
          .read(canvasSelectionProvider.notifier)
          .select({(kind: SelectableKind.ability, id: 'tide')});
      await tester.pump();
      expect(dot(0), findsOneWidget);

      container.read(canvasSelectionProvider.notifier).clear();
      await tester.pump();
      expect(dot(0), findsNothing);
    });

    testWidgets('a wall that was removed shows no dots', (tester) async {
      await pumpWall(tester, const []);
      expect(find.byType(CustomPaint), findsNothing);
    });

    testWidgets('dragging a dot moves that point, as one undo step',
        (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      final mouse = await hoverWall(tester, container);
      final scale = CoordinateSystem.instance.worldHeightToScreen(1);

      await tester.drag(dot(0), const Offset(60, 0), touchSlopX: 0);
      await settle(tester);

      final path = container.read(abilityProvider).single.wallPath!;
      expect(path.single.dx, closeTo(60 / scale, 1.5));
      expect(path.single.dy, closeTo(-300, 0.5));

      container.read(actionProvider.notifier).undoAction();
      expect(
        container.read(abilityProvider).single.wallPath,
        const [Offset(0, -300)],
      );
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('the dots stay when a mouse lets go on one', (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      final mouse = await hoverWall(tester, container);

      await mouse.moveTo(tester.getCenter(dot(0)));
      await tester.pump();
      await mouse.down(tester.getCenter(dot(0)));
      await tester.pump();
      await mouse.moveBy(const Offset(40, 0));
      await tester.pump();
      await mouse.moveBy(const Offset(20, 0));
      await tester.pump();
      await mouse.up();
      await settle(tester);

      expect(dot(0), findsOneWidget);
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
      expect(dot(0), findsNothing);
    });

    testWidgets('dragging a dot on the defending side saves the attack side',
        (tester) async {
      final container = await pumpWall(
        tester,
        const [Offset(0, 300)],
        isAttack: false,
      );
      final mouse = await hoverWall(tester, container);
      final scale = CoordinateSystem.instance.worldHeightToScreen(1);

      await tester.drag(dot(0), const Offset(60, 0), touchSlopX: 0);
      await settle(tester);

      expect(
        container.read(abilityProvider).single.wallPath!.single.dx,
        closeTo(-60 / scale, 1.5),
      );
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('dragging a pale dot adds a bend in its place', (tester) async {
      final container = await pumpWall(tester, const [
        Offset(0, -150),
        Offset(0, -300),
      ]);
      final mouse = await hoverWall(tester, container);

      await tester.drag(pale(1), const Offset(50, 0), touchSlopX: 0);
      await settle(tester);

      final path = container.read(abilityProvider).single.wallPath!;
      expect(path, hasLength(3));
      expect(path.first, const Offset(0, -150));
      expect(path.last, const Offset(0, -300));
      expect(path[1].dx, greaterThan(10));
      expect(path[1].dy, closeTo(-225, 2));
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('a drag stops at the longest wall', (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      final mouse = await hoverWall(tester, container);

      await tester.drag(dot(0), const Offset(0, -700), touchSlopY: 0);
      await settle(tester);

      expect(meters(container), closeTo(60, 0.05));
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('pulling a bend out of a full-length wall stays at the longest',
        (tester) async {
      final longest = 60 * wallWorldPerMeter(_mapScale);
      final container = await pumpWall(tester, [Offset(0, -longest)]);
      final mouse = await hoverWall(tester, container);

      // One long move: the pan starts with the pointer already far out.
      final finger = await tester.startGesture(tester.getCenter(pale(0)));
      await finger.moveBy(const Offset(220, 0));
      await tester.pump();
      await finger.up();
      await settle(tester);

      expect(container.read(abilityProvider).single.wallPath, hasLength(2));
      expect(meters(container), lessThanOrEqualTo(60.05));
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('a page turned under a touch drag lets the dots go',
        (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      final mouse = await hoverWall(tester, container);
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
      expect(container.read(wallHoverProvider), isNull);

      container
          .read(canvasSelectionProvider.notifier)
          .select({(kind: SelectableKind.ability, id: 'tide')});
      await tester.pump();
      final finger = await tester.startGesture(tester.getCenter(dot(0)));
      await finger.moveBy(const Offset(60, 0));
      await tester.pump();
      (container.read(strategyProvider.notifier) as _TestStrategyProvider)
          .turnPage();
      await tester.pump();
      await finger.up();
      container.read(canvasSelectionProvider.notifier).clear();
      await settle(tester);

      expect(container.read(wallHoverProvider), isNull);
      expect(dot(0), findsNothing);
    });

    testWidgets("a removed drag leaves another wall's drag alone",
        (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      final mouse = await hoverWall(tester, container);
      final finger = await tester.startGesture(tester.getCenter(dot(0)));
      await finger.moveBy(const Offset(60, 0));
      await tester.pump();
      const other = (id: 'other', path: [Offset(1, 1)]);
      container.read(wallDraftProvider.notifier).set(other);

      container.read(abilityProvider.notifier).fromHive(const []);
      await tester.pump();
      await tester.pump();

      expect(container.read(wallDraftProvider), other);
      await finger.up();
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('an over-long wall can shrink and not grow', (tester) async {
      final longest = 60 * wallWorldPerMeter(_mapScale);
      final container = await pumpWall(tester, [Offset(longest + 200, 0)]);
      final mouse = await hoverWall(tester, container);
      final before = meters(container);
      final onWall = tester.getCenter(pale(0));

      await tester.drag(dot(0), const Offset(80, 0), touchSlopX: 0);
      await settle(tester);
      expect(meters(container), lessThanOrEqualTo(before + 0.05));

      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
      await mouse.moveTo(onWall);
      await tester.pump();
      await tester.drag(dot(0), const Offset(-80, 0), touchSlopX: 0);
      await settle(tester);
      expect(meters(container), lessThan(before - 1));
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('a dot drag the ability goes out from under leaves no draft',
        (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      final mouse = await hoverWall(tester, container);
      final finger = await tester.startGesture(tester.getCenter(dot(0)));
      await finger.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(container.read(wallDraftProvider), isNotNull);

      container.read(abilityProvider.notifier).fromHive(const []);
      await tester.pump();
      await tester.pump();

      expect(container.read(wallDraftProvider), isNull);
      await finger.up();
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('turning the page under a dot drag drops it unsaved',
        (tester) async {
      final container = await pumpWall(tester, const [Offset(0, -300)]);
      final mouse = await hoverWall(tester, container);
      final finger = await tester.startGesture(tester.getCenter(dot(0)));
      await finger.moveBy(const Offset(60, 0));
      await tester.pump();

      (container.read(strategyProvider.notifier) as _TestStrategyProvider)
          .turnPage();
      await tester.pump();
      expect(container.read(wallDraftProvider), isNull);

      await finger.moveBy(const Offset(60, 0));
      await finger.up();
      await tester.pump();
      expect(
        container.read(abilityProvider).single.wallPath,
        const [Offset(0, -300)],
      );
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('a wall holds no more than its most points', (tester) async {
      final container = await pumpWall(tester, [
        for (var i = 1; i <= maxWallPathPoints; i++) Offset(i * 20, -i * 30),
      ]);
      final mouse = await hoverWall(tester, container);

      expect(dot(maxWallPathPoints - 1), findsOneWidget);
      expect(pale(0), findsNothing);
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });

    testWidgets('right-clicking a dot takes it away, but never the last one',
        (tester) async {
      final container = await pumpWall(tester, const [
        Offset(0, -150),
        Offset(0, -300),
      ]);
      final mouse = await hoverWall(tester, container);

      await tester.tap(dot(0), buttons: kSecondaryButton);
      await settle(tester);
      expect(
        container.read(abilityProvider).single.wallPath,
        const [Offset(0, -300)],
      );

      await tester.tap(dot(0), buttons: kSecondaryButton);
      await settle(tester);
      expect(
        container.read(abilityProvider).single.wallPath,
        const [Offset(0, -300)],
      );
      await mouse.moveTo(const Offset(5, 5));
      await settle(tester);
    });
  });

}
