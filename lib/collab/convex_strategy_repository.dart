import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

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
    await _api.users.ensureCurrentUser(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
    );
  }

  Stream<List<CloudFolderEntry>> watchAllFolders() {
    return _api.folders
        .listTree(
          scope: const ConvexOptional.present(FoldersListTreeArgsScope.all),
        )
        .watch()
        .map(
          (folders) => folders.map(_folderEntry).toList(growable: false),
        );
  }

  Stream<List<CloudStrategyEntry>> watchStrategiesForFolder(
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
              strategies.map(_strategyEntry).toList(growable: false),
        );
  }

  Stream<List<CloudStrategyEntry>> watchSharedStrategies() {
    return _api.strategies.listSharedWithMe().watch().map(
          (strategies) =>
              strategies.map(_strategyEntry).toList(growable: false),
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
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
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
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
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
    for (final op in ops) {
      if (cloudOperationExceedsPolicy(op)) {
        throw StateError(cloudOperationTooLargeMessage);
      }
    }
    if (serializedCloudBatchUtf8Bytes(
          strategyPublicId: strategyPublicId,
          clientId: clientId,
          ops: ops,
        ) >
        maxCloudBatchBytes) {
      throw StateError('Cloud operation batch exceeds the payload policy.');
    }

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
    return result.results.map(_opAck).toList(growable: false);
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
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
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
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
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
    await _api.folders.delete(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      folderPublicId: folderPublicId,
    );
  }

  Future<void> moveFolder({
    required String folderPublicId,
    String? parentFolderPublicId,
  }) async {
    await _api.folders.move(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
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
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
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
    bool? initialPageIsAutoNamed,
    required bool initialPageIsAttack,
    String? folderPublicId,
    String? themeProfileId,
    Map<String, dynamic>? themeOverridePalette,
    Map<String, dynamic>? initialPageSettings,
  }) async {
    await _api.strategies.createWithInitialPage(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      publicId: publicId,
      name: name,
      mapData: mapData,
      initialPagePublicId: initialPagePublicId,
      initialPageName: initialPageName,
      initialPageIsAutoNamed: _optional(initialPageIsAutoNamed),
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
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
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
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
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
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      strategyPublicId: strategyPublicId,
      folderPublicId: _optional(folderPublicId),
      expectedRevision: expectedRevision.toDouble(),
    );
  }

  Future<void> addPage({
    required String strategyPublicId,
    required String pagePublicId,
    required String name,
    bool? isAutoNamed,
    required int sortIndex,
    required bool isAttack,
    required int expectedRevision,
    Map<String, dynamic>? settings,
  }) async {
    await _api.pages.add(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      strategyPublicId: strategyPublicId,
      pagePublicId: pagePublicId,
      name: name,
      isAutoNamed: _optional(isAutoNamed),
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
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
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
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      targetType: _shareTargetType(targetType),
      targetPublicId: targetPublicId,
      token: token,
    );
  }

  Future<ShareRedemption> redeemShareLink(String token) async {
    final result = await _api.shares.redeem(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      token: token,
    );
    return switch (result) {
      SharesRedeemResultFolder(:final folderPublicId, :final role) =>
        ShareRedemption(
          targetType: 'folder',
          folderPublicId: folderPublicId,
          role: role.wireName,
        ),
      SharesRedeemResultStrategy(
        :final folderPublicId,
        :final strategyPublicId,
        :final role,
      ) =>
        ShareRedemption(
          targetType: 'strategy',
          folderPublicId: folderPublicId,
          strategyPublicId: strategyPublicId,
          role: role.wireName,
        ),
    };
  }
}

bool isTypedConvexUnauthenticatedError(Object error) {
  return (error is ConvexFunctionException &&
          error.code == ConvexErrorCode.unauthenticated) ||
      (error is ConvexClientFunctionError &&
          error.rawCode == ConvexErrorCode.unauthenticated.wireName);
}

bool isMissingImageUploadIntentError(Object error) =>
    error is ConvexFunctionException &&
    error.code == ConvexErrorCode.uploadIntentNotFound;

CloudFolderEntry _folderEntry(FoldersListTreeResultItem folder) {
  return (
    folder: Folder(
      id: folder.publicId,
      name: folder.name,
      dateCreated: _dateTime(folder.createdAt),
      parentID: folder.parentFolderPublicId,
      iconId: folderIconIdFromCloud(
        iconId: folder.iconId?.toInt(),
        codePoint: folder.iconCodePoint?.toInt(),
        fontFamily: folder.iconFontFamily,
        fontPackage: folder.iconFontPackage,
      ),
      color: folderColorFromWireName(folder.color),
      customColor: folderCustomColorFromCloud(folder.customColorValue?.toInt()),
    ),
    role: folder.role.wireName,
  );
}

