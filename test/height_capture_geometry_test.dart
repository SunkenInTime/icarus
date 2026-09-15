import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/height_runtime_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/screenshot/capture_geometry.dart';
import 'package:icarus/screenshot/persistent_offscreen_renderer.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/height_view_cone.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';

import 'height_runtime_test_support.dart';

const _size = Size(800, 450);

StrategyPage _conePage() => StrategyPage(
    id: 'page',
    name: 'Page',
    sortIndex: 0,
    isAttack: true,
    agentData: const [],
    abilityData: const [],
    utilityData: [
      PlacedUtility(
          id: 'cone', type: UtilityType.viewCone90, position: Offset.zero)
    ],
    drawingData: const [],
    textData: const [],
    imageData: const [],
    settings: StrategySettings());

SvgHeightRuntime _svgRuntime() {
  final model = SvgHeightVisibility.fromJson({
    'version': 1,
    'coordinateSpace': 'svg',
    'verticalSpace': 'meters-above-local-floor',
    'walls': [
      {
        'id': 'wall',
        'rings': [
          [80, 160, 82, 160, 82, 360, 80, 360]
        ],
        'fillRule': 'evenodd',
        'unknownHeight': false,
        'bands': [
          [0, null]
        ],
      }
    ],
    'supports': [],
    'receiver': [
      {
        'rings': [
          [-100, -100, 600, -100, 600, 600, -100, 600]
        ],
        'fillRule': 'evenodd',
      }
    ],
  });
  return SplitSvgHeightRuntime.forMap(MapValue.ascent, model, model);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.FragmentProgram program;
  setUpAll(() async {
    appProviderContainer = ProviderContainer();
    program =
        await ui.FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
  });
  tearDownAll(() => appProviderContainer.dispose());
  setUp(() => CoordinateSystem(playAreaSize: _size));

  ProviderContainer containerFor(TestHeightDependencies deps) =>
      ProviderContainer(overrides: [
        mapProvider.overrideWith(_Map.new),
        navigationGeometryProvider
            .overrideWith((ref, map) async => testHeightNavigation),
        heightRuntimeDependenciesProvider.overrideWithValue(deps),
      ]);

  test('low-level legacy height runtime stays pending until assets are ready',
      () async {
    final deps = TestHeightDependencies(program)
      ..releaseAssets = Completer<void>();
    final container = containerFor(deps);
    final subscription =
        container.listen(heightRuntimeProvider(MapValue.ascent), (_, __) {});
    var ready = false;
    final loading = container
        .read(heightRuntimeProvider(MapValue.ascent).future)
        .then((runtime) {
      ready = true;
      return runtime;
    });
    await deps.assetStarted.future;
    expect(ready, isFalse);
    deps.releaseAssets!.complete();
    final runtime = await loading;
    expect(runtime.worker, same(deps.worker));
    expect(deps.openCalls, 1);
    subscription.close();
    container.dispose();
    await closeHeightRuntimes();
    expect(deps.worker.closeCalls, 1);
  });

  test('PNG and raw video captures paint the mounted production SVG cone',
      () async {
    var legacyLoads = 0;
    final container = ProviderContainer(overrides: [
      mapProvider.overrideWith(_Map.new),
      worldGeometryEnabledProvider.overrideWith((ref, map) => true),
      svgHeightRuntimeProvider.overrideWith((ref, map) async => _svgRuntime()),
      viewConeGeometryProvider.overrideWith((ref, map) async {
        legacyLoads++;
        return null;
      }),
    ]);
    final lease =
        (await prepareCaptureGeometry(container, MapValue.ascent, [_conePage()])
            .timeout(const Duration(seconds: 5)))!;
    final renderer = PersistentOffscreenRenderer(
        targetSize: _size,
        waitForFrameData: lease.waitForFrame,
        wrapWidget: (child) => UncontrolledProviderScope(
            container: container,
            child: MediaQuery(
                data: const MediaQueryData(size: _size), child: child)));
    try {
      final frames = await (() async {
        final png = await renderer
            .capture(_svgFrame(rotation: 0))
            .timeout(const Duration(seconds: 5));
        final first = await _decode(png);
        final stable = await renderer.captureRawRgba(_svgFrame(rotation: 0));
        expect(stable, orderedEquals(first));
        final second = await renderer.captureRawRgba(_svgFrame(rotation: 1.2));
        final settled = await renderer.captureRawRgba(_svgFrame(rotation: 1.2));
        expect(second, orderedEquals(settled));
        return (first, second);
      })();
      expect(frames.$1.any((value) => value > 0), isTrue);
      expect(frames.$2, isNot(orderedEquals(frames.$1)));
      expect(legacyLoads, 0);
    } finally {
      await renderer.dispose(waitForFrame: () async {});
      lease.close();
      container.dispose();
    }
  });

  test('a low-level legacy cone query failure aborts pixel export', () async {
    final deps = TestHeightDependencies(program);
    final container = containerFor(deps);
    final subscription =
        container.listen(heightRuntimeProvider(MapValue.ascent), (_, __) {});
    final runtime = await container
        .read(heightRuntimeProvider(MapValue.ascent).future)
        .timeout(const Duration(seconds: 5));
    deps.worker.computeError = StateError('native query failed');
    final renderer = PersistentOffscreenRenderer(
        targetSize: _size,
        waitForFrameData: runtime.waitIdle,
        wrapWidget: (child) => UncontrolledProviderScope(
            container: container,
            child: MediaQuery(
                data: const MediaQueryData(size: _size), child: child)));
    try {
      await expectLater(
          renderer.capture(_legacyFrame(runtime)), throwsStateError);
      expect(deps.worker.computeCalls, 1);
    } finally {
      await renderer.dispose(waitForFrame: () async {});
      subscription.close();
      container.dispose();
      await closeHeightRuntimes();
    }
  });
}

Widget _legacyFrame(HeightRuntime runtime, {double rotation = 0}) =>
    SizedBox.fromSize(
        size: _size,
        child: Stack(children: [
          HeightViewCone(
              runtime: runtime,
              canonicalOrigin: const Offset(700, 500),
              rotation: rotation,
              range: 120,
              angle: math.pi / 2,
              isAttack: true,
              zoom: 1)
        ]));

Widget _svgFrame({double rotation = 0}) => SizedBox.fromSize(
    size: _size,
    child: ViewConeWidget(
        id: null,
        angle: 90,
        rotation: rotation,
        worldOrigin: const Offset(700, 500),
        length: 120,
        showCenterMarker: false));
Future<Uint8List> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  image.dispose();
  codec.dispose();
  return bytes;
}

class _Map extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}
