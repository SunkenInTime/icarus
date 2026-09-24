import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/screenshot/capture_geometry.dart';
import 'package:icarus/screenshot/offscreen_capture.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';

StrategyPage _page(
        {List<PlacedAgentNode> agents = const [],
        List<PlacedAbility> abilities = const [],
        List<PlacedUtility> utilities = const []}) =>
    StrategyPage(
      id: 'page',
      name: 'Page',
      sortIndex: 0,
      isAttack: true,
      agentData: agents,
      abilityData: abilities,
      utilityData: utilities,
      drawingData: const [],
      textData: const [],
      imageData: const [],
      settings: StrategySettings(),
    );

StrategyPage _conePage() => _page(utilities: [
      PlacedUtility(
        id: 'cone',
        type: UtilityType.viewCone90,
        position: Offset.zero,
      )
    ]);

SvgHeightRuntime _runtime(MapValue map) {
  final model = SvgHeightVisibility.fromJson({
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
  });
  return SplitSvgHeightRuntime.forMap(map, model, model);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final video in [false, true]) {
    test(
        '${video ? 'Video with a cone on a later page' : 'PNG'} waits for a cold SVG runtime and retains it',
        () async {
      CoordinateSystem(playAreaSize: const Size(1600, 900));
      final completion = Completer<SvgHeightRuntime?>();
      var disposed = false;
      var legacyLoads = 0;
      final container = ProviderContainer(overrides: [
        worldGeometryEnabledProvider.overrideWith((ref, map) => true),
        svgHeightRuntimeProvider.overrideWith((ref, map) {
          ref.onDispose(() => disposed = true);
          return completion.future;
        }),
        viewConeGeometryProvider.overrideWith((ref, map) {
          legacyLoads++;
          return Future.value(null);
        }),
      ]);
      addTearDown(container.dispose);
      var ready = false;
      final preparation = prepareCaptureGeometry(
              container, MapValue.ascent, [if (video) _page(), _conePage()])
          .then((lease) {
        ready = true;
        return lease;
      });
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      expect(CoordinateSystem.instance.effectiveSize, const Size(1600, 900));
      expect(
          CoordinateSystem.instance.screenToCoordinate(const Offset(800, 450)),
          Offset(CoordinateSystem.instance.worldNormalizedWidth / 2, 500),
          reason:
              'A live drag keeps its canvas coordinates during cold loading.');
      expect(legacyLoads, 0);
      completion.complete(_runtime(MapValue.ascent));
      final lease = await preparation;
      expect(ready, isTrue);
      await container.pump();
      expect(disposed, isFalse,
          reason: 'No mounted cone exists between video pages.');
      expect(
          container
              .read(svgHeightRuntimeProvider(MapValue.ascent))
              .requireValue,
          isNotNull);
      expect(legacyLoads, 0);
      lease!.close();
      await container.pump();
      expect(disposed, isTrue);
    });
  }

  for (final fails in [false, true]) {
    test(
        'pixel capture restores live coordinates before output selection${fails ? ' even on failure' : ''}',
        () async {
      CoordinateSystem(playAreaSize: const Size(1600, 900));
      final capture = withScreenshotCoordinates(() async {
        expect(CoordinateSystem.instance.effectiveSize,
            CoordinateSystem.screenShotSize);
        if (fails) throw StateError('capture failed');
        return 'pixels';
      });
      if (fails) {
        await expectLater(capture, throwsStateError);
      } else {
        expect(await capture, 'pixels');
      }
      expect(CoordinateSystem.instance.effectiveSize, const Size(1600, 900));
      expect(
          CoordinateSystem.instance.screenToCoordinate(const Offset(800, 450)),
          Offset(CoordinateSystem.instance.worldNormalizedWidth / 2, 500));
    });
  }

  for (final missing in [false, true]) {
    test(
        'capture aborts for a ${missing ? 'missing' : 'failed'} SVG runtime and releases the provider',
        () async {
      var disposed = false;
      var legacyLoads = 0;
      final container = ProviderContainer(overrides: [
        worldGeometryEnabledProvider.overrideWith((ref, map) => true),
        svgHeightRuntimeProvider.overrideWith((ref, map) async {
          ref.onDispose(() => disposed = true);
          if (missing) return null;
          throw const FormatException('bad asset');
        }),
        viewConeGeometryProvider.overrideWith((ref, map) async {
          legacyLoads++;
          return null;
        }),
      ]);
      addTearDown(container.dispose);
      await expectLater(
          prepareCaptureGeometry(container, MapValue.ascent, [_conePage()]),
          throwsA(missing ? isA<StateError>() : isA<FormatException>()));
      expect(legacyLoads, 0);
      await container.pump();
      expect(disposed, isTrue);
    });
  }

  test('pages without sightlines do not request geometry', () async {
    var svgRequested = false, legacyRequested = false;
    final container = ProviderContainer(overrides: [
      svgHeightRuntimeProvider.overrideWith((ref, map) async {
        svgRequested = true;
        throw StateError('must not load');
      }),
      viewConeGeometryProvider.overrideWith((ref, map) async {
        legacyRequested = true;
        throw StateError('must not load');
      }),
    ]);
    addTearDown(container.dispose);
    expect(await prepareCaptureGeometry(container, MapValue.ascent, [_page()]),
        isNull);
    expect(svgRequested, isFalse);
    expect(legacyRequested, isFalse);
  });

  test('all cone owners are detected, while a hidden ability cone is ignored',
      () {
    final turret = PlacedAbility(
        id: 'turret',
        position: Offset.zero,
        data: AgentData.agents[AgentType.killjoy]!.abilities[2]);
    expect(pageNeedsCaptureGeometry(_page(abilities: [turret])), isTrue);
    expect(
        pageNeedsCaptureGeometry(_page(abilities: [
          turret.copyWith(
              visualState: const AbilityVisualState(showVisionCone: false))
        ])),
        isFalse);
    expect(
        pageNeedsCaptureGeometry(_page(agents: [
          PlacedViewConeAgent(
            id: 'agent',
            type: AgentType.sova,
            position: Offset.zero,
            presetType: UtilityType.viewCone90,
          )
        ])),
        isTrue);
    expect(pageNeedsCaptureGeometry(_conePage()), isTrue);
  });
}
