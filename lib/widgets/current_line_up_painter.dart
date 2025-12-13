import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/line_up_line_painter.dart';

/// Paints the highlight line for the lineup currently being built (agent + ability).
/// Kept separate from LineUpLinePainter so it can be layered independently.
class CurrentLineUpPainter extends ConsumerWidget {
  const CurrentLineUpPainter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final double abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final double agentSize =
        coordinateSystem.scale(ref.watch(strategySettingsProvider).agentSize);
    final double mapScale = ref.watch(mapProvider.notifier).mapScale;
    final PlacedAgent? currentAgent = ref.watch(lineUpProvider).currentAgent;
    final PlacedAbility? currentAbility =
        ref.watch(lineUpProvider).currentAbility;

    return IgnorePointer(
      ignoring: true,
      child: CustomPaint(
        painter: _CurrentLinePainter(
          coordinateSystem: coordinateSystem,
          abilitySize: abilitySize,
          agentSize: agentSize,
          mapScale: mapScale,
          currentAgent: currentAgent,
          currentAbility: currentAbility,
          resizeCounter: ref.watch(lineUpCanvasResizeProvider),
        ),
      ),
    );
  }
}

class _CurrentLinePainter extends CustomPainter {
  final CoordinateSystem coordinateSystem;
  final double abilitySize;
  final double agentSize;
  final double mapScale;
  final PlacedAgent? currentAgent;
  final PlacedAbility? currentAbility;
  final int resizeCounter;

  _CurrentLinePainter({
    required this.coordinateSystem,
    required this.abilitySize,
    required this.agentSize,
    required this.mapScale,
    this.currentAgent,
    this.currentAbility,
    required this.resizeCounter,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (currentAgent == null || currentAbility == null) return;

    final highlightPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = coordinateSystem.scale(Settings.brushSize)
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final startPosition =
        coordinateSystem.coordinateToScreen(currentAgent!.position) +
            Offset((agentSize / 2), (agentSize / 2));

    final endPosition = coordinateSystem
            .coordinateToScreen(currentAbility!.position) +
        currentAbility!.data.abilityData!
            .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
            .scale(coordinateSystem.scaleFactor, coordinateSystem.scaleFactor);

    canvas.drawLine(startPosition, endPosition, highlightPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    if (oldDelegate is _CurrentLinePainter) {
      return oldDelegate.currentAgent != currentAgent ||
          oldDelegate.currentAbility != currentAbility ||
          oldDelegate.abilitySize != abilitySize ||
          oldDelegate.agentSize != agentSize ||
          oldDelegate.mapScale != mapScale ||
          oldDelegate.resizeCounter != resizeCounter;
    }
    return true;
  }
}
