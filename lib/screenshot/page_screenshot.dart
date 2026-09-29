import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/screenshot/capture_geometry.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/screenshot/offscreen_capture.dart';
import 'package:icarus/screenshot/persistent_offscreen_renderer.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

/// Renders the page open in the editor, as it is on screen, to a PNG.
///
/// The capture reads the editor's live state rather than a saved copy, so a
/// cloud strategy captures exactly like a local one and nothing waits on a
/// save or a sync. Throws [CaptureImagesUnavailable] rather than return a
/// picture with an image missing.
Future<Uint8List> captureEditorPage(WidgetRef ref) async {
  final strategyState = ref.read(strategyProvider);
  final strategyId = strategyState.strategyId;
  if (strategyId == null) {
    throw StateError('No strategy is open to capture.');
  }
  final page = _editorPage(ref);
  final mapState = ref.read(mapProvider);
  final theme = ref.read(strategyThemeProvider);

  final images = await resolveCaptureImageSources(
    {
      for (final image in page.imageData)
        image.id: readStrategyImageSource(
          ref,
          (id: image.id, fileExtension: image.fileExtension),
        ),
    },
    fetch: (imageId, url) => downloadCloudImageBytes(
      url,
      freshUrl: () =>
          ref.read(convexStrategyRepositoryProvider).getImageAssetUrl(
                strategyPublicId: strategyId,
                assetPublicId: imageId,
              ),
    ),
  );

  final view = ScreenshotView(
    isAttack: page.isAttack,
    mapValue: mapState.currentMap,
    showSpawnBarrier: mapState.showSpawnBarrier,
    showRegionNames: mapState.showRegionNames,
    showUltOrbs: mapState.showUltOrbs,
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
    themeProfileId: theme.profileId,
    themeOverridePalette: theme.overridePalette,
  );

  final container = ProviderContainer(
    overrides: [captureImageSourcesProvider.overrideWithValue(images)],
  );
  CaptureGeometryLease? geometry;
  try {
    // The sightline models load asynchronously; the capture waits for the
    // page's geometry before the first frame is taken.
    geometry = await prepareCaptureGeometry(
      container,
      mapState.currentMap,
      [page],
    );
    final waitForFrame = geometry?.waitForFrame;
    return await withScreenshotCoordinates(() async {
      view.hydrateProviders(container);
      final renderer = PersistentOffscreenRenderer(
        targetSize: CoordinateSystem.screenShotSize,
        waitForFrameData: waitForFrame,
        wrapWidget: (child) =>
            wrapForOffscreenCapture(child, container: container),
      );
      try {
        await renderer.prepare(
          view,
          settleDuration: const Duration(milliseconds: 800),
        );
        return await renderer.capture(view);
      } finally {
        await renderer.dispose();
      }
    });
  } finally {
    geometry?.close();
    container.dispose();
  }
}

/// The page on the canvas right now. Drawings are copied: a capture
/// rebuilds their paths in screenshot coordinates, and the editor's own
/// strokes must keep theirs.
StrategyPage _editorPage(WidgetRef ref) {
  final lineUps = ref.read(lineUpProvider).graph;
  return StrategyPage(
    id: ref.read(strategyPageSessionProvider).activePageId ?? '',
    name: _activePageName(ref) ?? '',
    drawingData: DrawingProvider.fromJson(
      DrawingProvider.objectToJson(ref.read(drawingProvider).elements),
    ),
    agentData: ref.read(agentProvider),
    abilityData: ref.read(abilityProvider),
    textData: ref.read(textProvider.notifier).snapshotForPersistence(),
    imageData: ref.read(placedImageProvider).images,
    utilityData: ref.read(utilityProvider),
    sortIndex: 0,
    isAttack: ref.read(mapProvider).isAttack,
    settings: ref.read(strategySettingsProvider),
    lineUpOrigins: lineUps.origins,
    lineUpLandings: lineUps.landings,
    lineUpLinks: lineUps.links,
  );
}

/// The open page's name, from wherever its strategy lives, as the pages bar
/// shows it.
String? _activePageName(WidgetRef ref) {
  final strategy = ref.read(strategyProvider);
  final pageId = ref.read(strategyPageSessionProvider).activePageId;
  if (pageId == null) return null;
  return switch (strategy.source) {
    StrategySource.cloud => ref
        .read(remoteEditorSnapshotProvider)
        .valueOrNull
        ?.pages
        .where((page) => page.publicId == pageId)
        .firstOrNull
        ?.name,
    StrategySource.local => Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .get(strategy.strategyId)
        ?.pages
        .where((page) => page.id == pageId)
        .firstOrNull
        ?.name,
    null => null,
  };
}
