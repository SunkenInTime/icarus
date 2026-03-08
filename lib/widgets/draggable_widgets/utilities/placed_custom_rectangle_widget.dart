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
import 'package:icarus/widgets/draggable_widgets/utilities/custom_shape_resize_tooltip.dart';
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
  static const double _rectangleBorderStrokeVirtual = 2.0;

  double? _localWidthMeters;
  double? _localLengthMeters;
  double _widthDragOffsetMeters = 0;
  double _lengthDragOffsetMeters = 0;
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
    final rightHandleOverflow = coordinateSystem.scale(4);
    final bottomHandleOverflow = coordinateSystem.scale(4);

    return SizedBox(
      width: scaledLength + rightHandleOverflow,
      height: scaledWidth + bottomHandleOverflow,
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
              lengthMeters: lengthMeters,
            ),
          if (!_isDragging && !isScreenshot)
            _buildWidthHandle(
              coordinateSystem: coordinateSystem,
              scaledWidth: scaledWidth,
              scaledLength: scaledLength,
              mapScale: mapScale,
              widthMeters: widthMeters,
            ),
          if (!isScreenshot && _activeHandle != _RectangleResizeHandle.none)
            _buildResizeTooltip(
              coordinateSystem: coordinateSystem,
              scaledWidth: scaledWidth,
              scaledLength: scaledLength,
              widthMeters: widthMeters,
              lengthMeters: lengthMeters,
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
    required double lengthMeters,
  }) {
    final handleWidth = coordinateSystem.scale(8);
    final handleHeight = coordinateSystem.scale(28);
    final handleCenterX = _computeLengthHandleCenterX(
      coordinateSystem: coordinateSystem,
      scaledLength: scaledLength,
    );

    return Positioned(
      left: handleCenterX - (handleWidth / 2),
      top: (scaledWidth - handleHeight) / 2,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onPanStart: (details) {
            setState(() {
              _activeHandle = _RectangleResizeHandle.length;
              _lengthDragOffsetMeters = lengthMeters -
                  _estimateLengthMeters(details.globalPosition, mapScale);
            });
          },
          onPanUpdate: (details) =>
              _updateLength(details.globalPosition, mapScale),
          onPanEnd: (_) => _commitRectangleResize(),
          onPanCancel: _resetActiveHandle,
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
    required double widthMeters,
  }) {
    final handleWidth = coordinateSystem.scale(28);
    final handleHeight = coordinateSystem.scale(8);
    final handleCenterY = _computeWidthHandleCenterY(
      coordinateSystem: coordinateSystem,
      scaledWidth: scaledWidth,
    );

    return Positioned(
      left: (scaledLength - handleWidth) / 2,
      top: handleCenterY - (handleHeight / 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onPanStart: (details) {
            setState(() {
              _activeHandle = _RectangleResizeHandle.width;
              _widthDragOffsetMeters = widthMeters -
                  _estimateWidthMeters(details.globalPosition, mapScale);
            });
          },
          onPanUpdate: (details) =>
              _updateWidth(details.globalPosition, mapScale),
          onPanEnd: (_) => _commitRectangleResize(),
          onPanCancel: _resetActiveHandle,
          child: _ResizePill(
            width: handleWidth,
            height: handleHeight,
          ),
        ),
      ),
    );
  }

  void _updateLength(Offset globalPosition, double mapScale) {
    final nextLength = (_estimateLengthMeters(globalPosition, mapScale) +
            _lengthDragOffsetMeters)
        .clamp(_minLengthMeters, _maxLengthMeters);

    setState(() {
      _localLengthMeters = nextLength.toDouble();
    });
  }

  void _updateWidth(Offset globalPosition, double mapScale) {
    final nextWidth = (_estimateWidthMeters(globalPosition, mapScale) +
            _widthDragOffsetMeters)
        .clamp(_minWidthMeters, _maxWidthMeters);

    setState(() {
      _localWidthMeters = nextWidth.toDouble();
    });
  }

  double _estimateLengthMeters(Offset globalPosition, double mapScale) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return _localLengthMeters ?? _minLengthMeters;

    final coordinateSystem = CoordinateSystem.instance;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final localPosition = renderBox.globalToLocal(globalPosition);
    final lengthVirtual =
        coordinateSystem.normalize(math.max(localPosition.dx, 0));
    return (lengthVirtual / meterScale).toDouble();
  }

  double _estimateWidthMeters(Offset globalPosition, double mapScale) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return _localWidthMeters ?? _minWidthMeters;

    final coordinateSystem = CoordinateSystem.instance;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final localPosition = renderBox.globalToLocal(globalPosition);
    final widthVirtual =
        coordinateSystem.normalize(math.max(localPosition.dy, 0));
    return (widthVirtual / meterScale).toDouble();
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

    _resetActiveHandle();
  }

  void _resetActiveHandle() {
    setState(() {
      _activeHandle = _RectangleResizeHandle.none;
      _lengthDragOffsetMeters = 0;
      _widthDragOffsetMeters = 0;
    });
  }

  Widget _buildResizeTooltip({
    required CoordinateSystem coordinateSystem,
    required double scaledWidth,
    required double scaledLength,
    required double widthMeters,
    required double lengthMeters,
  }) {
    final handleCenter = _activeHandle == _RectangleResizeHandle.length
        ? Offset(
            _computeLengthHandleCenterX(
              coordinateSystem: coordinateSystem,
              scaledLength: scaledLength,
            ),
            scaledWidth / 2,
          )
        : Offset(
            scaledLength / 2,
            _computeWidthHandleCenterY(
              coordinateSystem: coordinateSystem,
              scaledWidth: scaledWidth,
            ),
          );
    final label = _activeHandle == _RectangleResizeHandle.length ? 'L' : 'W';
    final valueMeters = _activeHandle == _RectangleResizeHandle.length
        ? lengthMeters
        : widthMeters;
    final gap = coordinateSystem.scale(16);

    return Positioned(
      left: handleCenter.dx,
      top: handleCenter.dy - gap,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -1.0),
        child: CustomShapeResizeTooltip(
          label: label,
          valueMeters: valueMeters,
        ),
      ),
    );
  }

  double _computeLengthHandleCenterX({
    required CoordinateSystem coordinateSystem,
    required double scaledLength,
  }) {
    return scaledLength -
        (_computeRectangleBorderStrokeWidth(coordinateSystem) / 2);
  }

  double _computeWidthHandleCenterY({
    required CoordinateSystem coordinateSystem,
    required double scaledWidth,
  }) {
    return scaledWidth -
        (_computeRectangleBorderStrokeWidth(coordinateSystem) / 2);
  }

  double _computeRectangleBorderStrokeWidth(CoordinateSystem coordinateSystem) {
    return coordinateSystem.scale(_rectangleBorderStrokeVirtual);
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
