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
        PendingImageBytes(:final bytes) => MemoryImage(bytes),
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

/// Bytes this device is still uploading, painted until the cloud URL
/// arrives. Only where images are not files (web).
final class PendingImageBytes extends StrategyImageSource {
  const PendingImageBytes(this.bytes);
  final Uint8List bytes;
}

/// A cloud image whose URL has not arrived yet.
final class ImageLoading extends StrategyImageSource {
  const ImageLoading();
}

/// Nothing to show: the cloud upload failed, or a local strategy is missing
/// the file.
final class ImageFailed extends StrategyImageSource {
  const ImageFailed();
}

typedef StrategyImageKey = ({String id, String? fileExtension});

/// Where the bytes for [image] come from, read from a widget's build.
///
/// The file check runs on every build, so a file written or removed while
/// the image is on screen is seen on the next rebuild. Every media cache
/// change rebuilds the caller, so a finished download is seen at once.
StrategyImageSource watchStrategyImageSource(
  WidgetRef ref,
  StrategyImageKey image,
) {
  final (storageDirectory, source, strategyId) = ref.watch(
    strategyProvider
        .select((s) => (s.storageDirectory, s.source, s.strategyId)),
  );
  final remoteAsset = ref.watch(
    remoteEditorSnapshotProvider
        .select((snapshot) => snapshot.valueOrNull?.assetsById[image.id]),
  );
  ref.watch(cloudMediaCacheProvider);
  // Bytes this browser is still uploading for the signed-in account. They
  // only paint when neither the file check below nor the cloud URL has
  // anything. Where images are files there are never pending bytes.
  Uint8List? pendingBytes;
  if (!ref.watch(imageFilesOnDeviceProvider)) {
    final accountId = ref.watch(cloudMediaAccountIdProvider);
    if (accountId != null && strategyId != null) {
      final key = pendingMediaStorageKey((
        accountId: accountId,
        strategyPublicId: strategyId,
        assetPublicId: image.id,
      ));
      pendingBytes =
          ref.watch(pendingMediaBytesProvider.select((pending) => pending[key]));
    }
  }

  return resolveStrategyImageSource(
    localFilePath: findLocalImageFile(
      storageDirectory: storageDirectory,
      imageId: image.id,
      fileExtension: image.fileExtension,
    ),
    isCloudStrategy: source == StrategySource.cloud,
    remoteAsset: remoteAsset,
    pendingBytes: pendingBytes,
  );
}

/// A file on this device wins, then the cloud URL, then bytes still
/// uploading from this device. Without any, a cloud image is still on its
/// way unless its upload failed.
StrategyImageSource resolveStrategyImageSource({
  required String? localFilePath,
  required bool isCloudStrategy,
  required RemoteImageAsset? remoteAsset,
  Uint8List? pendingBytes,
}) {
  if (localFilePath != null) return LocalImageFile(localFilePath);
  final url = remoteAsset?.url;
  if (url != null && url.isNotEmpty) return RemoteImageUrl(url);
  if (pendingBytes != null) return PendingImageBytes(pendingBytes);
  if (isCloudStrategy && remoteAsset?.uploadStatus != 'failed') {
    return const ImageLoading();
  }
  return const ImageFailed();
}
