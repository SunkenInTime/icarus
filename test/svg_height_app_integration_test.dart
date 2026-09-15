import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/view_cone/vision_world_gzip.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_elevation_menu.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

Map<String, dynamic> _fixture({List<Map<String, dynamic>> walls = const []}) =>
    {
      'version': 1,
      'coordinateSpace': 'svg',
      'verticalSpace': 'meters-above-local-floor',
      'walls': walls,
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

class _SplitMap extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.split, isAttack: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  tearDownAll(() => appProviderContainer.dispose());

  test('bundled Split geometry hits the exact painted vent edge', () {
    final json = jsonDecode(
      utf8.decode(
        decodeWorldGzip(
          Uint8List.fromList(
            File('assets/maps/split_svg_height_attack.json.gz')
                .readAsBytesSync(),
          ),
        ),
      ),
    ) as Map<String, dynamic>;
    final model = SvgHeightVisibility.fromJson(json);
    final hit = model.castRay(
      origin: const Offset(259.8, 202),
      directionRadians: -math.pi / 2,
      range: 100,
    );
    expect(hit, isNotNull);
    expect(hit!.point.dx, closeTo(259.8, 1e-10));
    expect(hit.point.dy, closeTo(196.596, 1e-10));
    expect(hit.distance, closeTo(5.404, 1e-10));
  });

  test('production provider validates both bundled sides and receivers',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final subscription =
        container.listen(svgHeightRuntimeProvider(MapValue.split), (_, __) {});
    addTearDown(subscription.close);
    final runtime =
        await container.read(svgHeightRuntimeProvider(MapValue.split).future);
    expect(runtime, isNotNull);
    expect(runtime!.attack.receivers, hasLength(1));
    expect(runtime.defense.receivers, hasLength(1));
    expect(runtime.attack.ground, isNotNull);
    expect(runtime.defense.ground, isNotNull);
    expect(runtime.attack.supports.length, greaterThanOrEqualTo(16));
    expect(runtime.defense.supports.length, runtime.attack.supports.length);
    expect(
        runtime.attack.supports
            .any((support) => support.automaticStandingAllowed),
        isTrue);
    expect(
      runtime.attack.supports,
      everyElement(
        predicate<SvgHeightSupport>(
          (support) =>
              support.label != null &&
              support.floorElevationMeters != null &&
              support.surfaceElevationMeters != null,
        ),
      ),
    );
    expect(runtime.attack.runtimeEdgeCount, greaterThan(0));
    expect(runtime.defense.runtimeEdgeCount, greaterThan(0));
  });

  test('production provider loads measured Icebox ground on both sides',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final subscription =
        container.listen(svgHeightRuntimeProvider(MapValue.icebox), (_, __) {});
    addTearDown(subscription.close);
    final runtime =
        await container.read(svgHeightRuntimeProvider(MapValue.icebox).future);
    expect(runtime, isNotNull);
    for (final model in [runtime!.attack, runtime.defense]) {
      expect(model.requiresPhysicalGround, isTrue);
      expect(model.ground, isNotNull);
      expect(model.receivers, isNotEmpty);
    }
  });

  test('only reviewed asset pairs enter the SVG-height runtime', () async {
    expect(hasSvgHeightRuntime(MapValue.split), isTrue);
    for (final entry in svgHeightMapRegistrations.entries) {
      final registration = entry.value;
      expect(registration.map, entry.key);
      expect(hasSvgHeightRuntime(entry.key), isTrue);
      expect(File(registration.attackModelAsset).existsSync(), isTrue);
      expect(File(registration.defenseModelAsset).existsSync(), isTrue);
      expect(File(registration.attackArtworkAsset).existsSync(), isTrue);
      expect(File(registration.defenseArtworkAsset).existsSync(), isTrue);
      expect(registration.viewBox, Maps.mapViewBox[registration.map]);
    }

    MapValue? unregistered;
    for (final map in MapValue.values) {
      if (!hasSvgHeightRuntime(map)) {
        unregistered = map;
        break;
      }
    }
    if (unregistered != null) {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        await container.read(svgHeightRuntimeProvider(unregistered).future),
        isNull,
      );
    }
  });

  test('map transforms use each canonical SVG registration', () {
    for (final map in MapValue.values) {
      final transform = SvgHeightMapTransform.forMap(map);
      expect(transform.viewBox, Maps.mapViewBox[map]);
      const source = Offset(123.25, 234.75);
      for (final attack in [true, false]) {
        final world = transform.sideWorldFromSource(source, isAttack: attack);
        final restored = transform.sourceFromSideWorld(world, isAttack: attack);
        expect(restored.dx, closeTo(source.dx, 1e-10), reason: map.name);
        expect(restored.dy, closeTo(source.dy, 1e-10), reason: map.name);
      }
    }
  });

  test('defense projection includes the literal artwork translation', () {
    const raw = Offset(406.1335, 307.7385);
    final displayed =
        SplitSvgMapTransform.sideWorldFromSource(raw, isAttack: false);
    expect(
      displayed.dx,
      closeTo(
          SplitSvgMapTransform.offset.dx +
              (raw.dx + .8238) * SplitSvgMapTransform.scale,
          1e-10),
    );
    final restored =
        SplitSvgMapTransform.sourceFromSideWorld(displayed, isAttack: false);
    expect(restored.dx, closeTo(raw.dx, 1e-10));
    expect(restored.dy, closeTo(raw.dy, 1e-10));
  });

  test('elevation menu keeps stacked support choices explicit', () {
    final json = _fixture();
    json['supports'] = [
      {
        'id': 'lower',
        'label': 'Lower box',
        'rings': [
          [0, 0, 10, 0, 10, 10, 0, 10]
        ],
        'heightAboveFloorMeters': 2,
        'floorElevationMeters': 3,
        'surfaceElevationMeters': 5,
        'automaticStandingAllowed': true,
      },
      {
        'id': 'upper',
        'label': 'Upper box',
        'rings': [
          [0, 0, 10, 0, 10, 10, 0, 10]
        ],
        'heightAboveFloorMeters': 4,
        'floorElevationMeters': 3,
        'surfaceElevationMeters': 7,
        'automaticStandingAllowed': true,
      },
    ];
    final model = SvgHeightVisibility.fromJson(json);
    double? changed;
    final item = buildSvgHeightElevationMenuItem(
      model: model,
      origin: const Offset(5, 5),
      selectedElevationCm: 999,
      onChanged: (value) => changed = value,
    );
    expect((item.trailing! as Text).data, 'Upper box (auto*)');
    expect(item.items, hasLength(3));
    final choices = item.items.cast<ShadContextMenuItem>();
    expect((choices[0].child as Text).data,
        'Automatic (saved height unavailable)');
    expect((choices[1].child as Text).data, 'Lower box (+6.75 m)');
    expect((choices[2].child as Text).data, 'Upper box (+8.75 m)');
    choices[2].onPressed!();
    expect(changed, 875);
  });

  testWidgets(
      'mounted cone defaults to the playable top and honors saved ground',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final json = _fixture(walls: [
      {
        'id': 'box-side',
        'rings': [
          [150, 194, 250, 194, 250, 195, 150, 195]
        ],
        'bands': [
          [0, 4]
        ],
        'unknownHeight': false,
        'floorElevationMeters': 0,
      }
    ]);
    json.addAll({
      'version': 2,
      'verticalSpace': 'meters-source-elevation',
      'ground': {
        'vertices': [0, 0, 1, 600, 0, 1, 600, 600, 1, 0, 600, 1],
        'triangles': [0, 1, 2, 0, 2, 3]
      },
      'supports': [
        {
          'id': 'playable-top',
          'label': 'Box top',
          'rings': [
            [190, 196, 210, 196, 210, 210, 190, 210]
          ],
          'heightAboveFloorMeters': 3,
          'floorElevationMeters': 1,
          'surfaceElevationMeters': 4,
          'automaticStandingAllowed': true,
        }
      ],
    });
    final model = SvgHeightVisibility.fromJson(json);
    final runtime = SplitSvgHeightRuntime(model, model);
    final origin = SplitSvgMapTransform.sideWorldFromSource(
        const Offset(200, 200),
        isAttack: true);
    Future<Uint8List> render(double? elevation) async {
      await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
              width: 400,
              height: 300,
              child: SvgHeightViewCone(
                runtime: runtime,
                canonicalOrigin: origin,
                rotation: 0,
                range: 100,
                angle: math.pi / 2,
                isAttack: true,
                elevation: elevation,
              ))));
      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<SvgHeightViewConePainter>()
          .single;
      return (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), const Size(400, 300));
        final picture = recorder.endRecording();
        final image = await picture.toImage(400, 300);
        final bytes =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
                .buffer
                .asUint8List();
        image.dispose();
        picture.dispose();
        return bytes;
      }))!;
    }

    final automatic = await render(null);
    expect(await render(575), orderedEquals(automatic));
    final lower = await render(275);
    int alphaSum(Uint8List bytes) => [
          for (var i = 3; i < bytes.length; i += 4) bytes[i]
        ].fold(0, (sum, alpha) => sum + alpha);
    expect(alphaSum(automatic), greaterThan(alphaSum(lower)));
    expect(await render(null), orderedEquals(automatic));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mounted anonymous cones own separate cache entries',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final model = SvgHeightVisibility.fromJson(_fixture());
    final runtime = SplitSvgHeightRuntime(model, model);
    final origin = SplitSvgMapTransform.sideWorldFromSource(
        const Offset(200, 200),
        isAttack: true);

    Widget cone(String key) => SizedBox(
          width: 300,
          height: 300,
          child: SvgHeightViewCone(
            key: ValueKey(key),
            runtime: runtime,
            canonicalOrigin: origin,
            rotation: 0,
            range: 100,
            angle: math.pi / 2,
            isAttack: true,
          ),
        );
    Widget harness(List<Widget> children) => Directionality(
        textDirection: TextDirection.ltr, child: Row(children: children));
    await tester.pumpWidget(harness([cone('one'), cone('two')]));
    expect(runtime.attackCache.observerCount, 2);
    await tester.pumpWidget(harness([cone('two')]));
    expect(runtime.attackCache.observerCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(runtime.attackCache.observerCount, 0);
  });

  testWidgets('Split stays hidden while semantic data loads and skips 3D',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final completion = Completer<SplitSvgHeightRuntime?>();
    var oldGeometryLoads = 0;
    final container = ProviderContainer(overrides: [
      mapProvider.overrideWith(_SplitMap.new),
      worldGeometryEnabledProvider.overrideWith((ref, map) => true),
      svgHeightRuntimeProvider.overrideWith((ref, map) => completion.future),
      viewConeGeometryProvider.overrideWith((ref, map) async {
        oldGeometryLoads++;
        return null;
      }),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const ShadApp(
        home: Scaffold(
          body: ViewConeWidget(
            id: null,
            angle: 90,
            length: 60,
            worldOrigin: Offset(700, 500),
          ),
        ),
      ),
    ));
    final loadingPainter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<ViewConePainter>()
        .single;
    expect(loadingPainter.visibilityPolygon, hasLength(1));
    expect(oldGeometryLoads, 0);

    final model = SvgHeightVisibility.fromJson(_fixture());
    completion.complete(SplitSvgHeightRuntime(model, model));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SvgHeightViewCone), findsOneWidget);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is CustomPaint &&
            widget.painter is SvgHeightViewConePainter),
        findsOneWidget);
    expect(oldGeometryLoads, 0);
  });

  testWidgets(
      'unchanged cones reuse painting while pose and scale invalidate it',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    final model = SvgHeightVisibility.fromJson(_fixture());
    final runtime = SplitSvgHeightRuntime(model, model);
    final origin = SplitSvgMapTransform.sideWorldFromSource(
        const Offset(200, 200),
        isAttack: true);
    Future<SvgHeightViewConePainter> paint(
        {double rotation = 0, bool attack = true}) async {
      await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
              width: 300,
              height: 300,
              child: SvgHeightViewCone(
                  runtime: runtime,
                  canonicalOrigin: origin,
                  rotation: rotation,
                  range: 100,
                  angle: math.pi / 2,
                  isAttack: attack))));
      return tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<SvgHeightViewConePainter>()
          .single;
    }

    final first = await paint();
    expect(identical(await paint(), first), true);
    final rotated = await paint(rotation: .1);
    expect(identical(rotated, first), false);
    CoordinateSystem(playAreaSize: const Size(1280, 720));
    final resized = await paint(rotation: .1);
    expect(identical(resized, rotated), false);
    expect(identical(await paint(rotation: .1), resized), true);
    final defense = await paint(rotation: .1, attack: false);
    expect(identical(defense, resized), false);
    expect(runtime.attackCache.observerCount, 0);
    expect(runtime.defenseCache.observerCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('receiver is the final paint clip, including its holes', () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const painter = SvgHeightViewConePainter(
      visibilityPolygon: [
        Offset(0, 0),
        Offset(100, 0),
        Offset(100, 100),
        Offset(0, 100),
      ],
      receiverRings: [
        [Offset(0, 0), Offset(60, 0), Offset(60, 100), Offset(0, 100)],
        [Offset(20, 20), Offset(40, 20), Offset(40, 40), Offset(20, 40)],
      ],
      receiverEvenOdd: true,
      apex: Offset(50, 50),
      radius: 100,
    );
    painter.paint(canvas, const Size(100, 100));
    final image = await recorder.endRecording().toImage(100, 100);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int alpha(int x, int y) => bytes.getUint8((y * 100 + x) * 4 + 3);
    expect(alpha(10, 50), greaterThan(0));
    expect(alpha(30, 30), 0, reason: 'authored receiver hole');
    expect(alpha(80, 50), 0, reason: 'outside SVG receiver');
    image.dispose();
  });

  testWidgets(
      'cached native path transforms match the original point projection',
      (tester) async {
    final coordinates = CoordinateSystem(playAreaSize: const Size(1280, 720));
    final model = SvgHeightVisibility.fromJson(_fixture(walls: [
      {
        'id': 'wall',
        'rings': [
          [180, 170, 181, 170, 181, 230, 180, 230]
        ],
        'fillRule': 'evenodd',
        'unknownHeight': false,
        'bands': [
          [0, null]
        ],
      }
    ]));
    final runtime = SplitSvgHeightRuntime(model, model);
    final canonical = SplitSvgMapTransform.sideWorldFromSource(
        const Offset(200, 200),
        isAttack: true);
    Future<Uint8List> pixels(
        SvgHeightViewConePainter painter, Size size) async {
      return (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        painter.paint(Canvas(recorder), size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(400, 300);
        final bytes =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
                .buffer
                .asUint8List();
        image.dispose();
        picture.dispose();
        return bytes;
      }))!;
    }

    for (final attack in [true, false])
      for (final rotation in [0.0, .73, 2.1]) {
        await tester.pumpWidget(Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
                width: 400,
                height: 300,
                child: SvgHeightViewCone(
                    runtime: runtime,
                    canonicalOrigin: canonical,
                    rotation: rotation,
                    range: 150,
                    angle: math.pi / 2,
                    isAttack: attack))));
        final actual = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((p) => p.painter)
            .whereType<SvgHeightViewConePainter>()
            .single;
        final origin = coordinates.positionForSide(
            canonicalPosition: canonical,
            reflectionOffset: Offset.zero,
            isAttack: attack);
        final source =
            SplitSvgMapTransform.sourceFromSideWorld(origin, isAttack: attack);
        final cone = model.cone(
            origin: source,
            directionRadians: rotation - math.pi / 2,
            range: 150 / SplitSvgMapTransform.scale,
            apertureRadians: math.pi / 2);
        final radius = coordinates.worldHeightToScreen(150);
        final apex = Offset(radius, radius);
        final size = Size(radius * 2, radius);
        Offset project(Offset p) {
          final delta =
              SplitSvgMapTransform.sideWorldFromSource(p, isAttack: attack) -
                  origin;
          final c = math.cos(-rotation), s = math.sin(-rotation);
          return apex +
              coordinates.worldOffsetToScreen(Offset(
                  delta.dx * c - delta.dy * s, delta.dx * s + delta.dy * c));
        }

        final expected = SvgHeightViewConePainter(
            visibilityPolygon: cone.polygon.map(project).toList(),
            receiverRings: [
              for (final ring in model.receivers.single.rings)
                ring.map(project).toList()
            ],
            receiverEvenOdd: true,
            apex: apex,
            radius: radius);
        final a = await pixels(actual, size), b = await pixels(expected, size);
        var maximum = 0;
        var alphaMaximum = 0, changedPixels = 0;
        for (var i = 0; i < a.length; i++)
          maximum = math.max(maximum, (a[i] - b[i]).abs());
        for (var i = 3; i < a.length; i += 4) {
          alphaMaximum = math.max(alphaMaximum, (a[i] - b[i]).abs());
          if (a[i] != b[i]) changedPixels++;
        }
        // ignore: avoid_print
        print(
            'paint comparison: max=$maximum alpha=$alphaMaximum pixels=$changedPixels');
        expect(maximum, lessThanOrEqualTo(2),
            reason: 'side=$attack rotation=$rotation');
      }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
