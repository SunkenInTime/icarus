import 'dart:async';
import 'dart:convert';

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  Future<List<CloudFolderSummary>> listFoldersForParent(
    String? parentFolderPublicId, {
    String scope = 'owned',
  }) async {
    final response = await _client.query('folders:listForParent', {
      if (parentFolderPublicId != null)
        'parentFolderPublicId': parentFolderPublicId,
      'scope': scope,
    });
    return _decodeObjectList(response)
        .map(CloudFolderSummary.fromJson)
        .toList(growable: false);
  }

  Future<List<CloudFolderSummary>> listAllFolders(
      {String scope = 'all'}) async {
    final response = await _client.query('folders:listAll', {'scope': scope});
    return _decodeObjectList(response)
        .map(CloudFolderSummary.fromJson)
        .toList(growable: false);
  }

  Stream<List<CloudFolderSummary>> watchAllFolders() {
    final controller = StreamController<List<CloudFolderSummary>>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      try {
        controller.add(await listAllFolders());
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }

      subscription = await _client.subscribe(
        name: 'folders:listAll',
        args: const {'scope': 'all'},
        onUpdate: (value) {
          try {
            final mapped = _decodeObjectList(value)
                .map(CloudFolderSummary.fromJson)
                .toList(growable: false);
            controller.add(mapped);
          } catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
        },
        onError: (message, value) {
          controller.addError(Exception('folders:listAll error: $message'));
        },
      );
    }

    start();
    controller.onCancel = () {
      try {
        subscription?.cancel();
      } catch (_) {}
    };

    return controller.stream;
  }

  Future<List<CloudStrategySummary>> listStrategiesForFolder(
    String? folderPublicId, {
    String scope = 'owned',
  }) async {
    final response = await _client.query('strategies:listForFolder', {
      if (folderPublicId != null) 'folderPublicId': folderPublicId,
      'scope': scope,
    });
    return _decodeObjectList(response)
        .map(CloudStrategySummary.fromJson)
        .toList(growable: false);
  }

  Future<List<CloudStrategySummary>> listSharedStrategies() async {
    final response = await _client.query('strategies:listSharedWithMe', {});
    return _decodeObjectList(response)
        .map(CloudStrategySummary.fromJson)
        .toList(growable: false);
  }

  Stream<List<CloudFolderSummary>> watchFoldersForParent(
    String? parentFolderPublicId, {
    String scope = 'owned',
  }) {
    final controller = StreamController<List<CloudFolderSummary>>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      try {
        controller.add(
            await listFoldersForParent(parentFolderPublicId, scope: scope));
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }

      subscription = await _client.subscribe(
        name: 'folders:listForParent',
        args: {
          if (parentFolderPublicId != null)
            'parentFolderPublicId': parentFolderPublicId,
          'scope': scope,
        },
        onUpdate: (value) {
          try {
            final mapped = _decodeObjectList(value)
                .map(CloudFolderSummary.fromJson)
                .toList(growable: false);
            controller.add(mapped);
          } catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
        },
        onError: (message, value) {
          controller
              .addError(Exception('folders:listForParent error: $message'));
        },
      );
    }

    start();
    controller.onCancel = () {
      try {
        subscription?.cancel();
      } catch (_) {}
    };

    return controller.stream;
  }

  Stream<List<CloudStrategySummary>> watchStrategiesForFolder(
    String? folderPublicId, {
    String scope = 'owned',
  }) {
    final controller = StreamController<List<CloudStrategySummary>>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      try {
        controller
            .add(await listStrategiesForFolder(folderPublicId, scope: scope));
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }

      subscription = await _client.subscribe(
        name: 'strategies:listForFolder',
        args: {
          if (folderPublicId != null) 'folderPublicId': folderPublicId,
          'scope': scope,
        },
        onUpdate: (value) {
          try {
            final mapped = _decodeObjectList(value)
                .map(CloudStrategySummary.fromJson)
                .toList(growable: false);
            controller.add(mapped);
          } catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
        },
        onError: (message, value) {
          controller
              .addError(Exception('strategies:listForFolder error: $message'));
        },
      );
    }

    start();

    controller.onCancel = () {
      try {
        subscription?.cancel();
      } catch (_) {}
    };

    return controller.stream;
  }

  Stream<List<CloudStrategySummary>> watchSharedStrategies() {
    final controller = StreamController<List<CloudStrategySummary>>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      try {
        controller.add(await listSharedStrategies());
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }

      subscription = await _client.subscribe(
        name: 'strategies:listSharedWithMe',
        args: const {},
        onUpdate: (value) {
          try {
            final mapped = _decodeObjectList(value)
                .map(CloudStrategySummary.fromJson)
                .toList(growable: false);
            controller.add(mapped);
          } catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
        },
        onError: (message, value) {
          controller.addError(
              Exception('strategies:listSharedWithMe error: $message'));
        },
      );
    }

    start();

    controller.onCancel = () {
      try {
        subscription?.cancel();
      } catch (_) {}
    };

    return controller.stream;
  }

  Stream<RemoteStrategyHeader> watchStrategyHeader(String strategyPublicId) {
    final controller = StreamController<RemoteStrategyHeader>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      subscription = await _client.subscribe(
        name: 'strategies:getHeader',
        args: {'strategyPublicId': strategyPublicId},
        onUpdate: (value) {
          try {
            controller.add(RemoteStrategyHeader.fromJson(_decodeObject(value)));
          } catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
        },
        onError: (message, value) {
          controller
              .addError(Exception('strategies:getHeader error: $message'));
        },
      );
    }

    start();
    controller.onCancel = () {
      try {
        subscription?.cancel();
      } catch (_) {}
    };

    return controller.stream;
  }

  Future<List<RemotePage>> listPagesForStrategy(String strategyPublicId) async {
    final response = await _client.query('pages:listForStrategy', {
      'strategyPublicId': strategyPublicId,
    });
    return _decodeObjectList(response)
        .map(RemotePage.fromJson)
        .toList(growable: false)
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
  }

  Future<List<RemoteImageAsset>> listImageAssetsForStrategy(
    String strategyPublicId,
  ) async {
    final response = await _client.query('images:listForStrategy', {
      'strategyPublicId': strategyPublicId,
    });
    return _decodeObjectList(response)
        .map(RemoteImageAsset.fromJson)
        .toList(growable: false);
  }

  Future<List<RemoteElement>> listElementsForStrategy(
    String strategyPublicId,
  ) async {
    final response = await _client.query('elements:listForStrategy', {
      'strategyPublicId': strategyPublicId,
    });
    return _decodeObjectList(response)
        .map(RemoteElement.fromJson)
        .toList(growable: false)
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
  }

  Future<List<RemoteLineup>> listLineupsForStrategy(
    String strategyPublicId,
  ) async {
    final response = await _client.query('lineups:listForStrategy', {
      'strategyPublicId': strategyPublicId,
    });
    return _decodeObjectList(response)
        .map(RemoteLineup.fromJson)
        .toList(growable: false)
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
  }

  Stream<List<T>> _watchList<T>({
    required String name,
    required Map<String, dynamic> args,
    required T Function(Map<String, dynamic>) fromJson,
  }) {
    final controller = StreamController<List<T>>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      subscription = await _client.subscribe(
        name: name,
        args: args,
        onUpdate: (value) {
          try {
            final mapped =
                _decodeObjectList(value).map(fromJson).toList(growable: false);
            controller.add(mapped);
          } catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
        },
        onError: (message, value) {
          controller.addError(Exception('$name error: $message'));
        },
      );
    }

    start();
    controller.onCancel = () {
      try {
        subscription?.cancel();
      } catch (_) {}
    };

    return controller.stream;
  }

  Stream<List<RemotePage>> watchPagesForStrategy(String strategyPublicId) {
    return _watchList(
      name: 'pages:listForStrategy',
      args: {'strategyPublicId': strategyPublicId},
      fromJson: RemotePage.fromJson,
    ).map((pages) => pages..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)));
  }

  Stream<List<RemoteImageAsset>> watchImageAssetsForStrategy(
    String strategyPublicId,
  ) {
    return _watchList(
      name: 'images:listForStrategy',
      args: {'strategyPublicId': strategyPublicId},
      fromJson: RemoteImageAsset.fromJson,
    );
  }

  Stream<List<RemoteElement>> watchElementsForStrategy(
    String strategyPublicId,
  ) {
    return _watchList(
      name: 'elements:listForStrategy',
      args: {'strategyPublicId': strategyPublicId},
      fromJson: RemoteElement.fromJson,
    ).map((elements) =>
        elements..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)));
  }

  Stream<List<RemoteLineup>> watchLineupsForStrategy(
    String strategyPublicId,
  ) {
    return _watchList(
      name: 'lineups:listForStrategy',
      args: {'strategyPublicId': strategyPublicId},
      fromJson: RemoteLineup.fromJson,
    ).map((lineups) =>
        lineups..sort((a, b) => a.sortIndex.compareTo(b.sortIndex)));
  }

  Future<RemoteStrategySnapshot> fetchSnapshot(String strategyPublicId) async {
    final headerRaw = await _client.query('strategies:getHeader', {
      'strategyPublicId': strategyPublicId,
    });
    final header = RemoteStrategyHeader.fromJson(_decodeObject(headerRaw));

    final pages = await listPagesForStrategy(strategyPublicId);
    final assets = await listImageAssetsForStrategy(strategyPublicId);
    final elements = await listElementsForStrategy(strategyPublicId);
    final lineups = await listLineupsForStrategy(strategyPublicId);
    final assetsById = <String, RemoteImageAsset>{
      for (final asset in assets) asset.publicId: asset,
    };

    return RemoteStrategySnapshot(
      header: header,
      pages: pages,
      elementsByPage: RemoteStrategySnapshot.groupElementsByPage(elements),
      lineupsByPage: RemoteStrategySnapshot.groupLineupsByPage(lineups),
      assetsById: assetsById,
    );
  }

  Future<String> generateImageUploadUrl(String strategyPublicId) async {
    final response = await _client.mutation(
      name: 'images:generateUploadUrl',
      args: {
        'strategyPublicId': strategyPublicId,
      },
    );
    return (_decodeObject(response)['uploadUrl'] as String?) ?? '';
  }

  Future<void> completeImageUpload({
    required String strategyPublicId,
    required String assetPublicId,
    required String storageId,
    String? mimeType,
    String? fileExtension,
    int? width,
    int? height,
  }) async {
    await _client.mutation(
      name: 'images:completeUpload',
      args: {
        'strategyPublicId': strategyPublicId,
        'assetPublicId': assetPublicId,
        'storageId': storageId,
        if (mimeType != null) 'mimeType': mimeType,
        if (fileExtension != null) 'fileExtension': fileExtension,
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
    String? themeOverridePalette,
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
    String? themeOverridePalette,
    String? initialPageSettings,
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
