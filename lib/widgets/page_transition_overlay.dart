import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/ability_vision.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';

import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/page_transition/agent_path.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_circle_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/agents/placed_view_cone_agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_vision_cone_composite.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';

Offset _overlayScreenPosition({
  required PlacedWidget widget,
  required CoordinateSystem coordinateSystem,
  required double agentSize,
  required double mapScale,
  required double abilitySize,
  Offset? coordinatePosition,
}) {
  final screen = screenPositionForWidget(
    widget: widget,
    coordinateSystem: coordinateSystem,
    coordinatePosition: coordinatePosition,
    mapScale: mapScale,
    agentSize: agentSize,
    abilitySize: abilitySize,
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
  if (widget is PlacedAbility &&
      widget.visualState.showVisionCone &&
      AbilityVisionConeSpec.forAbility(widget.data) != null &&
      widget.data.abilityData != null) {
    return screen -
        abilityVisionConeChildOffsetScreen(
          coordinateSystem: coordinateSystem,
          ability: widget.data.abilityData!,
          mapScale: mapScale,
          abilitySize: abilitySize,
        );
  }
  return screen;
}

/// Pure, progress-parameterized rendering of a set of transition entries.
/// Shared by the live [PageTransitionOverlay] and the video exporter, so the
/// exported frames can never drift from the in-app page switch.
class TransitionEntriesLayer extends ConsumerWidget {
  const TransitionEntriesLayer({
    super.key,
    required this.entries,
    required this.agentPaths,
    required this.t,
    required this.direction,
    required this.agentSize,
    required this.abilitySize,
  });

  final List<PageTransitionEntry> entries;
  final Map<String, AgentTransitionPath> agentPaths;

  /// Curved progress in [0, 1].
  final double t;
  final PageTransitionDirection direction;

  /// Marker sizes already interpolated for [t].
  final double agentSize;
  final double abilitySize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapScale = Maps.mapScale[ref.watch(mapProvider).currentMap] ?? 1.0;
    final orderedEntries = [...entries]..sort(PageLayering.compareEntries);
    final renderer = _EntryRenderer(
      coordinateSystem: CoordinateSystem.instance,
      mapScale: mapScale,
      direction: direction,
      agentSize: agentSize,
      abilitySize: abilitySize,
      agentPaths: agentPaths,
      t: t,
    );

    return IgnorePointer(
      ignoring: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final entry in orderedEntries) renderer.buildEntry(entry),
        ],
      ),
    );
  }
}

class _EntryRenderer {
  const _EntryRenderer({
    required this.coordinateSystem,
    required this.mapScale,
    required this.direction,
    required this.agentSize,
    required this.abilitySize,
    required this.agentPaths,
    required this.t,
  });

  final CoordinateSystem coordinateSystem;
  final double mapScale;
  final PageTransitionDirection direction;
  final double agentSize;
  final double abilitySize;
  final Map<String, AgentTransitionPath> agentPaths;
  final double t;

  Offset _startScreenPosition(PageTransitionEntry entry) {
    return _overlayScreenPosition(
      widget: entry.from ?? entry.to!,
      coordinateSystem: coordinateSystem,
      coordinatePosition: entry.startPos,
      agentSize: agentSize,
      mapScale: mapScale,
      abilitySize: abilitySize,
    );
  }

  Offset _endScreenPosition(PageTransitionEntry entry) {
    return _overlayScreenPosition(
      widget: entry.to ?? entry.from!,
      coordinateSystem: coordinateSystem,
      coordinatePosition: entry.endPos,
      agentSize: agentSize,
      mapScale: mapScale,
      abilitySize: abilitySize,
    );
  }

