import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_view_cone_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _HavenMap extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.haven, isAttack: false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SvgHeightRuntime runtime;
  setUpAll(() {
    appProviderContainer = ProviderContainer();
    SvgHeightVisibility load(String side) {
      final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(
          gzip.decode(File('assets/maps/haven_svg_height_$side.json.gz')
              .readAsBytesSync()))));
      final library = Platform.environment['ICARUS_SVG_NATIVE_LIBRARY'];
      if (library != null) {
        expect(model.enableNativeAcceleration(libraryPath: library), isTrue);
      }
      return model;
    }

    runtime = SvgHeightRuntime.forMap(
        MapValue.haven, load('attack'), load('defense'));
  });
  tearDownAll(() {
    runtime.dispose();
    appProviderContainer.dispose();
  });

  for (final attack in [false, true]) {
    testWidgets(
        'Haven cone stays on its walls when markers resize, side=$attack',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final coordinates =
          CoordinateSystem(playAreaSize: const Size(1920, 1080));
      final container = ProviderContainer(overrides: [
        mapProvider.overrideWith(_HavenMap.new),
        svgHeightRuntimeProvider.overrideWith((ref, map) async => runtime),
      ]);
      addTearDown(container.dispose);
      container.read(mapProvider.notifier).fromHive(MapValue.haven, attack);

      // The reported pose, expressed at the historical marker size. Resizing
      // changes presentation only, so every size must paint the same sightline.
      const canonicalCenter = Offset(885.124, 437.01);
      final agent = PlacedViewConeAgent(
        id: 'haven-resized-cone',
        type: AgentType.neon,
        presetType: UtilityType.viewCone90,
        position: canonicalCenter -
            coordinates.virtualOffsetToWorld(
                const Offset(Settings.agentSize / 2, Settings.agentSize / 2)),
        rotation: -1.505 - math.pi / 2,
        length: 162.584 *
            SvgHeightMapTransform.forMap(MapValue.haven).scale /
            coordinates.virtualLengthToWorld(1),
      );
      container.read(agentProvider.notifier).fromHive([agent]);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: ShadApp(
            home: Scaffold(
                body: Stack(children: [
          PlacedViewConeAgentWidget(agent: agent, onDragEnd: (_, __) {}),
        ]))),
      ));
      await tester.pump();
      await tester.pump();

      Offset display(Offset canonical) =>
          coordinates.coordinateToScreen(coordinates.positionForSide(
              canonicalPosition: canonical,
              reflectionOffset: Offset.zero,
              isAttack: attack));

      void expectAligned() {
        final origin = tester
            .widget<ViewConeWidget>(find.byType(ViewConeWidget))
            .worldOrigin!;
        final center = tester.getCenter(find.byType(AgentWidget));
        expect((display(origin) - center).distance, lessThan(1e-7),
            reason: 'Raycasting must start at the rendered marker center.');
      }

      Uint8List? baseline;
      for (final size in [35.0, 15.0, 25.0, 45.0, 35.0]) {
        container.read(strategySettingsProvider.notifier).updateAgentSize(size);
        await tester.pump();
        expectAligned();
        final finder = find.byWidgetPredicate((widget) =>
            widget is CustomPaint &&
            widget.painter is SvgHeightViewConePainter);
        final box = tester.renderObject<RenderBox>(finder);
        final painter = tester.widget<CustomPaint>(finder).painter!;
        final pixels = (await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          final center = display(canonicalCenter);
          canvas.translate(160 - center.dx, 160 - center.dy);
          canvas.transform(box.getTransformTo(null).storage);
          painter.paint(canvas, box.size);
          final picture = recorder.endRecording();
          final image = await picture.toImage(320, 320);
          final bytes =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
                  .buffer
                  .asUint8List();
          image.dispose();
          picture.dispose();
          return bytes;
        }))!;
        if (baseline == null) {
          baseline = pixels;
          expect([
            for (var i = 3; i < pixels.length; i += 4) pixels[i]
          ], contains(greaterThan(0)), reason: 'The cone must actually paint.');
        } else {
          expect(pixels, orderedEquals(baseline),
              reason:
                  'Marker size $size must not move wall contacts or shadows.');
        }
      }

      for (final size in [15.0, 45.0]) {
        container.read(strategySettingsProvider.notifier).updateAgentSize(size);
        await tester.pump();
        final gesture = await tester
            .startGesture(tester.getCenter(find.byType(AgentWidget)));
        await gesture.moveBy(const Offset(12, 6));
        await tester.pump();
        expectAligned();
        await gesture.moveBy(const Offset(5, -3));
        await tester.pump();
        expectAligned();
        expect(container.read(agentProvider).single.position, agent.position,
            reason: 'Previewing a drag must not save a position.');
        await gesture.up();
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
