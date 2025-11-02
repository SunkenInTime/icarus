// ignore_for_file: prefer_const_constructors

import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/ability_bar_provider.dart';

import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/widgets/dot_painter.dart';

import 'package:icarus/widgets/drawing_painter.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:screenshot/screenshot.dart';

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
          color: const Color(0xFF1B1B1B),
          child: InteractiveViewer(
            transformationController: controller,
            onInteractionEnd: (details) {
              ref
                  .read(screenZoomProvider.notifier)
                  .updateZoom(controller.value.getMaxScaleOnAxis());
            },
            child: Stack(
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
                      : PlacedWidgetBuilder(),
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
                  child: InteractivePainter(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
