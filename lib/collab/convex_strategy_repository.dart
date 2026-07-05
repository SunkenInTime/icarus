import 'dart:async';
import 'dart:convert';

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';

final convexStrategyRepositoryProvider = Provider<ConvexStrategyRepository>(
  (ref) => ConvexStrategyRepository(ConvexClient.instance),
);

class ConvexStrategyRepository {
  ConvexStrategyRepository(this._client);

  final ConvexClient _client;

  Object? _decodeJsonPayload(dynamic value) {
    if (value is String) {
      try {
        return jsonDecode(value);
      } catch (_) {
        return value;
      }
    }
    return value;
  }

  Map<String, dynamic> _decodeObject(dynamic value) {
    final decoded = _decodeJsonPayload(value);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw FormatException(
        'Expected object payload, received ${decoded.runtimeType}');
  }

  List<Map<String, dynamic>> _decodeObjectList(dynamic value) {
    final decoded = _decodeJsonPayload(value);
    if (decoded is! List) {
      throw FormatException(
          'Expected list payload, received ${decoded.runtimeType}');
    }

    return decoded
        .map((item) => _decodeJsonPayload(item))
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Stream<List<CloudFolderSummary>> watchAllFolders() {
    return _watchList(
      name: 'folders:listAll',
      args: const {'scope': 'all'},
      fromJson: CloudFolderSummary.fromJson,
    );
  }

  Stream<List<CloudFolderSummary>> watchFoldersForParent(
    String? parentFolderPublicId, {
    String scope = 'owned',
  }) {
    return _watchList(
      name: 'folders:listForParent',
      args: {
        if (parentFolderPublicId != null)
          'parentFolderPublicId': parentFolderPublicId,
        'scope': scope,
      },
      fromJson: CloudFolderSummary.fromJson,
    );
  }

  Stream<List<CloudStrategySummary>> watchStrategiesForFolder(
    String? folderPublicId, {
    String scope = 'owned',
  }) {
    return _watchList(
      name: 'strategies:listForFolder',
      args: {
        if (folderPublicId != null) 'folderPublicId': folderPublicId,
        'scope': scope,
      },
      fromJson: CloudStrategySummary.fromJson,
    );
  }

  Stream<List<CloudStrategySummary>> watchSharedStrategies() {
    return _watchList(
      name: 'strategies:listSharedWithMe',
      args: const {},
      fromJson: CloudStrategySummary.fromJson,
    );
  }

  Stream<List<T>> _watchList<T>({
    required String name,
    required Map<String, dynamic> args,
    required T Function(Map<String, dynamic>) fromJson,
  }) {
    return _watch<List<T>>(
      name: name,
      args: args,
      decode: (value) =>
          _decodeObjectList(value).map(fromJson).toList(growable: false),
    );
  }

  Stream<T> _watchObject<T>({
    required String name,
    required Map<String, dynamic> args,
    required T Function(Map<String, dynamic>) fromJson,
  }) {
    return _watch<T>(
      name: name,
      args: args,
      decode: (value) => fromJson(_decodeObject(value)),
    );
  }

  Stream<T> _watch<T>({
    required String name,
    required Map<String, dynamic> args,
    required T Function(dynamic) decode,
  }) {
    final controller = StreamController<T>.broadcast();
    SubscriptionHandle? subscription;
    bool isListening = false;
    int epoch = 0;

    Future<void> start(int myEpoch) async {
      try {
        final nextSubscription = await _client.subscribe(
          name: name,
          args: args,
          onUpdate: (value) {
            if (!isListening || epoch != myEpoch) {
              return;
            }
            try {
              controller.add(decode(value));
            } catch (error, stackTrace) {
              controller.addError(error, stackTrace);
            }
          },
          onError: (message, _) {
            if (!isListening || epoch != myEpoch) {
              return;
            }
            controller.addError(Exception('$name error: $message'));
          },
        );

        if (!isListening || epoch != myEpoch) {
          try {
            nextSubscription.cancel();
          } catch (_) {}
          return;
        }

        subscription = nextSubscription;
      } catch (error, stackTrace) {
        if (isListening && epoch == myEpoch) {
          controller.addError(error, stackTrace);
        }
      }
    }

    controller.onListen = () {
      if (isListening) {
        return;
      }
      isListening = true;
      final myEpoch = ++epoch;
      start(myEpoch);
    };

    controller.onCancel = () {
      isListening = false;
      try {
        subscription?.cancel();
      } catch (_) {}
      subscription = null;
      epoch += 1;
    };

    return controller.stream;
  }

  Future<RemoteStrategySnapshot> fetchSnapshot(String strategyPublicId) async {
    final response = await _client.query('snapshot:get', {
      'strategyPublicId': strategyPublicId,
    });
    return _decodeSnapshot(_decodeObject(response));
  }

  Stream<RemoteStrategySnapshot> watchSnapshot(String strategyPublicId) {
    return _watchObject(
      name: 'snapshot:get',
      args: {'strategyPublicId': strategyPublicId},
      fromJson: _decodeSnapshot,
    );
  }

  RemoteStrategySnapshot _decodeSnapshot(Map<String, dynamic> value) {
    final header =
        RemoteStrategyHeader.fromJson(_decodeObject(value['header']));
    // snapshot:get returns pages, elements, and lineups ordered by sortIndex.
    final pages = _decodeObjectList(value['pages'])
        .map(RemotePage.fromJson)
        .toList(growable: false);
    final elements = _decodeObjectList(value['elements'])
        .map(RemoteElement.fromJson)
        .toList(growable: false);
    final lineups = _decodeObjectList(value['lineups'])
        .map(RemoteLineup.fromJson)
        .toList(growable: false);
    final assets = _decodeObjectList(value['assets'])
        .map(RemoteImageAsset.fromJson)
        .toList(growable: false);

    return RemoteStrategySnapshot(
      header: header,
      pages: pages,
      elementsByPage: RemoteStrategySnapshot.groupElementsByPage(elements),
      lineupsByPage: RemoteStrategySnapshot.groupLineupsByPage(lineups),
      assetsById: {
        for (final asset in assets) asset.publicId: asset,
      },
    );
  }

  Future<CloudImageUploadIntent> generateImageUploadUrl({
    required String strategyPublicId,
    required String assetPublicId,
    required String mimeType,
    required String fileExtension,
    int? byteSize,
    int? width,
    int? height,
  }) async {
    final response = await _client.action(
      name: 'images:generateUploadUrl',
      args: {
        'strategyPublicId': strategyPublicId,
        'assetPublicId': assetPublicId,
        'mimeType': mimeType,
        'fileExtension': fileExtension,
        if (byteSize != null) 'byteSize': byteSize,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      },
    );
    return CloudImageUploadIntent.fromJson(_decodeObject(response));
  }

  Future<void> completeImageUpload({
    required String strategyPublicId,
    required String assetPublicId,
    String? provider,
    String? uploadId,
    String? objectKey,
    String? storageId,
    String? etag,
    String? mimeType,
    String? fileExtension,
    int? byteSize,
    int? width,
    int? height,
  }) async {
    await _client.action(
      name: 'images:completeUpload',
      args: {
        'strategyPublicId': strategyPublicId,
        'assetPublicId': assetPublicId,
        if (provider != null) 'provider': provider,
        if (uploadId != null) 'uploadId': uploadId,
        if (objectKey != null) 'objectKey': objectKey,
        if (storageId != null) 'storageId': storageId,
        if (etag != null) 'etag': etag,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileExtension != null) 'fileExtension': fileExtension,
        if (byteSize != null) 'byteSize': byteSize,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      },
    );
  }

