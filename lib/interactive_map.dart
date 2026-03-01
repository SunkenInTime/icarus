// ignore_for_file: prefer_const_constructors

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_bar_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/placement_center_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/transition_provider.dart';

import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/drawing_painter.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/delete_area.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:icarus/widgets/image_drop_target.dart';
import 'package:icarus/widgets/line_up_placer.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _MapSvgColorMapper extends ColorMapper {
  const _MapSvgColorMapper(this.replacements);

  final Map<int, Color> replacements;

  @override
  Color substitute(
    String? id,
    String elementName,
    String attributeName,
    Color color,
  ) {
    final opaqueColorValue = (color.toARGB32() & 0x00FFFFFF) | 0xFF000000;
    final replacement = replacements[opaqueColorValue];
    if (replacement == null) {
      return color;
    }
    // Keep per-element opacity from the original SVG.
    final alpha = (color.a * 255.0).round().clamp(0, 255);
    return replacement.withAlpha(alpha);
  }
}

class InteractiveMap extends ConsumerStatefulWidget {
  const InteractiveMap({
    super.key,
  });

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _InteractiveMapState();
}

class _InteractiveMapState extends ConsumerState<InteractiveMap> {
  static const Color _mapBaseSourceColor = Color(0xFF271406);
  static const Color _mapDetailSourceColor = Color(0xFFB27C40);
  static const Color _mapHighlightSourceColor = Color(0xFFF08234);

  final controller = TransformationController();
  Size? _lastViewportSize;
  bool _placementCenterUpdateScheduled = false;

  Offset _clampToWorld(Offset value, CoordinateSystem coordinateSystem) {
    const double edgePadding = 10.0;
    final double maxX = coordinateSystem.worldNormalizedWidth - edgePadding;
    final double maxY = coordinateSystem.normalizedHeight - edgePadding;
    return Offset(
      value.dx.clamp(edgePadding, maxX).toDouble(),
      value.dy.clamp(edgePadding, maxY).toDouble(),
    );
  }

  void _updatePlacementCenter({
    required double viewportWidth,
    required double viewportHeight,
    required CoordinateSystem coordinateSystem,
  }) {
    final sceneCenter =
        controller.toScene(Offset(viewportWidth / 2, viewportHeight / 2));
    final normalizedCenter = coordinateSystem.screenToCoordinate(sceneCenter);
    ref
        .read(placementCenterProvider.notifier)
        .updateCenter(_clampToWorld(normalizedCenter, coordinateSystem));
  }

