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
import 'package:icarus/const/transition_data.dart';
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

  testWidgets('dragging a view cone agent on Haven, timeline', (tester) async {
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
    await binding.traceAction(() async {
      for (var pass = 0; pass < 4; pass++) {
        await drag(forward: pass.isEven);
      }
    }, retainPriorEvents: false);
    final raw = binding.reportData?['timeline'] as Map<String, dynamic>?;
    final events = (raw?['traceEvents'] as List?) ?? const [];
    final durations = <String, List<int>>{};
    final open = <String, int>{};
    for (final e in events.cast<Map>()) {
      final name = e['name'] as String?;
      if (name == null) continue;
      if (!(name.contains('Rasterizer') || name.contains('GPURasterizer') || name.contains('Animator::BeginFrame') || name.contains('Frame') || name.contains('Paint') || name.contains('Layout') || name.contains('Build'))) continue;
      final key = '$name-${e['tid']}';
      final ts = (e['ts'] as num?)?.toInt();
      if (ts == null) continue;
      if (e['ph'] == 'B') {
        open[key] = ts;
      } else if (e['ph'] == 'E' && open.containsKey(key)) {
        (durations[name] ??= []).add(ts - open.remove(key)!);
      } else if (e['ph'] == 'X' && e['dur'] != null) {
        (durations[name] ??= []).add((e['dur'] as num).toInt());
      }
    }
    for (final entry in durations.entries) {
      final list = entry.value..sort();
      if (list.isEmpty) continue;
      num pct(double p) => list[(list.length * p).clamp(0, list.length - 1).floor()];
      debugPrint('PERF_TIMELINE ${entry.key}: n=${list.length} p50=${pct(0.5)}us p90=${pct(0.9)}us p99=${pct(0.99)}us max=${list.last}us');
    }
  });
}

class _BenchmarkMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.haven, isAttack: true);
}
