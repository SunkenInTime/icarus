import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/active_page_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/valorant/valorant_match_strategy_data.dart';
import 'package:icarus/widgets/line_up_line_painter.dart';

class ValorantKillLinePainter extends ConsumerWidget {
  const ValorantKillLinePainter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePageId = ref.watch(activePageProvider);
    if (activePageId == null) return const SizedBox.shrink();

    final strategyId = ref.watch(strategyProvider).id;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    return ValueListenableBuilder(
      valueListenable: box.listenable(keys: [strategyId]),
      builder: (context, Box<StrategyData> b, _) {
        final strat = b.get(strategyId);
        final match = strat?.valorantMatch;
        if (match == null) return const SizedBox.shrink();

        ValorantPageMeta? meta;
        for (final m in match.pageMeta) {
          if (m.pageId == activePageId) {
            meta = m;
            break;
          }
        }
        if (meta == null || meta.type != ValorantEventType.kill) {
          return const SizedBox.shrink();
        }

        final kx = meta.killerX;
        final ky = meta.killerY;
        final vx = meta.victimX;
        final vy = meta.victimY;
        if (kx == null || ky == null || vx == null || vy == null) {
          return const SizedBox.shrink();
        }

        final coordinateSystem = CoordinateSystem.instance;
        final agentSizePx = coordinateSystem.scale(
          ref.watch(strategySettingsProvider).agentSize,
        );

        return IgnorePointer(
          ignoring: true,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _KillLinePainter(
                coordinateSystem: coordinateSystem,
                resizeCounter: ref.watch(lineUpCanvasResizeProvider),
                killer: Offset(kx, ky),
                victim: Offset(vx, vy),
                agentRadiusPx: agentSizePx / 2,
              ),
              size: Size.infinite,
            ),
          ),
        );
      },
    );
  }
}

class _KillLinePainter extends CustomPainter {
  final CoordinateSystem coordinateSystem;
  final int resizeCounter;
  final Offset killer;
  final Offset victim;
  final double agentRadiusPx;

  _KillLinePainter({
    required this.coordinateSystem,
    required this.resizeCounter,
    required this.killer,
    required this.victim,
    required this.agentRadiusPx,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final start = coordinateSystem.coordinateToScreen(killer);
    final end = coordinateSystem.coordinateToScreen(victim);

    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;

    // Shorten the line so it doesn't pass under the agent icons.
    final ux = dx / len;
    final uy = dy / len;
    final inset = math.min(agentRadiusPx, len / 2);

    final insetStart = start + Offset(ux * inset, uy * inset);
    final insetEnd = end - Offset(ux * inset, uy * inset);

    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = coordinateSystem.scale(Settings.brushSize)
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    canvas.drawLine(insetStart, insetEnd, paint);
    _drawArrow(canvas, paint, insetStart, insetEnd);
  }

  void _drawArrow(Canvas canvas, Paint paint, Offset from, Offset to) {
    final arrowHeadSize = coordinateSystem.scale(8);
    const arrowAngle = math.pi / 4;
    final angle = math.atan2(to.dy - from.dy, to.dx - from.dx);

    final arrowPoint1 = Offset(
      to.dx - arrowHeadSize * math.cos(angle - arrowAngle),
      to.dy - arrowHeadSize * math.sin(angle - arrowAngle),
    );
    final arrowPoint2 = Offset(
      to.dx - arrowHeadSize * math.cos(angle + arrowAngle),
      to.dy - arrowHeadSize * math.sin(angle + arrowAngle),
    );

    canvas.drawLine(to, arrowPoint1, paint);
    canvas.drawLine(to, arrowPoint2, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    if (oldDelegate is _KillLinePainter) {
      return oldDelegate.killer != killer ||
          oldDelegate.victim != victim ||
          oldDelegate.agentRadiusPx != agentRadiusPx ||
          oldDelegate.coordinateSystem.effectiveSize !=
              coordinateSystem.effectiveSize ||
          oldDelegate.resizeCounter != resizeCounter;
    }
    return true;
  }
}
