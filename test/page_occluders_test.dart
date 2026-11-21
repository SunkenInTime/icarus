import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/wall_path.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/view_cone/cone_coverage.dart';
import 'package:icarus/view_cone/page_occluders.dart';
import 'package:icarus/view_cone/sightline_report.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/view_cone/vision_occluders.dart';
import 'package:icarus/view_cone/vision_world_gzip.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_wall.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';
import 'package:path/path.dart' as path;
import 'package:shadcn_ui/shadcn_ui.dart';

const _sightBlockers = [
  (AgentType.astra, 2),
  (AgentType.brimstone, 2),
  (AgentType.clove, 2),
  (AgentType.cypher, 1),
  (AgentType.harbor, 1),
  (AgentType.harbor, 2),
  (AgentType.jett, 0),
  (AgentType.miks, 2),
  (AgentType.omen, 2),
  (AgentType.pheonix, 0),
  (AgentType.viper, 1),
  (AgentType.viper, 2),
];

AbilityInfo _ability(AgentType agent, int index) =>
    AgentData.agents[agent]!.abilities[index];

PlacedAbility _placed(
  AgentType agent,
  int index, {
  Offset position = const Offset(400, 300),
  double rotation = 0,
  List<Offset>? wallPath,
  AbilityVisualState visualState = const AbilityVisualState(),
}) =>
    PlacedAbility(
      data: _ability(agent, index),
      position: position,
      id: '${agent.name}-$index',
      rotation: rotation,
      wallPath: wallPath,
      visualState: visualState,
    );

Offset _drawnMiddle(PlacedAbility placed, double mapScale) =>
    placed.position +
    CoordinateSystem.virtualToWorld(
      storedAbilityAnchor(
        ability: placed.data.abilityData!,
        mapScale: mapScale,
      ),
    );

Map<String, dynamic> _openFloor() => {
      'version': 1,
      'coordinateSpace': 'svg',
      'verticalSpace': 'meters-above-local-floor',
      'walls': [],
      'supports': [],
      'receiver': [
        {
          'rings': [
            [-100, -100, 600, -100, 600, 600, -100, 600]
          ],
          'fillRule': 'evenodd',
        }
      ],
    };

class _Ascent extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);

  void flip() =>
      state = MapState(currentMap: MapValue.ascent, isAttack: !state.isAttack);
}

class _Split extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.split, isAttack: true);
}

