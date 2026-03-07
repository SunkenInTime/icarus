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
  bool _isResizePointerActive = false;
  _RectangleResizeHandle _activeHandle = _RectangleResizeHandle.none;
  Timer? _tooltipTimer;

  @override
  void initState() {
    super.initState();
    _localWidthMeters = widget.utility.customWidth;
    _localLengthMeters = widget.utility.customLength;
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

    if (_activeHandle != _RectangleResizeHandle.none || _isDragging) {
      // #region agent log
      appendDebugLog(
        hypothesisId: 'B',
        location:
            'placed_custom_rectangle_widget.dart:${97 + 1}',
        message: 'Rectangle widget rebuild during resize state',
        data: <String, Object?>{
          'id': widget.id,
          'activeHandle': _activeHandle.name,
          'isDragging': _isDragging,
          'isScreenshot': isScreenshot,
          'widthMeters': widthMeters,
          'lengthMeters': lengthMeters,
          'scaledWidth': scaledWidth,
          'scaledLength': scaledLength,
        },
      );
      // #endregion
    }

    return SizedBox(
      width: scaledLength,
      height: scaledWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _buildDraggableBody(
            utilityRef: utilityRef,
            widthMeters: widthMeters,
            lengthMeters: lengthMeters,
            mapScale: mapScale,
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
            if (_activeHandle == _RectangleResizeHandle.length)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment.center,
                    child: _ResizeTooltip(
                      label: 'Length',
                      valueMeters: lengthMeters,
                    ),
                  ),
                ),
              ),
            if (_activeHandle == _RectangleResizeHandle.width)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment.center,
                    child: _ResizeTooltip(
                      label: 'Width',
                      valueMeters: widthMeters,
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildDraggableBody({
    required PlacedUtility utilityRef,
    required double widthMeters,
    required double lengthMeters,
    required double mapScale,
  }) {
    return Draggable<PlacedUtility>(
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
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _beginRectangleResize(_RectangleResizeHandle.length),
          onPointerMove: (event) {
            if (_isResizePointerActive) {
              _updateLength(event.position, mapScale);
            }
          },
          onPointerUp: (_) => _commitRectangleResize(),
          onPointerCancel: (_) => _commitRectangleResize(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {
              log('RECT_LENGTH_PAN_START');
              _tooltipTimer?.cancel();
              // #region agent log
              appendDebugLog(
                hypothesisId: 'A',
                location:
                    'placed_custom_rectangle_widget.dart:${217 + 1}',
                message: 'Rectangle length handle pan start',
                data: <String, Object?>{
                  'id': widget.id,
                  'previousHandle': _activeHandle.name,
                  'localLengthMeters': _localLengthMeters,
                },
              );
              // #endregion
              _beginRectangleResize(_RectangleResizeHandle.length);
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
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _beginRectangleResize(_RectangleResizeHandle.width),
          onPointerMove: (event) {
            if (_isResizePointerActive) {
              _updateWidth(event.position, mapScale);
            }
          },
          onPointerUp: (_) => _commitRectangleResize(),
          onPointerCancel: (_) => _commitRectangleResize(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {
              log('RECT_WIDTH_PAN_START');
              _tooltipTimer?.cancel();
              // #region agent log
              appendDebugLog(
                hypothesisId: 'A',
                location:
                    'placed_custom_rectangle_widget.dart:${251 + 1}',
                message: 'Rectangle width handle pan start',
                data: <String, Object?>{
                  'id': widget.id,
                  'previousHandle': _activeHandle.name,
                  'localWidthMeters': _localWidthMeters,
                },
              );
              // #endregion
              _beginRectangleResize(_RectangleResizeHandle.width);
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
      _isResizePointerActive = true;
      _activeHandle = _RectangleResizeHandle.length;
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
      _isResizePointerActive = true;
      _activeHandle = _RectangleResizeHandle.width;
      _localWidthMeters = nextWidth.toDouble();
    });
  }

  void _commitRectangleResize() {
    if (_activeHandle == _RectangleResizeHandle.none || !_isResizePointerActive) {
      return;
    }

    final widthMeters = _localWidthMeters;
    final lengthMeters = _localLengthMeters;
    if (widthMeters != null && lengthMeters != null) {
      log('RECT_RESIZE_COMMIT width=$widthMeters length=$lengthMeters');
      ref.read(utilityProvider.notifier).updateCustomRectangleSize(
            id: widget.id,
            widthMeters: widthMeters,
            lengthMeters: lengthMeters,
          );
    }

    _tooltipTimer?.cancel();
    _isResizePointerActive = false;
    _tooltipTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) return;
      setState(() {
        _activeHandle = _RectangleResizeHandle.none;
      });
    });
  }

  void _beginRectangleResize(_RectangleResizeHandle handle) {
    _tooltipTimer?.cancel();
    setState(() {
      _isResizePointerActive = true;
      _activeHandle = handle;
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
