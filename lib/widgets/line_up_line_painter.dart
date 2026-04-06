import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

final lineUpCanvasResizeProvider =
    NotifierProvider<LineUpCanvasResizeNotifier, int>(
  LineUpCanvasResizeNotifier.new,
);

class LineUpCanvasResizeNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}

class LineUpLinePainter extends ConsumerStatefulWidget {
  const LineUpLinePainter({super.key});
  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _LineUpLinePainterState();
}

class _LineUpLinePainterState extends ConsumerState<ConsumerStatefulWidget> {
  Size? _previousSize;

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;

    // Use LayoutBuilder to get the actual rendered size of this canvas.
    return LayoutBuilder(
      builder: (context, constraints) {
        final currentSize = constraints.biggest;

        // Skip screenshots; only bump when size actually changes.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (coordinateSystem.isScreenshot) return;
          if (_previousSize == currentSize) return;
          _previousSize = currentSize;
          ref.read(lineUpCanvasResizeProvider.notifier).increment();
        });

        final resizeCounter = ref.watch(lineUpCanvasResizeProvider);
        final currentMap =
            ref.watch(mapProvider.select((state) => state.currentMap));
        final mapScale = Maps.mapScale[currentMap] ?? 1.0;

        return IgnorePointer(
          ignoring: true,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: LinePainter(
                resizeCounter: resizeCounter,
                hoveredLineUpTarget: ref.watch(hoveredLineUpTargetProvider),
                groups: ref.watch(lineUpProvider).groups,
                coordinateSystem: CoordinateSystem.instance,
                abilitySize: ref.watch(strategySettingsProvider).abilitySize,
                agentSize: coordinateSystem.scale(
                  ref.watch(strategySettingsProvider).agentSize,
                ),
                mapScale: mapScale,
                currentAgent: ref.watch(lineUpProvider).currentAgent,
                currentAbility: ref.watch(lineUpProvider).currentAbility,
              ),
              // Ensure it expands to the available area so constraints.biggest is meaningful.
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

class LinePainter extends CustomPainter {
  final HoveredLineUpTarget? hoveredLineUpTarget;
  final List<LineUpGroup> groups;
  final CoordinateSystem coordinateSystem;
  final double abilitySize;
  final double agentSize;
  final double mapScale;
  final PlacedAgent? currentAgent;
  final PlacedAbility? currentAbility;
  final int resizeCounter;

  LinePainter({
    super.repaint,
    required this.resizeCounter,
    required this.hoveredLineUpTarget,
    required this.groups,
    required this.coordinateSystem,
    required this.abilitySize,
    required this.agentSize,
    required this.mapScale,
    this.currentAgent,
    this.currentAbility,
  });
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white70
      ..strokeWidth = coordinateSystem.scale(Settings.brushSize)
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final highlightPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = coordinateSystem.scale(Settings.brushSize)
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    // Current lineup highlight moved to CurrentLineUpPainter.
    for (final group in groups) {
      final startPosition =
          coordinateSystem.coordinateToScreen(group.agent.position) +
              Offset((agentSize / 2), (agentSize / 2));

      for (final item in group.items) {
        final endPosition =
            coordinateSystem.coordinateToScreen(item.ability.position) +
                item.ability.data.abilityData!
                    .getAnchorPoint(
                      mapScale: mapScale,
                      abilitySize: abilitySize,
                    )
                    .scale(
                      coordinateSystem.scaleFactor,
                      coordinateSystem.scaleFactor,
                    );

        canvas.drawLine(
          startPosition,
          endPosition,
          (hoveredLineUpTarget?.matchesConnector(group.id, item.id) ?? false)
              ? highlightPaint
              : paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    if (oldDelegate is LinePainter) {
      return oldDelegate.hoveredLineUpTarget != hoveredLineUpTarget ||
          oldDelegate.groups != groups ||
          oldDelegate.coordinateSystem.effectiveSize !=
              coordinateSystem.effectiveSize ||
          oldDelegate.abilitySize != abilitySize ||
          oldDelegate.agentSize != agentSize ||
          oldDelegate.mapScale != mapScale ||
          oldDelegate.resizeCounter != resizeCounter;
    }
    return false;
  }
}