  Widget buildEntry(PageTransitionEntry entry) {
    final directionalOffset = coordinateSystem.scale(28);
    final directionSign =
        direction == PageTransitionDirection.forward ? 1.0 : -1.0;
    switch (entry.kind) {
      case TransitionKind.none:
        return _overlayItem(
          key: ValueKey('none_${entry.id}'),
          widget: entry.to!,
          pos: _endScreenPosition(entry),
          coordinatePosition: entry.endPos,
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
        );
      case TransitionKind.disappear:
        final screenTranslation = Offset(
          -directionSign * directionalOffset * t,
          0,
        );
        final coordinatePosition = entry.startPos +
            Offset(
              coordinateSystem.screenWidthToWorld(screenTranslation.dx),
              0,
            );
        final start = _startScreenPosition(entry)
            .translate(screenTranslation.dx, screenTranslation.dy);
        return _overlayItem(
          key: ValueKey('disappear_${entry.id}'),
          widget: entry.from!,
          pos: start,
          coordinatePosition: coordinatePosition,
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
        );
      case TransitionKind.move:
        final start = _startScreenPosition(entry);
        final end = _endScreenPosition(entry);
        final agentPath = agentPaths[entry.id];
        final pathPosition = agentPath?.positionAt(t);
        final pathTopLeft = pathPosition == null
            ? null
            : pathPosition -
                coordinateSystem.virtualOffsetToWorld(
                  Offset(agentSize / 2, agentSize / 2),
                );
        final coordinatePosition = pathTopLeft ??
            (Offset.lerp(entry.startPos, entry.endPos, t) ?? entry.endPos);
        final position = pathTopLeft == null
            ? (Offset.lerp(start, end, t) ?? end)
            : _overlayScreenPosition(
                widget: entry.to!,
                coordinateSystem: coordinateSystem,
                coordinatePosition: coordinatePosition,
                agentSize: agentSize,
                mapScale: mapScale,
                abilitySize: abilitySize,
              );
        return _overlayItem(
          key: ValueKey('move_${entry.id}'),
          widget: entry.to!,
          pos: position,
          coordinatePosition: coordinatePosition,
          opacity: 1,
          length: _lerpLength(entry.startLength, entry.endLength, t),
          armLengthsMeters: _lerpArmLengths(
            entry.startArmLengths,
            entry.endArmLengths,
            t,
          ),
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
        );
      case TransitionKind.appear:
        final screenTranslation = Offset(
          directionSign * directionalOffset * (1 - t),
          0,
        );
        final coordinatePosition = entry.endPos +
            Offset(
              coordinateSystem.screenWidthToWorld(screenTranslation.dx),
              0,
            );
        final end = _endScreenPosition(entry)
            .translate(screenTranslation.dx, screenTranslation.dy);
        // Images fade in early (front-loaded), like the drawing layer.
        final appearOpacity =
            entry.to is PlacedImage ? earlyFadeInOpacity(t) : t;
        return _overlayItem(
          key: ValueKey('appear_${entry.id}'),
          widget: entry.to!,
          pos: end,
          coordinatePosition: coordinatePosition,
          opacity: appearOpacity,
          length: entry.endLength,
          armLengthsMeters: entry.endArmLengths,
          rotation: entry.endRotation,
          scale: entry.endScale,
          textSize: entry.endTextSize,
          customDiameter: entry.endCustomDiameter,
          customWidth: entry.endCustomWidth,
          customLength: entry.endCustomLength,
          deadStateProgress: _deadStateProgressForEntry(entry, 1),
        );
    }
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
    required Offset coordinatePosition,
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
  }) {
    Widget child = PlacedWidgetPreview.build(
      widget,
      mapScale,
      coordinatePosition: coordinatePosition,
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
              .scale(
                coordinateSystem.scaleFactor,
                coordinateSystem.scaleFactor,
              ),
          child: child,
        );
      } else if (widget is PlacedUtility) {
        child = Transform.rotate(
          angle: angle,
          alignment: Alignment.topLeft,
          origin: utilityAnchorForScale(
            utility: widget,
            mapScale: mapScale,
            agentSize: agentSize,
            abilitySize: abilitySize,
          ).scale(
            coordinateSystem.scaleFactor,
            coordinateSystem.scaleFactor,
          ),
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
      if (widget.visualState.showVisionCone &&
          AbilityVisionConeSpec.forAbility(widget.data) != null) {
        return false;
      }
      return isRotatable(ability);
    }
    return widget is PlacedUtility;
  }
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
          ref
              .read(transitionProvider.notifier)
              .setProgress(kPageTransitionCurve.transform(_controller!.value));
          setState(() {});
        })
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            final notifier = ref.read(transitionProvider.notifier);
            Future.microtask(() {
              notifier.complete();
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(transitionProvider);
    _syncAnimation(state);

    if (!state.active) {
      return const SizedBox.shrink();
    }

    final t = kPageTransitionCurve.transform(_controller!.value);
    final agentSize = _lerpRequired(
      state.startAgentSize,
      state.endAgentSize,
      t,
    );
    final abilitySize = _lerpRequired(
      state.startAbilitySize,
      state.endAbilitySize,
      t,
    );

    return TransitionEntriesLayer(
      entries: state.entries,
      agentPaths: state.agentPaths,
      t: t,
      direction: state.direction,
      agentSize: agentSize,
      abilitySize: abilitySize,
    );
  }

  double _lerpRequired(double a, double b, double t) => a + (b - a) * t;
}

