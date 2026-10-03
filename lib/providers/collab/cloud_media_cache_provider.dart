import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/services/local_image_file.dart';

class CloudMediaCacheState {
  const CloudMediaCacheState({
    this.strategyPublicId,
    this.cachedAssetIds = const <String>{},
    this.inFlightAssetIds = const <String>{},
    this.lastErrorByAssetId = const <String, String>{},
  });

  final String? strategyPublicId;
  final Set<String> cachedAssetIds;
  final Set<String> inFlightAssetIds;
  final Map<String, String> lastErrorByAssetId;

  CloudMediaCacheState copyWith({
    String? strategyPublicId,
    bool clearStrategyPublicId = false,
    Set<String>? cachedAssetIds,
    Set<String>? inFlightAssetIds,
    Map<String, String>? lastErrorByAssetId,
  }) {
    return CloudMediaCacheState(
      strategyPublicId:
          clearStrategyPublicId ? null : (strategyPublicId ?? this.strategyPublicId),
      cachedAssetIds: cachedAssetIds ?? this.cachedAssetIds,
      inFlightAssetIds: inFlightAssetIds ?? this.inFlightAssetIds,
      lastErrorByAssetId: lastErrorByAssetId ?? this.lastErrorByAssetId,
    );
  }
}

class CloudImageDownloadException implements Exception {
  const CloudImageDownloadException(this.statusCode);
  final int statusCode;

  @override
  String toString() => 'Failed to download image ($statusCode).';
}

/// How long one image download may take before it counts as failed.
const cloudImageDownloadTimeout = Duration(seconds: 60);

/// Downloads a cloud image's bytes from [url], through [client] when given
/// (the caller owns it and closes it). A signed URL the host refuses (401,
/// 403, or 404: it expired) is swapped once for [freshUrl] from the server.
/// Throws [CloudImageDownloadException] when the bytes don't come, and a
/// [TimeoutException] when a request stalls.
Future<Uint8List> downloadCloudImageBytes(
  String url, {
  required Future<String?> Function() freshUrl,
  http.Client? client,
}) async {
  Future<http.Response> get(String url) =>
      (client?.get(Uri.parse(url)) ?? http.get(Uri.parse(url)))
          .timeout(cloudImageDownloadTimeout);
  var response = await get(url);
  if (const {401, 403, 404}.contains(response.statusCode)) {
    final refreshed = await freshUrl();
    if (refreshed != null && refreshed.isNotEmpty) {
      response = await get(refreshed);
    }
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw CloudImageDownloadException(response.statusCode);
  }
  return response.bodyBytes;
}

final cloudMediaCacheProvider =
    NotifierProvider<CloudMediaCacheNotifier, CloudMediaCacheState>(
  CloudMediaCacheNotifier.new,
);

class CloudMediaCacheNotifier extends Notifier<CloudMediaCacheState> {
  @override
  CloudMediaCacheState build() {
    return const CloudMediaCacheState();
  }

  Future<String> localAssetPath({
    required String strategyId,
    required String assetId,
    required String fileExtension,
  }) async {
    final imageFolder = await PlacedImageProvider.getImageFolder(strategyId);
    return PlacedImageProvider.buildImageFilePath(
      imageFolder.path,
      assetId,
      fileExtension,
    );
  }

  Future<File?> localFileForAsset({
    required String strategyId,
    required RemoteImageAsset asset,
  }) async {
    final file = File(
      await localAssetPath(
        strategyId: strategyId,
        assetId: asset.publicId,
        fileExtension: asset.fileExtension,
      ),
    );
    if (await file.exists()) {
      _markCached(asset.publicId);
      return file;
    }
    return null;
  }

  Future<void> ensureAssetsCached({
    required String strategyId,
    required String strategyPublicId,
    required Iterable<RemoteImageAsset> assets,
  }) async {
    final uniqueAssets = {
      for (final asset in assets) asset.publicId: asset,
    }.values.toList(growable: false);
    for (final asset in uniqueAssets) {
      await ensureAssetCached(
        strategyId: strategyId,
        strategyPublicId: strategyPublicId,
        asset: asset,
      );
    }
  }

  /// Downloads [asset] into the strategy's image folder. A platform without
  /// image files (web) has nothing to cache; it paints from the URL.
  Future<File?> ensureAssetCached({
    required String strategyId,
    required String strategyPublicId,
    required RemoteImageAsset asset,
  }) async {
    if (!deviceHasImageFiles) return null;
    final existing = await localFileForAsset(strategyId: strategyId, asset: asset);
    if (existing != null) {
      return existing;
    }

    if (asset.url == null || asset.url!.isEmpty) {
      _recordError(asset.publicId, 'Missing remote asset URL.');
      return null;
    }

    if (state.inFlightAssetIds.contains(asset.publicId)) {
      return null;
    }

    _markInFlight(asset.publicId, strategyPublicId);
    try {
      final bytes = await downloadCloudImageBytes(
        asset.url!,
        freshUrl: () {
          final linkView = ref.read(shareLinkViewProvider);
          return ref.read(convexStrategyRepositoryProvider).getImageAssetUrl(
                strategyPublicId: strategyPublicId,
                assetPublicId: asset.publicId,
                // A signed-out reader's only access is the link they opened.
                shareToken: linkView?.strategyPublicId == strategyPublicId
                    ? linkView!.token
                    : null,
              );
        },
      );
      final output = File(
        await localAssetPath(
          strategyId: strategyId,
          assetId: asset.publicId,
          fileExtension: asset.fileExtension,
        ),
      );
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes, flush: true);
      _markCached(asset.publicId);
      return output;
    } catch (error) {
      _recordError(asset.publicId, '$error');
      return null;
    } finally {
      _clearInFlight(asset.publicId);
    }
  }

  Future<bool> ensureAssetIdsCached({
    required String strategyId,
    required String strategyPublicId,
    required Map<String, RemoteImageAsset> assetsById,
    required Iterable<String> assetIds,
  }) async {
    for (final assetId in assetIds.toSet()) {
      final asset = assetsById[assetId];
      if (asset == null) {
        return false;
      }
      final file = await ensureAssetCached(
        strategyId: strategyId,
        strategyPublicId: strategyPublicId,
        asset: asset,
      );
      if (file == null || !await file.exists()) {
        return false;
      }
    }
    return true;
  }

  void resetStrategy(String? strategyPublicId) {
    state = CloudMediaCacheState(strategyPublicId: strategyPublicId);
  }

  void _markCached(String assetId) {
    final cached = {...state.cachedAssetIds, assetId};
    final errors = Map<String, String>.from(state.lastErrorByAssetId)
      ..remove(assetId);
    state = state.copyWith(
      cachedAssetIds: cached,
      lastErrorByAssetId: errors,
    );
  }

  void _markInFlight(String assetId, String strategyPublicId) {
    state = state.copyWith(
      strategyPublicId: strategyPublicId,
      inFlightAssetIds: {...state.inFlightAssetIds, assetId},
    );
  }

  void _clearInFlight(String assetId) {
    final next = {...state.inFlightAssetIds}..remove(assetId);
    state = state.copyWith(inFlightAssetIds: next);
  }

  void _recordError(String assetId, String error) {
    final errors = Map<String, String>.from(state.lastErrorByAssetId)
      ..[assetId] = error;
    state = state.copyWith(lastErrorByAssetId: errors);
  }
}
