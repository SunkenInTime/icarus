import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/placed_media_dimensions.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/providers/action_history_models.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/services/cloud_work_sent.dart';
import 'package:icarus/services/local_image_file.dart';
import 'package:icarus/services/video_export/video_export_errors.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

/// A page the export dialog offers.
typedef VideoExportPageChoice = ({String id, String name});

/// The open strategy's pages in order, from wherever the strategy lives.
List<VideoExportPageChoice> videoExportPageChoices(WidgetRef ref) {
  final strategy = ref.read(strategyProvider);
  return switch (strategy.source) {
    StrategySource.cloud => [
        for (final page in [
          ...?ref.read(remoteEditorSnapshotProvider).valueOrNull?.pages,
        ]..sortBySortIndex((page) => page.sortIndex))
          (id: page.publicId, name: page.name),
      ],
    StrategySource.local => [
        for (final page in [
          ...?Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
              .get(strategy.strategyId)
              ?.pages,
        ]..sortBySortIndex((page) => page.sortIndex))
          (id: page.id, name: page.name),
      ],
    null => const [],
  };
}

/// This device's changes to a cloud strategy did not reach the server in
/// time, so an export would leave out work the user can see.
class VideoExportNotSynced implements Exception {
  const VideoExportNotSynced();

  String get userMessage =>
      "Your latest changes haven't synced yet. Export once the strategy "
      'shows as synced.';

  @override
  String toString() => 'VideoExportNotSynced';
}

/// A selected page is gone from the strategy (a teammate deleted it), so
/// the video would not be the one the user asked for.
class VideoExportPagesChanged implements Exception {
  const VideoExportPagesChanged();

  String get userMessage =>
      'A page you selected was deleted. Check the pages and export again.';

  @override
  String toString() => 'VideoExportPagesChanged';
}

/// The strategy a video export renders, saved and whole, with its images,
/// which the export holds page by page. Release [images] once the export is
/// done.
typedef VideoExportSource = ({
  StrategyData strategy,
  CapturePageImages images,
});

/// The open strategy read whole, with what its cloud images are, before any
/// image is loaded.
typedef SavedStrategyRead = ({
  StrategyData strategy,
  Map<String, RemoteImageAsset> assets,
});

/// Saves the open strategy and reads it back whole for [pageIds], with its
/// images ready to load for a capture rendered at [pixelRatio].
///
/// A local strategy is saved and read back from the library. A cloud
/// strategy's other pages live only on the server, so the export sends the
/// open page's edits, waits for everything this device still has to send
/// for the strategy to land, then reads the whole strategy from the server.
///
/// Throws [VideoExportNotSynced] when this device's work does not land
/// (see [sendCloudWork]), [VideoExportPagesChanged] when a page in
/// [pageIds] no longer exists, [CaptureImagesUnavailable] when an image on
/// the exported pages is still loading, and [VideoExportCancelled] once
/// [isCancelled] turns true.
Future<VideoExportSource> loadVideoExportSource(
  WidgetRef ref, {
  required Set<String> pageIds,
  required double pixelRatio,
  bool Function() isCancelled = _never,
}) async {
  final read = await readSavedStrategy(
    ref,
    saveFirst: true,
    isCancelled: isCancelled,
  );
  final pages = [
    for (final page in read.strategy.pages)
      if (pageIds.contains(page.id)) page,
  ];
  if (pages.length != pageIds.length) {
    throw const VideoExportPagesChanged();
  }
  final images = capturePageImages(
    ref,
    read,
    pixelRatio: pixelRatio,
    isCancelled: isCancelled,
  );
  // An image still on its way stops the export before it starts; the
  // others load as the export reaches their pages.
  if (pages.any((page) => images
      .imagesOf(page)
      .values
      .any((image) => image.source is ImageLoading))) {
    throw const CaptureImagesUnavailable.stillLoading();
  }
  return (strategy: read.strategy, images: images);
}

