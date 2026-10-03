import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/strategy/remote_page_merge.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

Future<void> applyStrategyEditorPageData(
  Ref ref,
  StrategyEditorPageData data, {
  required String? themeProfileId,
  required MapThemePalette? themeOverridePalette,
  bool preserveHistory = false,
  MapValue? mapOverride,
}) async {
  ref.read(agentProvider.notifier).clearAll();
  ref.read(abilityProvider.notifier).clearAll();
  ref.read(drawingProvider.notifier).clearAll();
  ref.read(textProvider.notifier).clearAll();
  ref.read(placedImageProvider.notifier).clearAll();
  ref.read(utilityProvider.notifier).clearAll();
  ref.read(lineUpProvider.notifier).clearAll();
  if (!preserveHistory) {
    ref.read(actionProvider.notifier).clearActionHistory();
  }
  ref.read(agentProvider.notifier).fromHive(data.agents);
  ref.read(abilityProvider.notifier).fromHive(data.abilities);
  ref.read(drawingProvider.notifier).fromHive(data.drawings);
  ref.read(textProvider.notifier).fromHive(data.texts);
  ref.read(placedImageProvider.notifier).fromHive(data.images);
  ref.read(utilityProvider.notifier).fromHive(data.utilities);
  ref.read(lineUpProvider.notifier).fromHive(data.lineUpGraph);
  ref
      .read(mapProvider.notifier)
      .fromHive(mapOverride ?? data.map, data.isAttack);
  ref.read(strategySettingsProvider.notifier).fromHive(data.settings);
  ref.read(strategyThemeProvider.notifier).fromStrategy(
        profileId: themeProfileId,
        overridePalette: themeOverridePalette,
      );
  if (preserveHistory) {
    ref.read(actionProvider.notifier).reconcileHistory();
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    ref
        .read(drawingProvider.notifier)
        .rebuildAllPaths(CoordinateSystem.instance);
  });
}

/// Brings the page on screen to the server's copy without reloading it.
/// Nothing the user is mid-way through is touched: a stroke being drawn, an
/// open text draft, a lineup being placed, or an item in [holding].
///
/// Returns the entities in [changed] (from `remoteChangesSinceHydration`) it
/// left as they are because the user is holding them; they apply once the
/// hold ends.
Set<EntitySyncKey> mergeRemoteStrategyEditorPageData(
  Ref ref,
  StrategyEditorPageData data, {
  required Set<EntitySyncKey> changed,
  required Set<String> holding,
  required String? themeProfileId,
  required MapThemePalette? themeOverridePalette,
  MapValue? mapOverride,
}) {
  final heldBack = {
    for (final key in changed)
      if (key.kind == EntitySyncKeyKind.element &&
          holding.contains(key.entityId))
        key,
  };
  bool keep(String id) => holding.contains(id);

  ref.read(agentProvider.notifier).mergeRemote(data.agents, keep);
  ref.read(abilityProvider.notifier).mergeRemote(data.abilities, keep);
  ref.read(drawingProvider.notifier).mergeRemote(data.drawings, keep);
  ref.read(textProvider.notifier).mergeRemote(data.texts, keep);
  ref.read(placedImageProvider.notifier).mergeRemote(data.images, keep);
  ref.read(utilityProvider.notifier).mergeRemote(data.utilities, keep);

  final liveSync = ref.read(activePageLiveSyncProvider.notifier);
  final (lineUpGraph, heldGroups) = mergeHeldLineups(
    local: ref.read(lineUpProvider).graph,
    remote: data.lineUpGraph.deepCopy(),
    holding: holding,
    groupOf: (id) => liveSync.lineupGroupOf(data.pageId, id),
  );
  ref.read(lineUpProvider.notifier).mergeRemote(lineUpGraph);
  heldBack.addAll({
    for (final key in changed)
      if (key.kind == EntitySyncKeyKind.lineup &&
          heldGroups.contains(key.entityId))
        key,
  });

  ref
      .read(mapProvider.notifier)
      .fromHive(mapOverride ?? data.map, data.isAttack);
  ref.read(strategySettingsProvider.notifier).fromHive(data.settings);
  ref.read(strategyThemeProvider.notifier).fromStrategy(
        profileId: themeProfileId,
        overridePalette: themeOverridePalette,
      );
  ref.read(actionProvider.notifier).reconcileHistory();
  return heldBack;
}
