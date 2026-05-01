import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/duplicate_drag_modifier_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/deadlock_barrier_mesh_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class PlacedDeadlockBarrierMeshWidget extends ConsumerStatefulWidget {
  const PlacedDeadlockBarrierMeshWidget({
    super.key,
    required this.ability,
    required this.onDragEnd,
    required this.id,
    required this.data,
    this.isLineUp = false,
    this.contextMenuItems,
  });

  final PlacedAbility ability;
  final void Function(DraggableDetails details, String draggedId) onDragEnd;
  final String id;
  final PlacedWidget data;
  final bool isLineUp;
  final List<ShadContextMenuItem>? contextMenuItems;

  @override
  ConsumerState<PlacedDeadlockBarrierMeshWidget> createState() =>
      _PlacedDeadlockBarrierMeshWidgetState();
}

class _PlacedDeadlockBarrierMeshWidgetState
    extends ConsumerState<PlacedDeadlockBarrierMeshWidget>
    with SingleTickerProviderStateMixin {
  List<double>? _localArmLengthsMeters;
  List<double>? _resizeStartArmLengthsMeters;
  double? _localRotation;
  DeadlockBarrierMeshArm? _activeArm;
  DeadlockBarrierMeshArm? _hoveredArm;
  double _armDragOffsetMeters = 0;
  bool _isDragging = false;
  bool _isRotating = false;
  bool _isRotationHandleHovered = false;
  String? _activeDragId;
  Offset _rotationOriginGlobal = Offset.zero;
  late final AnimationController _animationController;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _localArmLengthsMeters =
        normalizeDeadlockBarrierMeshArmLengths(widget.ability.armLengthsMeters);
    _localRotation = widget.ability.rotation;
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 160),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(
      begin: 0.9,
      end: 1.0,
    ).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final currentMap =
        ref.watch(mapProvider.select((state) => state.currentMap));
    final mapScale = Maps.mapScale[currentMap] ?? 1.0;
    final abilitySize = ref.watch(strategySettingsProvider).abilitySize;
    final isScreenshot = ref.watch(screenshotProvider);

    final abilityRef = _resolveAbilityRef();
    if (abilityRef == null) {
      return const SizedBox.shrink();
    }

    final barrierAbility =
        abilityRef.data.abilityData! as DeadlockBarrierMeshAbility;
    final providerArmLengths =
        normalizeDeadlockBarrierMeshArmLengths(abilityRef.armLengthsMeters);
    final providerRotation = abilityRef.rotation;

    if (!_isDragging &&
        !_isRotating &&
        _activeArm == null &&
        !listEquals(_localArmLengthsMeters, providerArmLengths)) {
      _localArmLengthsMeters = providerArmLengths;
    }
    if (!_isDragging &&
        !_isRotating &&
        _activeArm == null &&
        _localRotation != providerRotation) {
      _localRotation = providerRotation;
    }

    final armLengths =
        normalizeDeadlockBarrierMeshArmLengths(_localArmLengthsMeters);
    final localRotation = _localRotation ?? providerRotation;
    final maxExtent = coordinateSystem.scale(
      deadlockBarrierMeshMaxExtent(
        mapScale: mapScale,
        abilitySize: abilitySize,
      ),
    );
    final abilitySizePx = coordinateSystem.scale(abilitySize);
    final iconInset = (maxExtent - abilitySizePx) / 2;
    final center = Offset(maxExtent / 2, maxExtent / 2);
    final screenPosition = screenPositionForWidget(
      widget: abilityRef,
      coordinateSystem: coordinateSystem,
    );
    final feedbackRotationOrigin = center.scale(
      ref.watch(screenZoomProvider),
      ref.watch(screenZoomProvider),
    );
    final showMesh = abilityRef.visualState.showRangeFill;

    final content = Transform.rotate(
      angle: localRotation,
      alignment: Alignment.topLeft,
      origin: center,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Opacity(
            opacity: _isDragging ? 0 : 1,
            child: DeadlockBarrierMeshWidget(
              lineUpId: abilityRef.lineUpID,
              iconPath: abilityRef.data.iconPath,
              id: widget.id,
              isAlly: abilityRef.isAlly,
              color: barrierAbility.color,
              mapScale: mapScale,
              armLengthsMeters: armLengths,
              showCenterAbility: false,
              visualState: abilityRef.visualState,
              watchMouse: false,
            ),
          ),
          Positioned(
            left: iconInset,
            top: iconInset,
            child: Draggable<PlacedWidget>(
              data: widget.data,
              dragAnchorStrategy: (draggable, context, position) {
                final renderObject = context.findRenderObject()! as RenderBox;
                final localIconOffset = renderObject.globalToLocal(position);
                final anchorWithinSquare =
                    localIconOffset + Offset(iconInset, iconInset);
                final rotatedAnchor = _rotateOffset(
                  anchorWithinSquare,
                  center,
                  localRotation,
                );
                return ref
                    .read(screenZoomProvider.notifier)
                    .zoomOffset(rotatedAnchor);
              },
              feedback: Opacity(
                opacity: Settings.feedbackOpacity,
                child: Transform.rotate(
                  angle: localRotation,
                  alignment: Alignment.topLeft,
                  origin: feedbackRotationOrigin,
                  child: ZoomTransform(
                    child: DeadlockBarrierMeshWidget(
                      lineUpId: abilityRef.lineUpID,
                      iconPath: abilityRef.data.iconPath,
                      id: widget.id,
                      isAlly: abilityRef.isAlly,
                      color: barrierAbility.color,
                      mapScale: mapScale,
                      armLengthsMeters: armLengths,
                      visualState: abilityRef.visualState,
                      watchMouse: false,
                    ),
                  ),
                ),
              ),
              childWhenDragging: const SizedBox.shrink(),
              onDragStarted: () {
                final shouldDuplicate =
                    !widget.isLineUp && ref.read(duplicateDragModifierProvider);
                final duplicateId = shouldDuplicate
                    ? ref.read(abilityProvider.notifier).duplicateAbilityAt(
                          sourceId: abilityRef.id,
                          position: abilityRef.position,
                        )
                    : null;
                setState(() {
                  _isDragging = true;
                  _activeDragId = duplicateId ?? abilityRef.id;
                });
              },
              onDragEnd: (details) {
                final dragId = _activeDragId ?? abilityRef.id;
                widget.onDragEnd(details, dragId);
                setState(() {
                  _isDragging = false;
                  _activeDragId = null;
                });
              },
              child: AbilityWidget(
                lineUpId: abilityRef.lineUpID,
                iconPath: abilityRef.data.iconPath,
                id: widget.id,
                isAlly: abilityRef.isAlly,
                watchMouse: true,
                contextMenuItems: widget.contextMenuItems,
              ),
            ),
          ),
          if (showMesh && !_isDragging && !isScreenshot)
            _buildRotationHandle(
              coordinateSystem: coordinateSystem,
              mapScale: mapScale,
              abilitySize: abilitySize,
            ),
          if (showMesh && !_isDragging && !isScreenshot)
            for (final arm in DeadlockBarrierMeshArm.values)
              _buildArmHandle(
                coordinateSystem: coordinateSystem,
                arm: arm,
                armLengthMeters: armLengths[arm.index],
                mapScale: mapScale,
                abilitySize: abilitySize,
              ),
        ],
      ),
    );

    return Positioned(
      left: screenPosition.dx,
      top: screenPosition.dy,
      child: content,
    );
  }

  PlacedAbility? _resolveAbilityRef() {
    if (widget.isLineUp) {
      return ref.watch(lineUpProvider).currentAbility;
    }

    final abilities = ref.watch(abilityProvider);
    final index = PlacedWidget.getIndexByID(widget.id, abilities);
    if (index < 0) {
      return null;
    }
    return abilities[index];
  }

  PlacedAbility? _readAbilityRef() {
    if (widget.isLineUp) {
      return ref.read(lineUpProvider).currentAbility;
    }

    final abilities = ref.read(abilityProvider);
    final index = PlacedWidget.getIndexByID(widget.id, abilities);
    if (index < 0) {
      return null;
    }
    return abilities[index];
  }

  Widget _buildRotationHandle({
    required CoordinateSystem coordinateSystem,
    required double mapScale,
    required double abilitySize,
  }) {
    final handleSize =
        coordinateSystem.scale(deadlockBarrierMeshHandleDiameterVirtual);
    final handleCenter = deadlockBarrierMeshRotationHandleCenter(
      mapScale: mapScale,
      abilitySize: abilitySize,
      coordinateSystem: coordinateSystem,
    );
    final isHighlighted = _isRotating || _isRotationHandleHovered;

    return Positioned(
      key: const ValueKey('deadlock-rotation-handle'),
      left: handleCenter.dx - (handleSize / 2),
      top: handleCenter.dy - (handleSize / 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        onEnter: (_) {
          setState(() {
            _isRotationHandleHovered = true;
          });
          _animationController.forward();
        },
        onExit: (_) {
          if (_isRotating) {
            return;
          }
          setState(() {
            _isRotationHandleHovered = false;
          });
          if (_hoveredArm == null) {
            _animationController.reverse();
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _startRotation(
            details.globalPosition,
            mapScale,
            abilitySize,
          ),
          onPanUpdate: (details) => _updateRotation(details.globalPosition),
          onPanEnd: (_) => _finishRotation(),
          onPanCancel: _cancelRotation,
          child: _buildHandleVisual(handleSize, isHighlighted),
        ),
      ),
    );
  }

  Widget _buildArmHandle({
    required CoordinateSystem coordinateSystem,
    required DeadlockBarrierMeshArm arm,
    required double armLengthMeters,
    required double mapScale,
    required double abilitySize,
  }) {
    final handleSize =
        coordinateSystem.scale(deadlockBarrierMeshHandleDiameterVirtual);
    final handleCenter = deadlockBarrierMeshHandleCenter(
      arm: arm,
      armLengthMeters: armLengthMeters,
      mapScale: mapScale,
      abilitySize: abilitySize,
      coordinateSystem: coordinateSystem,
    );
    final isHighlighted = _activeArm == arm || _hoveredArm == arm;

    return Positioned(
      key: ValueKey('deadlock-arm-handle-${arm.name}'),
      left: handleCenter.dx - (handleSize / 2),
      top: handleCenter.dy - (handleSize / 2),
      child: MouseRegion(
        cursor: _cursorForArm(arm),
        onEnter: (_) {
          setState(() {
            _hoveredArm = arm;
          });
          _animationController.forward();
        },
        onExit: (_) {
          if (_activeArm == arm) {
            return;
          }
          setState(() {
            if (_hoveredArm == arm) {
              _hoveredArm = null;
            }
          });
          if (_hoveredArm == null && !_isRotationHandleHovered) {
            _animationController.reverse();
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _startArmResize(
            arm,
            details.globalPosition,
            mapScale,
            abilitySize,
          ),
          onPanUpdate: (details) => _updateArmLength(
            details.globalPosition,
            arm,
            mapScale,
            abilitySize,
          ),
          onPanEnd: (_) => _finishArmResize(),
          onPanCancel: _cancelArmResize,
          child: _buildHandleVisual(handleSize, isHighlighted),
        ),
      ),
    );
  }

  Widget _buildHandleVisual(double handleSize, bool isHighlighted) {
    return AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: isHighlighted ? _scaleAnimation.value : 0.9,
          child: child,
        );
      },
      child: Container(
        width: handleSize,
        height: handleSize,
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
    );
  }

  MouseCursor _cursorForArm(DeadlockBarrierMeshArm arm) {
    switch (arm) {
      case DeadlockBarrierMeshArm.topRight:
      case DeadlockBarrierMeshArm.bottomLeft:
        return SystemMouseCursors.resizeUpLeftDownRight;
      case DeadlockBarrierMeshArm.topLeft:
      case DeadlockBarrierMeshArm.bottomRight:
        return SystemMouseCursors.resizeUpRightDownLeft;
    }
  }

  void _startRotation(
    Offset globalPosition,
    double mapScale,
    double abilitySize,
  ) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final coordinateSystem = CoordinateSystem.instance;
    final maxExtent = coordinateSystem.scale(
      deadlockBarrierMeshMaxExtent(
        mapScale: mapScale,
        abilitySize: abilitySize,
      ),
    );

    setState(() {
      _rotationOriginGlobal =
          renderBox.localToGlobal(Offset(maxExtent / 2, maxExtent / 2));
      _isRotating = true;
      _isRotationHandleHovered = true;
    });

    _updateRotation(globalPosition);
    _animationController.forward();
  }

  void _updateRotation(Offset globalPosition) {
    if (_rotationOriginGlobal == Offset.zero) {
      return;
    }

    final delta = globalPosition - _rotationOriginGlobal;
    final currentAngle = math.atan2(delta.dy, delta.dx);

    setState(() {
      _localRotation = currentAngle + (math.pi / 2);
    });
  }

  void _finishRotation() {
    if (_localRotation == null) {
      _cancelRotation();
      return;
    }

    if (widget.isLineUp) {
      ref.read(lineUpProvider.notifier).updateGeometry(
            rotation: _localRotation,
          );
    } else {
      final abilities = ref.read(abilityProvider);
      final index = PlacedWidget.getIndexByID(widget.id, abilities);
      if (index >= 0) {
        ref.read(abilityProvider.notifier).updateGeometry(
              index,
              rotation: _localRotation,
            );
      }
    }

    setState(() {
      _isRotating = false;
      _rotationOriginGlobal = Offset.zero;
    });
    if (_hoveredArm == null && !_isRotationHandleHovered) {
      _animationController.reverse();
    }
  }

  void _cancelRotation() {
    setState(() {
      _isRotating = false;
      _rotationOriginGlobal = Offset.zero;
      _isRotationHandleHovered = false;
      _localRotation = _readAbilityRef()?.rotation ?? _localRotation;
    });
    if (_hoveredArm == null) {
      _animationController.reverse();
    }
  }

  void _startArmResize(
    DeadlockBarrierMeshArm arm,
    Offset globalPosition,
    double mapScale,
    double abilitySize,
  ) {
    final currentArmLengths =
        normalizeDeadlockBarrierMeshArmLengths(_localArmLengthsMeters);
    setState(() {
      _activeArm = arm;
      _hoveredArm = arm;
      _resizeStartArmLengthsMeters = List<double>.from(currentArmLengths);
      _armDragOffsetMeters = currentArmLengths[arm.index] -
          _estimateArmLengthMeters(
            globalPosition,
            arm,
            mapScale,
            abilitySize,
          );
    });
    _animationController.forward();
  }

  void _updateArmLength(
    Offset globalPosition,
    DeadlockBarrierMeshArm arm,
    double mapScale,
    double abilitySize,
  ) {
    final nextLength = (_estimateArmLengthMeters(
              globalPosition,
              arm,
              mapScale,
              abilitySize,
            ) +
            _armDragOffsetMeters)
        .clamp(
          deadlockBarrierMeshMinArmLengthMeters,
          deadlockBarrierMeshMaxArmLengthMeters,
        )
        .toDouble();

    final nextArmLengths = List<double>.from(
      normalizeDeadlockBarrierMeshArmLengths(_localArmLengthsMeters),
    );
    nextArmLengths[arm.index] = nextLength;

    setState(() {
      _localArmLengthsMeters = nextArmLengths;
    });
  }

  double _estimateArmLengthMeters(
    Offset globalPosition,
    DeadlockBarrierMeshArm arm,
    double mapScale,
    double abilitySize,
  ) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) {
      final armLengths =
          normalizeDeadlockBarrierMeshArmLengths(_localArmLengthsMeters);
      return armLengths[arm.index];
    }

    final coordinateSystem = CoordinateSystem.instance;
    final maxExtent = coordinateSystem.scale(
      deadlockBarrierMeshMaxExtent(
        mapScale: mapScale,
        abilitySize: abilitySize,
      ),
    );
    final center = Offset(maxExtent / 2, maxExtent / 2);
    final localPosition = renderBox.globalToLocal(globalPosition);
    final unrotatedLocal = _rotateOffset(
      localPosition,
      center,
      -(_localRotation ?? 0),
    );
    final delta = unrotatedLocal - center;
    final deltaVirtual = Offset(
      coordinateSystem.normalize(delta.dx),
      coordinateSystem.normalize(delta.dy),
    );
    final vector = arm.unitVector;
    final projectedVirtual =
        (deltaVirtual.dx * vector.dx) + (deltaVirtual.dy * vector.dy);
    final meterScale = AgentData.inGameMetersDiameter * mapScale;
    return (projectedVirtual <= 0 ? 0 : projectedVirtual / meterScale)
        .toDouble();
  }

  void _finishArmResize() {
    final armLengths =
        normalizeDeadlockBarrierMeshArmLengths(_localArmLengthsMeters);

    if (widget.isLineUp) {
      ref.read(lineUpProvider.notifier).updateArmLengths(armLengths);
    } else {
      final abilities = ref.read(abilityProvider);
      final index = PlacedWidget.getIndexByID(widget.id, abilities);
      if (index >= 0) {
        ref.read(abilityProvider.notifier).updateArmLengths(index, armLengths);
      }
    }

    setState(() {
      _activeArm = null;
      _armDragOffsetMeters = 0;
      _resizeStartArmLengthsMeters = null;
    });
    if (_hoveredArm == null && !_isRotationHandleHovered) {
      _animationController.reverse();
    }
  }

  void _cancelArmResize() {
    setState(() {
      _localArmLengthsMeters = List<double>.from(
        _resizeStartArmLengthsMeters ?? _localArmLengthsMeters ?? const [],
      );
      _activeArm = null;
      _hoveredArm = null;
      _armDragOffsetMeters = 0;
      _resizeStartArmLengthsMeters = null;
    });
    if (!_isRotationHandleHovered) {
      _animationController.reverse();
    }
  }

  Offset _rotateOffset(Offset point, Offset origin, double angle) {
    final dx = point.dx - origin.dx;
    final dy = point.dy - origin.dy;

    final rotatedX = dx * math.cos(angle) - dy * math.sin(angle);
    final rotatedY = dx * math.sin(angle) + dy * math.cos(angle);

    return Offset(rotatedX + origin.dx, rotatedY + origin.dy);
  }
}