class PlacedWidgetPreview {
  static Widget build(
    PlacedWidget w,
    double mapScale, {
    Offset? coordinatePosition,
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
        isInteractive: false,
      );
    }
    if (w is PlacedViewConeAgent) {
      final previewAgent = coordinatePosition == null
          ? w
          : w.copyWith(position: coordinatePosition);
      return ViewConeAgentComposite(
        agent: previewAgent,
        rotation: rotation ?? w.rotation,
        length: length ?? w.length,
        forcedAgentSize: agentSize,
        isInteractive: false,
      );
    }
    if (w is PlacedCircleAgent) {
      return CircleAgentComposite(
        agent: w.copyWith(diameterMeters: customDiameter ?? w.diameterMeters),
        forcedAgentSize: agentSize,
        isInteractive: false,
      );
    }
    if (w is PlacedAbility) {
      if (w.data.abilityData == null) {
        return const SizedBox.shrink();
      }
      final ability = w.data.abilityData!;
      final visionSpec = AbilityVisionConeSpec.forAbility(w.data);
      if (visionSpec != null && w.visualState.showVisionCone) {
        final child = ability.createWidget(
          id: w.id,
          isAlly: w.isAlly,
          mapScale: mapScale,
          rotation: rotation ?? w.rotation,
          length: length ?? w.length,
          armLengthsMeters: armLengthsMeters ?? w.armLengthsMeters,
          visualState: w.visualState,
          watchMouse: false,
        );
        return AbilityVisionConeComposite(
          ability: w,
          spec: visionSpec,
          rotation: rotation ?? w.rotation,
          length: length ?? w.length,
          mapScale: mapScale,
          abilitySize: abilitySize,
          coordinatePosition: coordinatePosition,
          child: child,
        );
      }

      switch (ability) {
        case BaseAbility():
          return ability.createWidget(
            id: w.id,
            isAlly: w.isAlly,
            mapScale: mapScale,
            visualState: w.visualState,
            watchMouse: false,
          );
        case ImageAbility():
          return ability.createWidget(
            id: w.id,
            isAlly: w.isAlly,
            mapScale: mapScale,
            visualState: w.visualState,
            watchMouse: false,
          );
        case CircleAbility():
          return ability.createWidget(
            id: w.id,
            isAlly: w.isAlly,
            mapScale: mapScale,
            visualState: w.visualState,
            watchMouse: false,
          );
        case SectorCircleAbility():
          return ability.createWidget(
            id: w.id,
            isAlly: w.isAlly,
            mapScale: mapScale,
            rotation: rotation ?? w.rotation,
            visualState: w.visualState,
            watchMouse: false,
          );
        case DeadlockBarrierMeshAbility():
          return ability.createWidget(
            id: w.id,
            isAlly: w.isAlly,
            mapScale: mapScale,
            armLengthsMeters: armLengthsMeters ?? w.armLengthsMeters,
            visualState: w.visualState,
            watchMouse: false,
          );
        case SquareAbility():
          return ability.createWidget(
            id: w.id,
            isAlly: w.isAlly,
            mapScale: mapScale,
            rotation: rotation ?? w.rotation,
            length: length ?? w.length,
            visualState: w.visualState,
            watchMouse: false,
          );
        case CenterSquareAbility():
          return ability.createWidget(
            id: w.id,
            isAlly: w.isAlly,
            mapScale: mapScale,
            rotation: rotation ?? w.rotation,
            length: length ?? w.length,
            visualState: w.visualState,
            watchMouse: false,
          );
        case RotatableImageAbility():
          return ability.createWidget(
            id: w.id,
            isAlly: w.isAlly,
            mapScale: mapScale,
            length: length ?? w.length,
            visualState: w.visualState,
            watchMouse: false,
          );
      }
    }

