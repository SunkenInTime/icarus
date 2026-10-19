import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
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
import 'package:icarus/services/video_export/video_export_errors.dart';
import 'package:icarus/services/video_export/video_export_source.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

/// How a capture reads its finished frame: a PNG to save, or an image to
/// draw.
typedef _ReadFrame<T> = Future<T> Function(
  PersistentOffscreenRenderer renderer,
  Widget view,
);

Future<Uint8List> _png(PersistentOffscreenRenderer renderer, Widget view) =>
    renderer.capture(view);

Future<ui.Image> _image(PersistentOffscreenRenderer renderer, Widget view) =>
    renderer.captureImage(view);

/// The scale a page's thumbnail renders at: a fifth of the saved PNG's
/// 1920×1080, sharp at the size the screenshot dialog draws it.
const double pageThumbnailPixelRatio = 0.2;

/// Renders the page open in the editor, as it is on screen, to a PNG.
///
/// The capture reads the editor's live state rather than a saved copy, so a
/// cloud strategy captures exactly like a local one and nothing waits on a
/// save or a sync. Throws [CaptureImagesUnavailable] rather than return a
/// picture with an image missing.
Future<Uint8List> captureEditorPage(WidgetRef ref) => _renderEditorPage(
      ref,
      transparentBackground:
          ref.read(appPreferencesProvider).transparentScreenshotBackground,
      pixelRatio: 1,
      read: _png,
    );

Future<T> _renderEditorPage<T>(
  WidgetRef ref, {
  required bool transparentBackground,
  required double pixelRatio,
  required _ReadFrame<T> read,
  bool settleUntilQuiet = false,
}) async {
  final strategyState = ref.read(strategyProvider);
  final strategyId = strategyState.strategyId;
  if (strategyId == null) {
    throw StateError('No strategy is open to capture.');
  }
  final page = editorPageSnapshot(ref);
  final mapState = ref.read(mapProvider);
  final theme = ref.read(strategyThemeProvider);
  final preferences = ref.read(appPreferencesProvider);

  final images = await resolveCaptureImages(
    {
      // By picture, as the captured page's images look them up.
      for (final image in page.imageData)
        image.pictureId: readStrategyImageSource(
          ref,
          (id: image.pictureId, fileExtension: image.fileExtension),
        ),
    },
    fetch: (imageId, url, client) => downloadCloudImageBytes(
      url,
      client: client,
      freshUrl: () {
        final linkView = ref.read(shareLinkViewProvider);
        return ref.read(convexStrategyRepositoryProvider).getImageAssetUrl(
              strategyPublicId: strategyId,
              assetPublicId: imageId,
              // A signed-out reader's only access is the link they opened.
              shareToken: linkView?.strategyPublicId == strategyId
                  ? linkView!.token
                  : null,
            );
      },
    ),
  );

  final view = ScreenshotView(
    isAttack: page.isAttack,
    mapValue: mapState.currentMap,
    showSpawnBarrier: mapState.showSpawnBarrier,
    showRegionNames: mapState.showRegionNames,
    showUltOrbs: mapState.showUltOrbs,
    backgroundDotOpacity: preferences.backgroundDotOpacity,
    transparentBackground: transparentBackground,
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

  final container = createCaptureContainer(images: images.sources);
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
    return await CoordinateSystem.runInCapture(() async {
      view.hydrateProviders(container);
      final renderer = PersistentOffscreenRenderer(
        targetSize: CoordinateSystem.screenShotSize,
        pixelRatio: pixelRatio,
        waitForFrameData: waitForFrame,
        wrapWidget: (child) =>
            wrapForOffscreenCapture(child, container: container),
      );
      try {
        if (settleUntilQuiet) {
          await renderer.prepareUntilQuiet(view);
        } else {
          await renderer.prepare(
            view,
            settleDuration: const Duration(milliseconds: 800),
          );
        }
        return await read(renderer, view);
      } finally {
        await renderer.dispose();
      }
    });
  } finally {
    geometry?.close();
    container.dispose();
    images.release();
  }
}

/// One page's screenshot, with what its file is named after.
typedef PageScreenshot = ({int number, String name, Uint8List png});

