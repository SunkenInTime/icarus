import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/widgets/asset_svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/screenshot/caption_export_layout.dart';
import 'package:icarus/screenshot/caption_export_overlay.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';
import 'package:icarus/widgets/map_floor_clip.dart';
import 'package:icarus/widgets/map_svg_color_mapper.dart';
import 'package:icarus/view_cone/cone_coverage.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/drawing_painter.dart';
import 'package:icarus/widgets/map_door_layer.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';

class ScreenshotView extends ConsumerWidget {
  const ScreenshotView({
    super.key,
    required this.mapValue,
    required this.showSpawnBarrier,
    required this.showRegionNames,
    required this.showUltOrbs,
    required this.backgroundDotOpacity,
    required this.agents,
    required this.abilities,
    required this.text,
    required this.images,
    required this.drawings,
    required this.utilities,
    required this.strategySettings,
    required this.isAttack,
    required this.strategyState,
    this.pageName,
    this.lineUpGraph = LineUpGraph.empty,
    required this.themeProfileId,
    required this.themeOverridePalette,
    this.placedWidgetsOverride,
    this.drawingsOpacity = 1.0,
    this.transparentBackground = false,
    this.includeCaptions = false,
    this.onCaptionLayout,
    this.fadingCaptions = const [],
    this.doorTransition,
  });

  /// [page] of a saved [strategy] as a capture draws it, with the map layers
  /// [mapState] has turned on.
  factory ScreenshotView.forPage(
    StrategyData strategy,
    StrategyPage page, {
    required StrategyState strategyState,
    required MapState mapState,
    required double backgroundDotOpacity,
    bool transparentBackground = false,
    bool includeCaptions = false,
    ValueChanged<CaptionExportLayout>? onCaptionLayout,
    List<FadingCaptions> fadingCaptions = const [],
    Widget? placedWidgetsOverride,
    double drawingsOpacity = 1.0,
    MapDoorTransition? doorTransition,
  }) =>
      ScreenshotView(
        isAttack: page.isAttack,
        mapValue: strategy.mapData,
        showSpawnBarrier: mapState.showSpawnBarrier,
        showRegionNames: mapState.showRegionNames,
        showUltOrbs: mapState.showUltOrbs,
        backgroundDotOpacity: backgroundDotOpacity,
        agents: page.agentData,
        abilities: page.abilityData,
        text: page.textData,
        images: page.imageData,
        drawings: page.drawingData,
        utilities: page.utilityData,
        strategySettings: page.settings,
        strategyState: strategyState,
        pageName: page.name,
        lineUpGraph: page.lineUpGraph,
        themeProfileId: strategy.themeProfileId,
        themeOverridePalette: strategy.themeOverridePalette,
        placedWidgetsOverride: placedWidgetsOverride,
        drawingsOpacity: drawingsOpacity,
        transparentBackground: transparentBackground,
        includeCaptions: includeCaptions,
        onCaptionLayout: onCaptionLayout,
        fadingCaptions: fadingCaptions,
        doorTransition: doorTransition,
      );
  final StrategyState strategyState;
  final MapValue mapValue;
  final bool showSpawnBarrier;
  final bool showRegionNames;
  final bool showUltOrbs;
  final double backgroundDotOpacity;
  final List<PlacedAgentNode> agents;
  final List<PlacedAbility> abilities;
  final List<PlacedText> text;
  final List<PlacedImage> images;
  final List<DrawingElement> drawings;
  final List<PlacedUtility> utilities;
  final StrategySettings strategySettings;
  final bool isAttack;
  final String? pageName;
  final LineUpGraph lineUpGraph;
  final String? themeProfileId;
  final MapThemePalette? themeOverridePalette;

  /// Video export renders transition frames by swapping the placed-widget
  /// layer for a [TransitionEntriesLayer] at a fixed progress.
  final Widget? placedWidgetsOverride;

  /// Video export fades the drawing layer in early during transitions.
  final double drawingsOpacity;

  /// Leaves out the backdrop (the gradient and the dot grid), so everything
  /// around the map is transparent.
  final bool transparentBackground;

  /// Prints the page's captions (see [CaptionExportOverlay]).
  final bool includeCaptions;

  /// Hears what [includeCaptions] worked out for the page.
  final ValueChanged<CaptionExportLayout>? onCaptionLayout;

  /// Video export draws these over a transition frame instead, since neither
  /// page's items are in place on it.
  final List<FadingCaptions> fadingCaptions;

  /// Video export turns the doors on a transition frame, which draws the page
  /// it's going to.
  final MapDoorTransition? doorTransition;

