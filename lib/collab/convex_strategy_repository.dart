import 'dart:async';
import 'dart:math' show min;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/page_slices.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/collab/transport/convex_transport_adapter.dart';
import 'package:icarus/const/agents.dart';
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

  /// Permission to join [strategyPublicId]'s presence room, or null when this
  /// deployment has no presence service.
  Future<RoomPass?> issueRoomPass(String strategyPublicId) async {
    final result = await _api.presence.issueRoomPass(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      strategyPublicId: strategyPublicId,
    );
    if (result == null) return null;
    return RoomPass(
      url: Uri.parse(result.url),
      pass: result.pass,
      expiresAt: _dateTime(result.expiresAt),
    );
  }

  /// Whether the server accepts this build's cloud protocol: false while it
  /// refuses it. Throws when it cannot tell, offline or from a deployment
  /// that predates the question.
  Future<bool> serverAcceptsCloudProtocol() async {
    try {
      await _api.health
          .ping(
            clientProtocolVersion: ConvexOptional.present(
              currentCloudProtocolVersion.toDouble(),
            ),
          )
          .fetch();
      return true;
    } catch (error) {
      if (isClientUpgradeRequiredError(error)) return false;
      rethrow;
    }
  }

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
          includeAgentTypes: const ConvexOptional.present(true),
        )
        .watch()
        .map(_listedStrategyEntries);
  }

  /// The folders [scope] reaches, read once.
  Future<List<CloudFolderEntry>> fetchFolders({String scope = 'owned'}) async {
    final folders = await _api.folders
        .listTree(scope: ConvexOptional.present(_folderScope(scope)))
        .fetch();
    return folders.map(_folderEntry).toList(growable: false);
  }

  /// Where every folder and strategy of the caller's own library sits, read
  /// by the server in one transaction. Null is the top level.
  Future<CloudLibraryInventory> fetchInventory() async {
    final inventory = await _api.strategies.listInventory().fetch();
    return (
      folders: {
        for (final folder in inventory.folders)
          folder.publicId: folder.parentFolderPublicId,
      },
      strategies: {
        for (final strategy in inventory.strategies)
          strategy.publicId: strategy.folderPublicId,
      },
    );
  }

  /// The strategies in one folder (null is the top level), read once.
  Future<List<CloudStrategyEntry>> fetchStrategiesForFolder(
    String? folderPublicId, {
    String scope = 'owned',
  }) async {
    final strategies = await _api.strategies
        .listForFolder(
          folderPublicId: _optional(folderPublicId),
          scope: ConvexOptional.present(_folderScope(scope)),
          includeAgentTypes: const ConvexOptional.present(true),
        )
        .fetch();
    return strategies.map(_strategyEntry).toList(growable: false);
  }

  /// The strategies shared with the signed-in user directly, read once.
  Future<List<CloudStrategyEntry>> fetchSharedStrategies() async {
    final strategies = await _api.strategies
        .listSharedWithMe(includeAgentTypes: const ConvexOptional.present(true))
        .fetch();
    return strategies.map(_strategyEntry).toList(growable: false);
  }

  Stream<List<CloudStrategyEntry>> watchSharedStrategies() {
    return _api.strategies
        .listSharedWithMe(includeAgentTypes: const ConvexOptional.present(true))
        .watch()
        .map(_listedStrategyEntries);
  }

  /// [shareToken] is a share link the reader holds but has not redeemed
  /// (see [resolveSharedStrategy]); with it, a signed-out reader can view.
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    return _strategyShell(
      await _api.strategy
          .getShell(
            clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
            strategyPublicId: strategyPublicId,
            shareToken: _optional(shareToken),
          )
          .fetch(),
    );
  }

  /// Whether the server no longer has [strategyPublicId]: its shell query
  /// fails with NOT_FOUND, which getShell raises only for a missing strategy
  /// (deletion removes the row). Any other failure (offline, auth) is
  /// rethrown, so "could not tell" is never read as "deleted".
  Future<bool> strategyIsDeleted(String strategyPublicId) async {
    try {
      await fetchShell(strategyPublicId);
      return false;
    } catch (error) {
      if (isTypedConvexNotFoundError(error)) return true;
      rethrow;
    }
  }

  Stream<RemoteStrategyShell> watchShell(
    String strategyPublicId, {
    String? shareToken,
  }) {
    return _api.strategy
        .getShell(
          clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
          strategyPublicId: strategyPublicId,
          shareToken: _optional(shareToken),
        )
        .watch()
        .map(_strategyShell);
  }

  /// The pages watched in slices right now (see [watchPageSnapshot]), by
  /// [_pageKey]: the page the watch last handed on from its slices, or none
  /// while they fail, and how many watch it.
  final _slicedPages = <String, (RemotePageSnapshot?, int)>{};

  String _pageKey(
          String strategyPublicId, String pagePublicId, String? token) =>
      '$strategyPublicId|$pagePublicId|${token ?? ''}';

  /// [pagePublicId], read once. A page watched in slices answers with the
  /// page its watch last handed on, as the web client answers a read of any
  /// query it watches from the live answer: the read costs nothing, where
  /// reading it through every slice would cost a call each. It is that very
  /// answer, so a reader that noted the connection it came on (see
  /// RemoteEditorSnapshotNotifier.answeredOnCurrentConnection) still knows
  /// when it came from before a reconnect.
  Future<RemotePageSnapshot> fetchPageSnapshot({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) async {
    final (live, _) =
        _slicedPages[_pageKey(strategyPublicId, pagePublicId, shareToken)] ??
            (null, 0);
    if (live != null) return live;
    return _pageSnapshot(
      await _wholePage(strategyPublicId, pagePublicId, shareToken).fetch(),
    );
  }

  ConvexQuery<PageGetSnapshotResult> _wholePage(
    String strategyPublicId,
    String pagePublicId,
    String? shareToken,
  ) =>
      _api.page.getSnapshot(
        clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
        strategyPublicId: strategyPublicId,
        pagePublicId: pagePublicId,
        shareToken: _optional(shareToken),
        // This client keeps an image's picture id (PlacedImage.assetId).
        acceptsPictureIds: const ConvexOptional.present(true),
      );

  /// The frame and the slices starting at [starts] (see page_slices.dart).
  (
    ConvexQuery<PageGetFrameResult>,
    List<ConvexQuery<PageGetElementSliceResult>>,
  ) _pageParts(
    String strategyPublicId,
    String pagePublicId,
    String? shareToken,
    List<String> starts,
  ) {
    final protocol = currentCloudProtocolVersion.toDouble();
    final token = _optional(shareToken);
    return (
      _api.page.getFrame(
        clientProtocolVersion: protocol,
        strategyPublicId: strategyPublicId,
        pagePublicId: pagePublicId,
        shareToken: token,
      ),
      [
        for (final (index, start) in starts.indexed)
          _api.page.getElementSlice(
            clientProtocolVersion: protocol,
            strategyPublicId: strategyPublicId,
            pagePublicId: pagePublicId,
            shareToken: token,
            fromPublicId: start,
            toPublicId: index + 1 < starts.length
                ? ConvexOptional.present(starts[index + 1])
                : const ConvexOptional.absent(),
          ),
      ],
    );
  }

  /// The whole page, live. Watched whole at first, as reading it once just
  /// before costs nothing more; once it changes while watched (someone is
  /// editing it), watched in slices instead (see page_slices.dart), so each
  /// further edit re-reads one slice rather than the whole page. A page too
  /// small for more than one slice stays whole.
  Stream<RemotePageSnapshot> watchPageSnapshot({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) {
    final key = _pageKey(strategyPublicId, pagePublicId, shareToken);
    late final StreamController<RemotePageSnapshot> controller;
    StreamSubscription<PageGetSnapshotResult>? whole;
    StreamSubscription<PageGetSnapshotResult>? sliced;
    var registered = false;
    String? firstVersion;

    void watchSlices(PageGetSnapshotResult page) {
      final starts = pageSliceStarts(page.elements.length);
      if (starts.length == 1) return;
      final (frame, slices) =
          _pageParts(strategyPublicId, pagePublicId, shareToken, starts);
      sliced = assembledPages(
        ConvexQuery.watchTogether([frame, ...slices]),
      ).listen(
        (assembled) {
          final page = _pageSnapshot(assembled);
          final (_, watchers) = _slicedPages[key] ?? (null, 0);
          // The slices answered: they carry the page from here on.
          if (whole case final stopping?) {
            whole = null;
            unawaited(stopping.cancel());
            _slicedPages[key] = (page, watchers + 1);
            registered = true;
          } else {
            _slicedPages[key] = (page, watchers);
          }
          controller.add(page);
        },
        onError: (Object error, StackTrace stackTrace) {
          // Until the slices answer again, a read goes to the server rather
          // than to a page they no longer stand behind.
          if (registered) {
            final (_, watchers) = _slicedPages[key]!;
            _slicedPages[key] = (null, watchers);
          }
          controller.addError(error, stackTrace);
        },
      );
    }

    controller = StreamController<RemotePageSnapshot>(
      onListen: () {
        whole = _wholePage(strategyPublicId, pagePublicId, shareToken)
            .watch()
            .listen(
          (page) {
            controller.add(_pageSnapshot(page));
            // The web client can hand over its cached answer and then the
            // same one from the server: only different rows are a change.
            final version = _pageVersion(page);
            firstVersion ??= version;
            if (version != firstVersion && sliced == null) watchSlices(page);
          },
          onError: controller.addError,
        );
      },
      onPause: () {
        whole?.pause();
        sliced?.pause();
      },
      onResume: () {
        whole?.resume();
        sliced?.resume();
      },
      onCancel: () async {
        if (registered) {
          final (page, watchers) = _slicedPages[key]!;
          if (watchers <= 1) {
            _slicedPages.remove(key);
          } else {
            _slicedPages[key] = (page, watchers - 1);
          }
        }
        await Future.wait([
          if (whole case final w?) w.cancel(),
          if (sliced case final s?) s.cancel(),
        ]);
      },
    );
    return controller.stream;
  }

  /// Which of [assetPublicIds] the strategy's content shows on the server,
  /// pages in its trash included, or null while the server cannot tell yet.
  /// Asked a batch at a time.
  Future<Set<String>?> fetchReferencedAssetIds(
    String strategyPublicId,
    Iterable<String> assetPublicIds,
  ) async {
    final asked = assetPublicIds.toSet().toList(growable: false);
    final referenced = <String>{};
    for (var start = 0; start < asked.length; start += _referencedIdsBatch) {
      final ids = await _api.images
          .listReferencedAssetIds(
            strategyPublicId: strategyPublicId,
            assetPublicIds: asked.sublist(
              start,
              min(start + _referencedIdsBatch, asked.length),
            ),
          )
          .fetch();
      if (ids == null) return null;
      referenced.addAll(ids);
    }
    return referenced;
  }

  /// The server's MAX_REFERENCED_ASSET_IDS_PER_QUERY.
  static const _referencedIdsBatch = 100;

  /// [shareToken]: see [fetchShell].
  Future<RemoteFullStrategySnapshot> fetchFullSnapshot(
    String strategyPublicId, {
    String? shareToken,
  }) async {
    return upgradeRemoteFullSnapshot(_fullSnapshot(
      await _api.strategy
          .getFullSnapshot(
            clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
            strategyPublicId: strategyPublicId,
            shareToken: _optional(shareToken),
            // This client checks image references apart, so it can take a
            // snapshot without the pages in the server's trash.
            acceptsTrashedPagesLeftOut: const ConvexOptional.present(true),
            acceptsPictureIds: const ConvexOptional.present(true),
          )
          .fetch(),
    ));
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
    String? shareToken,
  }) async {
    final result = await _api.images
        .getAssetUrl(
          strategyPublicId: strategyPublicId,
          assetPublicId: assetPublicId,
          shareToken: _optional(shareToken),
        )
        .fetch();
    return result.url;
  }

  /// Sends [ops] to [strategyPublicId]. With [accountSubject], the account
  /// the ops belong to (its auth user id, as the outbox keys it), the
  /// server refuses the whole batch with FORBIDDEN unless that account is
  /// the one signed in when the batch arrives, which may be later than when
  /// it was sent.
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
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
      accountSubject: _optional(accountSubject),
      // This client restores deleted pages, so it sends such a delete again.
      checkTrashedPageDeletes: const ConvexOptional.present(true),
      // This client keeps an image's picture id (PlacedImage.assetId).
      acceptsPictureIds: const ConvexOptional.present(true),
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
    bool unfinishedMove = false,
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
      // Library lists skip the strategy until [finishMove].
      unfinishedMove: unfinishedMove
          ? const ConvexOptional.present(true)
          : const ConvexOptional.absent(),
    );
  }

  /// Deletes [strategyPublicId] only if a move left it unfinished. Says
  /// whether it was deleted, had finished, or was already gone.
  Future<AbandonedMove> abandonMove(String strategyPublicId) async {
    final result = await _api.strategies.abandonMove(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      strategyPublicId: strategyPublicId,
    );
    return switch (result.outcome) {
      StrategiesAbandonMoveResultOutcome.deleted => AbandonedMove.deleted,
      StrategiesAbandonMoveResultOutcome.finished => AbandonedMove.finished,
      StrategiesAbandonMoveResultOutcome.missing => AbandonedMove.missing,
    };
  }

  /// Shows a strategy made with `unfinishedMove` in library lists, once
  /// every part of it has landed. Refused when it is no longer in
  /// [folderPublicId] (null: the top level), the folder the move put it in.
  Future<void> finishMove(
    String strategyPublicId, {
    required String? folderPublicId,
  }) async {
    await _api.strategies.finishMove(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      strategyPublicId: strategyPublicId,
      folderPublicId: _optional(folderPublicId),
    );
  }

  /// Copies [sourceStrategyPublicId] into the signed-in user's library as
  /// [publicId]: pages, content, and images, in one server transaction.
  /// Retrying with the same [publicId] reuses the copy already made.
  Future<void> duplicateStrategy({
    required String sourceStrategyPublicId,
    required String publicId,
    required String name,
    String? folderPublicId,
  }) async {
    await _api.strategies.duplicate(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      sourceStrategyPublicId: sourceStrategyPublicId,
      publicId: publicId,
      name: name,
      folderPublicId: _optional(folderPublicId),
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

  /// Brings a deleted page back from the server's trash. Throws NOT_FOUND
  /// (see [isTypedConvexNotFoundError]) once it can no longer be restored.
  Future<void> restorePage({
    required String strategyPublicId,
    required String pagePublicId,
  }) async {
    await _api.pages.restore(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      strategyPublicId: strategyPublicId,
      pagePublicId: pagePublicId,
    );
  }

  /// The strategy's deleted pages that can still be restored, most
  /// recently deleted first.
  Future<List<TrashedPage>> listTrashedPages(String strategyPublicId) async {
    final pages = await _api.pages
        .listTrashed(strategyPublicId: strategyPublicId)
        .fetch();
    return [
      for (final page in pages)
        TrashedPage(
          pageId: page.publicId,
          name: page.name,
          deletedAt: _dateTime(page.deletedAt),
          restorableUntil: _dateTime(page.restorableUntil),
          deletedByName: page.deletedByName,
          deletedByYou: page.deletedByYou,
        ),
    ];
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

  /// Disables a link. With [removeMembers], also removes everyone whose
  /// access came from it.
  Future<void> revokeShareLink({
    required String targetType,
    required String targetPublicId,
    required String token,
    bool removeMembers = false,
  }) async {
    await _api.shares.revoke(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      targetType: _shareTargetType(targetType),
      targetPublicId: targetPublicId,
      token: token,
      removeMembers: removeMembers
          ? const ConvexOptional.present(true)
          : const ConvexOptional.absent(),
    );
  }

  /// Everyone besides the owner who can open the target. Owner only.
  /// The people the target was shared with directly, a page at a time:
  /// pass the previous page's [ShareMemberPage.nextCursor] as [cursor].
  Future<ShareMemberPage> listShareMembers({
    required String targetType,
    required String targetPublicId,
    String? cursor,
  }) async {
    final result = await _api.shares
        .listMembers(
          targetType: _shareTargetType(targetType),
          targetPublicId: targetPublicId,
          cursor: cursor == null
              ? const ConvexOptional.absent()
              : ConvexOptional.present(cursor),
        )
        .fetch();
    return ShareMemberPage(
      members: result.members
          .map(
            (member) => ShareMember(
              memberId: member.memberId,
              displayName: member.displayName,
              avatarUrl: member.avatarUrl,
              role: member.role.wireName,
              joinedAt: _dateTime(member.joinedAt),
              shareLinkToken: member.shareLinkToken,
            ),
          )
          .toList(growable: false),
      nextCursor: result.nextCursor,
    );
  }

  /// The names of the shared folders the target sits in, nearest first:
  /// their people can open it too.
  Future<List<String>> listShareFolderAccess({
    required String targetType,
    required String targetPublicId,
  }) async {
    final result = await _api.shares
        .listFolderAccess(
          targetType: _shareTargetType(targetType),
          targetPublicId: targetPublicId,
        )
        .fetch();
    return result.map((folder) => folder.name).toList(growable: false);
  }

  /// Who each of the target's links let in, by token.
  Future<Map<String, ShareLinkJoins>> listShareLinkJoins({
    required String targetType,
    required String targetPublicId,
  }) async {
    final result = await _api.shares
        .listLinkJoins(
          targetType: _shareTargetType(targetType),
          targetPublicId: targetPublicId,
        )
        .fetch();
    return {
      for (final link in result)
        link.token: ShareLinkJoins(
          joined: link.joined.round(),
          more: link.more,
          names: link.names,
        ),
    };
  }

  Future<void> setShareMemberRole({
    required String targetType,
    required String targetPublicId,
    required String memberId,
    required String role,
  }) async {
    await _api.shares.setMemberRole(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      targetType: _shareTargetType(targetType),
      targetPublicId: targetPublicId,
      memberId: memberId,
      role: _shareRole(role),
    );
  }

  Future<void> removeShareMember({
    required String targetType,
    required String targetPublicId,
    required String memberId,
  }) async {
    await _api.shares.removeMember(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      targetType: _shareTargetType(targetType),
      targetPublicId: targetPublicId,
      memberId: memberId,
    );
  }

  /// Ends the signed-in user's own access to something shared with them.
  Future<void> leaveShared({
    required String targetType,
    required String targetPublicId,
  }) async {
    await _api.shares.leave(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      targetType: _shareTargetType(targetType),
      targetPublicId: targetPublicId,
    );
  }

  /// What [token] opens and the access the signed-in user already has.
  /// Joins nothing. Throws NOT_FOUND or SHARE_LINK_REVOKED like
  /// [resolveSharedStrategy].
  Future<SharePreview> previewShareLink(String token) async {
    return switch (await _api.shares.preview(token: token).fetch()) {
      SharesPreviewResultStrategy(
        :final publicId,
        :final name,
        :final linkRole,
        :final myRole,
      ) =>
        SharePreview(
          targetType: 'strategy',
          publicId: publicId,
          name: name,
          linkRole: linkRole.wireName,
          myRole: myRole?.wireName,
        ),
      SharesPreviewResultFolder(
        :final publicId,
        :final name,
        :final linkRole,
        :final myRole,
      ) =>
        SharePreview(
          targetType: 'folder',
          publicId: publicId,
          name: name,
          linkRole: linkRole.wireName,
          myRole: myRole?.wireName,
        ),
    };
  }

  /// The strategy [token] shares, or null when it shares a folder. Needs no
  /// account. Throws NOT_FOUND for a link that never existed and
  /// SHARE_LINK_REVOKED for one its owner disabled.
  Future<String?> resolveSharedStrategy(String token) async {
    return switch (await _api.shares.resolve(token: token).fetch()) {
      SharesResolveResultStrategy(:final strategyPublicId) => strategyPublicId,
      SharesResolveResultFolder() => null,
    };
  }

  Future<ShareRedemption> redeemShareLink(String token) async {
    final result = await _api.shares.redeem(
      clientProtocolVersion: currentCloudProtocolVersion.toDouble(),
      token: token,
    );
    return switch (result) {
      SharesRedeemResultFolder(
        :final folderPublicId,
        :final role,
        :final alreadyHadAccess,
      ) =>
        ShareRedemption(
          targetType: 'folder',
          folderPublicId: folderPublicId,
          role: role.wireName,
          alreadyHadAccess: _alreadyHadAccess(alreadyHadAccess, role.wireName),
        ),
      SharesRedeemResultStrategy(
        :final folderPublicId,
        :final strategyPublicId,
        :final role,
        :final alreadyHadAccess,
      ) =>
        ShareRedemption(
          targetType: 'strategy',
          folderPublicId: folderPublicId,
          strategyPublicId: strategyPublicId,
          role: role.wireName,
          alreadyHadAccess: _alreadyHadAccess(alreadyHadAccess, role.wireName),
        ),
    };
  }

  /// The server's answer, or, from a deployment that predates the field,
  /// the part it can still tell us: an owner always had access.
  static bool _alreadyHadAccess(ConvexOptional<bool> reported, String role) {
    return reported.isPresent ? reported.value : role == 'owner';
  }
}

/// What abandoning a move found: the unfinished strategy, now deleted; a
/// strategy whose move finished, kept; or nothing.
enum AbandonedMove { deleted, finished, missing }

/// Whether [error] is the server's answer from running a function that
/// threw, so its transaction wrote nothing; not a lost answer (a timeout,
/// the connection), after which the call may still land.
bool isConvexFunctionError(Object error) =>
    error is ConvexFunctionException || error is ConvexClientFunctionError;

/// Whether a read failed without any answer from the server: offline, a
/// timeout, a dropped connection. A refusal or an answer this build can't
/// decode is an answer.
bool isConvexReadUnanswered(Object error) =>
    !isConvexFunctionError(error) &&
    error is! FormatException &&
    error is! ConvexNormalizationError;

bool isTypedConvexUnauthenticatedError(Object error) {
  return (error is ConvexFunctionException &&
          error.code == ConvexErrorCode.unauthenticated) ||
      (error is ConvexClientFunctionError &&
          error.rawCode == ConvexErrorCode.unauthenticated.wireName);
}

bool isTypedConvexNotFoundError(Object error) {
  return (error is ConvexFunctionException &&
          error.code == ConvexErrorCode.notFound) ||
      (error is ConvexClientFunctionError &&
          error.rawCode == ConvexErrorCode.notFound.wireName);
}

bool isShareLinkRevokedError(Object error) {
  return (error is ConvexFunctionException &&
          error.code == ConvexErrorCode.shareLinkRevoked) ||
      (error is ConvexClientFunctionError &&
          error.rawCode == ConvexErrorCode.shareLinkRevoked.wireName);
}

bool isTypedConvexForbiddenError(Object error) {
  return (error is ConvexFunctionException &&
          error.code == ConvexErrorCode.forbidden) ||
      (error is ConvexClientFunctionError &&
          error.rawCode == ConvexErrorCode.forbidden.wireName);
}

/// The server refused a duplicate because the strategy holds more content
/// than one copy can move within Convex's per-transaction limits.
bool isStrategyTooLargeToDuplicateError(Object error) {
  return (error is ConvexFunctionException &&
          error.code == ConvexErrorCode.strategyTooLargeToDuplicate) ||
      (error is ConvexClientFunctionError &&
          error.rawCode ==
              ConvexErrorCode.strategyTooLargeToDuplicate.wireName);
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
    strategyCount: folder.strategyCount.toInt(),
    mapPeeks: [
      for (final wireName in folder.mapPeeks)
        if (_mapValueOrNull(wireName) case final map?) map,
    ],
    agentTypes: [
      for (final name in folder.agentTypes)
        if (_agentTypeOrNull(name) case final type?) type,
    ],
  );
}

/// Unknown wire names are skipped: a peek at a map or agent this build does
/// not know yet must not break the folder list.
MapValue? _mapValueOrNull(String wireName) {
  for (final entry in Maps.mapNames.entries) {
    if (entry.value == wireName) return entry.key;
  }
  return null;
}

AgentType? _agentTypeOrNull(String name) {
  for (final type in AgentType.values) {
    if (type.name == name) return type;
  }
  return null;
}

/// The library list leaves out a strategy on a map this build does not
/// know, a newer map or whatever a peer with edit access wrote, instead of
/// failing the whole list. This build could not open it anyway.
List<CloudStrategyEntry> _listedStrategyEntries(
  List<StrategiesListForFolderResultItem> strategies,
) {
  return [
    for (final strategy in strategies)
      if (_mapValueOrNull(strategy.mapData) != null) _strategyEntry(strategy),
  ];
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
    agentTypes: [
      if (strategy.agentTypes.isPresent)
        for (final name in strategy.agentTypes.value)
          if (_agentTypeOrNull(name) case final type?) type,
    ],
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

/// The shell in [answer], a strategy:getShell answer the copy on this
/// computer kept. Throws when it does not decode.
RemoteStrategyShell strategyShellFromCopy(ConvexValue answer) => _strategyShell(
      StrategyGetShellResult.decode(answer, 'copy.strategy:getShell'),
      fromCopy: true,
    );

/// The page in [answer], a page:getSnapshot answer the copy on this computer
/// kept, last matched with the server at [copiedAt]. Throws when any part
/// of it does not decode.
RemotePageSnapshot pageSnapshotFromCopy(
  ConvexValue answer, {
  DateTime? copiedAt,
}) =>
    _pageSnapshot(
      PageGetSnapshotResult.decode(answer, 'copy.page:getSnapshot'),
      fromCopy: true,
      copiedAt: copiedAt,
    );

RemoteStrategyShell _strategyShell(
  StrategyGetShellResult result, {
  bool fromCopy = false,
}) {
  return RemoteStrategyShell(
    header: _strategyHeader(result.header),
    pages: result.pages.map(_page).toList(growable: false),
    fromCopy: fromCopy,
    serverAnswer: fromCopy ? null : result.encode('shell'),
  );
}

RemotePageSnapshot _pageSnapshot(
  PageGetSnapshotResult result, {
  bool fromCopy = false,
  DateTime? copiedAt,
}) {
  final assets = result.assets.map(_imageAsset).toList(growable: false);
  return RemotePageSnapshot(
    page: _page(result.page),
    content: _pageContent(result.content),
    elements: result.elements.map(_element).toList(growable: false),
    lineups: result.lineups.map(_lineup).toList(growable: false),
    assetsById: {for (final asset in assets) asset.publicId: asset},
    fromCopy: fromCopy,
    copiedAt: copiedAt,
    serverAnswer: fromCopy ? null : result.encode('pageSnapshot'),
  );
}

/// What [page] holds, by row and revision: any write to it changes this.
String _pageVersion(PageGetSnapshotResult page) => [
      page.page.revision,
      page.content.revision,
      for (final element in page.elements)
        '${element.publicId}:${element.revision}:${element.deleted}',
      for (final lineup in page.lineups)
        '${lineup.publicId}:${lineup.revision}:${lineup.deleted}',
    ].join('|');

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
    serverAnswer: result.encode('fullSnapshot'),
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

RemotePage _page(PageGetFrameResultPage page) {
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

RemotePageContent _pageContent(PageGetFrameResultContent content) {
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