/// Renders the open strategy's pages [pageIds] to PNGs, in page order.
///
/// Unlike [captureEditorPage], this reads the strategy as saved, because the
/// other pages exist only there: a local strategy is saved first, and a
/// cloud one waits for this device's work to land (see
/// [loadVideoExportSource], whose errors this throws).
///
/// [onPage] hears each page as it starts (1-based, of the total). Throws
/// [VideoExportCancelled] once [isCancelled] turns true.
Future<List<PageScreenshot>> captureStrategyPages(
  WidgetRef ref, {
  required Set<String> pageIds,
  required bool transparentBackground,
  void Function(int page, int total)? onPage,
  bool Function() isCancelled = _never,
}) async {
  final source = await loadVideoExportSource(
    ref,
    pageIds: pageIds,
    isCancelled: isCancelled,
  );
  final shots = <PageScreenshot>[];
  try {
    await _renderPages(
      ref,
      strategy: source.strategy,
      pages: _numbered(source.strategy, pageIds),
      images: source.images.sources,
      transparentBackground: transparentBackground,
      pixelRatio: 1,
      read: _png,
      onPage: onPage,
      onRendered: (number, page, png) =>
          shots.add((number: number, name: page.name, png: png)),
      isCancelled: isCancelled,
    );
  } finally {
    source.images.release();
  }
  return shots;
}

/// Renders small, see-through pictures of the open strategy's pages
/// [pageIds] for the screenshot dialog, handing each to [onThumbnail] as it
/// is ready; the receiver disposes it. The page open in the editor comes
/// first and is drawn as it is on screen, like [captureEditorPage]. The rest
/// are read as this device last left them, without saving or sending
/// anything first (see [readSavedStrategy]): looking is not saving.
///
/// Each page is taken as soon as nothing in it is still loading, rather
/// than after the fixed wait a saved screenshot allows, so the dialog fills
/// in quickly.
///
/// A page that cannot be drawn, say for an image that won't load, is
/// reported to [onUnavailable] with why, and the others still render.
/// Stops quietly once [isCancelled] turns true.
Future<void> renderPageThumbnails(
  WidgetRef ref, {
  required Set<String> pageIds,
  required void Function(String pageId, ui.Image image) onThumbnail,
  required void Function(Set<String> pageIds, Object error) onUnavailable,
  required bool Function() isCancelled,
}) async {
  final openPageId = ref.read(strategyPageSessionProvider).activePageId;
  if (pageIds.contains(openPageId)) {
    try {
      final image = await _renderEditorPage(
        ref,
        transparentBackground: true,
        pixelRatio: pageThumbnailPixelRatio,
        read: _image,
        settleUntilQuiet: true,
      );
      onThumbnail(openPageId!, image);
    } catch (error) {
      onUnavailable({openPageId!}, error);
    }
  }
  final others = {...pageIds}..remove(openPageId);
  if (others.isEmpty || isCancelled()) return;

  final SavedStrategyRead read;
  try {
    read = await readSavedStrategy(
      ref,
      saveFirst: false,
      isCancelled: isCancelled,
    );
  } on VideoExportCancelled {
    return;
  } catch (error) {
    onUnavailable(others, error);
    return;
  }
  final pages = _numbered(read.strategy, others);
  final missing = others.difference({for (final e in pages) e.page.id});
  if (missing.isNotEmpty) {
    onUnavailable(missing, const VideoExportPagesChanged());
  }

  // Each page's images load on their own, so one that won't load costs
  // only its own page.
  final ready = <({int number, StrategyPage page})>[];
  final held = <CaptureImages>[];
  try {
    for (final entry in pages) {
      if (isCancelled()) return;
      try {
        held.add(await resolvePageImages(
          ref,
          read,
          [entry.page],
          isCancelled: isCancelled,
        ));
        ready.add(entry);
      } on VideoExportCancelled {
        return;
      } catch (error) {
        onUnavailable({entry.page.id}, error);
      }
    }
    if (ready.isEmpty) return;
    await _renderPages(
      ref,
      strategy: read.strategy,
      pages: ready,
      images: {for (final images in held) ...images.sources},
      transparentBackground: true,
      pixelRatio: pageThumbnailPixelRatio,
      read: _image,
      onRendered: (_, page, image) => onThumbnail(page.id, image),
      onPageFailed: (page, error) => onUnavailable({page.id}, error),
      isCancelled: isCancelled,
      settleUntilQuiet: true,
    );
  } on VideoExportCancelled {
    return;
  } catch (error) {
    // The renderer itself could not start; nothing more will draw.
    onUnavailable({for (final entry in ready) entry.page.id}, error);
  } finally {
    for (final images in held) {
      images.release();
    }
  }
}

