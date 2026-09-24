// Frame cost of dragging a view-cone agent across a registered SVG-height map.
//
// flutter drive --driver=test_driver/performance_test.dart \
//   --target=integration_test/view_cone_drag_performance_test.dart --profile -d windows
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _viewportSize = Size(1200, 675);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dragging a view cone agent on Haven', (tester) async {
    tester.view
      ..physicalSize = _viewportSize
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final coordinateSystem = CoordinateSystem(playAreaSize: _viewportSize);
    final container = ProviderContainer(
      overrides: [mapProvider.overrideWith(_BenchmarkMapProvider.new)],
    );
    addTearDown(container.dispose);
    // The runtime provider auto-disposes; hold a listener for the whole test.
    final keepAlive = container.listen(
        svgHeightRuntimeProvider(MapValue.haven), (_, __) {});
    addTearDown(keepAlive.close);
    final runtime =
        await container.read(svgHeightRuntimeProvider(MapValue.haven).future);
    debugPrint('PERF_NATIVE ${runtime?.attack.usesNativeAcceleration}');

    // Cone origins on the painted floor: Garage (131.7,246) and the Garden
    // platform (254.6,371.1), both from Dara's Haven reports.
    final transform = SvgHeightMapTransform.forMap(MapValue.haven);
    final anchor = coordinateSystem.virtualOffsetToWorld(ViewConeWidget.anchorPointVirtual);
    Offset storedFor(Offset svg) =>
        transform.sideWorldFromSource(svg, isAttack: true) - anchor;
    Offset screenFor(Offset stored) => coordinateSystem.worldOffsetToScreen(
        stored + coordinateSystem.virtualOffsetToWorld(
            Offset(Settings.agentSize / 2, Settings.agentSize / 2)));
    final startStored = storedFor(const Offset(131.7, 246));
    final endStored = storedFor(const Offset(254.6, 371.1));
    final start = screenFor(startStored);
    final end = screenFor(endStored);
    debugPrint('PERF_POSES start=$start end=$end');
    final agent = PlacedViewConeAgent(
      id: 'performance-view-cone-agent',
      type: AgentType.jett,
      position: startStored,
      presetType: UtilityType.viewCone90,
      rotation: 0.6,
      length: ViewConeUtility.maxLength * 0.8,
    );
    container.read(agentProvider.notifier).fromHive([agent]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
              brightness: Brightness.dark,
              colorScheme: Settings.tacticalVioletTheme),
          home: Scaffold(
            body: SizedBox.fromSize(
              size: _viewportSize,
              child: const Stack(
                  children: [Positioned.fill(child: PlacedWidgetBuilder())]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> drag({required bool forward}) async {
      final from = forward ? start : end;
      final to = forward ? end : start;
      final gesture =
          await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      for (var step = 1; step <= 90; step++) {
        await gesture.moveTo(Offset.lerp(from, to, step / 90)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump();
      await tester.pumpAndSettle();
    }

    final queriesBefore = runtime!.cache(true).queryCount;
    await drag(forward: true);
    await drag(forward: false);
    debugPrint('PERF_CONES ${runtime.cache(true).queryCount - queriesBefore} cone queries in 180 drag frames');
    await binding.watchPerformance(() async {
      for (var pass = 0; pass < 6; pass++) {
        await drag(forward: pass.isEven);
      }
    }, reportKey: 'view_cone_drag_performance');
    final report = binding.reportData?['view_cone_drag_performance']
        as Map<String, dynamic>?;
    if (report != null) {
      const keys = [
        'average_frame_build_time_millis',
        '90th_percentile_frame_build_time_millis',
        '99th_percentile_frame_build_time_millis',
        'worst_frame_build_time_millis',
        'missed_frame_build_budget_count',
        'average_frame_rasterizer_time_millis',
        '90th_percentile_frame_rasterizer_time_millis',
        '99th_percentile_frame_rasterizer_time_millis',
        'worst_frame_rasterizer_time_millis',
        'missed_frame_rasterizer_budget_count',
        'frame_count',
        'new_gen_gc_count',
        'old_gen_gc_count',
      ];
      debugPrint('PERF_RESULT ${jsonEncode({for (final k in keys) k: report[k]})}');
    }
  });
}

class _BenchmarkMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.haven, isAttack: true);
}
