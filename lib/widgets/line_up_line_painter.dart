import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';

class LineUpLinePainter extends ConsumerStatefulWidget {
  const LineUpLinePainter({super.key});
  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _LineUpLinePainterState();
}

class _LineUpLinePainterState extends ConsumerState<ConsumerStatefulWidget> {
  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: true,
      child: CustomPaint(
        painter: LinePainter(
          hoveredLineUpId: ref.watch(hoveredLineUpIdProvider),
          lineUps: ref.watch(lineUpProvider).lineUps,
          coordinateSystem: CoordinateSystem.instance,
          abilitySize: ref.watch(strategySettingsProvider).abilitySize,
          agentSize: ref.watch(strategySettingsProvider).agentSize,
          mapScale: ref.watch(mapProvider.notifier).mapScale,
        ),
      ),
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

  LinePainter({
    super.repaint,
    required this.hoveredLineUpId,
    required this.lineUps,
    required this.coordinateSystem,
    required this.abilitySize,
    required this.agentSize,
    required this.mapScale,
  });
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white70
      ..strokeWidth = coordinateSystem.scale(Settings.brushSize)
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round;

    final highlightPaint = paint..color = Colors.white;

    for (final lineUp in lineUps) {
      final startPosition = coordinateSystem.coordinateToScreen(
          lineUp.agent.position + Offset(agentSize / 2, agentSize / 2));
      final endPosition = coordinateSystem.coordinateToScreen(lineUp
              .ability.position +
          lineUp.ability.data.abilityData!
              .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize));

      canvas.drawLine(
          startPosition,
          endPosition,
          (hoveredLineUpId == lineUp.id && hoveredLineUpId != null)
              ? highlightPaint
              : paint);
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
          oldDelegate.mapScale != mapScale;
    }
    return true;
  }
}