/// Reads the open strategy whole: a local one from the library, a cloud one
/// from the server.
///
/// With [saveFirst], this device's work goes first, as an export needs: a
/// local strategy is saved, and a cloud one sends its edits and waits for
/// them to land (throwing [VideoExportNotSynced] when they don't). Without
/// it, nothing is written or sent, so a preview never saves for the user;
/// the page open in the editor may then be behind what is on screen, while
/// the others are as this device last left them.
Future<SavedStrategyRead> readSavedStrategy(
  WidgetRef ref, {
  required bool saveFirst,
  bool Function() isCancelled = _never,
}) async {
  void checkCancelled() {
    if (isCancelled()) throw VideoExportCancelled();
  }

  final state = ref.read(strategyProvider);
  final strategyId = state.strategyId;
  if (strategyId == null) {
    throw StateError('No strategy is open to export.');
  }
  // A signed-out reader's only access is the link they opened.
  final linkView = ref.read(shareLinkViewProvider);
  final shareToken =
      linkView?.strategyPublicId == strategyId ? linkView!.token : null;

  switch (state.source) {
    case StrategySource.cloud:
      final RemoteFullStrategySnapshot snapshot;
      if (saveFirst) {
        try {
          final sameAccount = await sendCloudWork(
            ref.read,
            strategyId: strategyId,
            checkpoint: checkCancelled,
          );
          checkCancelled();
          snapshot = await ref
              .read(convexStrategyRepositoryProvider)
              .fetchFullSnapshot(strategyId, shareToken: shareToken);
          sameAccount();
        } on CloudWorkNotSent {
          throw const VideoExportNotSynced();
        }
      } else {
        snapshot = await ref
            .read(convexStrategyRepositoryProvider)
            .fetchFullSnapshot(strategyId, shareToken: shareToken);
      }
      checkCancelled();
      return (
        strategy:
            StrategyImportExportService.strategyDataFromRemoteSnapshot(snapshot),
        assets: snapshot.assetsById,
      );
    case StrategySource.local || null:
      if (saveFirst) {
        await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
        checkCancelled();
      }
      final saved =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategyId);
      if (saved == null) {
        throw StateError('Strategy $strategyId is not in the library.');
      }
      // The library's own objects, which the editor loads too: a capture
      // rebuilds drawing paths in its own coordinates, so it gets copies.
      return (
        strategy: saved.copyWith(pages: saved.pages.map(_detached).toList()),
        assets: const <String, RemoteImageAsset>{},
      );
  }
}

/// The images on the pages of [read], for a capture rendered at
/// [pixelRatio] to hold page by page. Loading them throws
/// [CaptureImagesUnavailable] when one cannot be loaded, and
/// [VideoExportCancelled] once [isCancelled] turns true.
CapturePageImages capturePageImages(
  WidgetRef ref,
  SavedStrategyRead read, {
  required double pixelRatio,
  bool Function() isCancelled = _never,
}) {
  final state = ref.read(strategyProvider);
  final strategyId = state.strategyId!;
  final linkView = ref.read(shareLinkViewProvider);
  final shareToken =
      linkView?.strategyPublicId == strategyId ? linkView!.token : null;
  final isCloud = state.source == StrategySource.cloud;
  return CapturePageImages(
    imagesOf: (page) => {
      // By picture, as the captured pages' images look them up.
      for (final image in page.imageData)
        image.pictureId: (
          source: resolveStrategyImageSource(
            localFilePath: findLocalImageFile(
              storageDirectory: state.storageDirectory,
              imageId: image.pictureId,
              fileExtension: image.fileExtension,
            ),
            isCloudStrategy: isCloud,
            // The whole strategy was just read. An export has waited for
            // this device's uploads to land; a preview shows those that
            // have.
            assetsLoaded: true,
            remoteAsset: read.assets[image.pictureId],
            uploadMayBeQueuedHere: false,
          ),
          drawnAtMost: PlacedImageDimensions.capturedPictureBox(
            pixelRatio: pixelRatio,
            aspectRatio: image.aspectRatio,
          ),
        ),
    },
    fetch: (imageId, url, client) => downloadCloudImageBytes(
      url,
      client: client,
      freshUrl: () =>
          ref.read(convexStrategyRepositoryProvider).getImageAssetUrl(
                strategyPublicId: strategyId,
                assetPublicId: imageId,
                shareToken: shareToken,
              ),
    ),
    checkpoint: () {
      if (isCancelled()) throw VideoExportCancelled();
    },
  );
}

bool _never() => false;

/// [page] with copies of everything placed on it, so nothing a capture does
/// to its objects reaches the library's or the editor's.
StrategyPage _detached(StrategyPage page) {
  final lineUps = page.lineUpGraph.deepCopy();
  return StrategyPage(
    id: page.id,
    name: page.name,
    drawingData: DrawingProvider.fromJson(
      DrawingProvider.objectToJson(page.drawingData),
    ),
    agentData: page.agentData.map(clonePlacedAgentNode).toList(),
    abilityData: page.abilityData.map(clonePlacedAbility).toList(),
    textData: page.textData.map(clonePlacedText).toList(),
    imageData: page.imageData.map(clonePlacedImage).toList(),
    utilityData: page.utilityData.map(clonePlacedUtility).toList(),
    sortIndex: page.sortIndex,
    isAttack: page.isAttack,
    settings: page.settings,
    lineUpOrigins: lineUps.origins,
    lineUpLandings: lineUps.landings,
    lineUpLinks: lineUps.links,
  );
}
