// ignore_for_file: prefer_const_constructors

import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/transition_provider.dart';

import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/drawing_painter.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:icarus/widgets/image_drop_target.dart';
import 'package:icarus/widgets/line_up_placer.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class InteractiveMap extends ConsumerStatefulWidget {
  const InteractiveMap({
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _InteractiveMapState();
}

class _InteractiveMapState extends ConsumerState<InteractiveMap> {
  final controller = TransformationController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    log(MediaQuery.sizeOf(context).height.toString());
    bool isAttack = ref.watch(mapProvider).isAttack;

    String assetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_map${isAttack ? "" : "_defense"}.svg';
    String barrierAssetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_map_spawn_wall.svg';

    final double height = MediaQuery.sizeOf(context).height - 90;
    final Size playAreaSize = Size(height * 1.2, height);
    CoordinateSystem(playAreaSize: playAreaSize);
    CoordinateSystem coordinateSystem = CoordinateSystem.instance;

    return Row(
      children: [
        Container(
          width: coordinateSystem.playAreaSize.width,
          height: coordinateSystem.playAreaSize.height,
          // color: ShadTheme.of(context).colorScheme.card,
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.5,
              colors: [
                Color(0xff18181b), // Zinc-900 (Darker center - under the map)
                ShadTheme.of(context)
                    .colorScheme
                    .background, // Zinc-950 (Dark edges - under the UI)
              ],
            ),
          ),
          child: ImageDropTarget(
            child: InteractiveViewer(
              transformationController: controller,
              onInteractionEnd: (details) {
                ref
                    .read(screenZoomProvider.notifier)
                    .updateZoom(controller.value.getMaxScaleOnAxis());
              },
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  //Dot Grid
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        ref.read(abilityBarProvider.notifier).updateData(null);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: DotGrid(),
                      ),
                    ),
                  ),
                  // Map SVG
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        ref.read(abilityBarProvider.notifier).updateData(null);
                      },
                      child: SvgPicture.asset(
                        assetName,
                        semanticsLabel: 'Map',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  if (ref.watch(mapProvider).showSpawnBarrier)
                    Positioned.fill(
                      top: 0,
                      left: isAttack ? -1.5 : 1.5,
                      child: Transform.flip(
                        flipX: !isAttack,
                        flipY: !isAttack,
                        child: SvgPicture.asset(
                          barrierAssetName,
                          semanticsLabel: 'Barrier',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  //Agents

                  Positioned.fill(
                    child: ref.watch(transitionProvider).hideView
                        ? SizedBox.shrink()
                        : Opacity(
                            opacity: ref.watch(interactionStateProvider) ==
                                    InteractionState.lineUpPlacing
                                ? 0.2
                                : 1.0,
                            child: PlacedWidgetBuilder(),
                          ),
                  ),

                  // Positioned.fill(child: child)
                  Positioned.fill(
                    child: ref.watch(transitionProvider).active
                        ? PageTransitionOverlay()
                        : SizedBox.shrink(),
                  ),
                  Positioned.fill(
                    child: ref.watch(transitionProvider).hideView &&
                            !ref.watch(transitionProvider).active
                        ? TemporaryWidgetBuilder()
                        : SizedBox.shrink(),
                  ),

                  //Painting
                  Positioned.fill(
                    child: Opacity(
                      opacity: ref.watch(interactionStateProvider) ==
                              InteractionState.lineUpPlacing
                          ? 0.2
                          : 1.0,
                      child: Transform.flip(
                          flipX: !isAttack,
                          flipY: !isAttack,
                          child: InteractivePainter()),
                    ),
                  ),

                  if (ref.watch(interactionStateProvider) ==
                      InteractionState.lineUpPlacing)
                    Positioned.fill(
                      child: LineupPositionWidget(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
