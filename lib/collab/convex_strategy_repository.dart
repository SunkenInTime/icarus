import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';

final convexStrategyRepositoryProvider = Provider<ConvexStrategyRepository>(
  (ref) => ConvexStrategyRepository.fromClient(ConvexClient.instance),
);

class ConvexStrategyRepository {
  ConvexStrategyRepository(this._api);

  factory ConvexStrategyRepository.fromClient(ConvexClient client) =>
      ConvexStrategyRepository(
        IcarusConvexApi(PlatformConvexTransport(client)),
      );

  final IcarusConvexApi _api;

  Future<void> ensureCurrentUser() async {
    await _api.users.ensureCurrentUser();
  }

  Stream<List<CloudFolderSummary>> watchAllFolders() {
    return _api.folders
        .listTree(
          scope: const ConvexOptional.present(FoldersListTreeArgsScope.all),
        )
        .watch()
        .map(
          (folders) => folders.map(_folderSummary).toList(growable: false),
        );
  }

  Stream<List<CloudStrategySummary>> watchStrategiesForFolder(
    String? folderPublicId, {
    String scope = 'owned',
  }) {
    return _api.strategies
        .listForFolder(
          folderPublicId: _optional(folderPublicId),
          scope: ConvexOptional.present(_folderScope(scope)),
        )
        .watch()
        .map(
          (strategies) =>
              strategies.map(_strategySummary).toList(growable: false),
        );
  }

  Stream<List<CloudStrategySummary>> watchSharedStrategies() {
    return _api.strategies.listSharedWithMe().watch().map(
          (strategies) =>
              strategies.map(_strategySummary).toList(growable: false),
        );
  }

  Future<RemoteStrategyShell> fetchShell(String strategyPublicId) async {
    return _strategyShell(
      await _api.strategy.getShell(strategyPublicId: strategyPublicId).fetch(),
    );
  }

  Stream<RemoteStrategyShell> watchShell(String strategyPublicId) {
    return _api.strategy
        .getShell(strategyPublicId: strategyPublicId)
        .watch()
        .map(_strategyShell);
  }

  Future<RemotePageSnapshot> fetchPageSnapshot({
    required String strategyPublicId,
    required String pagePublicId,
  }) async {
    return _pageSnapshot(
      await _api.page
          .getSnapshot(
            strategyPublicId: strategyPublicId,
            pagePublicId: pagePublicId,
          )
          .fetch(),
    );
  }

  Stream<RemotePageSnapshot> watchPageSnapshot({
    required String strategyPublicId,
    required String pagePublicId,
  }) {
    return _api.page
        .getSnapshot(
          strategyPublicId: strategyPublicId,
          pagePublicId: pagePublicId,
        )
        .watch()
        .map(_pageSnapshot);
  }

  Future<RemoteFullStrategySnapshot> fetchFullSnapshot(
    String strategyPublicId,
  ) async {
    return _fullSnapshot(
      await _api.strategy
          .getFullSnapshot(strategyPublicId: strategyPublicId)
          .fetch(),
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
    final result = await _api.images.generateUploadUrl(
      strategyPublicId: strategyPublicId,
      assetPublicId: assetPublicId,
      mimeType: mimeType,
      fileExtension: fileExtension,
      byteSize: _optionalNumber(byteSize),
      width: _optionalNumber(width),
      height: _optionalNumber(height),
    );
    return CloudImageUploadIntent(
      provider: result.provider.wireName,
      uploadId: result.uploadId,
      objectKey: result.objectKey,
      uploadUrl: result.uploadUrl,
      requiredHeaders: result.requiredHeaders,
      expiresAt: _dateTime(result.expiresAt),
      maxBytes: result.maxBytes.toInt(),
    );
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
    await _api.images.completeUpload(
      strategyPublicId: strategyPublicId,
      assetPublicId: assetPublicId,
      provider: provider == null
          ? const ConvexOptional.absent()
          : ConvexOptional.present(_imageProvider(provider)),
      uploadId: _optional(uploadId),
      objectKey: _optional(objectKey),
      storageId: _optional(storageId),
      etag: _optional(etag),
      mimeType: _optional(mimeType),
      fileExtension: _optional(fileExtension),
      byteSize: _optionalNumber(byteSize),
      width: _optionalNumber(width),
      height: _optionalNumber(height),
    );
  }

  Future<String?> getImageAssetUrl({
    required String strategyPublicId,
    required String assetPublicId,
  }) async {
    final result = await _api.images
        .getAssetUrl(
          strategyPublicId: strategyPublicId,
          assetPublicId: assetPublicId,
        )
        .fetch();
    return result.url;
  }

  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    if (ops.isEmpty) return const [];

    final typedOps = ops.indexed
        .map(
          (entry) => OpsApplyBatchArgsOpsItem.decode(
            ConvexValue.fromDart(entry.$2.toConvexJson()),
            'ops[${entry.$1}]',
          ),
        )
        .toList(growable: false);
    final result = await _api.ops.applyBatch(
      strategyPublicId: strategyPublicId,
      clientId: clientId,
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      ops: typedOps,
    );
    return result.results.indexed
        .map(
          (entry) => OpAck.fromJson(
            _object(entry.$2.encode('results[${entry.$1}]')),
          ),
        )
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
    await _api.folders.create(
      publicId: publicId,
      name: name,
      parentFolderPublicId: _optional(parentFolderPublicId),
      iconId: _optionalNumber(iconId),
      iconCodePoint: _optionalNumber(iconCodePoint),
      iconFontFamily: _optional(iconFontFamily),
      iconFontPackage: _optional(iconFontPackage),
      color: _optional(color),
      customColorValue: _optionalNumber(customColorValue),
    );
  }

