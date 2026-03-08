import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_circle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/custom_shape_resize_tooltip.dart';
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

  @override
  void initState() {
    super.initState();
    _localDiameterMeters = widget.utility.customDiameter;
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

    if (!_isDragging &&
        !_isResizing &&
        _localDiameterMeters != providerDiameterMeters) {
      _localDiameterMeters = providerDiameterMeters;
    }

    final diameterMeters = _localDiameterMeters ?? providerDiameterMeters;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final scaledDiameter = coordinateSystem.scale(diameterMeters * meterScale);
    final scaledMaxDiameter = coordinateSystem.scale(
      CustomCircleUtility.maxDiameterInVirtual(mapScale),
    );
    final circleInset = (scaledMaxDiameter - scaledDiameter) / 2;
    final arcRegionSize = coordinateSystem.scale(32);
    final handleCenter = _computeHandleCenter(
      coordinateSystem: coordinateSystem,
      scaledDiameter: scaledDiameter,
      scaledMaxDiameter: scaledMaxDiameter,
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

    return SizedBox(
      width: scaledMaxDiameter + rightOverflow,
      height: scaledMaxDiameter + bottomOverflow,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Draggable<PlacedUtility>(
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
          ),
          if (!_isDragging && !isScreenshot)
            _buildCircleHandle(
              coordinateSystem: coordinateSystem,
              scaledDiameter: scaledDiameter,
              scaledMaxDiameter: scaledMaxDiameter,
              circleInset: circleInset,
              mapScale: mapScale,
              arcRegionSize: arcRegionSize,
              arcRegionLeft: arcRegionLeft,
              arcRegionTop: arcRegionTop,
              diameterMeters: diameterMeters,
            ),
          if (!isScreenshot && _isResizing)
            _buildResizeTooltip(
              coordinateSystem: coordinateSystem,
              scaledDiameter: scaledDiameter,
              scaledMaxDiameter: scaledMaxDiameter,
              diameterMeters: diameterMeters,
            ),
        ],
      ),
    );
  }

  Widget _buildCircleHandle({
    required CoordinateSystem coordinateSystem,
    required double scaledDiameter,
    required double scaledMaxDiameter,
    required double circleInset,
    required double mapScale,
    required double arcRegionSize,
    required double arcRegionLeft,
    required double arcRegionTop,
    required double diameterMeters,
  }) {
    final strokeWidth = coordinateSystem.scale(_handleStrokeWidthVirtual);
    final circleBorderStrokeWidth =
        coordinateSystem.scale(_circleBorderStrokeVirtual);
    final handleSweep = _computeHandleSweep(
      coordinateSystem: coordinateSystem,
      scaledDiameter: scaledDiameter,
    );

    return Positioned(
      left: arcRegionLeft,
      top: arcRegionTop,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpLeftDownRight,
        onEnter: (_) {
          setState(() {
            _isHandleHovered = true;
          });
        },
        onExit: (_) {
          setState(() {
            _isHandleHovered = false;
          });
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _startCircleResize(
            globalPosition: details.globalPosition,
            mapScale: mapScale,
            diameterMeters: diameterMeters,
          ),
          onPanUpdate: (details) =>
              _updateDiameter(details.globalPosition, mapScale),
          onPanEnd: (_) => _finishCircleResize(),
          onPanCancel: _cancelCircleResize,
          child: SizedBox(
            width: arcRegionSize,
            height: arcRegionSize,
            child: Center(
              child: IgnorePointer(
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  scale: _isResizing || _isHandleHovered ? 1.0 : 0.9,
                  child: CustomPaint(
                    size: Size(arcRegionSize, arcRegionSize),
                    painter: _CircleResizeArcPainter(
                      color: Colors.white,
                      strokeWidth: strokeWidth,
                      circleDiameter: scaledDiameter,
                      circleOffset: Offset(circleInset - arcRegionLeft,
                          circleInset - arcRegionTop),
                      circleBorderStrokeWidth: circleBorderStrokeWidth,
                      handleSweep: handleSweep,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
    required double scaledMaxDiameter,
  }) {
    final radius = _computeCircleBorderRadius(
      coordinateSystem: coordinateSystem,
      scaledDiameter: scaledDiameter,
    );
    final center = scaledMaxDiameter / 2;
    return Offset(
      center + (radius * math.cos(_handleAngle)),
      center + (radius * math.sin(_handleAngle)),
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
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final scaledMaxDiameter = coordinateSystem.scale(
      CustomCircleUtility.maxDiameterInVirtual(mapScale),
    );
    final localPosition = renderBox.globalToLocal(globalPosition);
    final localCenter = Offset(scaledMaxDiameter / 2, scaledMaxDiameter / 2);
    final deltaFromCenter = localPosition - localCenter;
    final deltaVirtual = Offset(
      coordinateSystem.normalize(deltaFromCenter.dx),
      coordinateSystem.normalize(deltaFromCenter.dy),
    );

    final radiusEstimateX = deltaVirtual.dx / math.cos(_handleAngle);
    final radiusEstimateY = deltaVirtual.dy / math.sin(_handleAngle);
    final radiusVirtual =
        math.max((radiusEstimateX + radiusEstimateY) / 2, 0.0);
    return ((radiusVirtual * 2) / meterScale).toDouble();
  }

  void _finishCircleResize() {
    final diameterMeters = _localDiameterMeters;
    if (diameterMeters != null) {
      ref.read(utilityProvider.notifier).updateCustomCircleDiameter(
            id: widget.id,
            diameterMeters: diameterMeters,
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

  Widget _buildResizeTooltip({
    required CoordinateSystem coordinateSystem,
    required double scaledDiameter,
    required double scaledMaxDiameter,
    required double diameterMeters,
  }) {
    final handleCenter = _computeHandleCenter(
      coordinateSystem: coordinateSystem,
      scaledDiameter: scaledDiameter,
      scaledMaxDiameter: scaledMaxDiameter,
    );
    final gap = coordinateSystem.scale(16);

    return Positioned(
      left: handleCenter.dx,
      top: handleCenter.dy - gap,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -1.0),
        child: CustomShapeResizeTooltip(
          label: 'D',
          valueMeters: diameterMeters,
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
    final rect = Rect.fromLTWH(
      circleOffset.dx + (circleBorderStrokeWidth / 2),
      circleOffset.dy + (circleBorderStrokeWidth / 2),
      circleDiameter - circleBorderStrokeWidth,
      circleDiameter - circleBorderStrokeWidth,
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      rect,
      _PlacedCustomCircleWidgetState._handleAngle - (handleSweep / 2),
      handleSweep,
      false,
      paint,
    );
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
