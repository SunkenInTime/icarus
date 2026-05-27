import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/duplicate_drag_modifier_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_circle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_shape_resize_tooltip.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

double circleAgentCompositeDiameterVirtual(double mapScale) {
  return CustomCircleUtility.maxDiameterInVirtual(mapScale);
}

Offset circleAgentCompositeAgentOffsetVirtual({
  required double agentSize,
  required double mapScale,
}) {
  final inset = (circleAgentCompositeDiameterVirtual(mapScale) - agentSize) / 2;
  return Offset(inset, inset);
}

Offset circleAgentCompositeAgentOffsetScreen({
  required CoordinateSystem coordinateSystem,
  required double agentSize,
  required double mapScale,
}) {
  final offset = circleAgentCompositeAgentOffsetVirtual(
    agentSize: agentSize,
    mapScale: mapScale,
  );
  return Offset(
    coordinateSystem.scale(offset.dx),
    coordinateSystem.scale(offset.dy),
  );
}

class CircleAgentComposite extends ConsumerWidget {
  const CircleAgentComposite({
    super.key,
    required this.agent,
    this.forcedAgentSize,
  });

  final PlacedCircleAgent agent;
  final double? forcedAgentSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final agentSize =
        forcedAgentSize ?? ref.watch(strategySettingsProvider).agentSize;
    final currentMap =
        ref.watch(mapProvider.select((state) => state.currentMap));
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final scaledMaxDiameter =
        coordinateSystem.scale(circleAgentCompositeDiameterVirtual(mapScale));
    final agentOffset = circleAgentCompositeAgentOffsetScreen(
      coordinateSystem: coordinateSystem,
      agentSize: agentSize,
      mapScale: mapScale,
    );

    return SizedBox(
      width: scaledMaxDiameter,
      height: scaledMaxDiameter,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: CustomCircleUtilityWidget(
              id: null,
              diameterMeters: agent.diameterMeters,
              colorValue: agent.colorValue,
              opacityPercent: agent.opacityPercent,
              mapScale: mapScale,
              showCenterMarker: false,
            ),
          ),
          Positioned(
            left: agentOffset.dx,
            top: agentOffset.dy,
            child: AgentWidget(
              state: agent.state,
              isAlly: agent.isAlly,
              id: agent.id,
              agent: AgentData.agents[agent.type]!,
              forcedAgentSize: agentSize,
            ),
          ),
        ],
      ),
    );
  }
}

class PlacedCircleAgentWidget extends ConsumerStatefulWidget {
  const PlacedCircleAgentWidget({
    super.key,
    required this.agent,
    required this.onDragEnd,
  });

  final PlacedCircleAgent agent;
  final void Function(DraggableDetails details, String draggedId) onDragEnd;

  @override
  ConsumerState<PlacedCircleAgentWidget> createState() =>
      _PlacedCircleAgentWidgetState();
}