  Future<String?> getImageAssetUrl({
    required String strategyPublicId,
    required String assetPublicId,
  }) async {
    final response = await _client.query(
      'images:getAssetUrl',
      {
        'strategyPublicId': strategyPublicId,
        'assetPublicId': assetPublicId,
      },
    );
    return _decodeObject(response)['url'] as String?;
  }

  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    if (ops.isEmpty) {
      return const [];
    }

    final response = await _client.mutation(
      name: 'ops:applyBatch',
      args: {
        'strategyPublicId': strategyPublicId,
        'clientId': clientId,
        'clientProtocolVersion': currentCloudProtocolVersion,
        'ops': ops.map((op) => op.toConvexJson()).toList(growable: false),
      },
    );

    final resultList =
        (_decodeObject(response)['results'] as List?) ?? const [];
    return resultList
        .whereType<Map>()
        .map((item) => OpAck.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<void> createFolder({
    required String publicId,
    required String name,
    String? parentFolderPublicId,
    int? iconId,
    int? iconCodePoint,
    String? iconFontFamily,
    String? iconFontPackage,
    String? color,
    int? customColorValue,
  }) async {
    await _client.mutation(
      name: 'folders:create',
      args: {
        'publicId': publicId,
        'name': name,
        if (parentFolderPublicId != null)
          'parentFolderPublicId': parentFolderPublicId,
        if (iconId != null) 'iconId': iconId,
        if (iconCodePoint != null) 'iconCodePoint': iconCodePoint,
        if (iconFontFamily != null) 'iconFontFamily': iconFontFamily,
        if (iconFontPackage != null) 'iconFontPackage': iconFontPackage,
        if (color != null) 'color': color,
        if (customColorValue != null) 'customColorValue': customColorValue,
      },
    );
  }

  Future<void> createStrategy({
    required String publicId,
    required String name,
    required String mapData,
    String? folderPublicId,
    String? themeProfileId,
    Map<String, dynamic>? themeOverridePalette,
  }) async {
    await _client.mutation(
      name: 'strategies:create',
      args: {
        'publicId': publicId,
        'name': name,
        'mapData': mapData,
        if (folderPublicId != null) 'folderPublicId': folderPublicId,
        if (themeProfileId != null) 'themeProfileId': themeProfileId,
        if (themeOverridePalette != null)
          'themeOverridePalette': themeOverridePalette,
      },
    );
  }

  Future<void> createStrategyWithInitialPage({
    required String publicId,
    required String name,
    required String mapData,
    required String initialPagePublicId,
    required String initialPageName,
    required bool initialPageIsAttack,
    String? folderPublicId,
    String? themeProfileId,
    Map<String, dynamic>? themeOverridePalette,
    Map<String, dynamic>? initialPageSettings,
  }) async {
    await _client.mutation(
      name: 'strategies:createWithInitialPage',
      args: {
        'publicId': publicId,
        'name': name,
        'mapData': mapData,
        'initialPagePublicId': initialPagePublicId,
        'initialPageName': initialPageName,
        'initialPageIsAttack': initialPageIsAttack,
        if (folderPublicId != null) 'folderPublicId': folderPublicId,
        if (themeProfileId != null) 'themeProfileId': themeProfileId,
        if (themeOverridePalette != null)
          'themeOverridePalette': themeOverridePalette,
        if (initialPageSettings != null)
          'initialPageSettings': initialPageSettings,
      },
    );
  }

  Future<List<ShareLinkSummary>> listShareLinks({
    required String targetType,
    required String targetPublicId,
  }) async {
    final response = await _client.query('shares:list', {
      'targetType': targetType,
      'targetPublicId': targetPublicId,
    });
    return _decodeObjectList(response)
        .map(ShareLinkSummary.fromJson)
        .toList(growable: false);
  }

  Future<void> createShareLink({
    required String targetType,
    required String targetPublicId,
    required String token,
    required String role,
  }) async {
    await _client.mutation(
      name: 'shares:create',
      args: {
        'targetType': targetType,
        'targetPublicId': targetPublicId,
        'token': token,
        'role': role,
      },
    );
  }

  Future<void> revokeShareLink({
    required String targetType,
    required String targetPublicId,
    required String token,
  }) async {
    await _client.mutation(
      name: 'shares:revoke',
      args: {
        'targetType': targetType,
        'targetPublicId': targetPublicId,
        'token': token,
      },
    );
  }

  Future<Map<String, dynamic>> redeemShareLink(String token) async {
    final response = await _client.mutation(
      name: 'shares:redeem',
      args: {'token': token},
    );
    return _decodeObject(response);
  }
}
