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
import 'package:icarus/widgets/draggable_widgets/utilities/custom_rectangle_utility_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

enum _RectangleResizeHandle { none, length, width }

class PlacedCustomRectangleWidget extends ConsumerStatefulWidget {
  const PlacedCustomRectangleWidget({
    super.key,
    required this.utility,
    required this.id,
    required this.onDragEnd,
  });

  final PlacedUtility utility;
  final String id;
  final void Function(DraggableDetails details) onDragEnd;

  @override
  ConsumerState<PlacedCustomRectangleWidget> createState() =>
      _PlacedCustomRectangleWidgetState();
}

class _PlacedCustomRectangleWidgetState
    extends ConsumerState<PlacedCustomRectangleWidget> {
  static const double _minWidthMeters = 0.5;
  static const double _maxWidthMeters = 30.0;
  static const double _minLengthMeters = 1.0;
  static const double _maxLengthMeters = 60.0;

  double? _localWidthMeters;
  double? _localLengthMeters;
  bool _isDragging = false;
  _RectangleResizeHandle _activeHandle = _RectangleResizeHandle.none;

  @override
  void initState() {
    super.initState();
    _localWidthMeters = widget.utility.customWidth;
    _localLengthMeters = widget.utility.customLength;
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
    final providerWidthMeters = utilityRef.customWidth;
    final providerLengthMeters = utilityRef.customLength;
    if (providerWidthMeters == null || providerLengthMeters == null) {
      return const SizedBox.shrink();
    }

    if (_activeHandle == _RectangleResizeHandle.none && !_isDragging) {
      if (_localWidthMeters != providerWidthMeters) {
        _localWidthMeters = providerWidthMeters;
      }
      if (_localLengthMeters != providerLengthMeters) {
        _localLengthMeters = providerLengthMeters;
      }
    }

    final widthMeters = _localWidthMeters ?? providerWidthMeters;
    final lengthMeters = _localLengthMeters ?? providerLengthMeters;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final scaledWidth = coordinateSystem.scale(widthMeters * meterScale);
    final scaledLength = coordinateSystem.scale(lengthMeters * meterScale);

    return SizedBox(
      width: scaledLength,
      height: scaledWidth,
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
                child: CustomRectangleUtilityWidget(
                  id: null,
                  widthMeters: widthMeters,
                  rectLengthMeters: lengthMeters,
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
            child: CustomRectangleUtilityWidget(
              id: widget.id,
              widthMeters: widthMeters,
              rectLengthMeters: lengthMeters,
              colorValue: utilityRef.customColorValue,
              opacityPercent: utilityRef.customOpacityPercent,
              mapScale: mapScale,
            ),
          ),
          if (!_isDragging && !isScreenshot)
            _buildLengthHandle(
              coordinateSystem: coordinateSystem,
              scaledWidth: scaledWidth,
              scaledLength: scaledLength,
              mapScale: mapScale,
            ),
          if (!_isDragging && !isScreenshot)
            _buildWidthHandle(
              coordinateSystem: coordinateSystem,
              scaledWidth: scaledWidth,
              scaledLength: scaledLength,
              mapScale: mapScale,
            ),
          if (!isScreenshot)
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Transform.translate(
                    offset: Offset(0, coordinateSystem.scale(20)),
                    child: _ResizeBadge(
                      label: 'L',
                      valueMeters: lengthMeters,
                    ),
                  ),
                ),
              ),
            ),
          if (!isScreenshot)
            Positioned.fill(
              child: IgnorePointer(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Transform.translate(
                    offset: Offset(coordinateSystem.scale(54), 0),
                    child: _ResizeBadge(
                      label: 'W',
                      valueMeters: widthMeters,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLengthHandle({
    required CoordinateSystem coordinateSystem,
    required double scaledWidth,
    required double scaledLength,
    required double mapScale,
  }) {
    final handleWidth = coordinateSystem.scale(28);
    final handleHeight = coordinateSystem.scale(8);

    return Positioned(
      left: (scaledLength - handleWidth) / 2,
      top: scaledWidth - (handleHeight / 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            setState(() {
              _activeHandle = _RectangleResizeHandle.length;
            });
          },
          onPanUpdate: (details) =>
              _updateLength(details.globalPosition, mapScale),
          onPanEnd: (_) => _commitRectangleResize(),
          child: _ResizePill(
            width: handleWidth,
            height: handleHeight,
          ),
        ),
      ),
    );
  }

  Widget _buildWidthHandle({
    required CoordinateSystem coordinateSystem,
    required double scaledWidth,
    required double scaledLength,
    required double mapScale,
  }) {
    final handleWidth = coordinateSystem.scale(8);
    final handleHeight = coordinateSystem.scale(28);

    return Positioned(
      left: scaledLength - (handleWidth / 2),
      top: (scaledWidth - handleHeight) / 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            setState(() {
              _activeHandle = _RectangleResizeHandle.width;
            });
          },
          onPanUpdate: (details) =>
              _updateWidth(details.globalPosition, mapScale),
          onPanEnd: (_) => _commitRectangleResize(),
          child: _ResizePill(
            width: handleWidth,
            height: handleHeight,
          ),
        ),
      ),
    );
  }

  void _updateLength(Offset globalPosition, double mapScale) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final coordinateSystem = CoordinateSystem.instance;
    final zoom = ref.read(screenZoomProvider);
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final localPosition = renderBox.globalToLocal(globalPosition);
    final halfLengthVirtual =
        coordinateSystem.normalize(math.max(localPosition.dx, 0)) / zoom;
    final nextLength = (halfLengthVirtual * 2 / meterScale)
        .clamp(_minLengthMeters, _maxLengthMeters);

    setState(() {
      _localLengthMeters = nextLength.toDouble();
    });
  }

  void _updateWidth(Offset globalPosition, double mapScale) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final coordinateSystem = CoordinateSystem.instance;
    final zoom = ref.read(screenZoomProvider);
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final localPosition = renderBox.globalToLocal(globalPosition);
    final halfWidthVirtual =
        coordinateSystem.normalize(math.max(localPosition.dy, 0)) / zoom;
    final nextWidth =
        (halfWidthVirtual * 2 / meterScale).clamp(_minWidthMeters, _maxWidthMeters);

    setState(() {
      _localWidthMeters = nextWidth.toDouble();
    });
  }

  void _commitRectangleResize() {
    final widthMeters = _localWidthMeters;
    final lengthMeters = _localLengthMeters;
    if (widthMeters != null && lengthMeters != null) {
      ref.read(utilityProvider.notifier).updateCustomRectangleSize(
            id: widget.id,
            widthMeters: widthMeters,
            lengthMeters: lengthMeters,
          );
    }

    setState(() {
      _activeHandle = _RectangleResizeHandle.none;
    });
  }
}

class _ResizePill extends StatelessWidget {
  const _ResizePill({
    required this.width,
    required this.height,
  });

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
    );
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
