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
import 'package:icarus/widgets/draggable_widgets/utilities/rectangle_corner_resize_geometry.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/shape_indicator_fade.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

enum _RectangleResizeHandle { none, length, width, corner }

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
  static const double _rotationSnapStep = math.pi / 4;
  static const double _rotationSnapTolerance = 3 * math.pi / 180;
  static const List<Offset> _corners = [
    Offset(0, 0),
    Offset(1, 0),
    Offset(0, 1),
    Offset(1, 1),
  ];

  /// Render box of the unrotated shape itself, used to translate global
  /// pointer positions into shape-local space regardless of rotation.
  final GlobalKey _shapeKey = GlobalKey();

  double? _localWidthMeters;
  double? _localLengthMeters;
  double? _localRotation;
  double _widthDragOffsetMeters = 0;
  double _lengthDragOffsetMeters = 0;
  Offset _cornerPositionDeltaScreen = Offset.zero;
  Offset _cornerStartTopLeftGlobal = Offset.zero;
  Offset _cornerFixedGlobal = Offset.zero;
  Offset _cornerStartStoredPosition = Offset.zero;
  double _cornerGlobalScale = 1;
  bool _isDragging = false;
  bool _isShapeHovered = false;
  _RectangleResizeHandle _activeHandle = _RectangleResizeHandle.none;
  bool _isLengthHandleHovered = false;
  bool _isWidthHandleHovered = false;
  Offset? _activeResizeCorner;
  Offset? _hoveredResizeCorner;
  bool _isRotating = false;
  Offset? _rotatingCorner;
  Offset? _hoveredRotationCorner;
  Offset _rotationCenterGlobal = Offset.zero;
  double _rotationPointerStartAngle = 0;
  double _rotationStartValue = 0;

  @override
  void initState() {
    super.initState();
    _localWidthMeters = widget.utility.customWidth;
    _localLengthMeters = widget.utility.customLength;
    _localRotation = widget.utility.rotation;
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
    if (!_isRotating && _localRotation != utilityRef.rotation) {
      _localRotation = utilityRef.rotation;
    }

    final widthMeters = _localWidthMeters ?? providerWidthMeters;
    final lengthMeters = _localLengthMeters ?? providerLengthMeters;
    final rotation = _localRotation ?? utilityRef.rotation;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final scaledWidth = coordinateSystem.scale(widthMeters * meterScale);
    final scaledLength = coordinateSystem.scale(lengthMeters * meterScale);

    // The layout box is a square large enough to contain the shape at any
    // rotation plus the handle overhang, so every handle stays hit-testable.
    // It is centered on the shape via the translate below, which keeps the
    // shape's unrotated top-left exactly at the stored position.
    final handlePad = coordinateSystem.scale(
      Settings.shapeRotationHandleOffset +
          (Settings.shapeRotationHandleSize / 2) +
          Settings.shapeHandleHitPadding,
    );
    final diagonal = math.sqrt(
      (scaledLength * scaledLength) + (scaledWidth * scaledWidth),
    );
    final outerSize = diagonal + (2 * handlePad);
    final insetX = (outerSize - scaledLength) / 2;
    final insetY = (outerSize - scaledWidth) / 2;

    final showIndicators = !_isDragging &&
        !isScreenshot &&
        (_isShapeHovered ||
            _isRotating ||
            _activeHandle != _RectangleResizeHandle.none);

    return Transform.translate(
      offset: Offset(-insetX, -insetY) + _cornerPositionDeltaScreen,
      child: SizedBox(
        width: outerSize,
        height: outerSize,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Transform.rotate(
                angle: rotation,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: insetX,
                      top: insetY,
                      child: Draggable<PlacedUtility>(
                        data: utilityRef,
                        dragAnchorStrategy: ref
                            .read(screenZoomProvider.notifier)
                            .zoomDragAnchorStrategy,
                        feedback: Opacity(
                          opacity: Settings.feedbackOpacity,
                          child: ZoomTransform(
                            child: Transform.rotate(
                              angle: rotation,
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
                        child: KeyedSubtree(
                          key: _shapeKey,
                          child: CustomRectangleUtilityWidget(
                            id: widget.id,
                            widthMeters: widthMeters,
                            rectLengthMeters: lengthMeters,
                            colorValue: utilityRef.customColorValue,
                            opacityPercent: utilityRef.customOpacityPercent,
                            mapScale: mapScale,
                            centerMarkerVisible: showIndicators,
                          ),
                        ),
                      ),
                    ),
                    if (!_isDragging && !isScreenshot) ...[
                      _buildLengthHandle(
                        coordinateSystem: coordinateSystem,
                        scaledWidth: scaledWidth,
                        scaledLength: scaledLength,
                        insetX: insetX,
                        insetY: insetY,
                        mapScale: mapScale,
                        lengthMeters: lengthMeters,
                        showIndicators: showIndicators,
                      ),
                      _buildWidthHandle(
                        coordinateSystem: coordinateSystem,
                        scaledWidth: scaledWidth,
                        scaledLength: scaledLength,
                        insetX: insetX,
                        insetY: insetY,
                        mapScale: mapScale,
                        widthMeters: widthMeters,
                        showIndicators: showIndicators,
                      ),
                      for (final corner in _corners)
                        _buildCornerResizeHandle(
                          coordinateSystem: coordinateSystem,
                          corner: corner,
                          scaledWidth: scaledWidth,
                          scaledLength: scaledLength,
                          insetX: insetX,
                          insetY: insetY,
                          mapScale: mapScale,
                          rotation: rotation,
                          showIndicators: showIndicators,
                        ),
                      for (final corner in _corners)
                        _buildRotationHandle(
                          coordinateSystem: coordinateSystem,
                          corner: corner,
                          scaledWidth: scaledWidth,
                          scaledLength: scaledLength,
                          insetX: insetX,
                          insetY: insetY,
                          showIndicators: showIndicators,
                        ),
                    ],
                    // Topmost and translucent: reveals the handles when the
                    // pointer is anywhere over the shape without stealing
                    // events from the handles, the marker, or the map below.
                    Positioned(
                      left: insetX - handlePad,
                      top: insetY - handlePad,
                      width: scaledLength + (2 * handlePad),
                      height: scaledWidth + (2 * handlePad),
                      child: MouseRegion(
                        opaque: false,
                        onEnter: (_) {
                          setState(() {
                            _isShapeHovered = true;
                          });
                        },
                        onExit: (_) {
                          setState(() {
                            _isShapeHovered = false;
                          });
                        },
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!isScreenshot && _activeHandle != _RectangleResizeHandle.none)
              _buildResizeTooltip(
                coordinateSystem: coordinateSystem,
                scaledWidth: scaledWidth,
                scaledLength: scaledLength,
                widthMeters: widthMeters,
                lengthMeters: lengthMeters,
                rotation: rotation,
                outerSize: outerSize,
              ),
            if (!isScreenshot && _isRotating)
              _buildRotationTooltip(
                coordinateSystem: coordinateSystem,
                scaledWidth: scaledWidth,
                scaledLength: scaledLength,
                rotation: rotation,
                outerSize: outerSize,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLengthHandle({
    required CoordinateSystem coordinateSystem,
    required double scaledWidth,
    required double scaledLength,
    required double insetX,
    required double insetY,
    required double mapScale,
    required double lengthMeters,
    required bool showIndicators,
  }) {
    final pillThickness = coordinateSystem.scale(Settings.shapeHandleThickness);
    final pillLength = coordinateSystem.scale(Settings.shapeHandleLength);
    final hitPadding = coordinateSystem.scale(Settings.shapeHandleHitPadding);
    final hitWidth = pillThickness + (2 * hitPadding);
    final hitHeight = pillLength + (2 * hitPadding);
    final handleCenterX = _computeLengthHandleCenterX(
      coordinateSystem: coordinateSystem,
      scaledLength: scaledLength,
    );

    return Positioned(
      left: insetX + handleCenterX - (hitWidth / 2),
      top: insetY + ((scaledWidth - hitHeight) / 2),
      child: ShapeIndicatorFade(
        visible: showIndicators,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          onEnter: (_) {
            setState(() {
              _isLengthHandleHovered = true;
            });
          },
          onExit: (_) {
            setState(() {
              _isLengthHandleHovered = false;
            });
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) {
              setState(() {
                _activeHandle = _RectangleResizeHandle.length;
                _isLengthHandleHovered = true;
                _lengthDragOffsetMeters = lengthMeters -
                    _estimateLengthMeters(details.globalPosition, mapScale);
              });
            },
            onPanUpdate: (details) =>
                _updateLength(details.globalPosition, mapScale),
            onPanEnd: (_) => _commitRectangleResize(),
            onPanCancel: _resetActiveHandle,
            child: SizedBox(
              width: hitWidth,
              height: hitHeight,
              child: Center(
                child: _ResizePill(
                  width: pillThickness,
                  height: pillLength,
                  isActive: _activeHandle == _RectangleResizeHandle.length ||
                      _isLengthHandleHovered,
                ),
              ),
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
    required double insetX,
    required double insetY,
    required double mapScale,
    required double widthMeters,
    required bool showIndicators,
  }) {
    final pillThickness = coordinateSystem.scale(Settings.shapeHandleThickness);
    final pillLength = coordinateSystem.scale(Settings.shapeHandleLength);
    final hitPadding = coordinateSystem.scale(Settings.shapeHandleHitPadding);
    final hitWidth = pillLength + (2 * hitPadding);
    final hitHeight = pillThickness + (2 * hitPadding);
    final handleCenterY = _computeWidthHandleCenterY(
      coordinateSystem: coordinateSystem,
      scaledWidth: scaledWidth,
    );

    return Positioned(
      left: insetX + ((scaledLength - hitWidth) / 2),
      top: insetY + handleCenterY - (hitHeight / 2),
      child: ShapeIndicatorFade(
        visible: showIndicators,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeUpDown,
          onEnter: (_) {
            setState(() {
              _isWidthHandleHovered = true;
            });
          },
          onExit: (_) {
            setState(() {
              _isWidthHandleHovered = false;
            });
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) {
              setState(() {
                _activeHandle = _RectangleResizeHandle.width;
                _isWidthHandleHovered = true;
                _widthDragOffsetMeters = widthMeters -
                    _estimateWidthMeters(details.globalPosition, mapScale);
              });
            },
            onPanUpdate: (details) =>
                _updateWidth(details.globalPosition, mapScale),
            onPanEnd: (_) => _commitRectangleResize(),
            onPanCancel: _resetActiveHandle,
            child: SizedBox(
              width: hitWidth,
              height: hitHeight,
              child: Center(
                child: _ResizePill(
                  width: pillLength,
                  height: pillThickness,
                  isActive: _activeHandle == _RectangleResizeHandle.width ||
                      _isWidthHandleHovered,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCornerResizeHandle({
    required CoordinateSystem coordinateSystem,
    required Offset corner,
    required double scaledWidth,
    required double scaledLength,
    required double insetX,
    required double insetY,
    required double mapScale,
    required double rotation,
    required bool showIndicators,
  }) {
    final gripSize =
        coordinateSystem.scale(Settings.shapeCornerResizeHandleSize);
    final hitPadding = coordinateSystem.scale(Settings.shapeHandleHitPadding);
    final hitSize = gripSize + (2 * hitPadding);
    final cornerLocal = Offset(
      corner.dx * scaledLength,
      corner.dy * scaledWidth,
    );
    final isActive = (_activeHandle == _RectangleResizeHandle.corner &&
            _activeResizeCorner == corner) ||
        _hoveredResizeCorner == corner;

    return Positioned(
      left: insetX + cornerLocal.dx - (hitSize / 2),
      top: insetY + cornerLocal.dy - (hitSize / 2),
      child: ShapeIndicatorFade(
        visible: showIndicators,
        child: MouseRegion(
          cursor: _cornerResizeCursor(corner: corner, rotation: rotation),
          onEnter: (_) {
            setState(() {
              _hoveredResizeCorner = corner;
            });
          },
          onExit: (_) {
            setState(() {
              if (_hoveredResizeCorner == corner) {
                _hoveredResizeCorner = null;
              }
            });
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _startCornerResize(corner),
            onPanUpdate: (details) => _updateCornerResize(
              globalPosition: details.globalPosition,
              corner: corner,
              mapScale: mapScale,
              rotation: rotation,
            ),
            onPanEnd: (_) => _commitRectangleResize(),
            onPanCancel: _resetActiveHandle,
            child: SizedBox(
              width: hitSize,
              height: hitSize,
              child: Center(
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  scale: isActive ? 1.0 : 0.9,
                  child: Container(
                    width: gripSize,
                    height: gripSize,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(
                        coordinateSystem.scale(2),
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 3,
                          offset: Offset(0, 1),
                        ),
                      ],
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

  void _startCornerResize(Offset corner) {
    final shapeBox = _shapeKey.currentContext?.findRenderObject() as RenderBox?;
    if (shapeBox == null || shapeBox.size.isEmpty) return;

    final originGlobal = shapeBox.localToGlobal(Offset.zero);
    final horizontalEndGlobal =
        shapeBox.localToGlobal(Offset(shapeBox.size.width, 0));
    final globalScale =
        (horizontalEndGlobal - originGlobal).distance / shapeBox.size.width;
    final centerGlobal =
        shapeBox.localToGlobal(shapeBox.size.center(Offset.zero));
    final oppositeCornerLocal = Offset(
      (1 - corner.dx) * shapeBox.size.width,
      (1 - corner.dy) * shapeBox.size.height,
    );
    final utilities = ref.read(utilityProvider);
    final index = PlacedWidget.getIndexByID(widget.id, utilities);
    if (index < 0) return;

    setState(() {
      _activeHandle = _RectangleResizeHandle.corner;
      _activeResizeCorner = corner;
      _hoveredResizeCorner = corner;
      _cornerFixedGlobal = shapeBox.localToGlobal(oppositeCornerLocal);
      _cornerGlobalScale = globalScale;
      _cornerStartTopLeftGlobal = centerGlobal -
          Offset(
            shapeBox.size.width * globalScale / 2,
            shapeBox.size.height * globalScale / 2,
          );
      _cornerStartStoredPosition = utilities[index].position;
    });
  }

  void _updateCornerResize({
    required Offset globalPosition,
    required Offset corner,
    required double mapScale,
    required double rotation,
  }) {
    if (_activeHandle != _RectangleResizeHandle.corner ||
        _activeResizeCorner != corner) {
      return;
    }

    final coordinateSystem = CoordinateSystem.instance;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final globalScale = _cornerGlobalScale;
    final result = calculateRectangleCornerResize(
      draggedCorner: corner,
      pointer: globalPosition,
      fixedCorner: _cornerFixedGlobal,
      rotation: rotation,
      minimumSize: Size(
        coordinateSystem.scale(_minLengthMeters * meterScale) * globalScale,
        coordinateSystem.scale(_minWidthMeters * meterScale) * globalScale,
      ),
      maximumSize: Size(
        coordinateSystem.scale(_maxLengthMeters * meterScale) * globalScale,
        coordinateSystem.scale(_maxWidthMeters * meterScale) * globalScale,
      ),
    );
    final localLength = result.size.width / globalScale;
    final localWidth = result.size.height / globalScale;
    final globalPositionDelta = result.topLeft - _cornerStartTopLeftGlobal;

    setState(() {
      _localLengthMeters = coordinateSystem.normalize(localLength) / meterScale;
      _localWidthMeters = coordinateSystem.normalize(localWidth) / meterScale;
      _cornerPositionDeltaScreen = globalPositionDelta / globalScale;
    });
  }

  MouseCursor _cornerResizeCursor({
    required Offset corner,
    required double rotation,
  }) {
    final baseAngle = corner.dx == corner.dy ? math.pi / 4 : -math.pi / 4;
    final normalized = ((baseAngle + rotation) % math.pi + math.pi) % math.pi;
    final direction = (normalized / (math.pi / 4)).round() % 4;
    return switch (direction) {
      0 => SystemMouseCursors.resizeLeftRight,
      1 => SystemMouseCursors.resizeUpLeftDownRight,
      2 => SystemMouseCursors.resizeUpDown,
      _ => SystemMouseCursors.resizeUpRightDownLeft,
    };
  }

  Offset _rotationHandleCenterLocal({
    required CoordinateSystem coordinateSystem,
    required Offset corner,
    required double scaledWidth,
    required double scaledLength,
  }) {
    final outward = Offset(
      corner.dx == 0 ? -1 : 1,
      corner.dy == 0 ? -1 : 1,
    );
    final radialOffset =
        coordinateSystem.scale(Settings.shapeRotationHandleOffset) / math.sqrt2;
    return Offset(
          corner.dx * scaledLength,
          corner.dy * scaledWidth,
        ) +
        (outward * radialOffset);
  }

  Widget _buildRotationHandle({
    required CoordinateSystem coordinateSystem,
    required Offset corner,
    required double scaledWidth,
    required double scaledLength,
    required double insetX,
    required double insetY,
    required bool showIndicators,
  }) {
    final dotSize = coordinateSystem.scale(Settings.shapeRotationHandleSize);
    final hitPadding = coordinateSystem.scale(Settings.shapeHandleHitPadding);
    final hitSize = dotSize + (2 * hitPadding);
    final cornerLocal = _rotationHandleCenterLocal(
      coordinateSystem: coordinateSystem,
      corner: corner,
      scaledWidth: scaledWidth,
      scaledLength: scaledLength,
    );
    final isActive = (_isRotating && _rotatingCorner == corner) ||
        _hoveredRotationCorner == corner;

    return Positioned(
      left: insetX + cornerLocal.dx - (hitSize / 2),
      top: insetY + cornerLocal.dy - (hitSize / 2),
      child: ShapeIndicatorFade(
        visible: showIndicators,
        child: MouseRegion(
          cursor: _isRotating
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.grab,
          onEnter: (_) {
            setState(() {
              _hoveredRotationCorner = corner;
            });
          },
          onExit: (_) {
            setState(() {
              if (_hoveredRotationCorner == corner) {
                _hoveredRotationCorner = null;
              }
            });
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) =>
                _startRotationDrag(details.globalPosition, corner),
            onPanUpdate: (details) =>
                _updateRotationDrag(details.globalPosition),
            onPanEnd: (_) => _commitRotation(),
            onPanCancel: _cancelRotation,
            child: SizedBox(
              width: hitSize,
              height: hitSize,
              child: Center(
                child: AnimatedScale(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  scale: isActive ? 1.0 : 0.9,
                  child: Container(
                    width: dotSize,
                    height: dotSize,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black26,
                          blurRadius: 3,
                          offset: Offset(0, 1),
                        ),
                      ],
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

  void _startRotationDrag(Offset globalPosition, Offset corner) {
    final centerGlobal = _shapeCenterGlobal();
    if (centerGlobal == null) return;

    setState(() {
      _isRotating = true;
      _rotatingCorner = corner;
      _rotationCenterGlobal = centerGlobal;
      _rotationPointerStartAngle = math.atan2(
        globalPosition.dy - centerGlobal.dy,
        globalPosition.dx - centerGlobal.dx,
      );
      _rotationStartValue = _localRotation ?? widget.utility.rotation;
    });
  }

  void _updateRotationDrag(Offset globalPosition) {
    if (!_isRotating) return;

    final pointerAngle = math.atan2(
      globalPosition.dy - _rotationCenterGlobal.dy,
      globalPosition.dx - _rotationCenterGlobal.dx,
    );
    var nextRotation =
        _rotationStartValue + (pointerAngle - _rotationPointerStartAngle);
    final snapped =
        (nextRotation / _rotationSnapStep).round() * _rotationSnapStep;
    if ((nextRotation - snapped).abs() <= _rotationSnapTolerance) {
      nextRotation = snapped;
    }

    setState(() {
      _localRotation = nextRotation;
    });
  }

  void _commitRotation() {
    final rotation = _localRotation;
    final utilities = ref.read(utilityProvider);
    final index = PlacedWidget.getIndexByID(widget.id, utilities);
    if (rotation != null &&
        index >= 0 &&
        utilities[index].rotation != rotation) {
      ref
          .read(utilityProvider.notifier)
          .updateRotation(index, rotation, utilities[index].length);
    }

    setState(() {
      _isRotating = false;
      _rotatingCorner = null;
    });
  }

  void _cancelRotation() {
    setState(() {
      _localRotation = _rotationStartValue;
      _isRotating = false;
      _rotatingCorner = null;
    });
  }

  Offset? _shapeCenterGlobal() {
    final shapeBox = _shapeKey.currentContext?.findRenderObject() as RenderBox?;
    if (shapeBox == null) return null;
    // Rotation happens about the shape's center, so this point is exact for
    // any current rotation.
    return shapeBox.localToGlobal(shapeBox.size.center(Offset.zero));
  }

  Offset? _shapeLocalFromGlobal(Offset globalPosition) {
    final shapeBox = _shapeKey.currentContext?.findRenderObject() as RenderBox?;
    if (shapeBox == null) return null;
    // Inverts the full transform chain (zoom + rotation), so the result is in
    // unrotated shape space with the origin at the shape's top-left.
    return shapeBox.globalToLocal(globalPosition);
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
    final localPosition = _shapeLocalFromGlobal(globalPosition);
    if (localPosition == null) return _localLengthMeters ?? _minLengthMeters;

    final coordinateSystem = CoordinateSystem.instance;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final lengthVirtual =
        coordinateSystem.normalize(math.max(localPosition.dx, 0));
    return (lengthVirtual / meterScale).toDouble();
  }

  double _estimateWidthMeters(Offset globalPosition, double mapScale) {
    final localPosition = _shapeLocalFromGlobal(globalPosition);
    if (localPosition == null) return _localWidthMeters ?? _minWidthMeters;

    final coordinateSystem = CoordinateSystem.instance;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final widthVirtual =
        coordinateSystem.normalize(math.max(localPosition.dy, 0));
    return (widthVirtual / meterScale).toDouble();
  }

  void _commitRectangleResize() {
    final widthMeters = _localWidthMeters;
    final lengthMeters = _localLengthMeters;
    if (widthMeters != null && lengthMeters != null) {
      if (_activeHandle == _RectangleResizeHandle.corner) {
        final coordinateSystem = CoordinateSystem.instance;
        final nextPosition = _cornerStartStoredPosition +
            Offset(
              coordinateSystem
                  .screenWidthToWorld(_cornerPositionDeltaScreen.dx),
              coordinateSystem
                  .screenHeightToWorld(_cornerPositionDeltaScreen.dy),
            );
        ref.read(utilityProvider.notifier).updateCustomShapeGeometry(
              id: widget.id,
              position: nextPosition,
              widthMeters: widthMeters,
              lengthMeters: lengthMeters,
            );
      } else {
        ref.read(utilityProvider.notifier).updateCustomRectangleSize(
              id: widget.id,
              widthMeters: widthMeters,
              lengthMeters: lengthMeters,
            );
      }
    }

    _resetActiveHandle();
  }

  void _resetActiveHandle() {
    setState(() {
      _activeHandle = _RectangleResizeHandle.none;
      _lengthDragOffsetMeters = 0;
      _widthDragOffsetMeters = 0;
      _cornerPositionDeltaScreen = Offset.zero;
      _isLengthHandleHovered = false;
      _isWidthHandleHovered = false;
      _activeResizeCorner = null;
      _hoveredResizeCorner = null;
    });
  }

  Widget _buildResizeTooltip({
    required CoordinateSystem coordinateSystem,
    required double scaledWidth,
    required double scaledLength,
    required double widthMeters,
    required double lengthMeters,
    required double rotation,
    required double outerSize,
  }) {
    final handleCenterLocal = switch (_activeHandle) {
      _RectangleResizeHandle.length => Offset(
          _computeLengthHandleCenterX(
            coordinateSystem: coordinateSystem,
            scaledLength: scaledLength,
          ),
          scaledWidth / 2,
        ),
      _RectangleResizeHandle.width => Offset(
          scaledLength / 2,
          _computeWidthHandleCenterY(
            coordinateSystem: coordinateSystem,
            scaledWidth: scaledWidth,
          ),
        ),
      _RectangleResizeHandle.corner => Offset(
          (_activeResizeCorner?.dx ?? 1) * scaledLength,
          (_activeResizeCorner?.dy ?? 1) * scaledWidth,
        ),
      _RectangleResizeHandle.none => Offset(scaledLength / 2, scaledWidth / 2),
    };
    final anchor = _rotatedOverlayPosition(
      shapeLocal: handleCenterLocal,
      rotation: rotation,
      scaledWidth: scaledWidth,
      scaledLength: scaledLength,
      outerSize: outerSize,
    );
    final gap = coordinateSystem.scale(16);

    return Positioned(
      left: anchor.dx,
      top: anchor.dy - gap,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -1.0),
        child: _activeHandle == _RectangleResizeHandle.corner
            ? CustomShapeResizeTooltip(
                label: 'Size',
                valueText:
                    '${lengthMeters.toStringAsFixed(1)} × ${widthMeters.toStringAsFixed(1)} m',
              )
            : CustomShapeResizeTooltip(
                label:
                    _activeHandle == _RectangleResizeHandle.length ? 'L' : 'W',
                valueMeters: _activeHandle == _RectangleResizeHandle.length
                    ? lengthMeters
                    : widthMeters,
              ),
      ),
    );
  }

  Widget _buildRotationTooltip({
    required CoordinateSystem coordinateSystem,
    required double scaledWidth,
    required double scaledLength,
    required double rotation,
    required double outerSize,
  }) {
    final corner = _rotatingCorner ?? const Offset(1, 0);
    final anchor = _rotatedOverlayPosition(
      shapeLocal: _rotationHandleCenterLocal(
        coordinateSystem: coordinateSystem,
        corner: corner,
        scaledWidth: scaledWidth,
        scaledLength: scaledLength,
      ),
      rotation: rotation,
      scaledWidth: scaledWidth,
      scaledLength: scaledLength,
      outerSize: outerSize,
    );
    final degrees = (((rotation * 180 / math.pi) % 360) + 360) % 360;
    final gap = coordinateSystem.scale(16);

    return Positioned(
      left: anchor.dx,
      top: anchor.dy - gap,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -1.0),
        child: CustomShapeResizeTooltip(
          label: 'R',
          valueDegrees: degrees,
        ),
      ),
    );
  }

  /// Maps a point in unrotated shape space (origin at the shape's top-left)
  /// into the upright overlay layer that sits outside the rotation transform.
  Offset _rotatedOverlayPosition({
    required Offset shapeLocal,
    required double rotation,
    required double scaledWidth,
    required double scaledLength,
    required double outerSize,
  }) {
    final delta = shapeLocal - Offset(scaledLength / 2, scaledWidth / 2);
    final rotated = Offset(
      (delta.dx * math.cos(rotation)) - (delta.dy * math.sin(rotation)),
      (delta.dx * math.sin(rotation)) + (delta.dy * math.cos(rotation)),
    );
    return Offset(outerSize / 2, outerSize / 2) + rotated;
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
    required this.isActive,
  });

  final double width;
  final double height;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      scale: isActive ? 1.0 : 0.9,
      child: Container(
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
      ),
    );
  }
}
