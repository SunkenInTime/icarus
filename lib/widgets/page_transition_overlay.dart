import 'dart:developer' show log;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/widgets/custom_button.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';

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
    _ensureController(const Duration(seconds: 2));
    _controller!.forward(from: 0);
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
      }
    }

    log('Transition t=$t, moving=${moving.length}, appearing=${appearing.length}, disappearing=${disappearing.length}');

    return Stack(
      children: [
        // Align(
        //   child: SizedBox(
        //     width: 70,
        //     child: CustomButton(
        //       onPressed: () {
        //         _controller!.forward(from: 0);
        //       },
        //       height: 80,
        //       icon: const Icon(Icons.play_arrow),
        //       label: '',
        //       labelColor: Colors.white,
        //       backgroundColor: Colors.deepPurpleAccent,
        //     ),
        //   ),
        // ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: true,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Disappear: fixed at start position, fade out
                for (final e in disappearing)
                  _overlayItem(
                    key: ValueKey('disappear_${e.id}'),
                    widget: e.from!,
                    pos: coord.coordinateToScreen(e.startPos),
                    opacity: 1 - t,
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
          ),
        ),
      ],
    );
  }

  double? _lerpAngle(double? a, double? b, double t) {
    if (a == null || b == null) return null;
    return a + (b - a) * t;
  }

  Widget _overlayItem({
    required Key key,
    required PlacedWidget widget,
    required Offset pos,
    required double opacity,
    double? rotation,
  }) {
    //TODO: Set map scale
    log("jsf");
    Widget child =
        PlacedWidgetPreview.build(widget, 1); // central factory (below)
    if (rotation != null)
      child = Transform.rotate(angle: rotation, child: child);
    return Positioned(
      key: key,
      left: pos.dx,
      top: pos.dy,
      child: Opacity(opacity: opacity, child: child),
    );
  }
}

//Have animation controller be a value between 0-1
// Then the widgets would simply multiply their position by that value
// So if the widget is at 100, it would be at 0 when the value is 0, and at 100 when the value is 1
// This would allow for easy transitions between pages without needing to know the exact positions of each widget

// There needs to be 3 stack layers
// one for the widgets that are appearing
// one for the widgets that are disappearing
// one for widgets that are moving/or getting adjusted in some way

// for widgets that are moving or getting adjusted in some way
// they would need to have a delta postion and a delta size
// delta position is needed because position needs an x and y
// delta size is needed for things that only have one axis of movement/like/rotation or scale/length

//For appear/disappear widgets
// we would just need to use the PlacedWidgetBuilder and wrap an opacity animation around it
// and have the opacity be controlled by the animation controller value

//This would allow for reuse of widgets as they are as we are simply modifying their percentage of movement/adjustment to simulate actual value changes
//For multiplying the position/size/rotation/scale values by the animation scale we can use the provider to perform those functions on the PlacedWidget data type and we simply just render them with a modified PlacedWidgetBuilder, that fetches data from that source just like the others.

// I believe part of this work would involve modifying the PlacedWidgetBuilder to accept modified data from a source other than the provider, so that we can use it to render the widgets in their transition states or we could simply copy and paste and make our edits

class PlacedWidgetPreview {
  static Widget build(PlacedWidget w, double mapScale) {
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
          return ability.createWidget(w.id, w.isAlly, mapScale);
        case ImageAbility():
          return ability.createWidget(w.id, w.isAlly, mapScale);
        case CircleAbility():
          return ability.createWidget(w.id, w.isAlly, mapScale);
        case SquareAbility():
          return ability.createWidget(
              w.id, w.isAlly, mapScale, w.rotation, w.length);
        case CenterSquareAbility():
          return ability.createWidget(w.id, w.isAlly, mapScale);
        case RotatableImageAbility():
          return ability.createWidget(w.id, w.isAlly, mapScale);
      }
    }

    // if (w is PlacedText) {
    //   return PlacedTextBuilder(size: w.size, placedText: w, onDragEnd: (_) {});
    // }

    // if (w is PlacedImage) {
    //   return PlacedImageBuilder(
    //       placedImage: w, scale: w.scale, onDragEnd: (_) {});
    // }
    // if (w is PlacedUtility) {
    //   return UtilityWidgetBuilder(
    //     rotation: w.rotation,
    //     length: w.length,
    //     utility: w,
    //     id: w.id,
    //     onDragEnd: (_) {},
    //   );
    // }
    return const SizedBox.shrink();
  }
}