CloudStrategyEntry _strategyEntry(
  StrategiesListForFolderResultItem strategy,
) {
  return (
    strategy: StrategyData(
      id: strategy.publicId,
      name: strategy.name,
      mapData: _mapValue(strategy.mapData),
      versionNumber: Settings.versionNumber,
      lastEdited: _dateTime(strategy.updatedAt),
      createdAt: _dateTime(strategy.createdAt),
      folderID: strategy.folderPublicId,
      themeProfileId: strategy.themeProfileId,
      themeOverridePalette: _mapThemePalette(strategy.themeOverridePalette),
    ),
    revision: strategy.revision.toInt(),
    role: strategy.role.wireName,
    attackLabel: strategy.attackLabel.wireName,
  );
}

MapValue _mapValue(String wireName) {
  for (final entry in Maps.mapNames.entries) {
    if (entry.value == wireName) return entry.key;
  }
  throw ConvexDecodingException(
    'strategies.listForFolder.result.mapData',
    'unknown Icarus map $wireName',
  );
}

MapThemePalette? _mapThemePalette(
  OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette? palette,
) {
  final value = _themePaletteValue(palette);
  return value == null ? null : MapThemePalette.fromJson(value);
}

RemoteStrategyShell _strategyShell(StrategyGetShellResult result) {
  return RemoteStrategyShell(
    header: _strategyHeader(result.header),
    pages: result.pages.map(_page).toList(growable: false),
  );
}

RemotePageSnapshot _pageSnapshot(PageGetSnapshotResult result) {
  final assets = result.assets.map(_imageAsset).toList(growable: false);
  return RemotePageSnapshot(
    page: _page(result.page),
    content: _pageContent(result.content),
    elements: result.elements.map(_element).toList(growable: false),
    lineups: result.lineups.map(_lineup).toList(growable: false),
    assetsById: {for (final asset in assets) asset.publicId: asset},
  );
}

RemoteFullStrategySnapshot _fullSnapshot(StrategyGetFullSnapshotResult result) {
  final pages = result.pages.map((page) {
    return RemoteFullPage(
      page: RemotePage(
        publicId: page.publicId,
        strategyPublicId: page.strategyPublicId,
        name: page.name,
        isAutoNamed: _optionalValue(page.isAutoNamed),
        sortIndex: page.sortIndex.toInt(),
        isAttack: page.isAttack,
        revision: page.revision.toInt(),
        createdAt: _dateTime(page.createdAt),
        updatedAt: _dateTime(page.updatedAt),
      ),
      content: RemotePageContent(
        settings: _settingsValue(page.settings),
        revision: page.contentRevision.toInt(),
        createdAt: _dateTime(page.contentCreatedAt),
        updatedAt: _dateTime(page.contentUpdatedAt),
      ),
    );
  }).toList(growable: false);
  final elements = result.elements.map(_element).toList(growable: false);
  final lineups = result.lineups.map(_lineup).toList(growable: false);
  final assets = result.assets.map(_imageAsset).toList(growable: false);
  return RemoteFullStrategySnapshot(
    header: _strategyHeader(result.header),
    pages: pages,
    elementsByPage: RemoteFullStrategySnapshot.groupElementsByPage(elements),
    lineupsByPage: RemoteFullStrategySnapshot.groupLineupsByPage(lineups),
    assetsById: {for (final asset in assets) asset.publicId: asset},
  );
}

RemoteStrategyHeader _strategyHeader(StrategiesGetHeaderResult header) {
  return RemoteStrategyHeader(
    publicId: header.publicId,
    name: header.name,
    mapData: header.mapData,
    revision: header.revision.toInt(),
    createdAt: _dateTime(header.createdAt),
    updatedAt: _dateTime(header.updatedAt),
    themeProfileId: header.themeProfileId,
    themeOverridePalette: _themePaletteValue(header.themeOverridePalette),
    role: header.role.wireName,
  );
}

RemotePage _page(PageGetSnapshotResultPage page) {
  return RemotePage(
    publicId: page.publicId,
    strategyPublicId: page.strategyPublicId,
    name: page.name,
    isAutoNamed: _optionalValue(page.isAutoNamed),
    sortIndex: page.sortIndex.toInt(),
    isAttack: page.isAttack,
    revision: page.revision.toInt(),
    createdAt: _dateTime(page.createdAt),
    updatedAt: _dateTime(page.updatedAt),
  );
}

RemotePageContent _pageContent(PageGetSnapshotResultContent content) {
  return RemotePageContent(
    settings: _settingsValue(content.settings),
    revision: content.revision.toInt(),
    createdAt: _dateTime(content.createdAt),
    updatedAt: _dateTime(content.updatedAt),
  );
}

RemoteElement _element(ElementsListForPageResultItem element) {
  return RemoteElement(
    publicId: element.publicId,
    strategyPublicId: element.strategyPublicId,
    pagePublicId: element.pagePublicId,
    elementType: element.elementType.wireName,
    payload: element.payload,
    sortIndex: element.sortIndex.toInt(),
    revision: element.revision.toInt(),
    deleted: element.deleted,
  );
}