/// The pages of [strategy] in [pageIds], in page order, with their 1-based
/// numbers among all its pages.
List<({int number, StrategyPage page})> _numbered(
  StrategyData strategy,
  Set<String> pageIds,
) {
  final ordered = [...strategy.pages]
    ..sortBySortIndex((page) => page.sortIndex);
  return [
    for (final (index, page) in ordered.indexed)
      if (pageIds.contains(page.id)) (number: index + 1, page: page),
  ];
}

/// Renders [pages] of [strategy], in order, painting their images from
/// [images], and hands each frame [read] takes to [onRendered].
///
/// A page that fails to render goes to [onPageFailed] and the rest carry
/// on; without it, the failure ends the whole render.
Future<void> _renderPages<T>(
  WidgetRef ref, {
  required StrategyData strategy,
  required List<({int number, StrategyPage page})> pages,
  required Map<String, StrategyImageSource> images,
  required bool transparentBackground,
  required double pixelRatio,
  required _ReadFrame<T> read,
  required void Function(int number, StrategyPage page, T frame) onRendered,
  void Function(StrategyPage page, Object error)? onPageFailed,
  void Function(int page, int total)? onPage,
  bool Function() isCancelled = _never,
  bool settleUntilQuiet = false,
}) async {
  void checkCancelled() {
    if (isCancelled()) throw VideoExportCancelled();
  }

  final mapState = ref.read(mapProvider);
  final strategyState = ref.read(strategyProvider);
  final dotOpacity = ref.read(appPreferencesProvider).backgroundDotOpacity;
  final container = createCaptureContainer(images: images);
  CaptureGeometryLease? geometry;
  try {
    geometry = await prepareCaptureGeometry(
      container,
      strategy.mapData,
      [for (final entry in pages) entry.page],
    );
    final waitForFrame = geometry?.waitForFrame;
    await CoordinateSystem.runInCapture(() async {
      final renderer = PersistentOffscreenRenderer(
        targetSize: CoordinateSystem.screenShotSize,
        pixelRatio: pixelRatio,
        waitForFrameData: waitForFrame,
        wrapWidget: (child) =>
            wrapForOffscreenCapture(child, container: container),
      );
      try {
        var first = true;
        for (final (index, entry) in pages.indexed) {
          checkCancelled();
          onPage?.call(index + 1, pages.length);
          try {
            final view = ScreenshotView.forPage(
              strategy,
              entry.page,
              strategyState: strategyState,
              mapState: mapState,
              backgroundDotOpacity: dotOpacity,
              transparentBackground: transparentBackground,
            );
            view.hydrateProviders(container);
            if (settleUntilQuiet) {
              await renderer.prepareUntilQuiet(view);
            } else {
              // The first page loads the map's SVGs; later pages reuse
              // them and wait only for their own images.
              await renderer.prepare(
                view,
                settleDuration: Duration(milliseconds: first ? 800 : 300),
              );
            }
            first = false;
            onRendered(entry.number, entry.page, await read(renderer, view));
          } catch (error) {
            if (onPageFailed == null) rethrow;
            onPageFailed(entry.page, error);
          }
        }
        checkCancelled();
      } finally {
        await renderer.dispose();
      }
    });
  } finally {
    geometry?.close();
    container.dispose();
  }
}

bool _never() => false;

/// A copy of the page on the canvas right now. The editor keeps editing
/// its own objects in place while the capture fetches images, and a capture
/// rebuilds drawing paths in screenshot coordinates; neither may reach the
/// other.
@visibleForTesting
StrategyPage editorPageSnapshot(WidgetRef ref) {
  final lineUps = ref.read(lineUpProvider).graph.deepCopy();
  return StrategyPage(
    id: ref.read(strategyPageSessionProvider).activePageId ?? '',
    name: _activePageName(ref) ?? '',
    drawingData: DrawingProvider.fromJson(
      DrawingProvider.objectToJson(ref.read(drawingProvider).elements),
    ),
    agentData: ref.read(agentProvider).map(clonePlacedAgentNode).toList(),
    abilityData: ref.read(abilityProvider).map(clonePlacedAbility).toList(),
    textData: ref
        .read(textProvider.notifier)
        .snapshotForPersistence()
        .map(clonePlacedText)
        .toList(),
    imageData:
        ref.read(placedImageProvider).images.map(clonePlacedImage).toList(),
    utilityData: ref.read(utilityProvider).map(clonePlacedUtility).toList(),
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
