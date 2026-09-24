import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/providers/collab/cloud_media_cache_provider.dart';
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

final strategyImageSourceProvider = Provider.autoDispose
    .family<StrategyImageSource, StrategyImageKey>((ref, image) {
  final (storageDirectory, source) = ref.watch(
    strategyProvider.select((s) => (s.storageDirectory, s.source)),
  );
  final remoteAsset = ref.watch(
    remoteEditorSnapshotProvider
        .select((snapshot) => snapshot.valueOrNull?.assetsById[image.id]),
  );
  // Look on the device again once the cloud media cache has downloaded it.
  ref.watch(
    cloudMediaCacheProvider
        .select((cache) => cache.cachedAssetIds.contains(image.id)),
  );

  return resolveStrategyImageSource(
    localFilePath: findLocalImageFile(
      storageDirectory: storageDirectory,
      imageId: image.id,
      fileExtension: image.fileExtension,
    ),
    isCloudStrategy: source == StrategySource.cloud,
    remoteAsset: remoteAsset,
  );
});

/// A file on this device wins, then the cloud URL. Without either, a cloud
/// image is still on its way unless its upload failed.
StrategyImageSource resolveStrategyImageSource({
  required String? localFilePath,
  required bool isCloudStrategy,
  required RemoteImageAsset? remoteAsset,
}) {
  if (localFilePath != null) return LocalImageFile(localFilePath);
  final url = remoteAsset?.url;
  if (url != null && url.isNotEmpty) return RemoteImageUrl(url);
  if (isCloudStrategy && remoteAsset?.uploadStatus != 'failed') {
    return const ImageLoading();
  }
  return const ImageFailed();
}
