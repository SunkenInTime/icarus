import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/draggable_widgets/placed_widget_builder.dart';
import 'package:icarus/widgets/drawing_painter.dart';

class ScreenshotView extends ConsumerWidget {
  const ScreenshotView({
    super.key,
    required this.mapValue,
    required this.agents,
    required this.abilities,
    required this.text,
    required this.images,
    required this.drawings,
    required this.utilities,
    required this.strategySettings,
    required this.isAttack,
    required this.strategyState,
  });
  final StrategyState strategyState;
  final MapValue mapValue;
  final List<PlacedAgent> agents;
  final List<PlacedAbility> abilities;
  final List<PlacedText> text;
  final List<PlacedImage> images;
  final List<DrawingElement> drawings;
  final List<PlacedUtility> utilities;
  final StrategySettings strategySettings;
  final bool isAttack;

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
    ref.read(utilityProvider.notifier).fromHive(utilities);

    ref
        .read(drawingProvider.notifier)
        .rebuildAllPaths(CoordinateSystem.instance);
    String assetName =
        'assets/maps/${Maps.mapNames[ref.watch(mapProvider).currentMap]}_map${isAttack ? "" : "_defense"}.svg';
    return Container(
      color: const Color(0xFF1B1B1B),
      height: CoordinateSystem.screenShotSize.height,
      width: CoordinateSystem.screenShotSize.width,
      child: Stack(
        children: [
          const Positioned.fill(
              child: Padding(
            padding: EdgeInsets.all(4.0),
            child: DotGrid(isScreenshot: true),
          )),

          Positioned.fill(
            child: SvgPicture.asset(
              assetName,
              semanticsLabel: 'Map',
              fit: BoxFit.contain,
            ),
          ),

          const Positioned.fill(
            child: PlacedWidgetBuilder(),
          ),

          //Painting
          const Positioned.fill(
            child: InteractivePainter(),
          ),
          // Add any other widgets you want to include in the screenshot
        ],
      ),
    );
  }
}
