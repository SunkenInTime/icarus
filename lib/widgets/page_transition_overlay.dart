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
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/image/image_widget.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';

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

  Offset _startScreenPosition(
      PageTransitionEntry entry, CoordinateSystem coordinateSystem) {
    return screenPositionForWidget(
      widget: entry.from ?? entry.to!,
      coordinateSystem: coordinateSystem,
      coordinatePosition: entry.startPos,
    );
  }

  Offset _endScreenPosition(
      PageTransitionEntry entry, CoordinateSystem coordinateSystem) {
    return screenPositionForWidget(
      widget: entry.to ?? entry.from!,
      coordinateSystem: coordinateSystem,
      coordinatePosition: entry.endPos,
    );
  }

  Widget _buildEntry(
      {required PageTransitionEntry entry,
      required double t,
      required CoordinateSystem coordinateSystem,
      required PageTransitionDirection direction}) {
    final directionalOffset = coordinateSystem.scale(28);
    final directionSign =
        direction == PageTransitionDirection.forward ? 1.0 : -1.0;
    switch (entry.kind) {
      case TransitionKind.none:
        return _overlayItem(
          key: ValueKey('none_${entry.id}'),
          widget: entry.to!,
          pos: _endScreenPosition(entry, coordinateSystem),
          opacity: 1,
          length: entry.endLength,
          rotation: entry.endRotation,
        );
      case TransitionKind.disappear:
        final start = _startScreenPosition(entry, coordinateSystem).translate(
          -directionSign * directionalOffset * t,
          0,
        );
        return _overlayItem(
          key: ValueKey('disappear_${entry.id}'),
          widget: entry.from!,
          pos: start,
          opacity: 1 - t,
          length: entry.startLength,
          rotation: entry.startRotation,
        );
      case TransitionKind.move:
        final start = _startScreenPosition(entry, coordinateSystem);
        final end = _endScreenPosition(entry, coordinateSystem);
        return _overlayItem(
          key: ValueKey('move_${entry.id}'),
          widget: entry.to!,
          pos: Offset.lerp(start, end, t) ?? end,
          opacity: 1,
          length: _lerpLength(entry.startLength, entry.endLength, t),
          rotation: _lerpAngle(entry.startRotation, entry.endRotation, t),
        );
      case TransitionKind.appear:
        final end = _endScreenPosition(entry, coordinateSystem).translate(
          directionSign * directionalOffset * (1 - t),
          0,
        );
        return _overlayItem(
          key: ValueKey('appear_${entry.id}'),
          widget: entry.to!,
          pos: end,
          opacity: t,
          length: entry.endLength,
          rotation: entry.endRotation,
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

  Widget _overlayItem({
    required Key key,
    required PlacedWidget widget,
    required Offset pos,
    required double opacity,
    double? length,
    double? rotation,
  }) {
    //TODO: Set map scale
    final mapScale = Maps.mapScale[ref.read(mapProvider).currentMap]!;
    final abilitySize = ref.read(strategySettingsProvider).abilitySize;
    Widget child = PlacedWidgetPreview.build(
        widget, mapScale, length); // central factory (below)
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
  static Widget build(PlacedWidget w, double mapScale, double? length) {
    if (w is PlacedAgent) {
      return AgentWidget(
          isAlly: w.isAlly, id: w.id, agent: AgentData.agents[w.type]!);
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
      return TextWidget(text: w.text, id: w.id, size: w.size);
    }

    if (w is PlacedImage) {
      return ImageWidget(
        fileExtension: w.fileExtension,
        aspectRatio: w.aspectRatio,
        link: w.link,
        scale: w.scale,
        id: w.id,
      );
    }
    if (w is PlacedUtility) {
      return UtilityData.utilityWidgets[w.type]!.createWidget(
          id: w.id,
          rotation: w.rotation,
          length: length ?? w.length,
          mapScale: mapScale);
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
    final abilitySize = ref.read(strategySettingsProvider).abilitySize;
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
            ),
        ],
      ),
    );
  }

  Widget _widgetView(
      {required PlacedWidget widget,
      required double mapScale,
      required double abilitySize}) {
    final coord = CoordinateSystem.instance;
    final scaledPosition = screenPositionForWidget(
      widget: widget,
      coordinateSystem: coord,
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
            child: PlacedWidgetPreview.build(widget, mapScale, widget.length),
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
          child: PlacedWidgetPreview.build(widget, mapScale, widget.length),
        ),
      );
    } else {
      return Positioned(
        left: scaledPosition.dx,
        top: scaledPosition.dy,
        child: PlacedWidgetPreview.build(widget, mapScale, null),
      );
    }
  }
}
