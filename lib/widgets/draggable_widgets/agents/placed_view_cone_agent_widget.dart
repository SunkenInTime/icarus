import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:icarus/widgets/draggable_widgets/zoom_transform.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';

class ViewConeAgentComposite extends ConsumerWidget {
  const ViewConeAgentComposite({
    super.key,
    required this.agent,
    required this.rotation,
    required this.length,
    this.forcedAgentSize,
    this.applyRotation = true,
  });

  final PlacedViewConeAgent agent;
  final double rotation;
  final double length;
  final double? forcedAgentSize;
  final bool applyRotation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coordinateSystem = CoordinateSystem.instance;
    final agentSize =
        forcedAgentSize ?? ref.watch(strategySettingsProvider).agentSize;
    final scaledAgentSize = coordinateSystem.scale(agentSize);
    final agentCenter = Offset(scaledAgentSize / 2, scaledAgentSize / 2);
    final scaledAnchor = ViewConeWidget.anchorPointVirtual.scale(
      coordinateSystem.scaleFactor,
      coordinateSystem.scaleFactor,
    );

    Widget composite = SizedBox(
      width: scaledAgentSize,
      height: scaledAgentSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: agentCenter.dx - scaledAnchor.dx,
            top: agentCenter.dy - scaledAnchor.dy,
            child: ViewConeWidget(
              id: null,
              angle: UtilityData.getViewConeAngle(agent.presetType),
              length: length,
              showCenterMarker: false,
            ),
          ),
          AgentWidget(
            state: agent.state,
            isAlly: agent.isAlly,
            id: agent.id,
            agent: AgentData.agents[agent.type]!,
            forcedAgentSize: agentSize,
          ),
        ],
      ),
    );

    if (!applyRotation || rotation == 0) {
      return composite;
    }

    return Transform.rotate(
      angle: rotation,
      alignment: Alignment.topLeft,
      origin: agentCenter,
      child: composite,
    );
  }
}

class PlacedViewConeAgentWidget extends ConsumerStatefulWidget {
  const PlacedViewConeAgentWidget({
    super.key,
    required this.agent,
    required this.onDragEnd,
  });

  final PlacedViewConeAgent agent;
  final void Function(DraggableDetails details, String draggedId) onDragEnd;

  @override
  ConsumerState<PlacedViewConeAgentWidget> createState() =>
      _PlacedViewConeAgentWidgetState();
}

class _PlacedViewConeAgentWidgetState
    extends ConsumerState<PlacedViewConeAgentWidget> {
  Offset _rotationOrigin = Offset.zero;
  double? _localRotation;
  double? _localLength;
  bool _isDragging = false;
  String? _activeDragId;

  @override
  void initState() {
    super.initState();
    _localRotation = widget.agent.rotation;
    _localLength = widget.agent.length;
  }

  Offset _rotateOffset(Offset point, Offset origin, double angle) {
    final dx = point.dx - origin.dx;
    final dy = point.dy - origin.dy;

    final rotatedX = dx * math.cos(angle) - dy * math.sin(angle);
    final rotatedY = dx * math.sin(angle) + dy * math.cos(angle);

    return Offset(rotatedX + origin.dx, rotatedY + origin.dy);
  }

  @override
  Widget build(BuildContext context) {
    final coordinateSystem = CoordinateSystem.instance;
    final agents = ref.watch(agentProvider);
    final index = PlacedWidget.getIndexByID(widget.agent.id, agents);
    if (index < 0) {
      return const SizedBox.shrink();
    }

    final current = agents[index];
    if (current is! PlacedViewConeAgent) {
      return const SizedBox.shrink();
    }

    final agentSize = ref.watch(strategySettingsProvider).agentSize;
    final scaledAgentSize = coordinateSystem.scale(agentSize);
    final agentCenterVirtual = Offset(agentSize / 2, agentSize / 2);
    final agentCenterScaled = Offset(scaledAgentSize / 2, scaledAgentSize / 2);

    if (!_isDragging && _rotationOrigin == Offset.zero) {
      if (_localRotation != current.rotation) {
        _localRotation = current.rotation;
      }
      if (_localLength != current.length) {
        _localLength = current.length;
      }
    }

    final localRotation = _localRotation ?? current.rotation;
    final localLength = _localLength ?? current.length;

    return Positioned(
      left: coordinateSystem.coordinateToScreen(current.position).dx,
      top: coordinateSystem.coordinateToScreen(current.position).dy,
      child: RotatableWidget(
        rotation: localRotation,
        isDragging: _isDragging,
        origin: agentCenterVirtual,
        buttonTop: agentCenterVirtual.dy - localLength - 7.5,
        buttonLeft: agentCenterVirtual.dx - 7.5,
        onPanStart: (_) {
          ref.read(agentProvider.notifier).updateViewConeHistory(current.id);
          final box = context.findRenderObject() as RenderBox;
          _rotationOrigin = box.localToGlobal(agentCenterScaled);
        },
        onPanUpdate: (details) {
          if (_rotationOrigin == Offset.zero) return;

          final delta = details.globalPosition - _rotationOrigin;
          final currentAngle = math.atan2(delta.dy, delta.dx);
          final nextRotation = currentAngle + (math.pi / 2);
          final nextLength = (coordinateSystem.normalize(delta.distance) /
                  ref.watch(screenZoomProvider))
              .clamp(ViewConeUtility.minLength, ViewConeUtility.maxLength);

          setState(() {
            _localRotation = nextRotation;
            _localLength = nextLength.toDouble();
          });
        },
        onPanEnd: (_) {
          ref.read(agentProvider.notifier).updateViewConeGeometry(
                id: current.id,
                rotation: _localRotation ?? current.rotation,
                length: _localLength ?? current.length,
              );
          setState(() {
            _rotationOrigin = Offset.zero;
          });
        },
        child: Draggable<PlacedWidget>(
          data: current,
          dragAnchorStrategy: (draggable, context, position) {
            final renderObject = context.findRenderObject()! as RenderBox;
            final rotatedPosition = _rotateOffset(
              renderObject.globalToLocal(position),
              agentCenterScaled,
              localRotation,
            );

            return ref
                .read(screenZoomProvider.notifier)
                .zoomOffset(rotatedPosition);
          },
          feedback: Opacity(
            opacity: Settings.feedbackOpacity,
            child: ZoomTransform(
              child: ViewConeAgentComposite(
                agent: current,
                rotation: localRotation,
                length: localLength,
                forcedAgentSize: agentSize,
              ),
            ),
          ),
          childWhenDragging: const SizedBox.shrink(),
          onDragStarted: () {
            final shouldDuplicate = HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed;
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
          child: ViewConeAgentComposite(
            agent: current,
            rotation: 0,
            length: localLength,
            forcedAgentSize: agentSize,
            applyRotation: false,
          ),
        ),
      ),
    );
  }
}
