import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/mouse_watch.dart';

/// Grayscale color matrix for dead agents
const ColorFilter _grayscaleFilter = ColorFilter.matrix(<double>[
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
]);

/// Muted background colors for dead agents
const Color _mutedAllyBGColor = Color.fromARGB(255, 60, 60, 60);
const Color _mutedEnemyBGColor = Color.fromARGB(255, 70, 50, 50);

/// Muted outline colors for dead agents
const Color _mutedAllyOutlineColor = Color.fromARGB(100, 100, 100, 100);
const Color _mutedEnemyOutlineColor = Color.fromARGB(100, 120, 80, 80);

class AgentWidget extends ConsumerWidget {
  const AgentWidget({
    super.key,
    required this.agent,
    required this.id,
    required this.isAlly,
    this.lineUpId,
    this.state = AgentState.none,
  });

  final String? lineUpId;
  final String? id;
  final bool isAlly;
  final AgentData agent;
  final AgentState state;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final agentSize = ref.watch(strategySettingsProvider).agentSize;
    final isDead = state == AgentState.dead;

    final agentImage = RepaintBoundary(child: Image.asset(agent.iconPath));

    // Determine background color
    Color bgColor = Settings.enemyBGColor;
    if (isAlly) {
      bgColor = Settings.allyBGColor;
    }

    if (isDead) {
      if (isAlly) {
        bgColor = _mutedAllyBGColor;
      } else {
        bgColor = _mutedEnemyBGColor;
      }
    }

    if (lineUpId != null && ref.watch(hoveredLineUpIdProvider) == lineUpId) {
      bgColor = Colors.deepPurple;
    }

    // Determine outline color
    Color outlineColor = Settings.enemyOutlineColor;
    if (isAlly) {
      outlineColor = Settings.allyOutlineColor;
    }

    if (isDead) {
      if (isAlly) {
        outlineColor = _mutedAllyOutlineColor;
      } else {
        outlineColor = _mutedEnemyOutlineColor;
      }
    }

    if (lineUpId != null && ref.watch(hoveredLineUpIdProvider) == lineUpId) {
      outlineColor = Colors.deepPurpleAccent;
    }

    Widget agentDisplay = agentImage;
    if (isDead) {
      agentDisplay = Stack(
        children: [
          ColorFiltered(
            colorFilter: _grayscaleFilter,
            child: agentImage,
          ),
          const Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _DeadXOverlayPainter(),
              ),
            ),
          ),
        ],
      );
    }
    final bool isLineUp = lineUpId != null;
    final bool isNoneInteractive =
        (id == null || id!.isEmpty) & (lineUpId == null);

    final decoration = BoxDecoration(
      color: bgColor,
      border: Border.all(
        color: outlineColor,
      ),
      borderRadius: const BorderRadius.all(
        Radius.circular(3),
      ),
    );

    final scaledSize = coordinateSystem.scale(agentSize);

    Widget agentCard;
    // Use Ink + InkWell so the ripple shows on top of the background

    if (isNoneInteractive) {
      agentCard = agentDisplay;
    } else if (isLineUp) {
      agentCard = Container(
        decoration: decoration,
        width: scaledSize,
        height: scaledSize,
        child: agentDisplay,
      );
    } else {
      agentCard = Material(
        color: Colors.transparent,
        child: Ink(
          decoration: decoration,
          width: scaledSize,
          height: scaledSize,
          child: InkWell(
            borderRadius: const BorderRadius.all(Radius.circular(3)),
            highlightColor: Colors.white.withValues(alpha: 0.2),
            splashColor: Colors.white.withValues(alpha: 0.3),
            onLongPress: () {
              if (id == null) return;
              log("Sigma pressed");
              ref.read(agentProvider.notifier).toggleAgentState(id!);
            },
            child: agentDisplay,
          ),
        ),
      );
    }

    return MouseWatch(
      lineUpId: lineUpId,
      cursor: SystemMouseCursors.click,
      onDeleteKeyPressed: () {
        if (lineUpId != null) {
          ref.read(lineUpProvider.notifier).deleteLineUpById(lineUpId!);
          return;
        }
        if (id == null) return;

        final action = UserAction(
            type: ActionType.deletion, id: id!, group: ActionGroup.agent);

        ref.read(actionProvider.notifier).addAction(action);
        ref.read(agentProvider.notifier).removeAgent(id!);
      },
      child: agentCard,
    );
  }
}

/// Draws a red X overlay for dead agents
class _DeadXOverlayPainter extends CustomPainter {
  const _DeadXOverlayPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red.withOpacity(0.8)
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Add some padding so the X doesn't touch the edges
    const padding = 4.0;

    // Draw first diagonal (top-left to bottom-right)
    canvas.drawLine(
      const Offset(padding, padding),
      Offset(size.width - padding, size.height - padding),
      paint,
    );

    // Draw second diagonal (top-right to bottom-left)
    canvas.drawLine(
      Offset(size.width - padding, padding),
      Offset(padding, size.height - padding),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
