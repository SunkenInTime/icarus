// GENERATED CODE - DO NOT MODIFY BY HAND.
// Generated from convex/function_spec.json by tool/icarus_convex_codegen.
// ignore_for_file: prefer_const_constructors, unused_element, unused_import

import 'dart:async';
import 'dart:typed_data';

import '../transport/convex_transport.dart';
import 'convex_error_codes.dart';
import 'convex_models.dart';

final class ConvexQuery<T> {
  const ConvexQuery({
    required ConvexTransport transport,
    required String name,
    required ConvexObject args,
    required T Function(ConvexValue) decode,
  }) : _transport = transport,
       _name = name,
       _args = args,
       _decode = decode;

  final ConvexTransport _transport;
  final String _name;
  final ConvexObject _args;
  final T Function(ConvexValue) _decode;

  Future<T> fetch() => _invoke(() => _transport.query(_name, _args), _decode);

  Stream<T> watch() {
    late final StreamController<T> controller;
    StreamSubscription<ConvexValue>? subscription;
    var active = false;

    controller = StreamController<T>(
      onListen: () {
        active = true;
        subscription = _transport
            .subscribe(_name, _args)
            .listen(
              (value) {
                if (!active) return;
                try {
                  controller.add(_decode(value));
                } catch (error, stackTrace) {
                  active = false;
                  controller.addError(error, stackTrace);
                  subscription?.cancel();
                  controller.close();
                }
              },
              onError: (Object error, StackTrace stackTrace) {
                if (!active) return;
                if (error is ConvexTransportError) {
                  controller.addError(
                    ConvexFunctionException.fromTransport(error),
                    stackTrace,
                  );
                  return;
                }
                active = false;
                controller.addError(error, stackTrace);
                subscription?.cancel();
                controller.close();
              },
              onDone: () {
                if (!active) return;
                active = false;
                controller.close();
              },
            );
      },
      onCancel: () {
        active = false;
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }
}

Future<T> _invoke<T>(
  Future<ConvexValue> Function() invoke,
  T Function(ConvexValue) decode,
) async {
  try {
    return decode(await invoke());
  } on ConvexTransportError catch (error) {
    throw ConvexFunctionException.fromTransport(error);
  }
}

abstract interface class IcarusConvexApi {
  factory IcarusConvexApi(ConvexTransport transport) = _IcarusConvexApi;
  ElementsModule get elements;
  FoldersModule get folders;
  HealthModule get health;
  ImagesModule get images;
  InvitesModule get invites;
  LineupsModule get lineups;
  OpsModule get ops;
  PageModule get page;
  PagesModule get pages;
  SharesModule get shares;
  StrategiesModule get strategies;
  StrategyModule get strategy;
  UsersModule get users;
}

final class _IcarusConvexApi implements IcarusConvexApi {
  _IcarusConvexApi(ConvexTransport transport)
    : elements = _ElementsModule(transport),
      folders = _FoldersModule(transport),
      health = _HealthModule(transport),
      images = _ImagesModule(transport),
      invites = _InvitesModule(transport),
      lineups = _LineupsModule(transport),
      ops = _OpsModule(transport),
      page = _PageModule(transport),
      pages = _PagesModule(transport),
      shares = _SharesModule(transport),
      strategies = _StrategiesModule(transport),
      strategy = _StrategyModule(transport),
      users = _UsersModule(transport);
  @override
  final ElementsModule elements;
  @override
  final FoldersModule folders;
  @override
  final HealthModule health;
  @override
  final ImagesModule images;
  @override
  final InvitesModule invites;
  @override
  final LineupsModule lineups;
  @override
  final OpsModule ops;
  @override
  final PageModule page;
  @override
  final PagesModule pages;
  @override
  final SharesModule shares;
  @override
  final StrategiesModule strategies;
  @override
  final StrategyModule strategy;
  @override
  final UsersModule users;
}

abstract interface class ElementsModule {
  ConvexQuery<List<ElementsListForPageResultItem>> listForPage({
    required String pagePublicId,
    required String strategyPublicId,
  });
  ConvexQuery<List<ElementsListForPageResultItem>> listForStrategy({
    required String strategyPublicId,
  });
}

final class _ElementsModule implements ElementsModule {
  const _ElementsModule(this._transport);
  final ConvexTransport _transport;
  @override
  ConvexQuery<List<ElementsListForPageResultItem>> listForPage({
    required String pagePublicId,
    required String strategyPublicId,
  }) {
    final args = encodeElementsListForPageArgs(
      pagePublicId: pagePublicId,
      strategyPublicId: strategyPublicId,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'elements:listForPage',
      args: args,
      decode: decodeElementsListForPageResult,
    );
  }

  @override
  ConvexQuery<List<ElementsListForPageResultItem>> listForStrategy({
    required String strategyPublicId,
  }) {
    final args = encodeElementsListForStrategyArgs(
      strategyPublicId: strategyPublicId,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'elements:listForStrategy',
      args: args,
      decode: decodeElementsListForStrategyResult,
    );
  }
}

abstract interface class FoldersModule {
  Future<ConvexValue> create({
    ConvexOptional<String> color = const ConvexOptional.absent(),
    ConvexOptional<double> customColorValue = const ConvexOptional.absent(),
    ConvexOptional<double> iconCodePoint = const ConvexOptional.absent(),
    ConvexOptional<String> iconFontFamily = const ConvexOptional.absent(),
    ConvexOptional<String> iconFontPackage = const ConvexOptional.absent(),
    ConvexOptional<double> iconId = const ConvexOptional.absent(),
    required String name,
    ConvexOptional<String> parentFolderPublicId = const ConvexOptional.absent(),
    required String publicId,
  });
  Future<FoldersDeleteResult> delete({required String folderPublicId});
  ConvexQuery<List<FoldersListTreeResultItem>> listTree({
    ConvexOptional<FoldersListTreeArgsScope> scope =
        const ConvexOptional.absent(),
  });
  Future<FoldersDeleteResult> move({
    required String folderPublicId,
    ConvexOptional<String> parentFolderPublicId = const ConvexOptional.absent(),
  });
  Future<FoldersDeleteResult> update({
    ConvexOptional<bool> clearCustomColorValue = const ConvexOptional.absent(),
    ConvexOptional<bool> clearIconFontFamily = const ConvexOptional.absent(),
    ConvexOptional<bool> clearIconFontPackage = const ConvexOptional.absent(),
    ConvexOptional<String> color = const ConvexOptional.absent(),
    ConvexOptional<double> customColorValue = const ConvexOptional.absent(),
    required String folderPublicId,
    ConvexOptional<double> iconCodePoint = const ConvexOptional.absent(),
    ConvexOptional<String> iconFontFamily = const ConvexOptional.absent(),
    ConvexOptional<String> iconFontPackage = const ConvexOptional.absent(),
    ConvexOptional<double> iconId = const ConvexOptional.absent(),
    ConvexOptional<String> name = const ConvexOptional.absent(),
  });
}

final class _FoldersModule implements FoldersModule {
  const _FoldersModule(this._transport);
  final ConvexTransport _transport;
  @override
  Future<ConvexValue> create({
    ConvexOptional<String> color = const ConvexOptional.absent(),
    ConvexOptional<double> customColorValue = const ConvexOptional.absent(),
    ConvexOptional<double> iconCodePoint = const ConvexOptional.absent(),
    ConvexOptional<String> iconFontFamily = const ConvexOptional.absent(),
    ConvexOptional<String> iconFontPackage = const ConvexOptional.absent(),
    ConvexOptional<double> iconId = const ConvexOptional.absent(),
    required String name,
    ConvexOptional<String> parentFolderPublicId = const ConvexOptional.absent(),
    required String publicId,
  }) {
    final args = encodeFoldersCreateArgs(
      color: color,
      customColorValue: customColorValue,
      iconCodePoint: iconCodePoint,
      iconFontFamily: iconFontFamily,
      iconFontPackage: iconFontPackage,
      iconId: iconId,
      name: name,
      parentFolderPublicId: parentFolderPublicId,
      publicId: publicId,
    );
    return _invoke(
      () => _transport.mutation('folders:create', args),
      decodeFoldersCreateResult,
    );
  }

  @override
  Future<FoldersDeleteResult> delete({required String folderPublicId}) {
    final args = encodeFoldersDeleteArgs(folderPublicId: folderPublicId);
    return _invoke(
      () => _transport.mutation('folders:delete', args),
      decodeFoldersDeleteResult,
    );
  }

  @override
  ConvexQuery<List<FoldersListTreeResultItem>> listTree({
    ConvexOptional<FoldersListTreeArgsScope> scope =
        const ConvexOptional.absent(),
  }) {
    final args = encodeFoldersListTreeArgs(scope: scope);
    return ConvexQuery(
      transport: _transport,
      name: 'folders:listTree',
      args: args,
      decode: decodeFoldersListTreeResult,
    );
  }

  @override
  Future<FoldersDeleteResult> move({
    required String folderPublicId,
    ConvexOptional<String> parentFolderPublicId = const ConvexOptional.absent(),
  }) {
    final args = encodeFoldersMoveArgs(
      folderPublicId: folderPublicId,
      parentFolderPublicId: parentFolderPublicId,
    );
    return _invoke(
      () => _transport.mutation('folders:move', args),
      decodeFoldersMoveResult,
    );
  }

  @override
  Future<FoldersDeleteResult> update({
    ConvexOptional<bool> clearCustomColorValue = const ConvexOptional.absent(),
    ConvexOptional<bool> clearIconFontFamily = const ConvexOptional.absent(),
    ConvexOptional<bool> clearIconFontPackage = const ConvexOptional.absent(),
    ConvexOptional<String> color = const ConvexOptional.absent(),
    ConvexOptional<double> customColorValue = const ConvexOptional.absent(),
    required String folderPublicId,
    ConvexOptional<double> iconCodePoint = const ConvexOptional.absent(),
    ConvexOptional<String> iconFontFamily = const ConvexOptional.absent(),
    ConvexOptional<String> iconFontPackage = const ConvexOptional.absent(),
    ConvexOptional<double> iconId = const ConvexOptional.absent(),
    ConvexOptional<String> name = const ConvexOptional.absent(),
  }) {
    final args = encodeFoldersUpdateArgs(
      clearCustomColorValue: clearCustomColorValue,
      clearIconFontFamily: clearIconFontFamily,
      clearIconFontPackage: clearIconFontPackage,
      color: color,
      customColorValue: customColorValue,
      folderPublicId: folderPublicId,
      iconCodePoint: iconCodePoint,
      iconFontFamily: iconFontFamily,
      iconFontPackage: iconFontPackage,
      iconId: iconId,
      name: name,
    );
    return _invoke(
      () => _transport.mutation('folders:update', args),
      decodeFoldersUpdateResult,
    );
  }
}

abstract interface class HealthModule {
  ConvexQuery<HealthPingResult> ping();
}

final class _HealthModule implements HealthModule {
  const _HealthModule(this._transport);
  final ConvexTransport _transport;
  @override
  ConvexQuery<HealthPingResult> ping() {
    final args = encodeHealthPingArgs();
    return ConvexQuery(
      transport: _transport,
      name: 'health:ping',
      args: args,
      decode: decodeHealthPingResult,
    );
  }
}

abstract interface class ImagesModule {
  Future<ImagesCompleteUploadResult> completeUpload({
    required String assetPublicId,
    ConvexOptional<double> byteSize = const ConvexOptional.absent(),
    ConvexOptional<String> etag = const ConvexOptional.absent(),
    ConvexOptional<String> fileExtension = const ConvexOptional.absent(),
    ConvexOptional<double> height = const ConvexOptional.absent(),
    ConvexOptional<String> mimeType = const ConvexOptional.absent(),
    ConvexOptional<String> objectKey = const ConvexOptional.absent(),
    ConvexOptional<ImagesCompleteUploadArgsProvider> provider =
        const ConvexOptional.absent(),
    ConvexOptional<String> storageId = const ConvexOptional.absent(),
    required String strategyPublicId,
    ConvexOptional<String> uploadId = const ConvexOptional.absent(),
    ConvexOptional<double> width = const ConvexOptional.absent(),
  });
  Future<FoldersDeleteResult> deleteAssetRef({
    required String assetPublicId,
    required String strategyPublicId,
  });
  Future<ImagesGenerateUploadUrlResult> generateUploadUrl({
    required String assetPublicId,
    ConvexOptional<double> byteSize = const ConvexOptional.absent(),
    required String fileExtension,
    ConvexOptional<double> height = const ConvexOptional.absent(),
    required String mimeType,
    required String strategyPublicId,
    ConvexOptional<double> width = const ConvexOptional.absent(),
  });
  ConvexQuery<ImagesGetAssetUrlResult> getAssetUrl({
    required String assetPublicId,
    required String strategyPublicId,
  });
  ConvexQuery<List<ImagesListForStrategyResultItem>> listForStrategy({
    required String strategyPublicId,
  });
}

final class _ImagesModule implements ImagesModule {
  const _ImagesModule(this._transport);
  final ConvexTransport _transport;
  @override
  Future<ImagesCompleteUploadResult> completeUpload({
    required String assetPublicId,
    ConvexOptional<double> byteSize = const ConvexOptional.absent(),
    ConvexOptional<String> etag = const ConvexOptional.absent(),
    ConvexOptional<String> fileExtension = const ConvexOptional.absent(),
    ConvexOptional<double> height = const ConvexOptional.absent(),
    ConvexOptional<String> mimeType = const ConvexOptional.absent(),
    ConvexOptional<String> objectKey = const ConvexOptional.absent(),
    ConvexOptional<ImagesCompleteUploadArgsProvider> provider =
        const ConvexOptional.absent(),
    ConvexOptional<String> storageId = const ConvexOptional.absent(),
    required String strategyPublicId,
    ConvexOptional<String> uploadId = const ConvexOptional.absent(),
    ConvexOptional<double> width = const ConvexOptional.absent(),
  }) {
    final args = encodeImagesCompleteUploadArgs(
      assetPublicId: assetPublicId,
      byteSize: byteSize,
      etag: etag,
      fileExtension: fileExtension,
      height: height,
      mimeType: mimeType,
      objectKey: objectKey,
      provider: provider,
      storageId: storageId,
      strategyPublicId: strategyPublicId,
      uploadId: uploadId,
      width: width,
    );
    return _invoke(
      () => _transport.action('images:completeUpload', args),
      decodeImagesCompleteUploadResult,
    );
  }

  @override
  Future<FoldersDeleteResult> deleteAssetRef({
    required String assetPublicId,
    required String strategyPublicId,
  }) {
    final args = encodeImagesDeleteAssetRefArgs(
      assetPublicId: assetPublicId,
      strategyPublicId: strategyPublicId,
    );
    return _invoke(
      () => _transport.action('images:deleteAssetRef', args),
      decodeImagesDeleteAssetRefResult,
    );
  }

  @override
  Future<ImagesGenerateUploadUrlResult> generateUploadUrl({
    required String assetPublicId,
    ConvexOptional<double> byteSize = const ConvexOptional.absent(),
    required String fileExtension,
    ConvexOptional<double> height = const ConvexOptional.absent(),
    required String mimeType,
    required String strategyPublicId,
    ConvexOptional<double> width = const ConvexOptional.absent(),
  }) {
    final args = encodeImagesGenerateUploadUrlArgs(
      assetPublicId: assetPublicId,
      byteSize: byteSize,
      fileExtension: fileExtension,
      height: height,
      mimeType: mimeType,
      strategyPublicId: strategyPublicId,
      width: width,
    );
    return _invoke(
      () => _transport.action('images:generateUploadUrl', args),
      decodeImagesGenerateUploadUrlResult,
    );
  }

  @override
  ConvexQuery<ImagesGetAssetUrlResult> getAssetUrl({
    required String assetPublicId,
    required String strategyPublicId,
  }) {
    final args = encodeImagesGetAssetUrlArgs(
      assetPublicId: assetPublicId,
      strategyPublicId: strategyPublicId,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'images:getAssetUrl',
      args: args,
      decode: decodeImagesGetAssetUrlResult,
    );
  }

  @override
  ConvexQuery<List<ImagesListForStrategyResultItem>> listForStrategy({
    required String strategyPublicId,
  }) {
    final args = encodeImagesListForStrategyArgs(
      strategyPublicId: strategyPublicId,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'images:listForStrategy',
      args: args,
      decode: decodeImagesListForStrategyResult,
    );
  }
}

abstract interface class InvitesModule {
  Future<FoldersDeleteResult> create({
    ConvexOptional<double> expiresAt = const ConvexOptional.absent(),
    required InvitesCreateArgsRole role,
    required String strategyPublicId,
    required String token,
  });
  ConvexQuery<ConvexValue> getValue({
    ConvexOptional<String> strategyPublicId = const ConvexOptional.absent(),
    ConvexOptional<String> token = const ConvexOptional.absent(),
  });
  Future<InvitesRedeemResult> redeem({required String token});
  Future<FoldersDeleteResult> revoke({
    required String strategyPublicId,
    required String token,
  });
}

final class _InvitesModule implements InvitesModule {
  const _InvitesModule(this._transport);
  final ConvexTransport _transport;
  @override
  Future<FoldersDeleteResult> create({
    ConvexOptional<double> expiresAt = const ConvexOptional.absent(),
    required InvitesCreateArgsRole role,
    required String strategyPublicId,
    required String token,
  }) {
    final args = encodeInvitesCreateArgs(
      expiresAt: expiresAt,
      role: role,
      strategyPublicId: strategyPublicId,
      token: token,
    );
    return _invoke(
      () => _transport.mutation('invites:create', args),
      decodeInvitesCreateResult,
    );
  }

  @override
  ConvexQuery<ConvexValue> getValue({
    ConvexOptional<String> strategyPublicId = const ConvexOptional.absent(),
    ConvexOptional<String> token = const ConvexOptional.absent(),
  }) {
    final args = encodeInvitesGetArgs(
      strategyPublicId: strategyPublicId,
      token: token,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'invites:get',
      args: args,
      decode: decodeInvitesGetResult,
    );
  }

  @override
  Future<InvitesRedeemResult> redeem({required String token}) {
    final args = encodeInvitesRedeemArgs(token: token);
    return _invoke(
      () => _transport.mutation('invites:redeem', args),
      decodeInvitesRedeemResult,
    );
  }

  @override
  Future<FoldersDeleteResult> revoke({
    required String strategyPublicId,
    required String token,
  }) {
    final args = encodeInvitesRevokeArgs(
      strategyPublicId: strategyPublicId,
      token: token,
    );
    return _invoke(
      () => _transport.mutation('invites:revoke', args),
      decodeInvitesRevokeResult,
    );
  }
}

abstract interface class LineupsModule {
  ConvexQuery<List<LineupsListForPageResultItem>> listForPage({
    required String pagePublicId,
    required String strategyPublicId,
  });
  ConvexQuery<List<LineupsListForPageResultItem>> listForStrategy({
    required String strategyPublicId,
  });
}

final class _LineupsModule implements LineupsModule {
  const _LineupsModule(this._transport);
  final ConvexTransport _transport;
  @override
  ConvexQuery<List<LineupsListForPageResultItem>> listForPage({
    required String pagePublicId,
    required String strategyPublicId,
  }) {
    final args = encodeLineupsListForPageArgs(
      pagePublicId: pagePublicId,
      strategyPublicId: strategyPublicId,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'lineups:listForPage',
      args: args,
      decode: decodeLineupsListForPageResult,
    );
  }

  @override
  ConvexQuery<List<LineupsListForPageResultItem>> listForStrategy({
    required String strategyPublicId,
  }) {
    final args = encodeLineupsListForStrategyArgs(
      strategyPublicId: strategyPublicId,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'lineups:listForStrategy',
      args: args,
      decode: decodeLineupsListForStrategyResult,
    );
  }
}

abstract interface class OpsModule {
  Future<OpsApplyBatchResult> applyBatch({
    required String clientId,
    required double clientProtocolVersion,
    required List<OpsApplyBatchArgsOpsItem> ops,
    required String strategyPublicId,
  });
}

final class _OpsModule implements OpsModule {
  const _OpsModule(this._transport);
  final ConvexTransport _transport;
  @override
  Future<OpsApplyBatchResult> applyBatch({
    required String clientId,
    required double clientProtocolVersion,
    required List<OpsApplyBatchArgsOpsItem> ops,
    required String strategyPublicId,
  }) {
    final args = encodeOpsApplyBatchArgs(
      clientId: clientId,
      clientProtocolVersion: clientProtocolVersion,
      ops: ops,
      strategyPublicId: strategyPublicId,
    );
    return _invoke(
      () => _transport.mutation('ops:applyBatch', args),
      decodeOpsApplyBatchResult,
    );
  }
}

abstract interface class PageModule {
  ConvexQuery<PageGetSnapshotResult> getSnapshot({
    required String pagePublicId,
    required String strategyPublicId,
  });
}

final class _PageModule implements PageModule {
  const _PageModule(this._transport);
  final ConvexTransport _transport;
  @override
  ConvexQuery<PageGetSnapshotResult> getSnapshot({
    required String pagePublicId,
    required String strategyPublicId,
  }) {
    final args = encodePageGetSnapshotArgs(
      pagePublicId: pagePublicId,
      strategyPublicId: strategyPublicId,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'page:getSnapshot',
      args: args,
      decode: decodePageGetSnapshotResult,
    );
  }
}

abstract interface class PagesModule {
  Future<ConvexValue> add({
    required double expectedRevision,
    required bool isAttack,
    required String name,
    required String pagePublicId,
    ConvexOptional<OpsApplyBatchArgsOpsItemPageAddPayloadSettings> settings =
        const ConvexOptional.absent(),
    required double sortIndex,
    required String strategyPublicId,
  });
  Future<ConvexValue> delete({
    required double expectedRevision,
    required String pagePublicId,
    required String strategyPublicId,
  });
  ConvexQuery<List<PageGetSnapshotResultPage>> listForStrategy({
    required String strategyPublicId,
  });
  Future<ConvexValue> rename({
    required double expectedRevision,
    required String name,
    required String pagePublicId,
    required String strategyPublicId,
  });
  Future<ConvexValue> reorder({
    required double expectedRevision,
    required List<String> orderedPagePublicIds,
    required String strategyPublicId,
  });
}

final class _PagesModule implements PagesModule {
  const _PagesModule(this._transport);
  final ConvexTransport _transport;
  @override
  Future<ConvexValue> add({
    required double expectedRevision,
    required bool isAttack,
    required String name,
    required String pagePublicId,
    ConvexOptional<OpsApplyBatchArgsOpsItemPageAddPayloadSettings> settings =
        const ConvexOptional.absent(),
    required double sortIndex,
    required String strategyPublicId,
  }) {
    final args = encodePagesAddArgs(
      expectedRevision: expectedRevision,
      isAttack: isAttack,
      name: name,
      pagePublicId: pagePublicId,
      settings: settings,
      sortIndex: sortIndex,
      strategyPublicId: strategyPublicId,
    );
    return _invoke(
      () => _transport.mutation('pages:add', args),
      decodePagesAddResult,
    );
  }

  @override
  Future<ConvexValue> delete({
    required double expectedRevision,
    required String pagePublicId,
    required String strategyPublicId,
  }) {
    final args = encodePagesDeleteArgs(
      expectedRevision: expectedRevision,
      pagePublicId: pagePublicId,
      strategyPublicId: strategyPublicId,
    );
    return _invoke(
      () => _transport.mutation('pages:delete', args),
      decodePagesDeleteResult,
    );
  }

  @override
  ConvexQuery<List<PageGetSnapshotResultPage>> listForStrategy({
    required String strategyPublicId,
  }) {
    final args = encodePagesListForStrategyArgs(
      strategyPublicId: strategyPublicId,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'pages:listForStrategy',
      args: args,
      decode: decodePagesListForStrategyResult,
    );
  }

  @override
  Future<ConvexValue> rename({
    required double expectedRevision,
    required String name,
    required String pagePublicId,
    required String strategyPublicId,
  }) {
    final args = encodePagesRenameArgs(
      expectedRevision: expectedRevision,
      name: name,
      pagePublicId: pagePublicId,
      strategyPublicId: strategyPublicId,
    );
    return _invoke(
      () => _transport.mutation('pages:rename', args),
      decodePagesRenameResult,
    );
  }

  @override
  Future<ConvexValue> reorder({
    required double expectedRevision,
    required List<String> orderedPagePublicIds,
    required String strategyPublicId,
  }) {
    final args = encodePagesReorderArgs(
      expectedRevision: expectedRevision,
      orderedPagePublicIds: orderedPagePublicIds,
      strategyPublicId: strategyPublicId,
    );
    return _invoke(
      () => _transport.mutation('pages:reorder', args),
      decodePagesReorderResult,
    );
  }
}

abstract interface class SharesModule {
  Future<FoldersDeleteResult> create({
    required InvitesCreateArgsRole role,
    required String targetPublicId,
    required SharesCreateArgsTargetType targetType,
    required String token,
  });
  ConvexQuery<List<SharesListResultItem>> list({
    required String targetPublicId,
    required SharesCreateArgsTargetType targetType,
  });
  Future<SharesRedeemResult> redeem({required String token});
  Future<FoldersDeleteResult> revoke({
    required String targetPublicId,
    required SharesCreateArgsTargetType targetType,
    required String token,
  });
}

final class _SharesModule implements SharesModule {
  const _SharesModule(this._transport);
  final ConvexTransport _transport;
  @override
  Future<FoldersDeleteResult> create({
    required InvitesCreateArgsRole role,
    required String targetPublicId,
    required SharesCreateArgsTargetType targetType,
    required String token,
  }) {
    final args = encodeSharesCreateArgs(
      role: role,
      targetPublicId: targetPublicId,
      targetType: targetType,
      token: token,
    );
    return _invoke(
      () => _transport.mutation('shares:create', args),
      decodeSharesCreateResult,
    );
  }

  @override
  ConvexQuery<List<SharesListResultItem>> list({
    required String targetPublicId,
    required SharesCreateArgsTargetType targetType,
  }) {
    final args = encodeSharesListArgs(
      targetPublicId: targetPublicId,
      targetType: targetType,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'shares:list',
      args: args,
      decode: decodeSharesListResult,
    );
  }

  @override
  Future<SharesRedeemResult> redeem({required String token}) {
    final args = encodeSharesRedeemArgs(token: token);
    return _invoke(
      () => _transport.mutation('shares:redeem', args),
      decodeSharesRedeemResult,
    );
  }

  @override
  Future<FoldersDeleteResult> revoke({
    required String targetPublicId,
    required SharesCreateArgsTargetType targetType,
    required String token,
  }) {
    final args = encodeSharesRevokeArgs(
      targetPublicId: targetPublicId,
      targetType: targetType,
      token: token,
    );
    return _invoke(
      () => _transport.mutation('shares:revoke', args),
      decodeSharesRevokeResult,
    );
  }
}

abstract interface class StrategiesModule {
  Future<ConvexValue> create({
    ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
    required String mapData,
    required String name,
    required String publicId,
    ConvexOptional<
          OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette
        >
        themeOverridePalette =
        const ConvexOptional.absent(),
    ConvexOptional<String> themeProfileId = const ConvexOptional.absent(),
  });
  Future<ConvexValue> createWithInitialPage({
    ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
    required bool initialPageIsAttack,
    required String initialPageName,
    required String initialPagePublicId,
    ConvexOptional<OpsApplyBatchArgsOpsItemPageAddPayloadSettings>
        initialPageSettings =
        const ConvexOptional.absent(),
    required String mapData,
    required String name,
    required String publicId,
    ConvexOptional<
          OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette
        >
        themeOverridePalette =
        const ConvexOptional.absent(),
    ConvexOptional<String> themeProfileId = const ConvexOptional.absent(),
  });
  Future<FoldersDeleteResult> delete({
    required double expectedRevision,
    required String strategyPublicId,
  });
  ConvexQuery<StrategiesGetHeaderResult> getHeader({
    required String strategyPublicId,
  });
  ConvexQuery<List<StrategiesListForFolderResultItem>> listForFolder({
    ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
    ConvexOptional<FoldersListTreeArgsScope> scope =
        const ConvexOptional.absent(),
  });
  ConvexQuery<List<StrategiesListForFolderResultItem>> listSharedWithMe();
  Future<ConvexValue> move({
    required double expectedRevision,
    ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
    required String strategyPublicId,
  });
  Future<ConvexValue> update({
    ConvexOptional<bool> clearThemeOverridePalette =
        const ConvexOptional.absent(),
    ConvexOptional<bool> clearThemeProfileId = const ConvexOptional.absent(),
    required double expectedRevision,
    ConvexOptional<String> mapData = const ConvexOptional.absent(),
    ConvexOptional<String> name = const ConvexOptional.absent(),
    required String strategyPublicId,
    ConvexOptional<
          OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette
        >
        themeOverridePalette =
        const ConvexOptional.absent(),
    ConvexOptional<String> themeProfileId = const ConvexOptional.absent(),
  });
}

final class _StrategiesModule implements StrategiesModule {
  const _StrategiesModule(this._transport);
  final ConvexTransport _transport;
  @override
  Future<ConvexValue> create({
    ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
    required String mapData,
    required String name,
    required String publicId,
    ConvexOptional<
          OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette
        >
        themeOverridePalette =
        const ConvexOptional.absent(),
    ConvexOptional<String> themeProfileId = const ConvexOptional.absent(),
  }) {
    final args = encodeStrategiesCreateArgs(
      folderPublicId: folderPublicId,
      mapData: mapData,
      name: name,
      publicId: publicId,
      themeOverridePalette: themeOverridePalette,
      themeProfileId: themeProfileId,
    );
    return _invoke(
      () => _transport.mutation('strategies:create', args),
      decodeStrategiesCreateResult,
    );
  }

  @override
  Future<ConvexValue> createWithInitialPage({
    ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
    required bool initialPageIsAttack,
    required String initialPageName,
    required String initialPagePublicId,
    ConvexOptional<OpsApplyBatchArgsOpsItemPageAddPayloadSettings>
        initialPageSettings =
        const ConvexOptional.absent(),
    required String mapData,
    required String name,
    required String publicId,
    ConvexOptional<
          OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette
        >
        themeOverridePalette =
        const ConvexOptional.absent(),
    ConvexOptional<String> themeProfileId = const ConvexOptional.absent(),
  }) {
    final args = encodeStrategiesCreateWithInitialPageArgs(
      folderPublicId: folderPublicId,
      initialPageIsAttack: initialPageIsAttack,
      initialPageName: initialPageName,
      initialPagePublicId: initialPagePublicId,
      initialPageSettings: initialPageSettings,
      mapData: mapData,
      name: name,
      publicId: publicId,
      themeOverridePalette: themeOverridePalette,
      themeProfileId: themeProfileId,
    );
    return _invoke(
      () => _transport.mutation('strategies:createWithInitialPage', args),
      decodeStrategiesCreateWithInitialPageResult,
    );
  }

  @override
  Future<FoldersDeleteResult> delete({
    required double expectedRevision,
    required String strategyPublicId,
  }) {
    final args = encodeStrategiesDeleteArgs(
      expectedRevision: expectedRevision,
      strategyPublicId: strategyPublicId,
    );
    return _invoke(
      () => _transport.mutation('strategies:delete', args),
      decodeStrategiesDeleteResult,
    );
  }

  @override
  ConvexQuery<StrategiesGetHeaderResult> getHeader({
    required String strategyPublicId,
  }) {
    final args = encodeStrategiesGetHeaderArgs(
      strategyPublicId: strategyPublicId,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'strategies:getHeader',
      args: args,
      decode: decodeStrategiesGetHeaderResult,
    );
  }

  @override
  ConvexQuery<List<StrategiesListForFolderResultItem>> listForFolder({
    ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
    ConvexOptional<FoldersListTreeArgsScope> scope =
        const ConvexOptional.absent(),
  }) {
    final args = encodeStrategiesListForFolderArgs(
      folderPublicId: folderPublicId,
      scope: scope,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'strategies:listForFolder',
      args: args,
      decode: decodeStrategiesListForFolderResult,
    );
  }

  @override
  ConvexQuery<List<StrategiesListForFolderResultItem>> listSharedWithMe() {
    final args = encodeStrategiesListSharedWithMeArgs();
    return ConvexQuery(
      transport: _transport,
      name: 'strategies:listSharedWithMe',
      args: args,
      decode: decodeStrategiesListSharedWithMeResult,
    );
  }

  @override
  Future<ConvexValue> move({
    required double expectedRevision,
    ConvexOptional<String> folderPublicId = const ConvexOptional.absent(),
    required String strategyPublicId,
  }) {
    final args = encodeStrategiesMoveArgs(
      expectedRevision: expectedRevision,
      folderPublicId: folderPublicId,
      strategyPublicId: strategyPublicId,
    );
    return _invoke(
      () => _transport.mutation('strategies:move', args),
      decodeStrategiesMoveResult,
    );
  }

  @override
  Future<ConvexValue> update({
    ConvexOptional<bool> clearThemeOverridePalette =
        const ConvexOptional.absent(),
    ConvexOptional<bool> clearThemeProfileId = const ConvexOptional.absent(),
    required double expectedRevision,
    ConvexOptional<String> mapData = const ConvexOptional.absent(),
    ConvexOptional<String> name = const ConvexOptional.absent(),
    required String strategyPublicId,
    ConvexOptional<
          OpsApplyBatchArgsOpsItemStrategyPatchPayloadThemeOverridePalette
        >
        themeOverridePalette =
        const ConvexOptional.absent(),
    ConvexOptional<String> themeProfileId = const ConvexOptional.absent(),
  }) {
    final args = encodeStrategiesUpdateArgs(
      clearThemeOverridePalette: clearThemeOverridePalette,
      clearThemeProfileId: clearThemeProfileId,
      expectedRevision: expectedRevision,
      mapData: mapData,
      name: name,
      strategyPublicId: strategyPublicId,
      themeOverridePalette: themeOverridePalette,
      themeProfileId: themeProfileId,
    );
    return _invoke(
      () => _transport.mutation('strategies:update', args),
      decodeStrategiesUpdateResult,
    );
  }
}

abstract interface class StrategyModule {
  ConvexQuery<StrategyGetFullSnapshotResult> getFullSnapshot({
    required String strategyPublicId,
  });
  ConvexQuery<StrategyGetShellResult> getShell({
    required String strategyPublicId,
  });
}

final class _StrategyModule implements StrategyModule {
  const _StrategyModule(this._transport);
  final ConvexTransport _transport;
  @override
  ConvexQuery<StrategyGetFullSnapshotResult> getFullSnapshot({
    required String strategyPublicId,
  }) {
    final args = encodeStrategyGetFullSnapshotArgs(
      strategyPublicId: strategyPublicId,
    );
    return ConvexQuery(
      transport: _transport,
      name: 'strategy:getFullSnapshot',
      args: args,
      decode: decodeStrategyGetFullSnapshotResult,
    );
  }

  @override
  ConvexQuery<StrategyGetShellResult> getShell({
    required String strategyPublicId,
  }) {
    final args = encodeStrategyGetShellArgs(strategyPublicId: strategyPublicId);
    return ConvexQuery(
      transport: _transport,
      name: 'strategy:getShell',
      args: args,
      decode: decodeStrategyGetShellResult,
    );
  }
}

abstract interface class UsersModule {
  Future<FoldersDeleteResult> ensureCurrentUser();
  ConvexQuery<UsersMeResult?> me();
}

final class _UsersModule implements UsersModule {
  const _UsersModule(this._transport);
  final ConvexTransport _transport;
  @override
  Future<FoldersDeleteResult> ensureCurrentUser() {
    final args = encodeUsersEnsureCurrentUserArgs();
    return _invoke(
      () => _transport.mutation('users:ensureCurrentUser', args),
      decodeUsersEnsureCurrentUserResult,
    );
  }

  @override
  ConvexQuery<UsersMeResult?> me() {
    final args = encodeUsersMeArgs();
    return ConvexQuery(
      transport: _transport,
      name: 'users:me',
      args: args,
      decode: decodeUsersMeResult,
    );
  }
}