SightBlockers _declared(
  Iterable<PlacedAbility> abilities, {
  required double mapScale,
}) {
  final blockers = SightBlockers();
  for (final ability in abilities) {
    blockers.declare(ability.id, sightBlockOf(ability, mapScale: mapScale));
  }
  return blockers;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('which placed abilities block sight', () {
    test('smokes and walls of smoke, fire and water, and nothing else', () {
      final blocking = {
        for (final agent in AgentData.agents.values)
          for (final ability in agent.abilities)
            if (blocksSight(ability)) (ability.type, ability.index),
      };
      expect(blocking, _sightBlockers.toSet());
    });

    test('every one of them blocks as it is placed', () {
      for (final (agent, index) in _sightBlockers) {
        final wallPath = _ability(agent, index).abilityData is GuidedWallAbility
            ? const [Offset(0, -40)]
            : null;
        expect(
          occluderOf(_placed(agent, index, wallPath: wallPath), mapScale: 1),
          isNotNull,
          reason: '${agent.name} $index',
        );
      }
    });

    test('a smoke is a circle as wide as it is drawn, where it is drawn', () {
      const mapScale = 0.9;
      for (final (agent, index) in [
        (AgentType.omen, 2),
        (AgentType.cypher, 1),
      ]) {
        final smoke = _placed(agent, index);
        final drawn = switch (smoke.data.abilityData) {
          ImageAbility(:final size) || CircleAbility(:final size) => size,
          _ => throw StateError('not a smoke'),
        };
        final occluder =
            occluderOf(smoke, mapScale: mapScale)! as CircleOccluder;
        expect(occluder.centre, _drawnMiddle(smoke, mapScale));
        expect(
          occluder.radius,
          closeTo(CoordinateSystem.virtualLengthInWorld(drawn * mapScale / 2),
              1e-9),
        );
      }
    });

    test('a resized cage blocks at the size it is drawn, not its old box', () {
      final cage = _ability(AgentType.cypher, 1).abilityData! as CircleAbility;
      expect(cage.storedSize, isNot(cage.size));
      final occluder = occluderOf(_placed(AgentType.cypher, 1), mapScale: 1)!
          as CircleOccluder;
      expect(occluder.radius,
          closeTo(CoordinateSystem.virtualLengthInWorld(cage.size / 2), 1e-9));
    });

    test('a turned wall runs from its icon the way it faces, its full length',
        () {
      const mapScale = 1.1;
      final wall = _placed(AgentType.viper, 2, rotation: math.pi / 2);
      final screen = wall.data.abilityData! as SquareAbility;
      final occluder = occluderOf(wall, mapScale: mapScale)! as LineOccluder;
      final icon = _drawnMiddle(wall, mapScale);
      expect(occluder.points.first, icon);
      final run = occluder.points.last - occluder.points.first;
      expect(
          run.dx,
          closeTo(CoordinateSystem.virtualLengthInWorld(screen.height * 1.1),
              1e-9));
      expect(run.dy, closeTo(0, 1e-9));
    });

    test('a High Tide blocks along the wall as drawn, and not without one', () {
      const path = [Offset(0, -40), Offset(30, -70)];
      final tide = _placed(AgentType.harbor, 1, wallPath: path);
      final icon = _drawnMiddle(tide, 1);
      final occluder = occluderOf(tide, mapScale: 1)! as LineOccluder;
      expect(
        occluder.points,
        smoothWallLine([icon, for (final point in path) icon + point]),
      );
      expect(occluderOf(_placed(AgentType.harbor, 1), mapScale: 1), isNull);
      expect(
        occluderOf(_placed(AgentType.harbor, 1, wallPath: const []),
            mapScale: 1),
        isNull,
      );
    });

    test('a Viper wall or cloud that is down, or a wall hidden, blocks nothing',
        () {
      const down = AbilityVisualState(showRangeFill: false);
      expect(
          occluderOf(_placed(AgentType.viper, 1, visualState: down),
              mapScale: 1),
          isNull);
      expect(
          occluderOf(_placed(AgentType.viper, 2, visualState: down),
              mapScale: 1),
          isNull);
      expect(
          occluderOf(_placed(AgentType.pheonix, 0, visualState: down),
              mapScale: 1),
          isNull);
      expect(
          occluderOf(_placed(AgentType.omen, 2, visualState: down),
              mapScale: 1),
          isNotNull);
      expect(
        occluderOf(_placed(AgentType.cypher, 1, visualState: down),
            mapScale: 1),
        isNotNull,
        reason: 'its outline still shows',
      );
    });
  });

  group('what a page draws is what blocks', () {
    late ProviderContainer container;
    late ConeCoverage coverage;

    setUp(() {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      container =
          ProviderContainer(overrides: [mapProvider.overrideWith(_Ascent.new)]);
      coverage = ConeCoverage();
    });

    Future<void> showPage(
      WidgetTester tester,
      List<PlacedAbility> abilities,
    ) async {
      container.read(abilityProvider.notifier).fromHive(abilities);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Scaffold(
            body: ConeCoverageScope(
              coverage: coverage,
              child: Consumer(
                builder: (context, ref, _) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (final ability in ref.watch(abilityProvider))
                      EditorEntityLayer(
                        key: ValueKey('entity-${ability.id}'),
                        id: ability.id,
                        kind: SelectableKind.ability,
                        child: PlacedAbilityWidget(
                          key: ValueKey(ability.id),
                          ability: ability,
                          onDragEnd: (_, __) {},
                          id: ability.id,
                          data: ability,
                          rotation: ability.rotation,
                          length: ability.length,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    Future<void> closePage(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      coverage.dispose();
    }

    Set<SightBlock> drawn() => {...coverage.blockers.all};

    Set<SightBlock> saved() => {
          for (final ability in container.read(abilityProvider))
            if (sightBlockOf(ability, mapScale: 1) case final block?) block,
        };

    Offset centreOf(PlacedAbility smoke) => (drawn()
            .singleWhere((block) => block.name == sightBlockName(smoke.data))
            .shape as CircleOccluder)
        .centre;

    Offset worldOf(Offset screen) =>
        CoordinateSystem.instance.screenToCoordinate(screen);

    void expectNear(Offset actual, Offset expected) =>
        expect((actual - expected).distance, lessThan(1e-6),
            reason: '$actual, expected $expected');

    testWidgets(
        'a smoke blocks where it is drawn as it is dragged, then '
        'where the page has it', (tester) async {
      final smoke = _placed(AgentType.omen, 2);
      await showPage(tester, [smoke]);
      expect(drawn(), saved());
      expect(drawn(), hasLength(1));
      final gesture = await tester
          .startGesture(tester.getCenter(find.byKey(ValueKey(smoke.id))));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      final first = centreOf(smoke);
      expect(first, isNot(_drawnMiddle(smoke, 1)));
      await gesture.moveBy(const Offset(40, -20));
      await tester.pump();
      expectNear(centreOf(smoke), first + worldOf(const Offset(40, -20)));
      await gesture.up();
      await tester.pump();
      expect(drawn(), saved());
      await closePage(tester);
    });

    testWidgets('switching sides mid-drag keeps the blocker under the smoke',
        (tester) async {
      final smoke = _placed(AgentType.omen, 2);
      await showPage(tester, [smoke]);
      final gesture = await tester
          .startGesture(tester.getCenter(find.byKey(ValueKey(smoke.id))));
      await gesture.moveBy(const Offset(30, 10));
      await tester.pump();
      final onAttack = centreOf(smoke);
      (container.read(mapProvider.notifier) as _Ascent).flip();
      await tester.pump();
      expectNear(
        centreOf(smoke),
        CoordinateSystem.instance.positionForSide(
          canonicalPosition: onAttack,
          reflectionOffset: Offset.zero,
          isAttack: false,
        ),
      );
      await gesture.up();
      await tester.pump();
      expect(drawn(), saved());
      await closePage(tester);
    });

    testWidgets('two smokes dragged at once each block where they are drawn',
        (tester) async {
      final darkCover = _placed(AgentType.omen, 2);
      final skySmoke =
          _placed(AgentType.brimstone, 2, position: const Offset(700, 500));
      await showPage(tester, [darkCover, skySmoke]);
      final one = await tester
          .startGesture(tester.getCenter(find.byKey(ValueKey(darkCover.id))));
      final two = await tester.startGesture(
          tester.getCenter(find.byKey(ValueKey(skySmoke.id))),
          pointer: 7);
      await one.moveBy(const Offset(30, 0));
      await two.moveBy(const Offset(0, 30));
      await tester.pump();
      final oneAt = centreOf(darkCover), twoAt = centreOf(skySmoke);
      await one.moveBy(const Offset(25, 0));
      await tester.pump();
      await two.moveBy(const Offset(0, 25));
      await tester.pump();
      expectNear(centreOf(darkCover), oneAt + worldOf(const Offset(25, 0)));
      expectNear(centreOf(skySmoke), twoAt + worldOf(const Offset(0, 25)));
      await one.up();
      await two.up();
      await tester.pump();
      expect(drawn(), saved());
      await closePage(tester);
    });

    testWidgets(
        'undoing in the middle of turning a wall leaves the wall as '
        'the page has it', (tester) async {
      final toxicScreen = _placed(AgentType.viper, 2);
      await showPage(tester, [toxicScreen]);
      final abilities = container.read(abilityProvider.notifier);
      abilities.updateVisualState(
          0, const AbilityVisualState(showRangeFill: false));
      abilities.updateVisualState(0, const AbilityVisualState());
      await tester.pump();
      final turning =
          tester.widget<RotatableWidget>(find.byType(RotatableWidget));
      turning.onPanStart(DragStartDetails(globalPosition: Offset.zero));
      turning.onPanUpdate(DragUpdateDetails(
          globalPosition: tester.getBottomRight(find.byType(RotatableWidget)) +
              const Offset(600, 0)));
      await tester.pump();
      expect(drawn(), isNot(saved()), reason: 'the wall turns as it is held');
      container.read(actionProvider.notifier).undoAction();
      await tester.pump();
      expect(find.byType(EditorItemHandle), findsNothing);
      expect(drawn(), saved());
      expect(drawn(), isEmpty, reason: 'the undo put the wall down');
      await closePage(tester);
    });

    for (final isAttack in [true, false]) {
      testWidgets(
          'a selection dragged together carries its smoke, '
          'attack=$isAttack', (tester) async {
        final smoke = _placed(AgentType.omen, 2);
        if (!isAttack) (container.read(mapProvider.notifier) as _Ascent).flip();
        await showPage(tester, [smoke]);
        container
            .read(canvasGroupDragProvider.notifier)
            .set((ids: {smoke.id}, by: const Offset(20, 10)));
        await tester.pump();
        final onScreen = worldOf(const Offset(20, 10));
        expectNear(centreOf(smoke),
            _drawnMiddle(smoke, 1) + (isAttack ? onScreen : -onScreen));
        container.read(canvasGroupDragProvider.notifier).set(null);
        await tester.pump();
        expect(drawn(), saved());
        await closePage(tester);
      });
    }

    testWidgets('a High Tide blocks along the dot being pulled',
        (tester) async {
      final tide =
          _placed(AgentType.harbor, 1, wallPath: const [Offset(0, -40)]);
      await showPage(tester, [tide]);
      container
          .read(wallDraftProvider.notifier)
          .set((id: tide.id, path: const [Offset(50, 0)]));
      await tester.pump();
      final line = drawn().single.shape as LineOccluder;
      expectNear(line.points.last, _drawnMiddle(tide, 1) + const Offset(50, 0));
      container.read(wallDraftProvider.notifier).set(null);
      await tester.pump();
      expect(drawn(), saved());
      await closePage(tester);
    });
  });

  testWidgets(
      'a page transition moves smokes and swaps those that come and go '
      'halfway', (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final container =
        ProviderContainer(overrides: [mapProvider.overrideWith(_Ascent.new)]);
    addTearDown(container.dispose);
    final moving = _placed(AgentType.omen, 2);
    final arriving =
        _placed(AgentType.brimstone, 2, position: const Offset(300, 600));
    final leaving =
        _placed(AgentType.jett, 0, position: const Offset(700, 600));
    double radiusOf(PlacedAbility smoke) =>
        (occluderOf(smoke, mapScale: 1)! as CircleOccluder).radius;

    final coverage = ConeCoverage();
    addTearDown(coverage.dispose);

    Future<List<CircleOccluder>> at(double t) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Scaffold(
            body: ConeCoverageScope(
              coverage: coverage,
              child: TransitionEntriesLayer(
                entries: [
                  PageTransitionEntry.move(
                    from: moving,
                    to: moving.copyWith(
                        position: moving.position + const Offset(100, 0)),
                  ),
                  PageTransitionEntry.appear(to: arriving),
                  PageTransitionEntry.disappear(from: leaving),
                ],
                agentPaths: const {},
                t: t,
                direction: PageTransitionDirection.forward,
                agentSize: 40,
                abilitySize: 40,
              ),
            ),
          ),
        ),
      ));
      return [
        for (final block in coverage.blockers.all)
          block.shape as CircleOccluder,
      ];
    }

    final early = await at(0.25);
    expect(early.map((smoke) => smoke.radius).toSet(),
        {radiusOf(moving), radiusOf(leaving)});
    expect(
      early.singleWhere((smoke) => smoke.radius == radiusOf(moving)).centre,
      _drawnMiddle(moving, 1) + const Offset(25, 0),
    );
    final late = await at(0.75);
    expect(late.map((smoke) => smoke.radius).toSet(),
        {radiusOf(moving), radiusOf(arriving)});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a High Tide moving between pages blocks along the wall drawn',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final container =
        ProviderContainer(overrides: [mapProvider.overrideWith(_Ascent.new)]);
    addTearDown(container.dispose);
    final from = _placed(AgentType.harbor, 1,
        wallPath: const [Offset(0, -40), Offset(20, -80)]);
    final to = from.copyWith(
      position: from.position + const Offset(60, 0),
      wallPath: const [Offset(40, -30), Offset(90, -30), Offset(120, 10)],
    );
    final coverage = ConeCoverage();
    addTearDown(coverage.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: ShadApp(
        home: Scaffold(
          body: ConeCoverageScope(
            coverage: coverage,
            child: TransitionEntriesLayer(
              entries: [PageTransitionEntry.move(from: from, to: to)],
              agentPaths: const {},
              t: 0.4,
              direction: PageTransitionDirection.forward,
              agentSize: 40,
              abilitySize: 40,
            ),
          ),
        ),
      ),
    ));
    final wall = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<WallPainter>()
        .single;
    final blocker = coverage.blockers.all.single.shape as LineOccluder;
    final coordinates = CoordinateSystem.instance;
    expect(blocker.points.length, wall.line.length);
    for (var i = 0; i < wall.line.length; i++) {
      expect(
        (coordinates.coordinateToScreen(blocker.points[i]) - wall.line[i])
            .distance,
        lessThan(1e-6),
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('a cone on the page', () {
    late SplitSvgHeightRuntime runtime;
    late SvgHeightMapTransform transform;
    final mapScale = Maps.mapScale[MapValue.split]!;
    const eye = Offset(200, 200);
    const range = 200.0;

    setUp(() {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      final model = SvgHeightVisibility.fromJson(_openFloor());
      runtime = SplitSvgHeightRuntime(model, model);
      transform = SvgHeightMapTransform.forMap(MapValue.split);
    });

    double reach() => range / transform.scale;

    Offset world(Offset source) =>
        transform.sideWorldFromSource(source, isAttack: true);

    PlacedAbility placedWithMiddleAt(PlacedAbility ability, Offset source) =>
        ability.copyWith(
          position: world(source) -
              CoordinateSystem.virtualToWorld(storedAbilityAnchor(
                ability: ability.data.abilityData!,
                mapScale: mapScale,
              )),
        );

    Future<(Uint8List, SvgHeightViewConePainter, double)> shotOf(
      WidgetTester tester,
    ) async {
      final shown = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<ShadowedConePainter>()
          .single;
      final size = Size(shown.cone.radius * 2, shown.cone.radius);
      final bytes = (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        shown.paint(Canvas(recorder), size);
        final picture = recorder.endRecording();
        final image =
            await picture.toImage(size.width.ceil(), size.height.ceil());
        final data =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
                .buffer
                .asUint8List();
        image.dispose();
        picture.dispose();
        return data;
      }))!;
      final pixelsPerSource =
          CoordinateSystem.instance.worldHeightToScreen(transform.scale);
      return (bytes, shown.cone, pixelsPerSource);
    }

    Future<(Uint8List, SvgHeightViewConePainter, double)> render(
      WidgetTester tester,
      List<PlacedAbility> abilities, {
      Offset from = eye,
      double rotation = 0,
    }) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SvgHeightViewCone(
          runtime: runtime,
          canonicalOrigin: world(from),
          rotation: rotation,
          range: range,
          angle: math.pi / 2,
          isAttack: true,
          blockers: _declared(abilities, mapScale: mapScale),
        ),
      ));
      return shotOf(tester);
    }

    bool blank((Uint8List, SvgHeightViewConePainter, double) shot) {
      final (bytes, _, _) = shot;
      for (var i = 3; i < bytes.length; i += 4) {
        if (bytes[i] != 0) return false;
      }
      return true;
    }

    bool lit(
      (Uint8List, SvgHeightViewConePainter, double) shot,
      double degreesFromAhead,
      double sourceDistance,
    ) {
      final (bytes, cone, pixelsPerSource) = shot;
      final width = (cone.radius * 2).ceil();
      final angle = degreesFromAhead * math.pi / 180;
      final at = cone.apex +
          Offset(math.sin(angle), -math.cos(angle)) *
              (sourceDistance * pixelsPerSource);
      return bytes[(at.dy.round() * width + at.dx.round()) * 4 + 3] > 0;
    }

    testWidgets('is lit up to a smoke in front of it and dark behind it',
        (tester) async {
      final ahead = reach() * 0.5;
      final smoke = placedWithMiddleAt(
          _placed(AgentType.omen, 2), eye - Offset(0, ahead));
      final radius =
          (occluderOf(smoke, mapScale: mapScale)! as CircleOccluder).radius /
              transform.scale;
      final shot = await render(tester, [smoke]);
      expect(lit(shot, 0, ahead - radius - 2), isTrue);
      expect(lit(shot, 0, ahead + radius + 2), isFalse);
      expect(lit(shot, 0, reach() * 0.95), isFalse);
      expect(lit(shot, 35, reach() * 0.9), isTrue,
          reason: 'past the edge of the smoke the cone still sees');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('is lit up to a wall across it and dark beyond it',
        (tester) async {
      final ahead = reach() * 0.5;
      final toxicScreen = _placed(AgentType.viper, 2, rotation: math.pi / 2);
      final length =
          (occluderOf(toxicScreen, mapScale: mapScale)! as LineOccluder)
                  .points
                  .last
                  .dx /
              transform.scale;
      expect(length, greaterThan(reach() * 2));
      final wall =
          placedWithMiddleAt(toxicScreen, eye + Offset(-reach(), -ahead));
      final shot = await render(tester, [wall]);
      for (final degrees in [-40.0, 0.0, 30.0]) {
        final crossing = ahead / math.cos(degrees * math.pi / 180);
        expect(lit(shot, degrees, crossing - 2), isTrue, reason: '$degrees');
        expect(lit(shot, degrees, crossing + 2), isFalse, reason: '$degrees');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('from inside a smoke shows nothing', (tester) async {
      final smoke = placedWithMiddleAt(_placed(AgentType.brimstone, 2), eye);
      expect(blank(await render(tester, [smoke])), isTrue);
      final clear = await render(tester, [
        placedWithMiddleAt(
            _placed(AgentType.brimstone, 2), eye + const Offset(0, 80)),
      ]);
      expect(lit(clear, 0, reach() * 0.5), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('from the rim of a smoke at the floor edge shows nothing',
        (tester) async {
      const onTheEdge = Offset(-100.4, 200);
      final standing = runtime.model(true).standablePointNear(onTheEdge)!;
      final smoke = _placed(AgentType.brimstone, 2);
      final radius =
          (occluderOf(smoke, mapScale: mapScale)! as CircleOccluder).radius /
              transform.scale;
      expect((standing - onTheEdge).distance, greaterThan(0.3),
          reason: 'the cone is cast from a point the smoke does not cover');
      final shot = await render(
        tester,
        [placedWithMiddleAt(smoke, onTheEdge - Offset(radius - 0.2, 0))],
        from: onTheEdge,
        rotation: math.pi / 2,
      );
      expect(blank(shot), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('carried with its smoke in a selection drag stays dark',
        (tester) async {
      final smoke = placedWithMiddleAt(_placed(AgentType.brimstone, 2), eye);
      final container = ProviderContainer(overrides: [
        mapProvider.overrideWith(_Split.new),
        svgHeightRuntimeProvider.overrideWith((ref, map) async => runtime),
      ]);
      addTearDown(container.dispose);

      Future<bool> coneShows(Set<String> carried) async {
        container
            .read(canvasGroupDragProvider.notifier)
            .set((ids: carried, by: const Offset(160, 0)));
        final shift = carried.contains(smoke.id)
            ? selectionDragInWorld(const Offset(160, 0), isAttack: true)
            : Offset.zero;
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SightBlockersScope(
              blockers: _declared(
                [smoke.copyWith(position: smoke.position + shift)],
                mapScale: mapScale,
              ),
              child: Stack(children: [
                EditorEntityLayer(
                  id: 'cone',
                  kind: SelectableKind.utility,
                  child: Positioned(
                    left: 0,
                    top: 0,
                    child: ViewConeWidget(
                      id: null,
                      angle: 60,
                      length: 100,
                      worldOrigin: world(eye),
                      showCenterMarker: false,
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ));
        await tester.pump();
        await tester.pump();
        return !blank(await shotOf(tester));
      }

      expect(await coneShows(const {}), isFalse);
      expect(await coneShows({smoke.id, 'cone'}), isFalse);
      expect(await coneShows({smoke.id}), isTrue,
          reason: 'the smoke alone is carried off the cone');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('with nothing near it is drawn as it always was',
        (tester) async {
      final far = placedWithMiddleAt(
          _placed(AgentType.omen, 2), eye + Offset(reach() * 3, 0));
      final shot = await render(tester, [far]);
      final (bytes, _, _) = shot;
      final (alone, _, _) = await render(tester, const []);
      expect(bytes, alone);
      expect(lit(shot, 0, reach() * 0.9), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the sightline report', () {
    final model = SvgHeightVisibility.fromJson(_openFloor());
    const eye = Offset(200, 200);
    const darkCover = SightBlock(
      name: 'Omen Dark Cover',
      shape: CircleOccluder(Offset(200, 150), 10),
    );

    SightlineReport reportOf(List<SightBlock> blockers) => buildSightlineReport(
          map: 'split',
          isAttack: true,
          appVersion: 'test',
          canonicalOrigin: Offset.zero,
          facingRadians: -math.pi / 2,
          apertureRadians: math.pi / 2,
          rangeSvg: 100,
          savedElevationCm: null,
          svgOrigin: eye,
          model: model,
          blockersSvg: blockers,
        );

    test('names the smoke and draws the cone dark behind it', () {
      final clear = reportOf(const []);
      final cut = reportOf(const [darkCover]);
      expect(clear.visibleArea!.contains(const Offset(200, 120)), isTrue);
      expect(cut.visibleArea!.contains(const Offset(200, 120)), isFalse);
      expect(cut.visibleArea!.contains(const Offset(200, 170)), isTrue);
      expect(cut.json['blockers'], [
        {
          'name': 'Omen Dark Cover',
          'kind': 'smoke',
          'centreSvg': [200.0, 150.0],
          'radiusSvg': 10.0,
        },
      ]);
      expect(clear.json.keys.toSet().difference(cut.json.keys.toSet()),
          isEmpty);
    });

    test('from inside a smoke draws no cone and says which smoke', () {
      final inside = reportOf(const [
        SightBlock(
          name: 'Brimstone Sky Smoke',
          shape: CircleOccluder(Offset(203, 200), 10),
        ),
      ]);
      expect(inside.json['insideSmoke'], 'Brimstone Sky Smoke');
      expect(inside.visibleArea, isNull);
      expect(inside.json['hits'], isNotEmpty);
    });
  });

  group('a strategy saved before smokes blocked cones', () {
    late List<StrategyPage> pages;

    setUpAll(() async {
      final archive = ZipDecoder().decodeBytes(await File(path.join(
        'test',
        'fixtures',
        'strategy_integrity',
        'canvas-compatibility-v97.ica',
      )).readAsBytes());
      final payload = jsonDecode(utf8.decode(archive.files
          .singleWhere((entry) => entry.name.endsWith('.json'))
          .content as List<int>)) as Map<String, dynamic>;
      pages = [
        for (final page in payload['pages'] as List)
          await StrategyPage.fromJson(
            json: Map<String, dynamic>.from(page as Map),
            strategyID: 'v97',
            strategyName: 'v97',
            isZip: true,
          ),
      ];
    });

    test('loads every smoke and wall it holds, as it was placed', () {
      final mapScale = Maps.mapScale[MapValue.ascent]!;
      final blockers = [
        for (final page in pages)
          for (final ability in page.abilityData)
            if (blocksSight(ability.data)) ability,
      ];
      final down = blockers
          .where((ability) => !ability.visualState.showRangeFill)
          .toList();
      expect(blockers.length - down.length, 14);
      expect(
          down.map((ability) => ability.data.type).toSet(), {AgentType.viper});
      for (final ability in blockers) {
        expect(
          occluderOf(ability, mapScale: mapScale) != null,
          !down.contains(ability) &&
              ability.data.abilityData is! GuidedWallAbility,
          reason: '${ability.data.name} on ${ability.id}',
        );
      }
    });

    testWidgets('draws cones on Ascent cut by its smokes', (tester) async {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      SvgHeightVisibility side(String name) =>
          SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(decodeWorldGzip(
            File('assets/maps/ascent_svg_height_$name.json.gz')
                .readAsBytesSync(),
          ))) as Map<String, dynamic>);
      final runtime = SplitSvgHeightRuntime.forMap(
          MapValue.ascent, side('attack'), side('defense'));
      final transform = SvgHeightMapTransform.forMap(MapValue.ascent);
      final mapScale = Maps.mapScale[MapValue.ascent]!;
      final model = runtime.model(true);
      final smokes = [
        for (final page in pages)
          for (final ability in page.abilityData)
            if (occluderOf(ability, mapScale: mapScale)
                case final CircleOccluder smoke)
              smoke,
      ];

      Future<bool?> litBehind(
        CircleOccluder smoke,
        Offset eye,
        List<VisionOccluder> occluders,
      ) async {
        final blockers = SightBlockers();
        for (final (index, shape) in occluders.indexed) {
          blockers.declare(
              index, SightBlock(name: 'smoke $index', shape: shape));
        }
        final smokeAt =
            transform.sourceFromSideWorld(smoke.centre, isAttack: true);
        final toSmoke = smokeAt - eye;
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: SvgHeightViewCone(
            runtime: runtime,
            canonicalOrigin: transform.sideWorldFromSource(eye, isAttack: true),
            rotation: math.atan2(toSmoke.dy, toSmoke.dx) + math.pi / 2,
            range: toSmoke.distance * transform.scale * 2,
            angle: math.pi / 3,
            isAttack: true,
            blockers: blockers,
          ),
        ));
        final shown = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((paint) => paint.painter)
            .whereType<ShadowedConePainter>()
            .singleOrNull;
        if (shown == null) return null;
        final width = (shown.cone.radius * 2).ceil();
        final height = shown.cone.radius.ceil();
        final bytes = (await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          shown.paint(
              Canvas(recorder), Size(shown.cone.radius * 2, shown.cone.radius));
          final picture = recorder.endRecording();
          final image = await picture.toImage(width, height);
          final data =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
                  .buffer
                  .asUint8List();
          image.dispose();
          picture.dispose();
          return data;
        }))!;
        final pixelsPerSource =
            CoordinateSystem.instance.worldHeightToScreen(transform.scale);
        final radius = smoke.radius / transform.scale;
        final behind = shown.cone.apex -
            Offset(0, (toSmoke.distance + radius + 2) * pixelsPerSource);
        return bytes[(behind.dy.round() * width + behind.dx.round()) * 4 + 3] >
            0;
      }

      var cut = 0;
      for (final smoke in smokes) {
        final smokeAt =
            transform.sourceFromSideWorld(smoke.centre, isAttack: true);
        for (var turn = 0; turn < 8; turn++) {
          final angle = turn * math.pi / 4;
          final eye = model.standablePointNear(smokeAt +
              Offset(math.cos(angle), math.sin(angle)) *
                  (smoke.radius / transform.scale) *
                  3);
          if (eye == null || await litBehind(smoke, eye, const []) != true) {
            continue;
          }
          expect(await litBehind(smoke, eye, [smoke]), isFalse,
              reason: 'from $eye past ${smoke.centre} on Ascent');
          cut++;
        }
      }
      expect(cut, greaterThan(0),
          reason: 'a spot beside one of its smokes that sees past it');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
