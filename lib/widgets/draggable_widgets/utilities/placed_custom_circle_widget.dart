import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
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

    if (!_isDragging && _localDiameterMeters != providerDiameterMeters) {
      _localDiameterMeters = providerDiameterMeters;
    }

    final diameterMeters = _localDiameterMeters ?? providerDiameterMeters;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final scaledDiameter = coordinateSystem.scale(diameterMeters * meterScale);

    return SizedBox(
      width: scaledDiameter,
      height: scaledDiameter,
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
          if (!isScreenshot)
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Transform.translate(
                    offset: Offset(0, -coordinateSystem.scale(8)),
                    child: _ResizeBadge(
                      label: 'D',
                      valueMeters: diameterMeters,
                    ),
                  ),
                ),
              ),
            ),
        ],
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
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) =>
              _updateDiameter(details.globalPosition, mapScale),
          onPanEnd: (_) => _commitCircleResize(),
          child: SizedBox(width: hitSize, height: hitSize),
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
      _localDiameterMeters = nextDiameter.toDouble();
    });
  }

  void _commitCircleResize() {
    final diameterMeters = _localDiameterMeters;
    if (diameterMeters != null) {
      ref.read(utilityProvider.notifier).updateCustomCircleDiameter(
            id: widget.id,
            diameterMeters: diameterMeters,
          );
    }
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

class _ResizeBadge extends StatelessWidget {
  const _ResizeBadge({
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