  void _schedulePlacementCenterUpdate({
    required double viewportWidth,
    required double viewportHeight,
    required CoordinateSystem coordinateSystem,
  }) {
    if (_placementCenterUpdateScheduled) return;
    _placementCenterUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _placementCenterUpdateScheduled = false;
      if (!mounted) return;
      _updatePlacementCenter(
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
        coordinateSystem: coordinateSystem,
      );
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isAttack = ref.watch(mapProvider).isAttack;
    final effectivePalette = ref.watch(effectiveMapThemePaletteProvider);
    final mapColorMapper = _MapSvgColorMapper({
      _mapBaseSourceColor.toARGB32(): effectivePalette.baseColor,
      _mapDetailSourceColor.toARGB32(): effectivePalette.detailColor,
      _mapHighlightSourceColor.toARGB32(): effectivePalette.highlightColor,
    });

    String assetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_map${isAttack ? "" : "_defense"}.svg';
    String barrierAssetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_spawn_walls.svg';
    String calloutsAssetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_call_outs${isAttack ? "" : "_defense"}.svg';
    String ultOrbsAssetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_ult_orbs.svg';

    return LayoutBuilder(
      builder: (context, constraints) {
        final double height = MediaQuery.sizeOf(context).height - 90;
        final double worldWidth = height * (16 / 9);
        final Size playAreaSize = Size(worldWidth, height);
        CoordinateSystem(playAreaSize: playAreaSize);
        final coordinateSystem = CoordinateSystem.instance;
        final double viewportWidth =
            (constraints.maxWidth - Settings.sideBarReservedWidth)
                .clamp(0.0, constraints.maxWidth);
        final viewportSize = Size(viewportWidth, height);
        if (_lastViewportSize != viewportSize) {
          final double currentScale = controller.value.getMaxScaleOnAxis();
          final double safeScale = currentScale == 0 ? 1.0 : currentScale;
          final double centeredOffsetX =
              (viewportWidth - (worldWidth * safeScale)) / 2;
          final double centeredOffsetY = (height - (height * safeScale)) / 2;
          final matrix = Matrix4.identity()..scale(safeScale);
          matrix.translate(
              centeredOffsetX / safeScale, centeredOffsetY / safeScale);
          controller.value = matrix;
          _schedulePlacementCenterUpdate(
            viewportWidth: viewportWidth,
            viewportHeight: height,
            coordinateSystem: coordinateSystem,
          );
          _lastViewportSize = viewportSize;
        }
        final double mapWidth = height * coordinateSystem.mapAspectRatio;
        final double mapLeft = (worldWidth - mapWidth) / 2;

        return Row(
          children: [
            SizedBox(
              width: viewportWidth,
              height: height,
              child: Container(
                width: viewportWidth,
                height: height,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 1.5,
                    colors: [
                      Color(0xff18181b),
                      ShadTheme.of(context).colorScheme.background,
                    ],
                  ),
                ),
                child: ImageDropTarget(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: InteractiveViewer(
                          transformationController: controller,
                          constrained: false,
                          alignment: Alignment.topLeft,
                          minScale: 1.0,
                          maxScale: 8.0,
                          onInteractionUpdate: (_) {
                            ref.read(screenZoomProvider.notifier).updateZoom(
                                controller.value.getMaxScaleOnAxis());
                            _updatePlacementCenter(
                              viewportWidth: viewportWidth,
                              viewportHeight: height,
                              coordinateSystem: coordinateSystem,
                            );
                          },
                          onInteractionEnd: (details) {
                            ref.read(screenZoomProvider.notifier).updateZoom(
                                controller.value.getMaxScaleOnAxis());
                            _updatePlacementCenter(
                              viewportWidth: viewportWidth,
                              viewportHeight: height,
                              coordinateSystem: coordinateSystem,
                            );
                          },
                          child: SizedBox(
                            width: worldWidth,
                            height: height,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                // Dot Grid
                                Positioned.fill(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onTap: () {
                                      ref
                                          .read(abilityBarProvider.notifier)
                                          .updateData(null);
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(4.0),
                                      child: DotGrid(),
                                    ),
                                  ),
                                ),
                                // Map SVG
                                Positioned(
                                  left: mapLeft,
                                  top: 0,
                                  width: mapWidth,
                                  height: height,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.translucent,
                                    onTap: () {
                                      ref
                                          .read(abilityBarProvider.notifier)
                                          .updateData(null);
                                    },
                                    child: SvgPicture.asset(
                                      assetName,
                                      colorMapper: mapColorMapper,
                                      semanticsLabel: 'Map',
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                                if (ref.watch(mapProvider).showSpawnBarrier)
                                  Positioned(
                                    left: mapLeft,
                                    top: 0,
                                    width: mapWidth,
                                    height: height,
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
                                if (ref.watch(mapProvider).showRegionNames)
                                  Positioned(
                                    left: mapLeft,
                                    top: 0,
                                    width: mapWidth,
                                    height: height,
                                    child: SvgPicture.asset(
                                      calloutsAssetName,
                                      semanticsLabel: 'Callouts',
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                if (ref.watch(mapProvider).showUltOrbs)
                                  Positioned(
                                    left: mapLeft,
                                    top: 0,
                                    width: mapWidth,
                                    height: height,
                                    child: Transform.flip(
                                      flipX: !isAttack,
                                      flipY: !isAttack,
                                      child: SvgPicture.asset(
                                        ultOrbsAssetName,
                                        semanticsLabel: 'Ult Orbs',
                                        fit: BoxFit.contain,
                                      ),
                                    ),
                                  ),
                                Positioned.fill(
                                  child: ref.watch(transitionProvider).hideView
                                      ? SizedBox.shrink()
                                      : Opacity(
                                          opacity: ref.watch(
                                                      interactionStateProvider) ==
                                                  InteractionState.lineUpPlacing
                                              ? 0.2
                                              : 1.0,
                                          child: PlacedWidgetBuilder(),
                                        ),
                                ),
                                Positioned.fill(
                                  child: ref.watch(transitionProvider).active
                                      ? PageTransitionOverlay()
                                      : SizedBox.shrink(),
                                ),
                                Positioned.fill(
                                  child: ref
                                              .watch(transitionProvider)
                                              .hideView &&
                                          ref.watch(transitionProvider).phase ==
                                              PageTransitionPhase.preparing
                                      ? TemporaryWidgetBuilder()
                                      : SizedBox.shrink(),
                                ),
                                // Painting
                                Positioned.fill(
                                  child: Opacity(
                                    opacity:
                                        ref.watch(interactionStateProvider) ==
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
                                  const Positioned.fill(
                                    child: LineupPositionWidget(),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: DeleteArea(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              width: Settings.sideBarReservedWidth,
              height: height,
            ),
          ],
        );
      },
    );
  }
}
