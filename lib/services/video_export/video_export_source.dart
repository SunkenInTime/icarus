import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/services/local_image_file.dart';
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

/// The strategy a video export renders, saved and whole, with its images
/// decoded. Release [images] once the export is done.
typedef VideoExportSource = ({StrategyData strategy, CaptureImages images});

/// How long a cloud export waits for this device's changes to land.
const videoExportSyncTimeout = Duration(seconds: 20);

/// Saves the open strategy and reads it back whole for [pageIds].
///
/// A local strategy is read back from the library. A cloud strategy's other
/// pages live only on the server, so the export waits for this device's
/// changes to land (the strategy shows as synced), then reads the whole
/// strategy from the server. Throws [VideoExportNotSynced] when they don't
/// land within [videoExportSyncTimeout], and [CaptureImagesUnavailable] when
/// an image on the exported pages cannot be fetched.
Future<VideoExportSource> loadVideoExportSource(
  WidgetRef ref, {
  required Set<String> pageIds,
}) async {
  final state = ref.read(strategyProvider);
  final strategyId = state.strategyId;
  if (strategyId == null) {
    throw StateError('No strategy is open to export.');
  }
  await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
  // A signed-out reader's only access is the link they opened.
  final linkView = ref.read(shareLinkViewProvider);
  final shareToken =
      linkView?.strategyPublicId == strategyId ? linkView!.token : null;

  final StrategyData strategy;
  final Map<String, RemoteImageAsset> assets;
  switch (state.source) {
    case StrategySource.cloud:
      await _waitUntilSynced(ref);
      final snapshot = await ref
          .read(convexStrategyRepositoryProvider)
          .fetchFullSnapshot(strategyId, shareToken: shareToken);
      strategy =
          StrategyImportExportService.strategyDataFromRemoteSnapshot(snapshot);
      assets = snapshot.assetsById;
    case StrategySource.local || null:
      final saved =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategyId);
      if (saved == null) {
        throw StateError('Strategy $strategyId is not in the library.');
      }
      strategy = saved;
      assets = const {};
  }

  final isCloud = state.source == StrategySource.cloud;
  final images = await resolveCaptureImages(
    {
      for (final page in strategy.pages)
        if (pageIds.contains(page.id))
          for (final image in page.imageData)
            image.id: resolveStrategyImageSource(
              localFilePath: findLocalImageFile(
                storageDirectory: state.storageDirectory,
                imageId: image.id,
                fileExtension: image.fileExtension,
              ),
              isCloudStrategy: isCloud,
              // The whole strategy was just read, and this device has
              // nothing left to upload.
              assetsLoaded: true,
              remoteAsset: assets[image.id],
              uploadMayBeQueuedHere: false,
            ),
    },
    fetch: (imageId, url) => downloadCloudImageBytes(
      url,
      freshUrl: () =>
          ref.read(convexStrategyRepositoryProvider).getImageAssetUrl(
                strategyPublicId: strategyId,
                assetPublicId: imageId,
                shareToken: shareToken,
              ),
    ),
  );
  return (strategy: strategy, images: images);
}

Future<void> _waitUntilSynced(WidgetRef ref) async {
  if (ref.read(strategySaveStateProvider).canLeaveSafely) return;
  final synced = Completer<void>();
  final subscription = ref.listenManual(
    strategySaveStateProvider.select((state) => state.canLeaveSafely),
    (_, canLeaveSafely) {
      if (canLeaveSafely && !synced.isCompleted) synced.complete();
    },
  );
  try {
    await synced.future.timeout(videoExportSyncTimeout);
  } on TimeoutException {
    throw const VideoExportNotSynced();
  } finally {
    subscription.close();
  }
}
