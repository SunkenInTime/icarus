import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/debug/debug_log.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_circle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

class PlacedCustomCircleWidget extends ConsumerStatefulWidget {
  const PlacedCustomCircleWidget({
    super.key,
    required this.utility,
    required this.id,
    required this.onDragEnd,
  });

  final PlacedUtility utility;
  final String id;
  final void Function(DraggableDetails details) onDragEnd;

  @override
  ConsumerState<PlacedCustomCircleWidget> createState() =>
      _PlacedCustomCircleWidgetState();
}

class _PlacedCustomCircleWidgetState
    extends ConsumerState<PlacedCustomCircleWidget> {
  static const double _minDiameterMeters = 1.0;
  static const double _maxDiameterMeters = 40.0;
  static const double _handleAngle = math.pi / 4;
  static const double _handleSweep = math.pi / 5;

  double? _localDiameterMeters;
  bool _isDragging = false;
  bool _isResizing = false;
  bool _isResizePointerActive = false;
  Timer? _tooltipTimer;

  @override
  void initState() {
    super.initState();
    _localDiameterMeters = widget.utility.customDiameter;
  }

  @override
  void dispose() {
    _tooltipTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final currentMap =
        ref.watch(mapProvider.select((state) => state.currentMap));
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final isScreenshot = ref.watch(screenshotProvider);
    final utilities = ref.watch(utilityProvider);
    final index = PlacedWidget.getIndexByID(widget.id, utilities);

    if (index < 0) {
      return const SizedBox.shrink();
    }

    final utilityRef = utilities[index];
    final providerDiameterMeters = utilityRef.customDiameter;
    if (providerDiameterMeters == null) {
      return const SizedBox.shrink();
    }

    if (!_isResizing && !_isDragging && _localDiameterMeters != providerDiameterMeters) {
      _localDiameterMeters = providerDiameterMeters;
    }

    final diameterMeters = _localDiameterMeters ?? providerDiameterMeters;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final scaledDiameter = coordinateSystem.scale(diameterMeters * meterScale);

    if (_isResizing || _isDragging) {
      // #region agent log
      appendDebugLog(
        hypothesisId: 'B',
        location: 'placed_custom_circle_widget.dart:${85 + 1}',
        message: 'Circle widget rebuild during resize state',
        data: <String, Object?>{
          'id': widget.id,
          'isResizing': _isResizing,
          'isDragging': _isDragging,
          'isScreenshot': isScreenshot,
          'diameterMeters': diameterMeters,
          'scaledDiameter': scaledDiameter,
        },
      );
      // #endregion
    }

    return SizedBox(
      width: scaledDiameter,
      height: scaledDiameter,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _buildDraggableBody(
            utilityRef: utilityRef,
            diameterMeters: diameterMeters,
            mapScale: mapScale,
          ),
            if (!_isDragging && !isScreenshot)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _CircleResizeArcPainter(
                      color: Colors.white,
                      strokeWidth: coordinateSystem.scale(4),
                    ),
                  ),
                ),
              ),
            if (!_isDragging && !isScreenshot)
              _buildCircleHandle(
                coordinateSystem: coordinateSystem,
                scaledDiameter: scaledDiameter,
                mapScale: mapScale,
              ),
            if (_isResizing)
              _buildCircleTooltip(
                diameterMeters: diameterMeters,
              ),
        ],
      ),
    );
  }

  Widget _buildDraggableBody({
    required PlacedUtility utilityRef,
    required double diameterMeters,
    required double mapScale,
  }) {
    return Draggable<PlacedUtility>(
      data: utilityRef,
      dragAnchorStrategy:
          ref.read(screenZoomProvider.notifier).zoomDragAnchorStrategy,
      feedback: Opacity(
        opacity: Settings.feedbackOpacity,
        child: ZoomTransform(
          child: CustomCircleUtilityWidget(
            id: null,
            diameterMeters: diameterMeters,
            colorValue: utilityRef.customColorValue,
            opacityPercent: utilityRef.customOpacityPercent,
            mapScale: mapScale,
          ),
        ),
      ),
      childWhenDragging: const SizedBox.shrink(),
      onDragStarted: () {
        setState(() {
          _isDragging = true;
        });
      },
      onDragEnd: (details) {
        widget.onDragEnd(details);
        setState(() {
          _isDragging = false;
        });
      },
      child: CustomCircleUtilityWidget(
        id: widget.id,
        diameterMeters: diameterMeters,
        colorValue: utilityRef.customColorValue,
        opacityPercent: utilityRef.customOpacityPercent,
        mapScale: mapScale,
      ),
    );
  }

  Widget _buildCircleHandle({
    required CoordinateSystem coordinateSystem,
    required double scaledDiameter,
    required double mapScale,
  }) {
    final radius = scaledDiameter / 2;
    final handleCenter = Offset(
      radius + (radius * math.cos(_handleAngle)),
      radius + (radius * math.sin(_handleAngle)),
    );
    final hitSize = coordinateSystem.scale(28);

    return Positioned(
      left: handleCenter.dx - (hitSize / 2),
      top: handleCenter.dy - (hitSize / 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _beginCircleResize(),
          onPointerMove: (event) {
            if (_isResizePointerActive) {
              _updateDiameter(event.position, mapScale);
            }
          },
          onPointerUp: (_) => _commitCircleResize(),
          onPointerCancel: (_) => _commitCircleResize(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {
              log('CIRCLE_PAN_START');
              _tooltipTimer?.cancel();
              // #region agent log
              appendDebugLog(
                hypothesisId: 'A',
                location: 'placed_custom_circle_widget.dart:${187 + 1}',
                message: 'Circle resize handle pan start',
                data: <String, Object?>{
                  'id': widget.id,
                  'wasResizing': _isResizing,
                  'localDiameterMeters': _localDiameterMeters,
                },
              );
              // #endregion
              _beginCircleResize();
            },
            onPanUpdate: (details) =>
                _updateDiameter(details.globalPosition, mapScale),
            onPanEnd: (_) => _commitCircleResize(),
            child: SizedBox(width: hitSize, height: hitSize),
          ),
        ),
      ),
    );
  }

  Widget _buildCircleTooltip({
    required double diameterMeters,
  }) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.center,
          child: _ResizeTooltip(
            label: 'Diameter',
            valueMeters: diameterMeters,
          ),
        ),
      ),
    );
  }

  void _updateDiameter(Offset globalPosition, double mapScale) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final coordinateSystem = CoordinateSystem.instance;
    final zoom = ref.read(screenZoomProvider);
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final localPosition = renderBox.globalToLocal(globalPosition);
    final localVirtual = Offset(
      coordinateSystem.normalize(math.max(localPosition.dx, 0)) / zoom,
      coordinateSystem.normalize(math.max(localPosition.dy, 0)) / zoom,
    );

    final radiusEstimateX = localVirtual.dx / (1 + math.cos(_handleAngle));
    final radiusEstimateY = localVirtual.dy / (1 + math.sin(_handleAngle));
    final radiusVirtual = math.max((radiusEstimateX + radiusEstimateY) / 2, 0.0);
    final nextDiameter = ((radiusVirtual * 2) / meterScale)
        .clamp(_minDiameterMeters, _maxDiameterMeters);

    setState(() {
      _isResizePointerActive = true;
      _isResizing = true;
      _localDiameterMeters = nextDiameter.toDouble();
    });
  }

  void _commitCircleResize() {
    if (!_isResizing || !_isResizePointerActive) {
      return;
    }

    final diameterMeters = _localDiameterMeters;
    if (diameterMeters != null) {
      log('CIRCLE_RESIZE_COMMIT diameter=$diameterMeters');
      // #region agent log
      appendDebugLog(
        hypothesisId: 'D',
        location: 'placed_custom_circle_widget.dart:${243 + 1}',
        message: 'Circle resize commit requested',
        data: <String, Object?>{
          'id': widget.id,
          'diameterMeters': diameterMeters,
          'isResizing': _isResizing,
        },
      );
      // #endregion
      ref.read(utilityProvider.notifier).updateCustomCircleDiameter(
            id: widget.id,
            diameterMeters: diameterMeters,
          );
    }

    _tooltipTimer?.cancel();
    _isResizePointerActive = false;
    _tooltipTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() {
        _isResizing = false;
      });
    });
  }

  void _beginCircleResize() {
    _tooltipTimer?.cancel();
    setState(() {
      _isResizePointerActive = true;
      _isResizing = true;
    });
  }
}

class _CircleResizeArcPainter extends CustomPainter {
  const _CircleResizeArcPainter({
    required this.color,
    required this.strokeWidth,
  });

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      rect,
      _PlacedCustomCircleWidgetState._handleAngle -
          (_PlacedCustomCircleWidgetState._handleSweep / 2),
      _PlacedCustomCircleWidgetState._handleSweep,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CircleResizeArcPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

class _ResizeTooltip extends StatelessWidget {
  const _ResizeTooltip({
    required this.label,
    required this.valueMeters,
  });

  final String label;
  final double valueMeters;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white70, width: 1.5),
      ),
      child: Text(
        '$label ${valueMeters.toStringAsFixed(1)} m',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