  static const _pageNameStyle = TextStyle(
    color: Color(0xffb8b8c2),
    decoration: TextDecoration.none,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    shadows: [
      Shadow(
        color: Color(0xaa000000),
        offset: Offset(0, 1),
        blurRadius: 4,
      ),
    ],
  );
  static const double _pageNameLeft = 28;
  static const double _pageNameBottom = 22;

  /// Where [name] prints on a capture.
  Rect _pageNameRect(BuildContext context, String name) {
    const frame = CoordinateSystem.screenShotSize;
    final painter = TextPainter(
      text: TextSpan(
        text: name,
        style: DefaultTextStyle.of(context).style.merge(_pageNameStyle),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: frame.width - 2 * _pageNameLeft);
    final size = painter.size;
    painter.dispose();
    return Rect.fromLTWH(
      _pageNameLeft,
      frame.height - _pageNameBottom - size.height,
      size.width,
      size.height,
    );
  }

  /// Loads this frame into the isolated providers used for offscreen capture.
  /// Call it inside [CoordinateSystem.runInCapture], as the whole capture
  /// runs, so drawing paths are built in the capture's coordinates.
  ///
  /// Call this before mounting or updating the view. Riverpod intentionally
  /// rejects provider writes from [build], even though release builds do not
  /// surface that assertion.
  void hydrateProviders(ProviderContainer container) {
    container.read(agentProvider.notifier).fromHive(agents);
    container.read(screenshotProvider.notifier).setIsScreenShot(true);
    container.read(abilityProvider.notifier).fromHive(abilities);
    container.read(drawingProvider.notifier).fromHive(drawings);
    container.read(mapProvider.notifier).fromHive(mapValue, isAttack);
    container.read(textProvider.notifier).fromHive(text);
    container.read(placedImageProvider.notifier).fromHive(images);
    container
        .read(strategySettingsProvider.notifier)
        .fromHive(strategySettings);
    container.read(strategyThemeProvider.notifier).fromStrategy(
          profileId: themeProfileId,
          overridePalette: themeOverridePalette,
        );
    container.read(utilityProvider.notifier).fromHive(utilities);
    container.read(lineUpProvider.notifier).fromHive(lineUpGraph);
    container
        .read(drawingProvider.notifier)
        .rebuildAllPaths(CoordinateSystem.instance);
    // Keep the strategy closed while its dependent providers are hydrated so
    // their listeners cannot mistake capture setup for user edits.
    container.read(strategyProvider.notifier).setFromState(strategyState);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => ConeCoverageHost(
        builder: (context, cones) => _build(context, ref, cones),
      );

  Widget _build(BuildContext context, WidgetRef ref, ConeCoverage cones) {
    String assetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_map${isAttack ? "" : "_defense"}.svg';
    String barrierAssetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_spawn_walls.svg';
    String calloutsAssetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_call_outs${isAttack ? "" : "_defense"}.svg';
    String ultOrbsAssetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_ult_orbs.svg';
    final effectivePalette = ref.watch(effectiveMapThemePaletteProvider);
    final mapColorMapper = MapSvgColorMapper.forPalette(effectivePalette);
    final mapWidth = CoordinateSystem.screenShotSize.height *
        CoordinateSystem.instance.mapAspectRatio;
    final mapLeft = (CoordinateSystem.screenShotSize.width - mapWidth) / 2;
    // The map's box is wider than most maps, so the margins start at its art.
    final artWidth = applyBoxFit(
      BoxFit.contain,
      Maps.mapViewBox[mapValue]!,
      Size(mapWidth, CoordinateSystem.screenShotSize.height),
    ).destination.width;
    final artLeft = (CoordinateSystem.screenShotSize.width - artWidth) / 2;
    final name = pageName?.trim();
    final hasName = name?.isNotEmpty ?? false;

    return MapFloor(
      map: mapValue,
      isAttack: isAttack,
      child: SizedBox(
        height: CoordinateSystem.screenShotSize.height,
        width: CoordinateSystem.screenShotSize.width,
        child: Stack(
          children: [
            if (!transparentBackground)
              Positioned.fill(
                child: ScreenshotBackdrop(dotOpacity: backgroundDotOpacity),
              ),
            Positioned(
              left: mapLeft,
              top: 0,
              width: mapWidth,
              height: CoordinateSystem.screenShotSize.height,
              child: CanonicalMapArtwork(
                map: mapValue,
                isAttack: isAttack,
                child: AssetSvg(
                  assetName,
                  colorMapper: mapColorMapper,
                  semanticsLabel: 'Map',
                  fit: BoxFit.contain,
                ),
              ),
            ),
            // View cones: the map as they reveal it, shown wherever one
            // reaches, as in the editor.
            Positioned.fill(
              child: ConeCoverageLayer(
                coverage: cones,
                opacity: ref.watch(appPreferencesProvider).viewConeOpacity,
                child: Stack(
                  children: [
                    Positioned(
                      left: mapLeft,
                      top: 0,
                      width: mapWidth,
                      height: CoordinateSystem.screenShotSize.height,
                      child: CanonicalMapArtwork(
                        map: mapValue,
                        isAttack: isAttack,
                        child: AssetSvg(
                          assetName,
                          colorMapper:
                              MapSvgColorMapper.revealed(effectivePalette),
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (showSpawnBarrier)
              Positioned(
                left: mapLeft,
                top: 0,
                width: mapWidth,
                height: CoordinateSystem.screenShotSize.height,
                child: Transform.flip(
                  flipX: !isAttack,
                  flipY: !isAttack,
                  child: AssetSvg(
                    barrierAssetName,
                    semanticsLabel: 'Barrier',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            if (showRegionNames)
              Positioned(
                left: mapLeft,
                top: 0,
                width: mapWidth,
                height: CoordinateSystem.screenShotSize.height,
                child: AssetSvg(
                  calloutsAssetName,
                  semanticsLabel: 'Callouts',
                  fit: BoxFit.contain,
                ),
              ),
            if (showUltOrbs)
              Positioned(
                left: mapLeft,
                top: 0,
                width: mapWidth,
                height: CoordinateSystem.screenShotSize.height,
                child: Transform.flip(
                  flipX: !isAttack,
                  flipY: !isAttack,
                  child: AssetSvg(
                    ultOrbsAssetName,
                    semanticsLabel: 'Ult Orbs',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            Positioned.fill(
              child: MapDoorBars(
                map: mapValue,
                isAttack: isAttack,
                changed: changedMapDoors(utilities, mapValue),
                transition: doorTransition,
              ),
            ),
            Positioned.fill(
              child: ConeCoverageScope(
                coverage: cones,
                // Lets the captions find the items by their drawn outlines.
                child: CanvasItemRegistryScope(
                  registry: ref.read(canvasItemRegistryProvider),
                  child: placedWidgetsOverride ?? const PlacedWidgetBuilder(),
                ),
              ),
            ),

            //Painting
            Positioned.fill(
              // Mirror the live map so defense-side screenshots flip drawings too.
              child: Opacity(
                opacity: drawingsOpacity,
                child: Transform.flip(
                  flipX: !isAttack,
                  flipY: !isAttack,
                  child: InteractivePainter(
                    mapScaleOverride: Maps.mapScale[mapValue] ?? 1.0,
                    isAttackOverride: isAttack,
                  ),
                ),
              ),
            ),
            if (hasName)
              Positioned(
                left: _pageNameLeft,
                bottom: _pageNameBottom,
                child: SizedBox(
                  width:
                      CoordinateSystem.screenShotSize.width - 2 * _pageNameLeft,
                  child: Text(
                    name!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _pageNameStyle,
                  ),
                ),
              ),
            if (includeCaptions)
              Positioned.fill(
                child: CaptionExportOverlay(
                  items: captionExportItems([
                    ...agents,
                    ...abilities,
                    ...text,
                    ...images,
                    ...withoutMapDoors(utilities, mapValue),
                  ]),
                  drawings: drawings,
                  isAttack: isAttack,
                  mapLeft: artLeft,
                  mapRight: artLeft + artWidth,
                  pageName: hasName ? _pageNameRect(context, name!) : null,
                  onLayout: onCaptionLayout,
                ),
              ),
            if (fadingCaptions.isNotEmpty)
              Positioned.fill(
                child: FadingCaptionsLayer(captions: fadingCaptions),
              ),
          ],
        ),
      ),
    );
  }
}

/// What a screenshot draws around the map unless its background is left
/// out: the canvas gradient and its dot grid, at the screenshot's size.
class ScreenshotBackdrop extends StatelessWidget {
  const ScreenshotBackdrop({super.key, required this.dotOpacity});

  final double dotOpacity;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.5,
          colors: [
            Settings.tacticalVioletTheme.card,
            Settings.tacticalVioletTheme.background,
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4.0),
        child: DotGrid(isScreenshot: true, opacity: dotOpacity),
      ),
    );
  }
}