RemoteLineup _lineup(LineupsListForPageResultItem lineup) {
  return RemoteLineup(
    publicId: lineup.publicId,
    strategyPublicId: lineup.strategyPublicId,
    pagePublicId: lineup.pagePublicId,
    payload: lineup.payload,
    sortIndex: lineup.sortIndex.toInt(),
    revision: lineup.revision.toInt(),
    deleted: lineup.deleted,
  );
}

RemoteImageAsset _imageAsset(ImagesListForStrategyResultItem asset) {
  return RemoteImageAsset(
    publicId: asset.publicId,
    provider: asset.provider.wireName,
    uploadStatus: asset.uploadStatus.wireName,
    fileExtension: asset.fileExtension,
    mimeType: asset.mimeType,
    width: asset.width?.toInt(),
    height: asset.height?.toInt(),
    byteSize: asset.byteSize?.toInt(),
    uploadedAt: asset.uploadedAt == null ? null : _dateTime(asset.uploadedAt!),
    url: asset.url,
    legacyStoragePath: asset.legacyStoragePath,
  );
}

OpAck _opAck(OpsApplyBatchResultResultsItem result) {
  return switch (result) {
    OpsApplyBatchResultResultsItemApplied(
      :final opId,
      :final appliedRevision
    ) =>
      AppliedOpAck(opId: opId, revision: appliedRevision.toInt()),
    OpsApplyBatchResultResultsItemNoop(:final opId, :final currentRevision) =>
      NoopOpAck(
        opId: opId,
        currentRevision:
            currentRevision.isPresent ? currentRevision.value.toInt() : null,
      ),
    OpsApplyBatchResultResultsItemRejected(
      :final opId,
      :final reason,
      :final current,
    ) =>
      RejectedOpAck(
        opId: opId,
        rejectionReason: OpRejectionReason.fromWireName(reason.wireName),
        current: current.isPresent ? _currentSnapshot(current.value) : null,
      ),
    OpsApplyBatchResultResultsItemFailed(
      :final opId,
      :final code,
      :final rawCode,
      :final message,
    ) =>
      FailedOpAck(
        opId: opId,
        code: code,
        rawCode: rawCode,
        message: message,
      ),
  };
}

CurrentOpSnapshot _currentSnapshot(
  OpsApplyBatchResultResultsItemRejectedCurrent current,
) {
  return switch (current) {
    OpsApplyBatchResultResultsItemRejectedCurrentStrategy(
      :final revision,
      :final value,
    ) =>
      StrategyCurrentSnapshot(
        revision: revision.toInt(),
        value: {
          'name': value.name,
          'mapData': value.mapData,
          'themeProfileId': value.themeProfileId,
          'themeOverridePalette': _themePaletteValue(
            value.themeOverridePalette,
          ),
        },
      ),
    OpsApplyBatchResultResultsItemRejectedCurrentPage(
      :final revision,
      :final value,
    ) =>
      PageCurrentSnapshot(
        revision: revision.toInt(),
        value: {
          'name': value.name,
          if (value.isAutoNamed.isPresent)
            'isAutoNamed': value.isAutoNamed.value,
          'sortIndex': value.sortIndex,
          'isAttack': value.isAttack,
        },
      ),
    OpsApplyBatchResultResultsItemRejectedCurrentPageContent(
      :final revision,
      :final value,
    ) =>
      PageContentCurrentSnapshot(
        revision: revision.toInt(),
        value: {'settings': _settingsValue(value.settings)},
      ),
    OpsApplyBatchResultResultsItemRejectedCurrentElement(
      :final revision,
      :final value,
    ) =>
      ElementCurrentSnapshot(revision: revision.toInt(), value: value),
    OpsApplyBatchResultResultsItemRejectedCurrentLineup(
      :final revision,
      :final value,
    ) =>
      LineupCurrentSnapshot(revision: revision.toInt(), value: value),
  };
}

CloudPayload? _themePaletteValue(
  OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette? palette,
) {
  return palette == null ? null : _object(palette.encode('theme'));
}

CloudPayload? _settingsValue(
  OpsApplyBatchArgsOpsItemPageAddPayloadSettings? settings,
) {
  return settings == null ? null : _object(settings.encode('settings'));
}

Map<String, dynamic> _object(ConvexObject value) {
  return Map<String, dynamic>.from(value.toDart());
}

DateTime _dateTime(double milliseconds) =>
    DateTime.fromMillisecondsSinceEpoch(milliseconds.toInt());

ConvexOptional<T> _optional<T>(T? value) => value == null
    ? const ConvexOptional.absent()
    : ConvexOptional.present(value);

T? _optionalValue<T>(ConvexOptional<T> value) =>
    value.isPresent ? value.value : null;

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
