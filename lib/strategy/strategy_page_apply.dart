import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

Future<void> applyStrategyEditorPageData(
  Ref ref,
  StrategyEditorPageData data, {
  required String themeProfileId,
  required MapThemePalette? themeOverridePalette,
}) async {
  ref.read(actionProvider.notifier).resetActionState();
  ref.read(agentProvider.notifier).fromHive(data.agents);
  ref.read(abilityProvider.notifier).fromHive(data.abilities);
  ref.read(drawingProvider.notifier).fromHive(data.drawings);
  ref.read(textProvider.notifier).fromHive(data.texts);
  ref.read(placedImageProvider.notifier).fromHive(data.images);
  ref.read(utilityProvider.notifier).fromHive(data.utilities);
  ref.read(lineUpProvider.notifier).fromHive(data.lineups);
  ref.read(mapProvider.notifier).fromHive(data.map, data.isAttack);
  ref.read(strategySettingsProvider.notifier).fromHive(data.settings);
  ref.read(strategyThemeProvider.notifier).fromStrategy(
        profileId: themeProfileId,
        overridePalette: themeOverridePalette,
      );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    ref
        .read(drawingProvider.notifier)
        .rebuildAllPaths(CoordinateSystem.instance);
  });
}