    if (w is PlacedText) {
      return TextWidget(
        text: w.text,
        id: w.id,
        size: textSize ?? w.size,
        fontSize: w.fontSize,
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
      if (UtilityData.isViewCone(w.type)) {
        final resolvedPosition = coordinatePosition ?? w.position;
        return ViewConeWidget(
          id: null,
          angle: UtilityData.getViewConeAngle(w.type),
          rotation: rotation ?? w.rotation,
          length: length ?? w.length,
          worldOrigin: resolvedPosition +
              CoordinateSystem.instance.virtualOffsetToWorld(
                ViewConeWidget.anchorPointVirtual,
              ),
          visionElevation: w.visionElevation,
        );
      }
      return UtilityData.utilityWidgets[w.type]!.createWidget(
        id: w.id,
        isAlly: w.isAlly,
        rotation: rotation ?? w.rotation,
        length: length ?? w.length,
        mapScale: mapScale,
        agentSize: agentSize,
        abilitySize: abilitySize,
        diameterMeters: customDiameter ?? w.customDiameter,
        widthMeters: customWidth ?? w.customWidth,
        rectLengthMeters: customLength ?? w.customLength,
        colorValue: w.customColorValue,
        opacityPercent: w.customOpacityPercent,
        // Custom shapes only show their center marker on hover; the
        // non-interactive transition overlay matches the unhovered state.
        showCenterMarker: !UtilityData.isCustomShape(w.type),
      );
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

  Widget _widgetView({
    required PlacedWidget widget,
    required double mapScale,
    required double abilitySize,
    required double agentSize,
  }) {
    final coord = CoordinateSystem.instance;
    final scaledPosition = _overlayScreenPosition(
      widget: widget,
      coordinateSystem: coord,
      agentSize: agentSize,
      mapScale: mapScale,
      abilitySize: abilitySize,
    );

    if (widget is PlacedUtility && widget.rotation != 0) {
      return Positioned(
        left: scaledPosition.dx,
        top: scaledPosition.dy,
        child: Transform.rotate(
          angle: widget.rotation,
          alignment: Alignment.topLeft,
          origin: utilityAnchorForScale(
            utility: widget,
            mapScale: mapScale,
            agentSize: agentSize,
            abilitySize: abilitySize,
          ).scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          ),
          child: PlacedWidgetPreview.build(
            widget,
            mapScale,
            length: widget.length,
            agentSize: agentSize,
            abilitySize: abilitySize,
          ),
        ),
      );
    } else if (widget is PlacedAbility &&
        widget.rotation != 0 &&
        widget.data.abilityData != null &&
        !(widget.visualState.showVisionCone &&
            AbilityVisionConeSpec.forAbility(widget.data) != null) &&
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
          length: widget is PlacedAbility ? widget.length : null,
          armLengthsMeters:
              widget is PlacedAbility ? widget.armLengthsMeters : null,
          agentSize: agentSize,
          abilitySize: abilitySize,
        ),
      );
    }
  }
}