class _PlacedCircleAgentWidgetState
    extends ConsumerState<PlacedCircleAgentWidget> {
  static const double _minDiameterMeters = 1.0;
  static const double _maxDiameterMeters =
      CustomCircleUtility.maxDiameterMeters;
  static const double _handleAngle = math.pi / 4;
  static const double _maxHandleSweep = math.pi / 7;
  static const double _handleArcLengthVirtual = 18.0;
  static const double _circleBorderStrokeVirtual = 2.0;
  static const double _handleStrokeWidthVirtual = 8.0;

  double? _localDiameterMeters;
  double? _resizeStartDiameterMeters;
  double _diameterDragOffsetMeters = 0;
  bool _isDragging = false;
  bool _isResizing = false;
  bool _isHandleHovered = false;
  String? _activeDragId;

  @override
  void initState() {
    super.initState();
    _localDiameterMeters = widget.agent.diameterMeters;
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final currentMap =
        ref.watch(mapProvider.select((state) => state.currentMap));
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final isScreenshot = ref.watch(screenshotProvider);
    final agents = ref.watch(agentProvider);
    final index = PlacedWidget.getIndexByID(widget.agent.id, agents);
    if (index < 0) {
      return const SizedBox.shrink();
    }

    final current = agents[index];
    if (current is! PlacedCircleAgent) {
      return const SizedBox.shrink();
    }

    if (!_isDragging &&
        !_isResizing &&
        _localDiameterMeters != current.diameterMeters) {
      _localDiameterMeters = current.diameterMeters;
    }

    final agentSize = ref.watch(strategySettingsProvider).agentSize;
    final diameterMeters = _localDiameterMeters ?? current.diameterMeters;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final scaledDiameter = coordinateSystem.scale(diameterMeters * meterScale);
    final scaledMaxDiameter =
        coordinateSystem.scale(circleAgentCompositeDiameterVirtual(mapScale));
    final circleCenter = Offset(
      scaledMaxDiameter / 2,
      scaledMaxDiameter / 2,
    );
    final compositeAgentOffset = circleAgentCompositeAgentOffsetScreen(
      coordinateSystem: coordinateSystem,
      agentSize: agentSize,
      mapScale: mapScale,
    );
    final arcRegionSize = coordinateSystem.scale(32);
    final handleCenter = _computeHandleCenter(
      coordinateSystem: coordinateSystem,
      scaledDiameter: scaledDiameter,
      circleCenter: circleCenter,
    );
    final arcRegionLeft = handleCenter.dx - (arcRegionSize / 2);
    final arcRegionTop = handleCenter.dy - (arcRegionSize / 2);
    final rightOverflow = math.max(
      0.0,
      (arcRegionLeft + arcRegionSize) - scaledMaxDiameter,
    );
    final bottomOverflow = math.max(
      0.0,
      (arcRegionTop + arcRegionSize) - scaledMaxDiameter,
    );

    return Positioned(
      left: coordinateSystem.coordinateToScreen(current.position).dx -
          compositeAgentOffset.dx,
      top: coordinateSystem.coordinateToScreen(current.position).dy -
          compositeAgentOffset.dy,
      child: SizedBox(
        width: scaledMaxDiameter + rightOverflow,
        height: scaledMaxDiameter + bottomOverflow,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Draggable<PlacedWidget>(
              data: current,
              dragAnchorStrategy:
                  ref.read(screenZoomProvider.notifier).zoomDragAnchorStrategy,
              feedback: Opacity(
                opacity: Settings.feedbackOpacity,
                child: ZoomTransform(
                  child: CircleAgentComposite(
                    agent: current.copyWith(diameterMeters: diameterMeters),
                    forcedAgentSize: agentSize,
                  ),
                ),
              ),
              childWhenDragging: const SizedBox.shrink(),
              onDragStarted: () {
                final shouldDuplicate =
                    ref.read(duplicateDragModifierProvider);
                final duplicateId = shouldDuplicate
                    ? ref.read(agentProvider.notifier).duplicateAgentAt(
                          sourceId: current.id,
                          position: current.position,
                        )
                    : null;
                setState(() {
                  _isDragging = true;
                  _activeDragId = duplicateId ?? current.id;
                });
              },
              onDragEnd: (details) {
                final dragId = _activeDragId ?? current.id;
                setState(() {
                  _isDragging = false;
                  _activeDragId = null;
                });
                widget.onDragEnd(details, dragId);
              },
              child: CircleAgentComposite(
                agent: current.copyWith(diameterMeters: diameterMeters),
                forcedAgentSize: agentSize,
              ),
            ),
            if (!_isDragging && !isScreenshot)
              Positioned(
                left: arcRegionLeft,
                top: arcRegionTop,
                child: _CircleResizeHandle(
                  arcRegionSize: arcRegionSize,
                  circleLeft: -arcRegionLeft,
                  circleTop: -arcRegionTop,
                  scaledDiameter: scaledDiameter,
                  handleSweep: _computeHandleSweep(
                    coordinateSystem: coordinateSystem,
                    scaledDiameter: scaledDiameter,
                  ),
                  onEnter: () {
                    setState(() {
                      _isHandleHovered = true;
                    });
                  },
                  onExit: () {
                    setState(() {
                      _isHandleHovered = false;
                    });
                  },
                  isHovered: _isHandleHovered,
                  isResizing: _isResizing,
                  onPanStart: (details) => _startCircleResize(
                    globalPosition: details.globalPosition,
                    mapScale: mapScale,
                    diameterMeters: diameterMeters,
                  ),
                  onPanUpdate: (details) =>
                      _updateDiameter(details.globalPosition, mapScale),
                  onPanEnd: (_) => _finishCircleResize(current),
                  onPanCancel: _cancelCircleResize,
                ),
              ),
            if (!isScreenshot && _isResizing)
              Positioned(
                left: handleCenter.dx,
                top: handleCenter.dy - coordinateSystem.scale(16),
                child: FractionalTranslation(
                  translation: const Offset(-0.5, -1.0),
                  child: CustomShapeResizeTooltip(
                    label: 'D',
                    valueMeters: diameterMeters,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  double _computeHandleSweep({
    required CoordinateSystem coordinateSystem,
    required double scaledDiameter,
  }) {
    final radius = _computeCircleBorderRadius(
      coordinateSystem: coordinateSystem,
      scaledDiameter: scaledDiameter,
    );
    if (radius <= 0) return _maxHandleSweep;

    final arcLength = coordinateSystem.scale(_handleArcLengthVirtual);
    return (arcLength / radius).clamp(0.0, _maxHandleSweep);
  }

  Offset _computeHandleCenter({
    required CoordinateSystem coordinateSystem,
    required double scaledDiameter,
    required Offset circleCenter,
  }) {
    final radius = _computeCircleBorderRadius(
      coordinateSystem: coordinateSystem,
      scaledDiameter: scaledDiameter,
    );
    return Offset(
      circleCenter.dx + (radius * math.cos(_handleAngle)),
      circleCenter.dy + (radius * math.sin(_handleAngle)),
    );
  }

  double _computeCircleBorderRadius({
    required CoordinateSystem coordinateSystem,
    required double scaledDiameter,
  }) {
    final circleBorderStrokeWidth =
        coordinateSystem.scale(_circleBorderStrokeVirtual);
    return math.max(0.0, (scaledDiameter / 2) - (circleBorderStrokeWidth / 2));
  }

  void _startCircleResize({
    required Offset globalPosition,
    required double mapScale,
    required double diameterMeters,
  }) {
    setState(() {
      _isResizing = true;
      _isHandleHovered = true;
      _resizeStartDiameterMeters = diameterMeters;
      _diameterDragOffsetMeters =
          diameterMeters - _estimateDiameterMeters(globalPosition, mapScale);
    });
  }

  void _updateDiameter(Offset globalPosition, double mapScale) {
    final nextDiameter = (_estimateDiameterMeters(globalPosition, mapScale) +
            _diameterDragOffsetMeters)
        .clamp(_minDiameterMeters, _maxDiameterMeters);

    setState(() {
      _localDiameterMeters = nextDiameter.toDouble();
    });
  }

  double _estimateDiameterMeters(Offset globalPosition, double mapScale) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return _localDiameterMeters ?? _minDiameterMeters;

    final coordinateSystem = CoordinateSystem.instance;
    final scaledMaxDiameter =
        coordinateSystem.scale(circleAgentCompositeDiameterVirtual(mapScale));
    final localCenter = Offset(scaledMaxDiameter / 2, scaledMaxDiameter / 2);
    final localPosition = renderBox.globalToLocal(globalPosition);
    final deltaFromCenter = localPosition - localCenter;
    final deltaVirtual = Offset(
      coordinateSystem.normalize(deltaFromCenter.dx),
      coordinateSystem.normalize(deltaFromCenter.dy),
    );

    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final radiusEstimateX = deltaVirtual.dx / math.cos(_handleAngle);
    final radiusEstimateY = deltaVirtual.dy / math.sin(_handleAngle);
    final radiusVirtual =
        math.max((radiusEstimateX + radiusEstimateY) / 2, 0.0);
    return ((radiusVirtual * 2) / meterScale).toDouble();
  }

  void _finishCircleResize(PlacedCircleAgent current) {
    final diameterMeters = _localDiameterMeters;
    if (diameterMeters != null) {
      ref.read(agentProvider.notifier).updateCircleGeometry(
            id: current.id,
            diameterMeters: diameterMeters,
            colorValue: current.colorValue,
            opacityPercent: current.opacityPercent,
          );
    }

    setState(() {
      _isResizing = false;
      _isHandleHovered = false;
      _diameterDragOffsetMeters = 0;
      _resizeStartDiameterMeters = null;
    });
  }

  void _cancelCircleResize() {
    setState(() {
      _isResizing = false;
      _isHandleHovered = false;
      _diameterDragOffsetMeters = 0;
      _localDiameterMeters = _resizeStartDiameterMeters ?? _localDiameterMeters;
      _resizeStartDiameterMeters = null;
    });
  }
}

class _CircleResizeHandle extends StatelessWidget {
  const _CircleResizeHandle({
    required this.arcRegionSize,
    required this.circleLeft,
    required this.circleTop,
    required this.scaledDiameter,
    required this.handleSweep,
    required this.onEnter,
    required this.onExit,
    required this.isHovered,
    required this.isResizing,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onPanCancel,
  });

  final double arcRegionSize;
  final double circleLeft;
  final double circleTop;
  final double scaledDiameter;
  final double handleSweep;
  final VoidCallback onEnter;
  final VoidCallback onExit;
  final bool isHovered;
  final bool isResizing;
  final GestureDragStartCallback onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;
  final VoidCallback onPanCancel;

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final strokeWidth = coordinateSystem
        .scale(_PlacedCircleAgentWidgetState._handleStrokeWidthVirtual);
    final circleBorderStrokeWidth = coordinateSystem
        .scale(_PlacedCircleAgentWidgetState._circleBorderStrokeVirtual);

    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      onEnter: (_) => onEnter(),
      onExit: (_) => onExit(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: onPanStart,
        onPanUpdate: onPanUpdate,
        onPanEnd: onPanEnd,
        onPanCancel: onPanCancel,
        child: SizedBox(
          width: arcRegionSize,
          height: arcRegionSize,
          child: Center(
            child: AnimatedScale(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              scale: isResizing || isHovered ? 1.0 : 0.9,
              child: CustomPaint(
                size: Size(arcRegionSize, arcRegionSize),
                painter: _CircleResizeArcPainter(
                  color: Colors.white,
                  strokeWidth: strokeWidth,
                  circleDiameter: scaledDiameter,
                  circleOffset: Offset(-circleLeft, -circleTop),
                  circleBorderStrokeWidth: circleBorderStrokeWidth,
                  handleSweep: handleSweep,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CircleResizeArcPainter extends CustomPainter {
  const _CircleResizeArcPainter({
    required this.color,
    required this.strokeWidth,
    required this.circleDiameter,
    required this.circleOffset,
    required this.circleBorderStrokeWidth,
    required this.handleSweep,
  });

  final Color color;
  final double strokeWidth;
  final double circleDiameter;
  final Offset circleOffset;
  final double circleBorderStrokeWidth;
  final double handleSweep;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final circleRadius = math.max(
      0.0,
      (circleDiameter / 2) - (circleBorderStrokeWidth / 2),
    );
    final circleCenter = Offset(
      circleOffset.dx + (circleDiameter / 2),
      circleOffset.dy + (circleDiameter / 2),
    );
    final handleCenter = Offset(
      circleCenter.dx +
          (circleRadius * math.cos(_PlacedCircleAgentWidgetState._handleAngle)),
      circleCenter.dy +
          (circleRadius * math.sin(_PlacedCircleAgentWidgetState._handleAngle)),
    );

    canvas.save();
    canvas.translate(center.dx - handleCenter.dx, center.dy - handleCenter.dy);
    canvas.drawArc(
      Rect.fromCircle(center: circleCenter, radius: circleRadius),
      _PlacedCircleAgentWidgetState._handleAngle - (handleSweep / 2),
      handleSweep,
      false,
      paint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CircleResizeArcPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.circleDiameter != circleDiameter ||
        oldDelegate.circleOffset != circleOffset ||
        oldDelegate.circleBorderStrokeWidth != circleBorderStrokeWidth ||
        oldDelegate.handleSweep != handleSweep;
  }
}
