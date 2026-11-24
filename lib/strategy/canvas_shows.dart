import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/drive_build.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/unshown_cloud_content_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

sealed class CanvasShows {
  const CanvasShows();
}

final class ShowsNothing extends CanvasShows {
  const ShowsNothing();
}

final class ShowsPage extends CanvasShows {
  const ShowsPage(this.strategyId, this.pageId);

  final String strategyId;
  final String pageId;
}

sealed class CanvasRead {
  const CanvasRead();
}

final class CanvasOf extends CanvasRead {
  const CanvasOf({
    required this.strategyId,
    required this.pageId,
    required this.drawings,
    required this.agents,
    required this.abilities,
    required this.texts,
    required this.images,
    required this.utilities,
    required this.lineUpGraph,
    required this.settings,
    required this.isAttack,
    required this.map,
    required this.themeProfileId,
    required this.themeOverridePalette,
    required this.unshown,
  });

  final String strategyId;
  final String pageId;
  final List<DrawingElement> drawings;
  final List<PlacedAgentNode> agents;
  final List<PlacedAbility> abilities;
  final List<PlacedText> texts;
  final List<PlacedImage> images;
  final List<PlacedUtility> utilities;
  final LineUpGraph lineUpGraph;
  final StrategySettings settings;
  final bool isAttack;
  final MapValue map;
  final String? themeProfileId;
  final MapThemePalette? themeOverridePalette;
  final UnshownCloudContent unshown;
}

final class CanvasNotShown extends CanvasRead {
  const CanvasNotShown();
}

CanvasRead readCanvas(Ref ref, String strategyId, String? pageId) {
  final shows = ref.read(canvasShowsProvider.notifier);
  if (pageId == null || !shows.shows(strategyId, pageId)) {
    shows.refused(strategyId, pageId);
    return const CanvasNotShown();
  }
  final map = ref.read(mapProvider);
  final theme = ref.read(strategyThemeProvider);
  return CanvasOf(
    strategyId: strategyId,
    pageId: pageId,
    drawings: ref.read(drawingProvider).elements,
    agents: ref.read(agentProvider),
    abilities: ref.read(abilityProvider),
    texts: ref.read(textProvider.notifier).snapshotForPersistence(),
    images: ref.read(placedImageProvider).images,
    utilities: ref.read(utilityProvider),
    lineUpGraph: ref.read(lineUpProvider).graph,
    settings: ref.read(strategySettingsProvider),
    isAttack: map.isAttack,
    map: map.currentMap,
    themeProfileId: theme.profileId,
    themeOverridePalette: theme.overridePalette,
    unshown: ref.read(unshownCloudContentProvider),
  );
}

final class CanvasRefusal {
  const CanvasRefusal({
    required this.what,
    required this.strategyId,
    required this.pageId,
    required this.canvas,
    required this.caller,
  });

  final String what;
  final String? strategyId;
  final String? pageId;
  final CanvasShows canvas;
  final String caller;

  @override
  String toString() => '$what for $strategyId page $pageId while the canvas '
      '${switch (canvas) {
        ShowsPage(:final strategyId, :final pageId) =>
          'shows $strategyId page $pageId',
        ShowsNothing() => 'shows nothing',
      }}, from $caller';
}

String _callerOf(StackTrace trace) {
  for (final line in trace.toString().split('\n')) {
    if (!line.contains('icarus')) continue;
    if (line.contains('canvas_shows') ||
        line.contains('readCanvas') ||
        line.contains('ignoresClick')) {
      continue;
    }
    return line.replaceFirst(RegExp(r'^#\d+\s+'), '').trim();
  }
  return 'an unknown caller';
}

final class CanvasShowsNotifier extends Notifier<CanvasShows> {
  final List<CanvasRefusal> refusals = [];

  @override
  CanvasShows build() => const ShowsNothing();

  void emptied() => state = const ShowsNothing();

  void shown(String strategyId, String pageId) =>
      state = ShowsPage(strategyId, pageId);

  bool shows(String strategyId, String pageId) => switch (state) {
        ShowsPage(strategyId: final shown, pageId: final page) =>
          shown == strategyId && page == pageId,
        ShowsNothing() => false,
      };

  void refused(String strategyId, String? pageId) =>
      _note('nothing shown', strategyId, pageId);

  void clickIgnored(String? strategyId, String pageId) =>
      _note('click ignored during an open', strategyId, pageId);

  void _note(String what, String? strategyId, String? pageId) {
    if (!driveBuild) return;
    refusals.add(CanvasRefusal(
      what: what,
      strategyId: strategyId,
      pageId: pageId,
      canvas: state,
      caller: _callerOf(StackTrace.current),
    ));
  }
}

final canvasShowsProvider = NotifierProvider<CanvasShowsNotifier, CanvasShows>(
  CanvasShowsNotifier.new,
);
