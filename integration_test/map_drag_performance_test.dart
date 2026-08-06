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
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/hovered_map_item_name_card.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _viewportSize = Size(1200, 675);
const _dragSourceKey = ValueKey('performance-drag-source');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dragging across placed agents', (tester) async {
    tester.view
      ..physicalSize = _viewportSize
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final coordinateSystem = CoordinateSystem(playAreaSize: _viewportSize);
    final container = ProviderContainer(
      overrides: [
        mapProvider.overrideWith(_BenchmarkMapProvider.new),
      ],
    );
    addTearDown(container.dispose);

    final agents = <PlacedAgent>[
      for (var index = 0; index < 12; index++)
        PlacedAgent(
          id: 'performance-agent-$index',
          type: AgentType.values[index % AgentType.values.length],
          position: storedAgentPositionForRenderedScreenPosition(
            coordinateSystem: coordinateSystem,
            renderedScreenPosition: Offset(150 + (index * 80), 310),
            agentSize: Settings.agentSize,
          ),
          isAlly: index.isEven,
        ),
    ];
    container.read(agentProvider.notifier).fromHive(agents);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: Scaffold(
            body: SizedBox.fromSize(
              size: _viewportSize,
              child: const Stack(
                children: [
                  Positioned.fill(child: PlacedWidgetBuilder()),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: HoveredMapItemNameCard(),
                  ),
                  Positioned(
                    left: 50,
                    top: 315,
                    child: _BenchmarkDragSource(key: _dragSourceKey),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Decode and raster-cache the feedback before collecting timings.
    await _dragAcrossAgents(tester, leftToRight: true);
    await tester.pumpAndSettle();

    await binding.watchPerformance(
      () async {
        for (var pass = 0; pass < 6; pass++) {
          await _dragAcrossAgents(tester, leftToRight: pass.isEven);
        }
        await tester.pumpAndSettle();
      },
      reportKey: 'map_drag_performance',
    );
    _printPerformanceSummary(binding, 'map_drag_performance');
  });
}

void _printPerformanceSummary(
  IntegrationTestWidgetsFlutterBinding binding,
  String reportKey,
) {
  final report = binding.reportData?[reportKey] as Map<String, dynamic>?;
  if (report == null) return;

  const metricKeys = [
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
  final summary = <String, dynamic>{
    'report': reportKey,
    for (final key in metricKeys) key: report[key],
  };
  debugPrint('PERF_RESULT ${jsonEncode(summary)}');
}

Future<void> _dragAcrossAgents(
  WidgetTester tester, {
  required bool leftToRight,
}) async {
  final source = tester.getCenter(find.byKey(_dragSourceKey));
  final start = leftToRight ? source : const Offset(1100, 337.5);
  final end = leftToRight ? const Offset(1100, 337.5) : source;
  final gesture =
      await tester.startGesture(start, kind: PointerDeviceKind.mouse);

  for (var step = 1; step <= 72; step++) {
    await gesture.moveTo(Offset.lerp(start, end, step / 72)!);
    await tester.pump(const Duration(milliseconds: 16));
  }

  await gesture.up();
  await tester.pump();
}

class _BenchmarkDragSource extends StatelessWidget {
  const _BenchmarkDragSource({super.key});

  @override
  Widget build(BuildContext context) {
    return Draggable<Object>(
      data: const Object(),
      feedback: Opacity(
        opacity: Settings.feedbackOpacity,
        child: ZoomTransform(
          child: AgentWidget(
            id: '',
            isAlly: true,
            agent: AgentData.agents[AgentType.jett]!,
          ),
        ),
      ),
      childWhenDragging: const SizedBox.square(dimension: 45),
      child: const _DragMarker(),
    );
  }
}

class _BenchmarkMapProvider extends MapProvider {
  @override
  MapState build() => MapState(
        currentMap: MapValue.ascent,
        isAttack: true,
      );
}

class _DragMarker extends StatelessWidget {
  const _DragMarker();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.primary,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: const SizedBox.square(dimension: 45),
    );
  }
}