  Future<void> updateFolder({
    required String folderPublicId,
    String? name,
    int? iconId,
    int? iconCodePoint,
    String? iconFontFamily,
    String? iconFontPackage,
    bool clearIconFontFamily = false,
    bool clearIconFontPackage = false,
    String? color,
    int? customColorValue,
    bool clearCustomColorValue = false,
  }) async {
    await _api.folders.update(
      folderPublicId: folderPublicId,
      name: _optional(name),
      iconId: _optionalNumber(iconId),
      iconCodePoint: _optionalNumber(iconCodePoint),
      iconFontFamily: _optional(iconFontFamily),
      iconFontPackage: _optional(iconFontPackage),
      clearIconFontFamily: _presentWhenTrue(clearIconFontFamily),
      clearIconFontPackage: _presentWhenTrue(clearIconFontPackage),
      color: _optional(color),
      customColorValue: _optionalNumber(customColorValue),
      clearCustomColorValue: _presentWhenTrue(clearCustomColorValue),
    );
  }

  Future<void> deleteFolder(String folderPublicId) async {
    await _api.folders.delete(folderPublicId: folderPublicId);
  }

  Future<void> moveFolder({
    required String folderPublicId,
    String? parentFolderPublicId,
  }) async {
    await _api.folders.move(
      folderPublicId: folderPublicId,
      parentFolderPublicId: _optional(parentFolderPublicId),
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
    await _api.strategies.create(
      publicId: publicId,
      name: name,
      mapData: mapData,
      folderPublicId: _optional(folderPublicId),
      themeProfileId: _optional(themeProfileId),
      themeOverridePalette: _themePalette(themeOverridePalette),
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
    await _api.strategies.createWithInitialPage(
      publicId: publicId,
      name: name,
      mapData: mapData,
      initialPagePublicId: initialPagePublicId,
      initialPageName: initialPageName,
      initialPageIsAttack: initialPageIsAttack,
      folderPublicId: _optional(folderPublicId),
      themeProfileId: _optional(themeProfileId),
      themeOverridePalette: _themePalette(themeOverridePalette),
      initialPageSettings: _pageSettings(initialPageSettings),
    );
  }

  Future<void> updateStrategyName({
    required String strategyPublicId,
    required String name,
    required int expectedRevision,
  }) async {
    await _api.strategies.update(
      strategyPublicId: strategyPublicId,
      name: ConvexOptional.present(name),
      expectedRevision: expectedRevision.toDouble(),
    );
  }

  Future<void> deleteStrategy({
    required String strategyPublicId,
    required int expectedRevision,
  }) async {
    await _api.strategies.delete(
      strategyPublicId: strategyPublicId,
      expectedRevision: expectedRevision.toDouble(),
    );
  }

  Future<void> moveStrategy({
    required String strategyPublicId,
    required String? folderPublicId,
    required int expectedRevision,
  }) async {
    await _api.strategies.move(
      strategyPublicId: strategyPublicId,
      folderPublicId: _optional(folderPublicId),
      expectedRevision: expectedRevision.toDouble(),
    );
  }

  Future<void> addPage({
    required String strategyPublicId,
    required String pagePublicId,
    required String name,
    required int sortIndex,
    required bool isAttack,
    required int expectedRevision,
    Map<String, dynamic>? settings,
  }) async {
    await _api.pages.add(
      strategyPublicId: strategyPublicId,
      pagePublicId: pagePublicId,
      name: name,
      sortIndex: sortIndex.toDouble(),
      isAttack: isAttack,
      expectedRevision: expectedRevision.toDouble(),
      settings: _pageSettings(settings),
    );
  }

  Future<List<ShareLinkSummary>> listShareLinks({
    required String targetType,
    required String targetPublicId,
  }) async {
    final result = await _api.shares
        .list(
          targetType: _shareTargetType(targetType),
          targetPublicId: targetPublicId,
        )
        .fetch();
    return result
        .map(
          (share) => ShareLinkSummary(
            token: share.token,
            role: share.role.wireName,
            createdAt: _dateTime(share.createdAt),
            revokedAt:
                share.revokedAt == null ? null : _dateTime(share.revokedAt!),
          ),
        )
        .toList(growable: false);
  }

  Future<void> createShareLink({
    required String targetType,
    required String targetPublicId,
    required String token,
    required String role,
  }) async {
    await _api.shares.create(
      targetType: _shareTargetType(targetType),
      targetPublicId: targetPublicId,
      token: token,
      role: _shareRole(role),
    );
  }

  Future<void> revokeShareLink({
    required String targetType,
    required String targetPublicId,
    required String token,
  }) async {
    await _api.shares.revoke(
      targetType: _shareTargetType(targetType),
      targetPublicId: targetPublicId,
      token: token,
    );
  }

  Future<Map<String, dynamic>> redeemShareLink(String token) async {
    final result = await _api.shares.redeem(token: token);
    return _object(result.encode('shares.redeem.result'));
  }
}

bool isTypedConvexUnauthenticatedError(Object error) {
  return (error is ConvexFunctionException &&
          error.code == ConvexErrorCode.unauthenticated) ||
      (error is ConvexClientFunctionError &&
          error.rawCode == ConvexErrorCode.unauthenticated.wireName);
}

CloudFolderSummary _folderSummary(FoldersListTreeResultItem folder) {
  return CloudFolderSummary(
    publicId: folder.publicId,
    name: folder.name,
    createdAt: _dateTime(folder.createdAt),
    updatedAt: _dateTime(folder.updatedAt),
    role: folder.role.wireName,
    parentFolderPublicId: folder.parentFolderPublicId,
    iconId: folder.iconId?.toInt(),
    iconCodePoint: folder.iconCodePoint?.toInt(),
    iconFontFamily: folder.iconFontFamily,
    iconFontPackage: folder.iconFontPackage,
    color: folder.color,
    customColorValue: folder.customColorValue?.toInt(),
  );
}

CloudStrategySummary _strategySummary(
  StrategiesListForFolderResultItem strategy,
) {
  return CloudStrategySummary(
    publicId: strategy.publicId,
    name: strategy.name,
    mapData: strategy.mapData,
    revision: strategy.revision.toInt(),
    createdAt: _dateTime(strategy.createdAt),
    updatedAt: _dateTime(strategy.updatedAt),
    role: strategy.role.wireName,
    attackLabel: strategy.attackLabel.wireName,
  );
}

RemoteStrategyShell _strategyShell(StrategyGetShellResult result) {
  return RemoteStrategyShell(
    header: RemoteStrategyHeader.fromJson(
      _object(result.header.encode('header')),
    ),
    pages: result.pages.indexed
        .map(
          (entry) => RemotePage.fromJson(
            _object(entry.$2.encode('pages[${entry.$1}]')),
          ),
        )
        .toList(growable: false),
  );
}

RemotePageSnapshot _pageSnapshot(PageGetSnapshotResult result) {
  final assets = result.assets.indexed
      .map(
        (entry) => RemoteImageAsset.fromJson(
          _object(entry.$2.encode('assets[${entry.$1}]')),
        ),
      )
      .toList(growable: false);
  return RemotePageSnapshot(
    page: RemotePage.fromJson(_object(result.page.encode('page'))),
    content: RemotePageContent.fromJson(
      _object(result.content.encode('content')),
    ),
    elements: result.elements.indexed
        .map(
          (entry) => RemoteElement.fromJson(
            _object(entry.$2.encode('elements[${entry.$1}]')),
          ),
        )
        .toList(growable: false),
    lineups: result.lineups.indexed
        .map(
          (entry) => RemoteLineup.fromJson(
            _object(entry.$2.encode('lineups[${entry.$1}]')),
          ),
        )
        .toList(growable: false),
    assetsById: {for (final asset in assets) asset.publicId: asset},
  );
}

RemoteFullStrategySnapshot _fullSnapshot(StrategyGetFullSnapshotResult result) {
  final pages = result.pages.indexed.map((entry) {
    final json = _object(entry.$2.encode('pages[${entry.$1}]'));
    return RemoteFullPage(
      page: RemotePage.fromJson(json),
      content: RemotePageContent.fromJson({
        'settings': json['settings'],
        'revision': json['contentRevision'],
        'createdAt': json['contentCreatedAt'],
        'updatedAt': json['contentUpdatedAt'],
      }),
    );
  }).toList(growable: false);
  final elements = result.elements.indexed
      .map(
        (entry) => RemoteElement.fromJson(
          _object(entry.$2.encode('elements[${entry.$1}]')),
        ),
      )
      .toList(growable: false);
  final lineups = result.lineups.indexed
      .map(
        (entry) => RemoteLineup.fromJson(
          _object(entry.$2.encode('lineups[${entry.$1}]')),
        ),
      )
      .toList(growable: false);
  final assets = result.assets.indexed
      .map(
        (entry) => RemoteImageAsset.fromJson(
          _object(entry.$2.encode('assets[${entry.$1}]')),
        ),
      )
      .toList(growable: false);
  return RemoteFullStrategySnapshot(
    header: RemoteStrategyHeader.fromJson(
      _object(result.header.encode('header')),
    ),
    pages: pages,
    elementsByPage: RemoteFullStrategySnapshot.groupElementsByPage(elements),
    lineupsByPage: RemoteFullStrategySnapshot.groupLineupsByPage(lineups),
    assetsById: {for (final asset in assets) asset.publicId: asset},
  );
}

Map<String, dynamic> _object(ConvexObject value) {
  return Map<String, dynamic>.from(value.toDart());
}

DateTime _dateTime(double milliseconds) =>
    DateTime.fromMillisecondsSinceEpoch(milliseconds.toInt());

ConvexOptional<T> _optional<T>(T? value) => value == null
    ? const ConvexOptional.absent()
    : ConvexOptional.present(value);

ConvexOptional<double> _optionalNumber(num? value) => value == null
    ? const ConvexOptional.absent()
    : ConvexOptional.present(value.toDouble());

ConvexOptional<bool> _presentWhenTrue(bool value) =>
    value ? const ConvexOptional.present(true) : const ConvexOptional.absent();

ConvexOptional<OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette>
    _themePalette(Map<String, dynamic>? value) {
  if (value == null) return const ConvexOptional.absent();
  return ConvexOptional.present(
    OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette.decode(
      ConvexValue.fromDart(value),
      'themeOverridePalette',
    ),
  );
}

ConvexOptional<OpsApplyBatchArgsOpsItemPageAddPayloadSettings> _pageSettings(
  Map<String, dynamic>? value,
) {
  if (value == null) return const ConvexOptional.absent();
  return ConvexOptional.present(
    OpsApplyBatchArgsOpsItemPageAddPayloadSettings.decode(
      ConvexValue.fromDart(value),
      'settings',
    ),
  );
}

FoldersListTreeArgsScope _folderScope(String value) => switch (value) {
      'all' => FoldersListTreeArgsScope.all,
      'owned' => FoldersListTreeArgsScope.owned,
      'shared' => FoldersListTreeArgsScope.shared,
      _ =>
        throw ArgumentError.value(value, 'scope', 'Unsupported folder scope'),
    };

ImagesCompleteUploadArgsProvider _imageProvider(String value) =>
    switch (value) {
      'convex' => ImagesCompleteUploadArgsProvider.convex,
      'r2' => ImagesCompleteUploadArgsProvider.r2,
      _ => throw ArgumentError.value(
          value,
          'provider',
          'Unsupported image provider',
        ),
    };

SharesCreateArgsTargetType _shareTargetType(String value) => switch (value) {
      'folder' => SharesCreateArgsTargetType.folder,
      'strategy' => SharesCreateArgsTargetType.strategy,
      _ => throw ArgumentError.value(
          value,
          'targetType',
          'Unsupported share target type',
        ),
    };

InvitesCreateArgsRole _shareRole(String value) => switch (value) {
      'editor' => InvitesCreateArgsRole.editor,
      'viewer' => InvitesCreateArgsRole.viewer,
      _ => throw ArgumentError.value(value, 'role', 'Unsupported share role'),
    };
