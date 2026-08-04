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
import 'package:icarus/widgets/draggable_widgets/utilities/rectangle_axis_resize_geometry.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/shape_indicator_fade.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';

enum _RectangleResizeHandle { none, left, right, top, bottom }

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
  static const List<_RectangleResizeHandle> _resizeHandles = [
    _RectangleResizeHandle.left,
    _RectangleResizeHandle.right,
    _RectangleResizeHandle.top,
    _RectangleResizeHandle.bottom,
  ];

  /// Render box of the unrotated shape itself, used to capture exact global
  /// edge anchors before a resize begins.
  final GlobalKey _shapeKey = GlobalKey();

  double? _localWidthMeters;
  double? _localLengthMeters;
  double? _localRotation;
  Offset _resizePointerStartGlobal = Offset.zero;
  Offset _resizeStartTopLeftGlobal = Offset.zero;
  Offset _resizeFixedEdgeCenterGlobal = Offset.zero;
  Offset _resizeStartStoredPosition = Offset.zero;
  Offset _resizePositionDeltaScreen = Offset.zero;
  Size _resizeStartSizeGlobal = Size.zero;
  double _resizeGlobalScale = 1;
  bool _isDragging = false;
  bool _isShapeHovered = false;
  _RectangleResizeHandle _activeHandle = _RectangleResizeHandle.none;
  _RectangleResizeHandle _hoveredResizeHandle = _RectangleResizeHandle.none;
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
      (Settings.shapeRotationHandleSize / 2) + Settings.shapeHandleHitPadding,
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
      offset: Offset(-insetX, -insetY) + _resizePositionDeltaScreen,
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
                            showCenterMarker: !isScreenshot,
                            centerMarkerVisible: showIndicators,
                          ),
                        ),
                      ),
                    ),
                    if (!_isDragging && !isScreenshot) ...[
                      for (final handle in _resizeHandles)
                        _buildResizeHandle(
                          coordinateSystem: coordinateSystem,
                          handle: handle,
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

  Widget _buildResizeHandle({
    required CoordinateSystem coordinateSystem,
    required _RectangleResizeHandle handle,
    required double scaledWidth,
    required double scaledLength,
    required double insetX,
    required double insetY,
    required double mapScale,
    required double rotation,
    required bool showIndicators,
  }) {
    final pillThickness = coordinateSystem.scale(Settings.shapeHandleThickness);
    final pillLength = coordinateSystem.scale(Settings.shapeHandleLength);
    final hitPadding = coordinateSystem.scale(Settings.shapeHandleHitPadding);
    final isLengthAxis = _isLengthHandle(handle);
    final hitWidth =
        (isLengthAxis ? pillThickness : pillLength) + (2 * hitPadding);
    final hitHeight =
        (isLengthAxis ? pillLength : pillThickness) + (2 * hitPadding);
    final handleCenter = _resizeHandleCenter(
      handle: handle,
      coordinateSystem: coordinateSystem,
      scaledLength: scaledLength,
      scaledWidth: scaledWidth,
    );

    return Positioned(
      left: insetX + handleCenter.dx - (hitWidth / 2),
      top: insetY + handleCenter.dy - (hitHeight / 2),
      child: ShapeIndicatorFade(
        visible: showIndicators,
        child: MouseRegion(
          cursor: _resizeCursor(handle: handle, rotation: rotation),
          onEnter: (_) {
            setState(() {
              _hoveredResizeHandle = handle;
            });
          },
          onExit: (_) {
            setState(() {
              if (_hoveredResizeHandle == handle) {
                _hoveredResizeHandle = _RectangleResizeHandle.none;
              }
            });
          },
          child: GestureDetector(
            key: ValueKey('custom-rectangle-resize-${handle.name}'),
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) =>
                _startAxisResize(details.globalPosition, handle),
            onPanUpdate: (details) => _updateAxisResize(
              globalPosition: details.globalPosition,
              handle: handle,
              mapScale: mapScale,
              rotation: rotation,
            ),
            onPanEnd: (_) => _commitRectangleResize(),
            onPanCancel: _resetActiveHandle,
            child: SizedBox(
              width: hitWidth,
              height: hitHeight,
              child: Center(
                child: _ResizePill(
                  width: isLengthAxis ? pillThickness : pillLength,
                  height: isLengthAxis ? pillLength : pillThickness,
                  isActive:
                      _activeHandle == handle || _hoveredResizeHandle == handle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isLengthHandle(_RectangleResizeHandle handle) =>
      handle == _RectangleResizeHandle.left ||
      handle == _RectangleResizeHandle.right;

  Offset _resizeHandleCenter({
    required _RectangleResizeHandle handle,
    required CoordinateSystem coordinateSystem,
    required double scaledLength,
    required double scaledWidth,
  }) {
    final halfStroke = _computeRectangleBorderStrokeWidth(coordinateSystem) / 2;
    return switch (handle) {
      _RectangleResizeHandle.left => Offset(halfStroke, scaledWidth / 2),
      _RectangleResizeHandle.right =>
        Offset(scaledLength - halfStroke, scaledWidth / 2),
      _RectangleResizeHandle.top => Offset(scaledLength / 2, halfStroke),
      _RectangleResizeHandle.bottom =>
        Offset(scaledLength / 2, scaledWidth - halfStroke),
      _RectangleResizeHandle.none => Offset(scaledLength / 2, scaledWidth / 2),
    };
  }

  MouseCursor _resizeCursor({
    required _RectangleResizeHandle handle,
    required double rotation,
  }) {
    final axisAngle =
        _isLengthHandle(handle) ? rotation : rotation + (math.pi / 2);
    final normalized = ((axisAngle % math.pi) + math.pi) % math.pi;
    final direction = (normalized / (math.pi / 4)).round() % 4;
    return switch (direction) {
      0 => SystemMouseCursors.resizeLeftRight,
      1 => SystemMouseCursors.resizeUpLeftDownRight,
      2 => SystemMouseCursors.resizeUpDown,
      _ => SystemMouseCursors.resizeUpRightDownLeft,
    };
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
    final cornerLocal = Offset(
      corner.dx * scaledLength,
      corner.dy * scaledWidth,
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

  void _startAxisResize(
    Offset globalPosition,
    _RectangleResizeHandle handle,
  ) {
    final shapeBox = _shapeKey.currentContext?.findRenderObject() as RenderBox?;
    if (shapeBox == null || shapeBox.size.isEmpty) return;

    final originGlobal = shapeBox.localToGlobal(Offset.zero);
    final horizontalEndGlobal =
        shapeBox.localToGlobal(Offset(shapeBox.size.width, 0));
    final globalScale =
        (horizontalEndGlobal - originGlobal).distance / shapeBox.size.width;
    final centerGlobal =
        shapeBox.localToGlobal(shapeBox.size.center(Offset.zero));
    final fixedEdgeLocal = switch (handle) {
      _RectangleResizeHandle.left =>
        Offset(shapeBox.size.width, shapeBox.size.height / 2),
      _RectangleResizeHandle.right => Offset(0, shapeBox.size.height / 2),
      _RectangleResizeHandle.top =>
        Offset(shapeBox.size.width / 2, shapeBox.size.height),
      _RectangleResizeHandle.bottom => Offset(shapeBox.size.width / 2, 0),
      _RectangleResizeHandle.none => shapeBox.size.center(Offset.zero),
    };
    final utilities = ref.read(utilityProvider);
    final index = PlacedWidget.getIndexByID(widget.id, utilities);
    if (index < 0) return;

    setState(() {
      _activeHandle = handle;
      _hoveredResizeHandle = handle;
      _resizePointerStartGlobal = globalPosition;
      _resizeFixedEdgeCenterGlobal = shapeBox.localToGlobal(fixedEdgeLocal);
      _resizeGlobalScale = globalScale;
      _resizeStartSizeGlobal = Size(
        shapeBox.size.width * globalScale,
        shapeBox.size.height * globalScale,
      );
      _resizeStartTopLeftGlobal = centerGlobal -
          Offset(
            shapeBox.size.width * globalScale / 2,
            shapeBox.size.height * globalScale / 2,
          );
      _resizeStartStoredPosition = utilities[index].position;
    });
  }

  void _updateAxisResize({
    required Offset globalPosition,
    required _RectangleResizeHandle handle,
    required double mapScale,
    required double rotation,
  }) {
    if (_activeHandle != handle) return;

    final coordinateSystem = CoordinateSystem.instance;
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    final result = calculateRectangleAxisResize(
      side: _toResizeSide(handle),
      pointerDelta: globalPosition - _resizePointerStartGlobal,
      fixedEdgeCenter: _resizeFixedEdgeCenterGlobal,
      rotation: rotation,
      startingSize: _resizeStartSizeGlobal,
      minimumSize: Size(
        coordinateSystem.scale(_minLengthMeters * meterScale) *
            _resizeGlobalScale,
        coordinateSystem.scale(_minWidthMeters * meterScale) *
            _resizeGlobalScale,
      ),
      maximumSize: Size(
        coordinateSystem.scale(_maxLengthMeters * meterScale) *
            _resizeGlobalScale,
        coordinateSystem.scale(_maxWidthMeters * meterScale) *
            _resizeGlobalScale,
      ),
    );

    setState(() {
      _localLengthMeters = coordinateSystem.normalize(
            result.size.width / _resizeGlobalScale,
          ) /
          meterScale;
      _localWidthMeters = coordinateSystem.normalize(
            result.size.height / _resizeGlobalScale,
          ) /
          meterScale;
      _resizePositionDeltaScreen =
          (result.topLeft - _resizeStartTopLeftGlobal) / _resizeGlobalScale;
    });
  }

  RectangleResizeSide _toResizeSide(_RectangleResizeHandle handle) =>
      switch (handle) {
        _RectangleResizeHandle.left => RectangleResizeSide.left,
        _RectangleResizeHandle.right => RectangleResizeSide.right,
        _RectangleResizeHandle.top => RectangleResizeSide.top,
        _RectangleResizeHandle.bottom => RectangleResizeSide.bottom,
        _RectangleResizeHandle.none => throw StateError('No active handle'),
      };

  void _commitRectangleResize() {
    final widthMeters = _localWidthMeters;
    final lengthMeters = _localLengthMeters;
    if (widthMeters != null && lengthMeters != null) {
      final coordinateSystem = CoordinateSystem.instance;
      final nextPosition = _resizeStartStoredPosition +
          Offset(
            coordinateSystem.screenWidthToWorld(_resizePositionDeltaScreen.dx),
            coordinateSystem.screenHeightToWorld(_resizePositionDeltaScreen.dy),
          );
      ref.read(utilityProvider.notifier).updateCustomShapeGeometry(
            id: widget.id,
            position: nextPosition,
            widthMeters: widthMeters,
            lengthMeters: lengthMeters,
          );
    }

    _resetActiveHandle();
  }

  void _resetActiveHandle() {
    setState(() {
      _activeHandle = _RectangleResizeHandle.none;
      _hoveredResizeHandle = _RectangleResizeHandle.none;
      _resizePositionDeltaScreen = Offset.zero;
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
    final handleCenterLocal = _resizeHandleCenter(
      handle: _activeHandle,
      coordinateSystem: coordinateSystem,
      scaledLength: scaledLength,
      scaledWidth: scaledWidth,
    );
    final anchor = _rotatedOverlayPosition(
      shapeLocal: handleCenterLocal,
      rotation: rotation,
      scaledWidth: scaledWidth,
      scaledLength: scaledLength,
      outerSize: outerSize,
    );
    final isLengthAxis = _isLengthHandle(_activeHandle);
    final label = isLengthAxis ? 'L' : 'W';
    final valueMeters = isLengthAxis ? lengthMeters : widthMeters;
    final gap = coordinateSystem.scale(16);

    return Positioned(
      left: anchor.dx,
      top: anchor.dy - gap,
      child: FractionalTranslation(
        translation: const Offset(-0.5, -1.0),
        child: CustomShapeResizeTooltip(
          label: label,
          valueMeters: valueMeters,
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
      shapeLocal: Offset(corner.dx * scaledLength, corner.dy * scaledWidth),
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
