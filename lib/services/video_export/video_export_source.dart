import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_image_source.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/screenshot/capture_images.dart';
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

/// The strategy a video export renders, saved and whole, with its images
/// decoded. Release [images] once the export is done.
typedef VideoExportSource = ({StrategyData strategy, CaptureImages images});

/// How long a cloud export waits for this device's changes to land.
const videoExportSyncTimeout = Duration(seconds: 20);

/// Saves the open strategy and reads it back whole for [pageIds].
///
/// A local strategy is saved and read back from the library. A cloud
/// strategy's other pages live only on the server, so the export sends the
/// open page's edits, waits for everything this device still has to send
/// for the strategy to land, then reads the whole strategy from the server.
///
/// Throws [VideoExportNotSynced] when this device's work does not land
/// within [videoExportSyncTimeout], [VideoExportPagesChanged] when a page in
/// [pageIds] no longer exists, [CaptureImagesUnavailable] when an image on
/// the exported pages cannot be loaded, and [VideoExportCancelled] once
/// [isCancelled] turns true.
Future<VideoExportSource> loadVideoExportSource(
  WidgetRef ref, {
  required Set<String> pageIds,
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

  final StrategyData strategy;
  final Map<String, RemoteImageAsset> assets;
  switch (state.source) {
    case StrategySource.cloud:
      // Queues the open page's edits and sends them.
      await ref
          .read(strategyPageSessionProvider.notifier)
          .flushCurrentPage(flushImmediately: true);
      checkCancelled();
      await _waitUntilSent(ref, strategyId, isCancelled: isCancelled);
      final snapshot = await ref
          .read(convexStrategyRepositoryProvider)
          .fetchFullSnapshot(strategyId, shareToken: shareToken);
      checkCancelled();
      strategy =
          StrategyImportExportService.strategyDataFromRemoteSnapshot(snapshot);
      assets = snapshot.assetsById;
    case StrategySource.local || null:
      await ref.read(strategyProvider.notifier).forceSaveNow(strategyId);
      checkCancelled();
      final saved =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategyId);
      if (saved == null) {
        throw StateError('Strategy $strategyId is not in the library.');
      }
      strategy = saved;
      assets = const {};
  }

  final pages = [
    for (final page in strategy.pages)
      if (pageIds.contains(page.id)) page,
  ];
  if (pages.length != pageIds.length) {
    throw const VideoExportPagesChanged();
  }

  final isCloud = state.source == StrategySource.cloud;
  final images = await resolveCaptureImages(
    {
      for (final page in pages)
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
    checkpoint: checkCancelled,
  );
  return (strategy: strategy, images: images);
}

bool _never() => false;

/// Waits until this device has nothing left to send for [strategyId]: no
/// op queued, in flight, or held for review, and no image uploading. Read
/// from the queues at each check: a save with nothing to send changes no
/// queue state, so nothing listening would hear it finish.
Future<void> _waitUntilSent(
  WidgetRef ref,
  String strategyId, {
  required bool Function() isCancelled,
}) async {
  bool sent() {
    final ops = ref.read(strategyOpQueueProvider);
    final media = ref.read(cloudMediaUploadQueueProvider);
    // An outbox with records it could not read cannot say they landed.
    return ops.outboxIsReliable &&
        media.outboxIsReliable &&
        ops.pending.isEmpty &&
        !ops.isFlushing &&
        media.jobsForStrategy(strategyId).isEmpty;
  }

  const step = Duration(milliseconds: 100);
  var waited = Duration.zero;
  while (!sent()) {
    if (isCancelled()) throw VideoExportCancelled();
    // Work held for the user's review never lands by waiting.
    if (ref.read(strategyOpQueueProvider).needsAttention) {
      throw const VideoExportNotSynced();
    }
    if (waited >= videoExportSyncTimeout) throw const VideoExportNotSynced();
    await Future<void>.delayed(step);
    waited += step;
  }
}
