import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
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
          log("LineUp Canvas resized to $currentSize");
        });

        final resizeCounter = ref.watch(lineUpCanvasResizeProvider);

        return IgnorePointer(
          ignoring: true,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: LinePainter(
                resizeCounter: resizeCounter,
                hoveredLineUpId: ref.watch(hoveredLineUpIdProvider),
                lineUps: ref.watch(lineUpProvider).lineUps,
                coordinateSystem: CoordinateSystem.instance,
                abilitySize: ref.watch(strategySettingsProvider).abilitySize,
                agentSize: coordinateSystem.scale(
                  ref.watch(strategySettingsProvider).agentSize,
                ),
                mapScale: ref.watch(mapProvider.notifier).mapScale,
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
  final String? hoveredLineUpId;
  final List<LineUp> lineUps;
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
    required this.hoveredLineUpId,
    required this.lineUps,
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
    for (final lineUp in lineUps) {
      final startPosition =
          coordinateSystem.coordinateToScreen(lineUp.agent.position) +
              Offset((agentSize / 2), (agentSize / 2));

      final endPosition = coordinateSystem
              .coordinateToScreen(lineUp.ability.position) +
          lineUp.ability.data.abilityData!
              .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
              .scale(
                  coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);

      canvas.drawLine(
        startPosition,
        endPosition,
        (hoveredLineUpId == lineUp.id && hoveredLineUpId != null)
            ? highlightPaint
            : paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    if (oldDelegate is LinePainter) {
      return oldDelegate.hoveredLineUpId != hoveredLineUpId ||
          oldDelegate.lineUps != lineUps ||
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
