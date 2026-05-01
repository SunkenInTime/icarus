import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/drawing_painter.dart';

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
    final alpha = (color.a * 255.0).round().clamp(0, 255);
    return replacement.withAlpha(alpha);
  }
}

class ScreenshotView extends ConsumerWidget {
  ScreenshotView({
    super.key,
    required this.mapValue,
    required this.showSpawnBarrier,
    required this.showRegionNames,
    required this.showUltOrbs,
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
    List<LineUpGroup> lineUpGroups = const [],
    @Deprecated('Use lineUpGroups instead') List<LineUp> lineUps = const [],
    required this.themeProfileId,
    required this.themeOverridePalette,
  }) : lineUpGroups = lineUpGroups.isNotEmpty
            ? lineUpGroups
            : lineUps.map(LineUpGroup.fromLegacyLineUp).toList();
  final StrategyState strategyState;
  final MapValue mapValue;
  final bool showSpawnBarrier;
  final bool showRegionNames;
  final bool showUltOrbs;
  final List<PlacedAgentNode> agents;
  final List<PlacedAbility> abilities;
  final List<PlacedText> text;
  final List<PlacedImage> images;
  final List<DrawingElement> drawings;
  final List<PlacedUtility> utilities;
  final StrategySettings strategySettings;
  final bool isAttack;
  final String? pageName;
  final List<LineUpGroup> lineUpGroups;
  final String? themeProfileId;
  final MapThemePalette? themeOverridePalette;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    CoordinateSystem.instance.setIsScreenshot(true);
    ref.read(strategyProvider.notifier).setFromState(strategyState);
    ref.read(agentProvider.notifier).fromHive(agents);
    ref.read(screenshotProvider.notifier).setIsScreenShot(true);

    ref.read(abilityProvider.notifier).fromHive(abilities);
    ref.read(drawingProvider.notifier).fromHive(drawings);
    ref.read(mapProvider.notifier).fromHive(mapValue, isAttack);
    ref.read(textProvider.notifier).fromHive(text);
    ref.read(placedImageProvider.notifier).fromHive(images);

    ref.read(strategySettingsProvider.notifier).fromHive(strategySettings);
    ref.read(strategyThemeProvider.notifier).fromStrategy(
          profileId: themeProfileId,
          overridePalette: themeOverridePalette,
        );
    ref.read(utilityProvider.notifier).fromHive(utilities);

    ref.read(lineUpProvider.notifier).fromHive(lineUpGroups);

    ref
        .read(drawingProvider.notifier)
        .rebuildAllPaths(CoordinateSystem.instance);
    String assetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_map${isAttack ? "" : "_defense"}.svg';
    String barrierAssetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_spawn_walls.svg';
    String calloutsAssetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_call_outs${isAttack ? "" : "_defense"}.svg';
    String ultOrbsAssetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_ult_orbs.svg';
    final effectivePalette = ref.watch(effectiveMapThemePaletteProvider);
    final mapColorMapper = _MapSvgColorMapper({
      0xFF271406: effectivePalette.baseColor,
      0xFFB27C40: effectivePalette.detailColor,
      0xFFF08234: effectivePalette.highlightColor,
    });
    final mapWidth = CoordinateSystem.screenShotSize.height *
        CoordinateSystem.instance.mapAspectRatio;
    final mapLeft = (CoordinateSystem.screenShotSize.width - mapWidth) / 2;

    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.5,
          colors: [
            const Color(0xff18181b),
            Settings.tacticalVioletTheme.background,
          ],
        ),
      ),
      height: CoordinateSystem.screenShotSize.height,
      width: CoordinateSystem.screenShotSize.width,
      child: Stack(
        children: [
          const Positioned.fill(
              child: Padding(
            padding: EdgeInsets.all(4.0),
            child: DotGrid(isScreenshot: true),
          )),
          Positioned(
            left: mapLeft,
            top: 0,
            width: mapWidth,
            height: CoordinateSystem.screenShotSize.height,
            child: SvgPicture.asset(
              assetName,
              colorMapper: mapColorMapper,
              semanticsLabel: 'Map',
              fit: BoxFit.contain,
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
                child: SvgPicture.asset(
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
              child: SvgPicture.asset(
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
                child: SvgPicture.asset(
                  ultOrbsAssetName,
                  semanticsLabel: 'Ult Orbs',
                  fit: BoxFit.contain,
                ),
              ),
            ),
          const Positioned.fill(
            child: PlacedWidgetBuilder(),
          ),

          //Painting
          Positioned.fill(
            // Mirror the live map so defense-side screenshots flip drawings too.
            child: Transform.flip(
              flipX: !isAttack,
              flipY: !isAttack,
              child: InteractivePainter(
                mapScaleOverride: Maps.mapScale[mapValue] ?? 1.0,
                isAttackOverride: isAttack,
              ),
            ),
          ),
          if (pageName?.trim().isNotEmpty ?? false)
            Positioned(
              left: 28,
              bottom: 22,
              child: SizedBox(
                width: CoordinateSystem.screenShotSize.width - 56,
                child: Text(
                  pageName!.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
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
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
