import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
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
        final currentMap = ref.watch(
          mapProvider.select((state) => state.currentMap),
        );
        final mapScale = Maps.mapScale[currentMap] ?? 1.0;

        final lineUpState = ref.watch(lineUpProvider);

        return IgnorePointer(
          ignoring: true,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: LinePainter(
                resizeCounter: resizeCounter,
                hoveredLineUpTarget: ref.watch(hoveredLineUpTargetProvider),
                lineUpState: lineUpState,
                coordinateSystem: CoordinateSystem.instance,
                abilitySize: ref.watch(strategySettingsProvider).abilitySize,
                agentSize: coordinateSystem.scale(
                  ref.watch(strategySettingsProvider).agentSize,
                ),
                mapScale: mapScale,
                isAttack: ref.watch(mapProvider).isAttack,
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

/// One line per distinct (origin, landing spot) pair. Hovering an origin
/// lights every line out of it, hovering a landing spot every line into it.
class LinePainter extends CustomPainter {
  final HoveredLineUpTarget? hoveredLineUpTarget;
  final LineUpState lineUpState;
  final CoordinateSystem coordinateSystem;
  final double abilitySize;
  final double agentSize;
  final double mapScale;
  final bool isAttack;
  final int resizeCounter;

  LinePainter({
    super.repaint,
    required this.resizeCounter,
    required this.hoveredLineUpTarget,
    required this.lineUpState,
    required this.coordinateSystem,
    required this.abilitySize,
    required this.agentSize,
    required this.mapScale,
    required this.isAttack,
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

    final originAnchors = <String, Offset>{};
    final landingAnchors = <String, Offset>{};

    for (final (originId, landingId) in lineUpState.connectorPairs) {
      final origin = lineUpState.originById(originId);
      final landing = lineUpState.landingById(landingId);
      if (origin == null || landing == null) continue;

      final startPosition = originAnchors.putIfAbsent(
        originId,
        () => screenAnchorForAgent(
          agent: origin.agent,
          coordinateSystem: coordinateSystem,
          isAttack: isAttack,
        ),
      );
      final endPosition = landingAnchors.putIfAbsent(
        landingId,
        () => screenAnchorForAbility(
          ability: landing.ability,
          coordinateSystem: coordinateSystem,
          mapScale: mapScale,
          isAttack: isAttack,
        ),
      );

      canvas.drawLine(
        startPosition,
        endPosition,
        (hoveredLineUpTarget?.matchesConnector(originId, landingId) ?? false)
            ? highlightPaint
            : paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    if (oldDelegate is LinePainter) {
      return oldDelegate.hoveredLineUpTarget != hoveredLineUpTarget ||
          oldDelegate.lineUpState != lineUpState ||
          oldDelegate.coordinateSystem.effectiveSize !=
              coordinateSystem.effectiveSize ||
          oldDelegate.abilitySize != abilitySize ||
          oldDelegate.agentSize != agentSize ||
          oldDelegate.mapScale != mapScale ||
          oldDelegate.isAttack != isAttack ||
          oldDelegate.resizeCounter != resizeCounter;
    }
    return false;
  }
}
