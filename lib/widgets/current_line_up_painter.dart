import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/line_up_line_painter.dart';

enum LineUpEnd { origin, landing }

/// A lineup end being dragged over the map: where its anchor would land, in
/// map-local pixels, and which end it is.
class LineUpDragHover {
  const LineUpDragHover({required this.end, required this.anchor});

  final LineUpEnd end;
  final Offset anchor;

  @override
  bool operator ==(Object other) =>
      other is LineUpDragHover && other.end == end && other.anchor == anchor;

  @override
  int get hashCode => Object.hash(end, anchor);
}

/// Null when nothing is being dragged.
final lineUpDragHoverProvider =
    NotifierProvider<LineUpDragHoverNotifier, LineUpDragHover?>(
  LineUpDragHoverNotifier.new,
);

class LineUpDragHoverNotifier extends Notifier<LineUpDragHover?> {
  @override
  LineUpDragHover? build() => null;

  void update(LineUpDragHover? hover) {
    if (state == hover) return;
    state = hover;
  }
}

/// Paints the line for the lineup currently being placed, from whichever end
/// is pinned or already dropped to the other. Kept separate from
/// LineUpLinePainter so it can be layered independently.
class CurrentLineUpPainter extends ConsumerWidget {
  const CurrentLineUpPainter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final double abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final double agentSize = coordinateSystem.scale(
      ref.watch(strategySettingsProvider).agentSize,
    );
    final currentMap = ref.watch(
      mapProvider.select((state) => state.currentMap),
    );
    final double mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final lineUpState = ref.watch(lineUpProvider);
    final placement = lineUpState.placement;
    final isAttack = ref.watch(mapProvider).isAttack;

    Offset? originAnchor;
    Offset? landingAnchor;
    if (placement != null) {
      final agent = placement.draftAgent ??
          lineUpState.originById(placement.pinnedOriginId ?? '')?.agent;
      final ability = placement.draftAbility ??
          lineUpState.landingById(placement.pinnedLandingId ?? '')?.ability;
      if (agent != null) {
        originAnchor = screenAnchorForAgent(
          agent: agent,
          coordinateSystem: coordinateSystem,
          isAttack: isAttack,
        );
      }
      if (ability != null) {
        landingAnchor = screenAnchorForAbility(
          ability: ability,
          coordinateSystem: coordinateSystem,
          mapScale: mapScale,
          isAttack: isAttack,
        );
      }
    }

    return IgnorePointer(
      ignoring: true,
      child: CustomPaint(
        painter: _CurrentLinePainter(
          strokeWidth: coordinateSystem.scale(Settings.brushSize),
          color: Settings.accentInk,
          originAnchor: originAnchor,
          landingAnchor: landingAnchor,
          dragHover: ref.watch(lineUpDragHoverProvider),
          abilitySize: abilitySize,
          agentSize: agentSize,
          resizeCounter: ref.watch(lineUpCanvasResizeProvider),
        ),
      ),
    );
  }
}

class _CurrentLinePainter extends CustomPainter {
  final double strokeWidth;
  final Color color;
  final Offset? originAnchor;
  final Offset? landingAnchor;
  final LineUpDragHover? dragHover;
  final double abilitySize;
  final double agentSize;
  final int resizeCounter;

  _CurrentLinePainter({
    required this.strokeWidth,
    required this.color,
    required this.originAnchor,
    required this.landingAnchor,
    required this.dragHover,
    required this.abilitySize,
    required this.agentSize,
    required this.resizeCounter,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    final hover = dragHover;
    if (hover != null) {
      // The dragged end replaces its settled counterpart, so the line runs
      // from the other end to the cursor instead of pointing at the old spot.
      final fixed =
          hover.end == LineUpEnd.origin ? landingAnchor : originAnchor;
      if (fixed != null) _drawDashed(canvas, fixed, hover.anchor, paint);
      return;
    }
    if (originAnchor != null && landingAnchor != null) {
      canvas.drawLine(originAnchor!, landingAnchor!, paint);
    }
  }

  void _drawDashed(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 8.0;
    const gap = 6.0;
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..lineTo(to.dx, to.dy);
    for (final ui.PathMetric metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CurrentLinePainter oldDelegate) {
    return oldDelegate.originAnchor != originAnchor ||
        oldDelegate.landingAnchor != landingAnchor ||
        oldDelegate.dragHover != dragHover ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.color != color ||
        oldDelegate.abilitySize != abilitySize ||
        oldDelegate.agentSize != agentSize ||
        oldDelegate.resizeCounter != resizeCounter;
  }
}
