import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/pending_media_bytes_store.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/media_bytes_source.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/local_image_file.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

/// Where the bytes for one image in the open strategy (a placed image or a
/// lineup image) come from.
sealed class StrategyImageSource {
  const StrategyImageSource();

  /// What to paint, or null while there is nothing to paint.
  ImageProvider? get imageProvider => switch (this) {
        LocalImageFile(:final path) => localImageProvider(path),
        RemoteImageUrl(:final url) => NetworkImage(
            url,
            // Paint through an <img> element when the host does not let the
            // browser fetch the bytes.
            webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
          ),
        ImageBytes(:final bytes) => MemoryImage(bytes),
        ImageLoading() || ImageFailed() => null,
      };
}

/// The image file is on this device. Never produced on web.
final class LocalImageFile extends StrategyImageSource {
  const LocalImageFile(this.path);
  final String path;
}

/// The image is fetched from its cloud asset URL.
final class RemoteImageUrl extends StrategyImageSource {
  const RemoteImageUrl(this.url);
  final String url;
}

/// Bytes in memory: an image this device is still uploading, painted until
/// the cloud URL arrives (only where images are not files, on web), or one
/// fetched ahead of an offscreen capture.
final class ImageBytes extends StrategyImageSource {
  const ImageBytes(this.bytes);
  final Uint8List bytes;
}

/// A cloud image whose URL has not arrived yet: its upload is under way, or
/// the page listing its asset is still loading.
final class ImageLoading extends StrategyImageSource {
  const ImageLoading();
}

/// Nothing to show: the cloud upload failed, the server has no asset for the
/// image and none is on its way, or a local strategy is missing the file.
final class ImageFailed extends StrategyImageSource {
  const ImageFailed();
}

typedef StrategyImageKey = ({String id, String? fileExtension});

/// What each image paints in an offscreen capture, by image id, and null
/// everywhere else.
///
/// A capture renders in its own provider container, which has no live cloud
/// page, upload queue, or pending bytes to resolve an image from. The
/// capture resolves every image it paints before it starts and overrides
/// this provider with the result.
final captureImageSourcesProvider =
    Provider<Map<String, StrategyImageSource>?>((ref) => null);

/// Where the bytes for [image] come from, read from a widget's build.
///
/// The file check runs on every build, so a file written or removed while
/// the image is on screen is seen on the next rebuild. Every media cache
/// change rebuilds the caller, so a finished download is seen at once.
StrategyImageSource watchStrategyImageSource(
  WidgetRef ref,
  StrategyImageKey image,
) =>
    _strategyImageSource(ref.watch, image);

/// Where the bytes for [image] come from right now, read once, as the
/// editor would paint it.
StrategyImageSource readStrategyImageSource(
  WidgetRef ref,
  StrategyImageKey image,
) =>
    _strategyImageSource(ref.read, image);

StrategyImageSource _strategyImageSource(
  T Function<T>(ProviderListenable<T> provider) watch,
  StrategyImageKey image,
) {
  final captured = watch(captureImageSourcesProvider);
  if (captured != null) return captured[image.id] ?? const ImageFailed();

  final (storageDirectory, source, strategyId) = watch(
    strategyProvider
        .select((s) => (s.storageDirectory, s.source, s.strategyId)),
  );
  final (assetsLoaded, remoteAsset) = watch(
    remoteEditorSnapshotProvider.select((snapshot) {
      final page = snapshot.valueOrNull?.activePage;
      return (page != null, page?.assetsById[image.id]);
    }),
  );
  final isCloudStrategy = source == StrategySource.cloud;
  // Only cloud images are ever queued for upload. Until the signed-in
  // account is known, or while the outbox holds records it could not read,
  // the queue cannot rule a queued upload out.
  final uploadMayBeQueuedHere = isCloudStrategy &&
      (watch(cloudMediaAccountIdProvider) == null ||
          watch(
            cloudMediaUploadQueueProvider.select(
              (queue) =>
                  !queue.outboxIsReliable ||
                  queue.jobsForStrategy(strategyId).any(
                        (job) => job.assetPublicId == image.id && !job.isFailed,
                      ),
            ),
          ));
  watch(cloudMediaCacheProvider);
  // Bytes this browser is still uploading for the signed-in account. They
  // only paint when neither the file check below nor the cloud URL has
  // anything. Where images are files there are never pending bytes.
  Uint8List? pendingBytes;
  if (!watch(imageFilesOnDeviceProvider)) {
    final accountId = watch(cloudMediaAccountIdProvider);
    if (accountId != null && strategyId != null) {
      final key = pendingMediaStorageKey((
        accountId: accountId,
        strategyPublicId: strategyId,
        assetPublicId: image.id,
      ));
      pendingBytes =
          watch(pendingMediaBytesProvider.select((pending) => pending[key]));
    }
  }

  return resolveStrategyImageSource(
    localFilePath: findLocalImageFile(
      storageDirectory: storageDirectory,
      imageId: image.id,
      fileExtension: image.fileExtension,
    ),
    isCloudStrategy: isCloudStrategy,
    assetsLoaded: assetsLoaded,
    remoteAsset: remoteAsset,
    uploadMayBeQueuedHere: uploadMayBeQueuedHere,
    pendingBytes: pendingBytes,
  );
}

/// A file on this device wins, then the cloud URL, then bytes still
/// uploading from this device. Without any, a cloud image is on its way
/// while its asset is pending, while this device may have its upload queued,
/// or while the page that lists its asset is still loading. [assetsLoaded]
/// is that page's live snapshot. The server gives every image its content
/// shows a pending asset until the upload lands, so an image the loaded page
/// has no asset for is not coming: it failed, or its upload never came and
/// was swept.
StrategyImageSource resolveStrategyImageSource({
  required String? localFilePath,
  required bool isCloudStrategy,
  required bool assetsLoaded,
  required RemoteImageAsset? remoteAsset,
  required bool uploadMayBeQueuedHere,
  Uint8List? pendingBytes,
}) {
  if (localFilePath != null) return LocalImageFile(localFilePath);
  final url = remoteAsset?.url;
  if (url != null && url.isNotEmpty) return RemoteImageUrl(url);
  if (pendingBytes != null) return ImageBytes(pendingBytes);
  if (!isCloudStrategy) return const ImageFailed();
  if (remoteAsset != null) {
    return remoteAsset.uploadStatus == 'failed'
        ? const ImageFailed()
        : const ImageLoading();
  }
  return !assetsLoaded || uploadMayBeQueuedHere
      ? const ImageLoading()
      : const ImageFailed();
}
