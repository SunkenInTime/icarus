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
import 'package:icarus/providers/page_occluders_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/view_cone/page_occluders.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/view_cone/vision_occluders.dart';
import 'package:icarus/view_cone/vision_world_gzip.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_wall.dart';
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
}

class _AscentDefense extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: false);
}

class _Split extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.split, isAttack: true);
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

  group('the page on screen', () {
    late ProviderContainer container;
    final smoke = _placed(AgentType.omen, 2);
    final stim =
        _placed(AgentType.brimstone, 0, position: const Offset(600, 300));

    setUp(() {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      container =
          ProviderContainer(overrides: [mapProvider.overrideWith(_Ascent.new)]);
      container.read(abilityProvider.notifier).fromHive([smoke, stim]);
    });
    tearDown(() => container.dispose());

    Offset centre() =>
        (container.read(pageOccludersProvider).single as CircleOccluder).centre;

    test('holds one occluder for the smoke and none for anything else', () {
      expect(centre(), _drawnMiddle(smoke, 1));
    });

    test('follows a smoke while it is dragged, and lets go after', () {
      container
          .read(heldAbilityProvider.notifier)
          .hold(smoke.copyWith(position: smoke.position + const Offset(30, 0)));
      expect(centre(), _drawnMiddle(smoke, 1) + const Offset(30, 0));
      container.read(heldAbilityProvider.notifier).letGo(smoke.id);
      expect(centre(), _drawnMiddle(smoke, 1));
    });

    for (final isAttack in [true, false]) {
      test('follows a selection dragged together, attack=$isAttack', () {
        final side = ProviderContainer(overrides: [
          mapProvider.overrideWith(isAttack ? _Ascent.new : _AscentDefense.new),
        ]);
        addTearDown(side.dispose);
        side.read(abilityProvider.notifier).fromHive([smoke]);
        side
            .read(canvasGroupDragProvider.notifier)
            .set((ids: {smoke.id}, by: const Offset(20, 10)));
        final onScreen =
            CoordinateSystem.instance.screenToCoordinate(const Offset(20, 10));
        final moved = isAttack ? onScreen : -onScreen;
        final circle =
            side.read(pageOccludersProvider).single as CircleOccluder;
        expect((circle.centre - (_drawnMiddle(smoke, 1) + moved)).distance,
            lessThan(1e-9));
      });
    }

    test('follows a High Tide wall while a dot is dragged', () {
      final tide =
          _placed(AgentType.harbor, 1, wallPath: const [Offset(0, -40)]);
      container.read(abilityProvider.notifier).fromHive([tide]);
      container
          .read(wallDraftProvider.notifier)
          .set((id: tide.id, path: const [Offset(50, 0)]));
      final line = container.read(pageOccludersProvider).single as LineOccluder;
      expect(line.points.last, _drawnMiddle(tide, 1) + const Offset(50, 0));
    });

    test('tells cones nothing when what moves blocks nothing', () {
      var heard = 0;
      container.listen(pageOccludersProvider, (_, __) => heard++);
      container
          .read(heldAbilityProvider.notifier)
          .hold(stim.copyWith(position: stim.position + const Offset(30, 0)));
      container.read(heldAbilityProvider.notifier).letGo(stim.id);
      expect(heard, 0);
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

    Future<List<CircleOccluder>> at(double t) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Scaffold(
            body: TransitionEntriesLayer(
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
      ));
      return tester
          .widget<PageOccludersScope>(find.byType(PageOccludersScope))
          .occluders
          .cast<CircleOccluder>();
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
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: ShadApp(
        home: Scaffold(
          body: TransitionEntriesLayer(
            entries: [PageTransitionEntry.move(from: from, to: to)],
            agentPaths: const {},
            t: 0.4,
            direction: PageTransitionDirection.forward,
            agentSize: 40,
            abilitySize: 40,
          ),
        ),
      ),
    ));
    final wall = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<WallPainter>()
        .single;
    final blocker = tester
        .widget<PageOccludersScope>(find.byType(PageOccludersScope))
        .occluders
        .single as LineOccluder;
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

    Future<(Uint8List, SvgHeightViewConePainter, double)?> render(
      WidgetTester tester,
      List<PlacedAbility> abilities,
    ) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SvgHeightViewCone(
          runtime: runtime,
          canonicalOrigin: world(eye),
          rotation: 0,
          range: range,
          angle: math.pi / 2,
          isAttack: true,
          occluders: pageOccluders(abilities, mapScale: mapScale),
        ),
      ));
      final shown = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<ShadowedConePainter>()
          .singleOrNull;
      if (shown == null) return null;
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
      final shot = (await render(tester, [smoke]))!;
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
      final shot = (await render(tester, [wall]))!;
      for (final degrees in [-40.0, 0.0, 30.0]) {
        final crossing = ahead / math.cos(degrees * math.pi / 180);
        expect(lit(shot, degrees, crossing - 2), isTrue, reason: '$degrees');
        expect(lit(shot, degrees, crossing + 2), isFalse, reason: '$degrees');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('from inside a smoke shows nothing', (tester) async {
      final smoke = placedWithMiddleAt(_placed(AgentType.brimstone, 2), eye);
      expect(await render(tester, [smoke]), isNull);
      final clear = await render(tester, [
        placedWithMiddleAt(
            _placed(AgentType.brimstone, 2), eye + const Offset(0, 80)),
      ]);
      expect(clear, isNotNull);
      expect(lit(clear!, 0, reach() * 0.5), isTrue);
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
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SvgHeightViewCone(
          runtime: runtime,
          canonicalOrigin: world(onTheEdge),
          rotation: math.pi / 2,
          range: range,
          angle: math.pi / 2,
          isAttack: true,
          occluders: pageOccluders([
            placedWithMiddleAt(smoke, onTheEdge - Offset(radius - 0.2, 0)),
          ], mapScale: mapScale),
        ),
      ));
      expect(
        tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((paint) => paint.painter)
            .whereType<ShadowedConePainter>(),
        isEmpty,
      );
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
      container.read(abilityProvider.notifier).fromHive([smoke]);

      Future<bool> coneShows(Set<String> carried) async {
        container
            .read(canvasGroupDragProvider.notifier)
            .set((ids: carried, by: const Offset(160, 0)));
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
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
        ));
        await tester.pump();
        await tester.pump();
        return tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((paint) => paint.painter)
            .whereType<ShadowedConePainter>()
            .isNotEmpty;
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
      final shot = (await render(tester, [far]))!;
      final shown = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<ShadowedConePainter>()
          .single;
      expect(shown.shadows, isNull);
      expect(lit(shot, 0, reach() * 0.9), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
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
            occluders: occluders,
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
