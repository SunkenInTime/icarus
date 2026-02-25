import 'dart:developer' show log;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
import 'package:icarus/widgets/delete_area.dart';
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
  @override
  void initState() {
    super.initState();
    _ensureController(const Duration(milliseconds: 200));

    SchedulerBinding.instance.addPostFrameCallback((_) {
      // This code will execute after the widget has been rendered
      // and its layout information is available.
      if (mounted) {
        // Check if the widget is still mounted
        ref.read(transitionProvider.notifier).setHideView(true);

        _controller!.forward(from: 0);
      }
    });
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

  @override
  Widget build(BuildContext context) {
    final coord = CoordinateSystem.instance;
    final state = ref.watch(transitionProvider);
    // if (!state.active) {
    //   _controller?.stop();
    //   log("Has stopped");
    //   return const SizedBox.shrink();
    // }

    log("Anim Ran");

    // _ensureController(state.duration);
    // // Start/restart when a transition becomes active and we're not currently animating
    // if (!_controller!.isAnimating) {
    //   _controller!.forward(from: 0);
    // }

    final t = Curves.easeInOut.transform(_controller!.value);
    log(t.toString());
    // Partition for clarity
    final moving = <PageTransitionEntry>[];
    final appearing = <PageTransitionEntry>[];
    final disappearing = <PageTransitionEntry>[];
    final none = <PageTransitionEntry>[];
    for (final e in state.entries) {
      switch (e.kind) {
        case TransitionKind.move:
          moving.add(e);
          break;
        case TransitionKind.appear:
          appearing.add(e);
          break;
        case TransitionKind.disappear:
          disappearing.add(e);
          break;
        case TransitionKind.none:
          none.add(e);
          break;
      }
    }

    log('Transition t=$t, moving=${moving.length}, appearing=${appearing.length}, disappearing=${disappearing.length}');

    return IgnorePointer(
      ignoring: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // None: unchanged items rendered at fixed position
          for (final e in none)
            _overlayItem(
              key: ValueKey('none_${e.id}'),
              widget: e.to!,
              pos: coord.coordinateToScreen(e.endPos),
              opacity: 1,
              length: e.endLength,
              rotation: e.endRotation,
            ),
          // Disappear: fixed at start position, fade out
          for (final e in disappearing)
            _overlayItem(
              key: ValueKey('disappear_${e.id}'),
              widget: e.from!,
              pos: coord.coordinateToScreen(e.startPos),
              opacity: 1 - t,
              length: e.startLength,
              rotation: e.startRotation,
            ),
          // Move: lerp start -> end
          for (final e in moving)
            _overlayItem(
              key: ValueKey('move_${e.id}'),
              widget: e.to!, // build with final data (visual)
              pos: Offset.lerp(coord.coordinateToScreen(e.startPos),
                      coord.coordinateToScreen(e.endPos), t) ??
                  coord.coordinateToScreen(e.endPos),
              opacity: 1,
              length: _lerpLength(e.startLength, e.endLength, t),
              rotation: _lerpAngle(e.startRotation, e.endRotation, t),
            ),
          // Appear: fixed at end position, fade in
          for (final e in appearing)
            _overlayItem(
              key: ValueKey('appear_${e.id}'),
              widget: e.to!,
              pos: coord.coordinateToScreen(e.endPos),
              opacity: t,
              rotation: e.endRotation,
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
    log("jsf");
    Widget child = PlacedWidgetPreview.build(
        widget, mapScale, length); // central factory (below)
    if (rotation != null && widget is PlacedAbility) {
      child = Transform.rotate(
        angle: rotation,
        alignment: Alignment.topLeft,
        origin: (widget)
            .data
            .abilityData!
            .getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize)
            .scale(CoordinateSystem.instance.scaleFactor,
                CoordinateSystem.instance.scaleFactor),
        child: child,
      );
    } else if (rotation != null && widget is PlacedUtility) {
      child = Transform.rotate(
        angle: rotation,
        alignment: Alignment.topLeft,
        origin: UtilityData.utilityWidgets[widget.type]!.getAnchorPoint().scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor),
        child: child,
      );
    }
    return Positioned(
      key: key,
      left: pos.dx,
      top: pos.dy,
      child: Opacity(opacity: opacity, child: child),
    );
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
    return IgnorePointer(
      ignoring: true,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final widget in state.allWidgets)
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
    final scaledPosition = coord.coordinateToScreen(widget.position);

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
    } else if (widget is PlacedAbility && widget.rotation != 0) {
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
