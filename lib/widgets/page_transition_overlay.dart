import 'dart:developer' show log;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';

import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_circle_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_view_cone_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';

Offset _overlayScreenPosition({
  required PlacedWidget widget,
  required CoordinateSystem coordinateSystem,
  required double agentSize,
  required double mapScale,
  Offset? coordinatePosition,
}) {
  final screen = screenPositionForWidget(
    widget: widget,
    coordinateSystem: coordinateSystem,
    coordinatePosition: coordinatePosition,
  );
  if (widget is PlacedViewConeAgent) {
    return screen -
        viewConeAgentCompositeAgentOffsetScreen(
          coordinateSystem: coordinateSystem,
          agentSize: agentSize,
        );
  }
  if (widget is PlacedCircleAgent) {
    return screen -
        circleAgentCompositeAgentOffsetScreen(
          coordinateSystem: coordinateSystem,
          agentSize: agentSize,
          mapScale: mapScale,
        );
  }
  return screen;
}

class PageTransitionOverlay extends ConsumerStatefulWidget {
  const PageTransitionOverlay({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() =>
      _PageTransitionOverlayState();
}

class _PageTransitionOverlayState extends ConsumerState<PageTransitionOverlay>
    with TickerProviderStateMixin {
  AnimationController? _controller;
  int? _activeTransitionId;

  @override
  void initState() {
    super.initState();
    _ensureController(kPageTransitionDuration);
  }

  void _ensureController(Duration duration) {
    if (_controller == null) {
      _controller = AnimationController(vsync: this, duration: duration)
        ..addListener(() {
          // ref.read(transitionProvider.notifier).setProgress(_controller!.value);
          setState(() {});
        })
        ..addStatusListener((status) {
          log("Status is${status.toString()}");
          if (status == AnimationStatus.completed) {
            // Defer provider write until after the frame.
            // log("Completed");
            final notifier = ref.read(transitionProvider.notifier);
            log("Calling complete");
            Future.microtask(() {
              try {
                notifier.complete();
              } catch (e, st) {
                log('Error calling complete: $e\n$st');
              }
            });
          }
        });
      return;
    }
    if (_controller!.duration != duration) {
      _controller!.duration = duration;
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _syncAnimation(PageTransitionState state) {
    _ensureController(state.duration);
    if (!state.active) {
      return;
    }
    if (_activeTransitionId == state.transitionId) {
      return;
    }
    _activeTransitionId = state.transitionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final latest = ref.read(transitionProvider);
      if (!latest.active || latest.transitionId != _activeTransitionId) return;
      _controller!.forward(from: 0);
    });
  }

  Offset _startScreenPosition(PageTransitionEntry entry,
      CoordinateSystem coordinateSystem, double agentSize) {
    final mapScale = Maps.mapScale[ref.read(mapProvider).currentMap] ?? 1.0;
    return _overlayScreenPosition(
      widget: entry.from ?? entry.to!,
      coordinateSystem: coordinateSystem,
      coordinatePosition: entry.startPos,
      agentSize: agentSize,
      mapScale: mapScale,
    );
  }

  Offset _endScreenPosition(PageTransitionEntry entry,
      CoordinateSystem coordinateSystem, double agentSize) {
    final mapScale = Maps.mapScale[ref.read(mapProvider).currentMap] ?? 1.0;
    return _overlayScreenPosition(
      widget: entry.to ?? entry.from!,
      coordinateSystem: coordinateSystem,
      coordinatePosition: entry.endPos,
      agentSize: agentSize,
      mapScale: mapScale,
    );
  }

  Widget _buildEntry(
      {required PageTransitionEntry entry,
      required double t,
      required CoordinateSystem coordinateSystem,
      required PageTransitionDirection direction,
      required double agentSize,
      required double abilitySize}) {
    final directionalOffset = coordinateSystem.scale(28);
    final directionSign =
        direction == PageTransitionDirection.forward ? 1.0 : -1.0;
    switch (entry.kind) {
      case TransitionKind.none:
        return _overlayItem(
          key: ValueKey('none_${entry.id}'),
          widget: entry.to!,
          pos: _endScreenPosition(entry, coordinateSystem, agentSize),
          opacity: 1,
          length: entry.endLength,
          armLengthsMeters: entry.endArmLengths,
          rotation: entry.endRotation,
          scale: entry.endScale,
          textSize: entry.endTextSize,
          customDiameter: entry.endCustomDiameter,
          customWidth: entry.endCustomWidth,
          customLength: entry.endCustomLength,
          deadStateProgress: _deadStateProgressForEntry(entry, 1),
          agentSize: agentSize,
          abilitySize: abilitySize,
        );
      case TransitionKind.disappear:
        final start = _startScreenPosition(
          entry,
          coordinateSystem,
          agentSize,
        ).translate(
          -directionSign * directionalOffset * t,
          0,
        );
        return _overlayItem(
          key: ValueKey('disappear_${entry.id}'),
          widget: entry.from!,
          pos: start,
          opacity: 1 - t,
          length: entry.startLength,
          armLengthsMeters: entry.startArmLengths,
          rotation: entry.startRotation,
          scale: entry.startScale,
          textSize: entry.startTextSize,
          customDiameter: entry.startCustomDiameter,
          customWidth: entry.startCustomWidth,
          customLength: entry.startCustomLength,
          deadStateProgress: _deadStateProgressForEntry(entry, 0),
          agentSize: agentSize,
          abilitySize: abilitySize,
        );
      case TransitionKind.move:
        final start = _startScreenPosition(entry, coordinateSystem, agentSize);
        final end = _endScreenPosition(entry, coordinateSystem, agentSize);
        return _overlayItem(
          key: ValueKey('move_${entry.id}'),
          widget: entry.to!,
          pos: Offset.lerp(start, end, t) ?? end,
          opacity: 1,
          length: _lerpLength(entry.startLength, entry.endLength, t),
          armLengthsMeters:
              _lerpArmLengths(entry.startArmLengths, entry.endArmLengths, t),
          rotation: _lerpAngle(entry.startRotation, entry.endRotation, t),
          scale: _lerpDouble(entry.startScale, entry.endScale, t),
          textSize: _lerpDouble(entry.startTextSize, entry.endTextSize, t),
          customDiameter: _lerpDouble(
            entry.startCustomDiameter,
            entry.endCustomDiameter,
            t,
          ),
          deadStateProgress: _deadStateProgressForEntry(entry, t),
          customWidth: _lerpDouble(
            entry.startCustomWidth,
            entry.endCustomWidth,
            t,
          ),
          customLength: _lerpDouble(
            entry.startCustomLength,
            entry.endCustomLength,
            t,
          ),
          agentSize: agentSize,
          abilitySize: abilitySize,
        );
      case TransitionKind.appear:
        final end = _endScreenPosition(
          entry,
          coordinateSystem,
          agentSize,
        ).translate(
          directionSign * directionalOffset * (1 - t),
          0,
        );
        return _overlayItem(
          key: ValueKey('appear_${entry.id}'),
          widget: entry.to!,
          pos: end,
          opacity: t,
          length: entry.endLength,
          armLengthsMeters: entry.endArmLengths,
          rotation: entry.endRotation,
          scale: entry.endScale,
          textSize: entry.endTextSize,
          customDiameter: entry.endCustomDiameter,
          customWidth: entry.endCustomWidth,
          customLength: entry.endCustomLength,
          deadStateProgress: _deadStateProgressForEntry(entry, 1),
          agentSize: agentSize,
          abilitySize: abilitySize,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final coord = CoordinateSystem.instance;
    final state = ref.watch(transitionProvider);
    _syncAnimation(state);

    if (!state.active) {
      return const SizedBox.shrink();
    }

    final t = Curves.easeInOutCubic.transform(_controller!.value);
    final agentSize =
        _lerpRequired(state.startAgentSize, state.endAgentSize, t);
    final abilitySize =
        _lerpRequired(state.startAbilitySize, state.endAbilitySize, t);
    final orderedEntries = [...state.entries]
      ..sort(PageLayering.compareEntries);

    return IgnorePointer(
      ignoring: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final entry in orderedEntries)
            _buildEntry(
              entry: entry,
              t: t,
              coordinateSystem: coord,
              direction: state.direction,
              agentSize: agentSize,
              abilitySize: abilitySize,
            ),
        ],
      ),
    );
  }

  double? _lerpAngle(double? a, double? b, double t) {
    if (a == null || b == null) return null;
    return a + (b - a) * t;
  }

  double? _lerpLength(double? a, double? b, double t) {
    if (a == null || b == null) return null;
    return a + (b - a) * t;
  }

  double? _lerpDouble(double? a, double? b, double t) {
    if (a == null || b == null) return null;
    return a + (b - a) * t;
  }

  List<double>? _lerpArmLengths(List<double>? a, List<double>? b, double t) {
    if (a == null || b == null || a.length != b.length) {
      return null;
    }

    return List<double>.generate(
      a.length,
      (index) => a[index] + (b[index] - a[index]) * t,
    );
  }

  double _lerpRequired(double a, double b, double t) => a + (b - a) * t;

  double? _deadStateProgressForEntry(PageTransitionEntry entry, double t) {
    final start = _agentDeadValue(entry.startAgentState);
    final end = _agentDeadValue(entry.endAgentState);
    if (start == null && end == null) {
      return null;
    }
    if (start == null) {
      return end;
    }
    if (end == null) {
      return start;
    }
    return _lerpRequired(start, end, t);
  }

  double? _agentDeadValue(AgentState? state) {
    if (state == null) {
      return null;
    }
    return state == AgentState.dead ? 1.0 : 0.0;
  }

  Widget _overlayItem({
    required Key key,
    required PlacedWidget widget,
    required Offset pos,
    required double opacity,
    double? length,
    List<double>? armLengthsMeters,
    double? rotation,
    double? scale,
    double? textSize,
    double? customDiameter,
    double? customWidth,
    double? customLength,
    double? deadStateProgress,
    required double agentSize,
    required double abilitySize,
  }) {
    final mapScale = Maps.mapScale[ref.read(mapProvider).currentMap]!;
    Widget child = PlacedWidgetPreview.build(
      widget,
      mapScale,
      length: length,
      armLengthsMeters: armLengthsMeters,
      rotation: rotation,
      scale: scale,
      textSize: textSize,
      customDiameter: customDiameter,
      customWidth: customWidth,
      customLength: customLength,
      deadStateProgress: deadStateProgress,
      agentSize: agentSize,
      abilitySize: abilitySize,
    ); // central factory (below)
    if (_shouldRotate(widget, rotation)) {
      final angle = rotation ?? 0;
      if (widget is PlacedAbility) {
        child = Transform.rotate(
          angle: angle,
          alignment: Alignment.topLeft,
          origin: (widget)
              .data
              .abilityData!
              .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
              .scale(CoordinateSystem.instance.scaleFactor,
                  CoordinateSystem.instance.scaleFactor),
          child: child,
        );
      } else if (widget is PlacedUtility) {
        child = Transform.rotate(
          angle: angle,
          alignment: Alignment.topLeft,
          origin: UtilityData.utilityWidgets[widget.type]!
              .getAnchorPoint()
              .scale(CoordinateSystem.instance.scaleFactor,
                  CoordinateSystem.instance.scaleFactor),
          child: child,
        );
      }
    }
    return Positioned(
      key: key,
      left: pos.dx,
      top: pos.dy,
      child: Opacity(opacity: opacity, child: child),
    );
  }

  bool _shouldRotate(PlacedWidget widget, double? rotation) {
    if (rotation == null || rotation == 0) {
      return false;
    }
    if (widget is PlacedAbility) {
      final ability = widget.data.abilityData;
      if (ability == null) {
        return false;
      }
      return isRotatable(ability);
    }
    return widget is PlacedUtility;
  }
}

class PlacedWidgetPreview {
  static Widget build(
    PlacedWidget w,
    double mapScale, {
    double? length,
    List<double>? armLengthsMeters,
    double? rotation,
    double? scale,
    double? textSize,
    double? customDiameter,
    double? customWidth,
    double? customLength,
    double? deadStateProgress,
    required double agentSize,
    required double abilitySize,
  }) {
    if (w is PlacedAgent) {
      return AgentWidget(
        isAlly: w.isAlly,
        id: w.id,
        agent: AgentData.agents[w.type]!,
        state: w.state,
        deadStateProgress: deadStateProgress,
        forcedAgentSize: agentSize,
      );
    }
    if (w is PlacedViewConeAgent) {
      return ViewConeAgentComposite(
        agent: w,
        rotation: rotation ?? w.rotation,
        length: length ?? w.length,
        forcedAgentSize: agentSize,
      );
    }
    if (w is PlacedCircleAgent) {
      return CircleAgentComposite(
        agent: w.copyWith(diameterMeters: customDiameter ?? w.diameterMeters),
        forcedAgentSize: agentSize,
      );
    }
    if (w is PlacedAbility) {
      if (w.data.abilityData == null) {
        return const SizedBox.shrink();
      }
      final ability = w.data.abilityData!;

      switch (ability) {
        case BaseAbility():
          return ability.createWidget(
              id: w.id, isAlly: w.isAlly, mapScale: mapScale);
        case ImageAbility():
          return ability.createWidget(
              id: w.id, isAlly: w.isAlly, mapScale: mapScale);
        case CircleAbility():
          return ability.createWidget(
              id: w.id, isAlly: w.isAlly, mapScale: mapScale);
        case DeadlockBarrierMeshAbility():
          return ability.createWidget(
            id: w.id,
            isAlly: w.isAlly,
            mapScale: mapScale,
            armLengthsMeters: armLengthsMeters ?? w.armLengthsMeters,
          );
        case SquareAbility():
          return ability.createWidget(
              id: w.id,
              isAlly: w.isAlly,
              mapScale: mapScale,
              rotation: w.rotation,
              length: length ?? w.length);
        case CenterSquareAbility():
          return ability.createWidget(
              id: w.id,
              isAlly: w.isAlly,
              mapScale: mapScale,
              length: length ?? w.length);
        case RotatableImageAbility():
          return ability.createWidget(
              id: w.id,
              isAlly: w.isAlly,
              mapScale: mapScale,
              length: length ?? w.length);
      }
    }

    if (w is PlacedText) {
      return TextWidget(
        text: w.text,
        id: w.id,
        size: textSize ?? w.size,
        tagColorValue: w.tagColorValue,
      );
    }

    if (w is PlacedImage) {
      return ImageWidget(
        fileExtension: w.fileExtension,
        aspectRatio: w.aspectRatio,
        link: w.link,
        scale: scale ?? w.scale,
        id: w.id,
        tagColorValue: w.tagColorValue,
      );
    }
    if (w is PlacedUtility) {
      return UtilityData.utilityWidgets[w.type]!.createWidget(
          id: w.id,
          rotation: w.rotation,
          length: length ?? w.length,
          mapScale: mapScale,
          diameterMeters: customDiameter ?? w.customDiameter,
          widthMeters: customWidth ?? w.customWidth,
          rectLengthMeters: customLength ?? w.customLength,
          colorValue: w.customColorValue,
          opacityPercent: w.customOpacityPercent);
    }
    return const SizedBox.shrink();
  }
}

class TemporaryWidgetBuilder extends ConsumerWidget {
  const TemporaryWidgetBuilder({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(transitionProvider);
    final mapScale = Maps.mapScale[ref.read(mapProvider).currentMap]!;
    final abilitySize = state.startAbilitySize;
    final agentSize = state.startAgentSize;
    final orderedWidgets = [...state.allWidgets]
      ..sort(PageLayering.comparePlacedWidgets);
    return IgnorePointer(
      ignoring: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final widget in orderedWidgets)
            _widgetView(
              widget: widget,
              mapScale: mapScale,
              abilitySize: abilitySize,
              agentSize: agentSize,
            ),
        ],
      ),
    );
  }

  Widget _widgetView(
      {required PlacedWidget widget,
      required double mapScale,
      required double abilitySize,
      required double agentSize}) {
    final coord = CoordinateSystem.instance;
    final scaledPosition = _overlayScreenPosition(
      widget: widget,
      coordinateSystem: coord,
      agentSize: agentSize,
      mapScale: mapScale,
    );

    if (widget is PlacedUtility && widget.rotation != 0) {
      return Positioned(
          left: scaledPosition.dx,
          top: scaledPosition.dy,
          child: Transform.rotate(
            angle: widget.rotation,
            alignment: Alignment.topLeft,
            origin: UtilityData.utilityWidgets[widget.type]!
                .getAnchorPoint()
                .scale(CoordinateSystem.instance.scaleFactor,
                    CoordinateSystem.instance.scaleFactor),
            child: PlacedWidgetPreview.build(
              widget,
              mapScale,
              length: widget.length,
              agentSize: agentSize,
              abilitySize: abilitySize,
            ),
          ));
    } else if (widget is PlacedAbility &&
        widget.rotation != 0 &&
        widget.data.abilityData != null &&
        isRotatable(widget.data.abilityData!)) {
      return Positioned(
        left: scaledPosition.dx,
        top: scaledPosition.dy,
        child: Transform.rotate(
          angle: widget.rotation,
          alignment: Alignment.topLeft,
          origin: (widget)
              .data
              .abilityData!
              .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
              .scale(coord.scaleFactor, coord.scaleFactor),
          child: PlacedWidgetPreview.build(
            widget,
            mapScale,
            length: widget.length,
            armLengthsMeters: widget.armLengthsMeters,
            agentSize: agentSize,
            abilitySize: abilitySize,
          ),
        ),
      );
    } else {
      return Positioned(
        left: scaledPosition.dx,
        top: scaledPosition.dy,
        child: PlacedWidgetPreview.build(
          widget,
          mapScale,
          armLengthsMeters:
              widget is PlacedAbility ? widget.armLengthsMeters : null,
          agentSize: agentSize,
          abilitySize: abilitySize,
        ),
      );
    }
  }
}
