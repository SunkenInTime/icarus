import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/strategy/strategy_cloud_migration.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/services/product_metrics.dart';
import 'package:icarus/services/image_file_name.dart';
import 'package:uuid/uuid.dart';

/// The local strategies and folders waiting to move to the cloud or moving
/// now. Until their move ends they can't be opened, changed or moved
/// elsewhere.
final movingToCloudProvider =
    NotifierProvider<MovingToCloud, Set<String>>(MovingToCloud.new);

class MovingToCloud extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void add(Set<String> localIds) => state = {...state, ...localIds};

  void remove(Set<String> localIds) => state = {...state}..removeAll(localIds);
}

/// Tells the user how a move went: [failed] when work stayed on this device.
typedef MoveToCloudMessage = void Function(String message, {bool failed});

final moveToCloudMessageProvider = Provider<MoveToCloudMessage>(
  (ref) => (message, {failed = false}) {
    Settings.showToast(
      message: message,
      backgroundColor: failed
          ? Settings.tacticalVioletTheme.destructive
          : Settings.tacticalVioletTheme.primary,
      autoCloseDuration: Duration(seconds: failed ? 6 : 3),
    );
  },
);

final moveToCloudProvider =
    NotifierProvider<MoveToCloudNotifier, void>(MoveToCloudNotifier.new);

enum _Outcome {
  /// In the cloud, and gone from this device.
  moved,

  /// Still on this device, as it was. Nothing of it is in the cloud.
  notMoved,

  /// Changed on this device while it moved, so it stays here as changed.
  changedMeanwhile,

  /// In the cloud, but its copy on this device could not be removed.
  movedLocalKept,

  /// In the cloud as it was read; it changed here meanwhile, so this
  /// device keeps the changed version too.
  movedChangedHere,
}

/// What one strategy's move writes to the cloud.
class _Plan {
  _Plan(this.pages, this.cloudPageIds, this.ops, this.ids);

  final List<StrategyPage> pages;
  final List<String> cloudPageIds;
  final List<StrategyOp> ops;
  final MovedItemIds ids;
}

/// Moves local strategies and folders into the signed-in user's cloud
/// library, one strategy at a time.
///
/// A strategy moves whole or not at all. Its cloud copy is made under new
/// ids (the server keeps one row per id, and copies of a local strategy
/// share theirs) and marked unfinished, which keeps it out of every library
/// list on every device: the strategy with its first page, its other pages,
/// its content, then its images through the upload queue. The copy is read
/// back and checked against what was sent; only then is it finished, and
/// only then does the local original go. When any part fails, or the
/// original changed meanwhile, the cloud copy is deleted, the original stays,
/// and the user is told.
///
/// A record of each move in progress is saved before the cloud copy is
/// made, so a copy left by a move the app never finished (it quit, or lost
/// the network) is deleted the next time this account is signed in.
class MoveToCloudNotifier extends Notifier<void> {
  static const _maxOpsPerBatch = 40;
  static const _imageAttemptsBeforeFailing = 3;
  static const _offlineGrace = Duration(seconds: 20);

  Future<void> _tail = Future<void>.value();

  @override
  void build() {
    ref.listen<bool>(
      authProvider.select((auth) => auth.isConvexUserReady),
      (previous, ready) {
        if (ready) unawaited(_cleanUpUnfinishedMoves());
      },
    );
    // Copies a past move left unfinished stay locked until cleanup removes
    // them: an edit made in one would go with it.
    final box = _movesBox;
    if (box != null && box.isNotEmpty) {
      scheduleMicrotask(() => _markMoving({...box.keys.cast<String>()}));
    }
    if (ref.read(authProvider).isConvexUserReady) {
      scheduleMicrotask(() => unawaited(_cleanUpUnfinishedMoves()));
    }
  }

  /// Moves the local strategy [localId] into the cloud folder
  /// [cloudFolderId] (the top level when null) of the signed-in account.
  Future<void> moveStrategy(String localId, {String? cloudFolderId}) {
    final strategy =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(localId);
    final accountId = ref.read(cloudMediaAccountIdProvider);
    if (strategy == null || accountId == null || _isMoving(localId)) {
      return Future.value();
    }
    final name = strategy.name;
    final leavesFolder = cloudFolderId == null && strategy.folderID != null;
    _markMoving({localId});
    return _enqueue(() async {
      try {
        if (!_canMoveFor(accountId, name)) return;
        final outcome = await _moveOne(
          localId,
          cloudFolderId: cloudFolderId,
          accountId: accountId,
        );
        ProductMetrics.instance.moveToCloud(
          kind: 'strategy',
          strategies: 1,
          outcome: switch (outcome) {
            _Outcome.moved ||
            _Outcome.movedLocalKept ||
            _Outcome.movedChangedHere =>
              'moved',
            _Outcome.notMoved => 'not_moved',
            _Outcome.changedMeanwhile => 'changed_meanwhile',
          },
        );
        switch (outcome) {
          case _Outcome.moved:
            _showMessage(
              leavesFolder
                  ? 'Moved "$name" to the cloud. It\'s in My Library.'
                  : 'Moved "$name" to the cloud.',
            );
          case _Outcome.notMoved:
            _showFailure(
              "Couldn't move \"$name\" to the cloud. "
              "It's still on this device.",
            );
          case _Outcome.changedMeanwhile:
            _showFailure(
              '"$name" changed while it was moving, so it stays on this '
              'device. Move it again to put the latest version in the cloud.',
            );
          case _Outcome.movedLocalKept:
            _showFailure(
              'Moved "$name" to the cloud, but its copy on this device '
              "couldn't be removed.",
            );
          case _Outcome.movedChangedHere:
            _showFailure(
              'Moved "$name" to the cloud. It changed while moving, so this '
              'device keeps the latest version too.',
            );
        }
      } finally {
        _unmarkMoving({localId});
      }
    });
  }

  /// Moves the local folder [localFolderId], with every folder and strategy
  /// in it, into the cloud folder [cloudParentId] (the top level when null).
  /// A strategy that cannot move stays on this device in its folder, and so
  /// do the folders holding it.
  Future<void> moveFolder(String localFolderId, {String? cloudParentId}) {
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
    final root = folders.get(localFolderId);
    final accountId = ref.read(cloudMediaAccountIdProvider);
    if (root == null || accountId == null) return Future.value();

    // The folder and everything below it, parents before children.
    final tree = <Folder>[root];
    for (var i = 0; i < tree.length; i++) {
      tree.addAll(folders.values.where((f) => f.parentID == tree[i].id));
    }
    final treeIds = {for (final folder in tree) folder.id};
    final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .where((s) => treeIds.contains(s.folderID))
        .toList()
      // Oldest edit first, so "Date updated" keeps their order in the cloud.
      ..sort((a, b) => a.lastEdited.compareTo(b.lastEdited));
    final localIds = {...treeIds, for (final s in strategies) s.id};
    // Part of it is already on its way; this move would copy that part twice.
    if (localIds.any(_isMoving)) return Future.value();
    _markMoving(localIds);

    return _enqueue(() async {
      try {
        if (!_canMoveFor(accountId, root.name)) return;
        final cloudFolderIds = await _createCloudFolders(
          tree,
          rootParentId: cloudParentId,
          accountId: accountId,
        );
        if (cloudFolderIds == null) {
          ProductMetrics.instance.moveToCloud(
            kind: 'folder',
            strategies: strategies.length,
            outcome: 'not_moved',
          );
          _showFailure(
            "Couldn't move \"${root.name}\" to the cloud. "
            "It's still on this device.",
          );
          return;
        }

        var failed = 0;
        final movedInto = <String>{};
        for (final strategy in strategies) {
          final outcome = await _moveOne(
            strategy.id,
            cloudFolderId: cloudFolderIds[strategy.folderID],
            accountId: accountId,
          );
          if (outcome == _Outcome.moved || outcome == _Outcome.movedLocalKept) {
            movedInto.add(strategy.folderID!);
          }
          if (outcome != _Outcome.moved) failed++;
          _unmarkMoving({strategy.id});
        }

        final foldersWent =
            await _settleFolders(tree, cloudFolderIds, movedInto);
        ProductMetrics.instance.moveToCloud(
          kind: 'folder',
          strategies: strategies.length,
          outcome: failed == 0
              ? 'moved'
              : failed == strategies.length
                  ? 'not_moved'
                  : 'partial',
        );

        if (failed == 0 && foldersWent) {
          _showMessage('Moved "${root.name}" to the cloud.');
        } else if (failed == 0) {
          _showFailure(
            'Moved the strategies in "${root.name}" to the cloud, but some '
            'of its folders stayed on this device.',
          );
        } else {
          final total = strategies.length;
          _showFailure(
            'Moved ${total - failed} of $total strategies in '
            '"${root.name}". The rest are still on this device.',
          );
        }
      } catch (error, stackTrace) {
        await _report('move_folder', error, stackTrace);
        ProductMetrics.instance.moveToCloud(
          kind: 'folder',
          strategies: strategies.length,
          outcome: 'failed',
        );
        _showFailure(
          "Couldn't finish moving \"${root.name}\". What didn't move is "
          'still on this device.',
        );
      } finally {
        _unmarkMoving(localIds);
      }
    });
  }

  /// Children before parents: a local folder goes once nothing is left in
  /// it. A cloud folder nothing moved into goes when its local folder stays,
  /// so the move can be tried again without leaving an empty twin behind.
  /// Returns whether every local folder went: one whose cloud twin someone
  /// deleted meanwhile stays here.
  Future<bool> _settleFolders(
    List<Folder> tree,
    Map<String, String> cloudFolderIds,
    Set<String> movedInto,
  ) async {
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
    final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final repository = ref.read(convexStrategyRepositoryProvider);
    final inCloud = {
      for (final entry in await repository.watchAllFolders().first)
        entry.folder.id,
    };
    var allWent = true;
    final cloudHolds = <String>{...movedInto};
    for (final folder in tree.reversed) {
      if (cloudHolds.contains(folder.id) && folder.parentID != null) {
        cloudHolds.add(folder.parentID!);
      }
      final emptyHere =
          !strategies.values.any((s) => s.folderID == folder.id) &&
              !folders.values.any((f) => f.parentID == folder.id);
      final cloudId = cloudFolderIds[folder.id]!;
      if (emptyHere && !inCloud.contains(cloudId)) {
        allWent = false;
      } else if (emptyHere) {
        await ref.read(pinnedItemsProvider.notifier).replacePin(
              folder.id,
              cloudId,
            );
        await folders.delete(folder.id);
      } else if (!cloudHolds.contains(folder.id)) {
        try {
          await repository.deleteFolder(cloudId);
        } catch (error, stackTrace) {
          await _report('delete_empty_folder', error, stackTrace);
        }
      }
    }
    ref.invalidate(cloudFolderTreeProvider);
    return allWent;
  }

  /// Completes once every move asked for so far has ended.
  @visibleForTesting
  Future<void> idle() async {
    // A cleanup asked for while building starts on the next turn.
    await Future<void>.delayed(Duration.zero);
    await _tail;
  }

  Future<void> _enqueue(Future<void> Function() move) {
    final next = _tail.then((_) => move());
    _tail = next.catchError((_) {});
    return next;
  }

  /// Whether a move asked for by [accountId] can start now. Says why not.
  bool _canMoveFor(String accountId, String name) {
    if (ref.read(cloudMediaAccountIdProvider) != accountId) {
      _showFailure(
        'You signed in to another account, so "$name" stays on this device.',
      );
      return false;
    }
    if (ref.read(authProvider).isConvexUserReady &&
        ref.read(convexConnectionSnapshotProvider)) {
      return true;
    }
    _showFailure(
      "Can't reach the cloud right now, so \"$name\" stays on this device. "
      'Try again when you are online.',
    );
    return false;
  }

  /// Makes a cloud folder for each of [tree] under new ids. Returns the
  /// cloud id of each local folder, or null when one could not be made; the
  /// ones already made are then deleted (they are still empty).
  Future<Map<String, String>?> _createCloudFolders(
    List<Folder> tree, {
    required String? rootParentId,
    required String accountId,
  }) async {
    final repository = ref.read(convexStrategyRepositoryProvider);
    final cloudIds = <String, String>{};
    try {
      for (final folder in tree) {
        _requireAccount(accountId);
        final cloudId = const Uuid().v4();
        final icon = FolderIconRegistry.resolve(folder.iconId).iconData;
        // Known before it is asked for: a create whose answer is lost may
        // still have made the folder, and the rollback deletes it.
        cloudIds[folder.id] = cloudId;
        await repository.createFolder(
          publicId: cloudId,
          name: folder.name,
          parentFolderPublicId: folder.id == tree.first.id
              ? rootParentId
              : cloudIds[folder.parentID],
          iconId: folder.iconId,
          iconCodePoint: icon?.codePoint,
          iconFontFamily: icon?.fontFamily,
          iconFontPackage: icon?.fontPackage,
          color: folder.color.name,
          customColorValue: folder.customColor?.toARGB32(),
        );
      }
      return cloudIds;
    } catch (error, stackTrace) {
      await _report('create_folder', error, stackTrace);
      for (final cloudId in cloudIds.values.toList().reversed) {
        try {
          await repository.deleteFolder(cloudId);
        } catch (error, stackTrace) {
          await _report('delete_unfinished_folder', error, stackTrace);
        }
      }
      ref.invalidate(cloudFolderTreeProvider);
      return null;
    }
  }

  Future<_Outcome> _moveOne(
    String localId, {
    required String? cloudFolderId,
    required String accountId,
  }) async {
    final String cloudId;
    final StrategyData stored;
    try {
      // The editor lets go of it first, saved: nothing it holds in memory
      // may change the original once the move has read it.
      final editor = ref.read(strategyProvider);
      if (editor.strategyId == localId &&
          editor.source == StrategySource.local) {
        final strategies = ref.read(strategyProvider.notifier);
        await strategies.forceSaveNow(localId);
        await strategies.clearCurrentStrategy();
      }
      final found =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(localId);
      if (found == null) return _Outcome.notMoved;
      stored = found;
      cloudId = const Uuid().v4();
      // Its cloud copy can't be opened either while it is being built.
      _markMoving({cloudId});
      await _saveUnfinishedMove(
        cloudId,
        accountId: accountId,
        localId: localId,
      );
    } catch (error, stackTrace) {
      await _report('start_move', error, stackTrace);
      return _Outcome.notMoved;
    }
    final name = stored.name;
    final folderId = stored.folderID;
    bool originalGone() => !Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .containsKey(localId);
    bool unchanged() {
      final current =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(localId);
      // A save puts a new object; a rename or folder move changes this one.
      return identical(current, stored) &&
          current!.name == name &&
          current.folderID == folderId;
    }

    try {
      final strategy = StrategyMigrator.migrateToCurrentVersion(stored);
      final plan = _plan(strategy);
      final uploads = await _copyImageFiles(
        localId: localId,
        cloudId: cloudId,
        pictures: plan.ids.pictures,
      );
      await _createCloudStrategy(
        strategy,
        plan,
        cloudId: cloudId,
        cloudFolderId: cloudFolderId,
        accountId: accountId,
      );
      _requireAccount(accountId);
      await ref
          .read(cloudMediaUploadQueueProvider.notifier)
          .enqueueMovedImages(strategyPublicId: cloudId, images: uploads);
      await _waitForImages(cloudId, accountId: accountId);
      await _verify(cloudId, plan, uploads);
      // A changed original stays as the newer version. One that is gone
      // leaves the cloud copy as the only one, which finishes.
      if (!unchanged() && !originalGone()) {
        await _abandon(cloudId);
        return _Outcome.changedMeanwhile;
      }
      _requireAccount(accountId);
      // Refused if its folder was deleted meanwhile; the original stays.
      await ref
          .read(convexStrategyRepositoryProvider)
          .finishMove(cloudId, folderPublicId: cloudFolderId);
    } catch (error, stackTrace) {
      await _report('move_strategy', error, stackTrace);
      // A finishMove whose answer was lost did finish the move.
      if (await _abandon(cloudId) != AbandonedMove.finished) {
        return _Outcome.notMoved;
      }
    }

    // The cloud copy is complete and listed. The record goes before the
    // original: were the app to stop between the two, the strategy would be
    // in both places, not neither.
    try {
      await _forgetUnfinishedMove(cloudId);
      _unmarkMoving({cloudId});
      // The original goes only as it was read, whatever wrote to it since,
      // and not while the editor holds it again (a load that began before
      // the move): the check and the removal run with nothing in between.
      if (originalGone()) return _Outcome.moved;
      if (!unchanged() || ref.read(strategyProvider).strategyId == localId) {
        return _Outcome.movedChangedHere;
      }
      final removal =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).delete(localId);
      await removal;
      await ref.read(pinnedItemsProvider.notifier).replacePin(localId, cloudId);
      try {
        final images = await PlacedImageProvider.getImageFolder(localId);
        await images.parent.delete(recursive: true);
      } on FileSystemException {
        // Only disk space; nothing shows these files any more.
      }
    } catch (error, stackTrace) {
      await _report('remove_moved_original', error, stackTrace);
      return _Outcome.movedLocalKept;
    } finally {
      ref.invalidate(cloudStrategiesProvider);
    }
    return _Outcome.moved;
  }

  _Plan _plan(StrategyData strategy) {
    final pages = [...strategy.pages]
      ..sortBySortIndex((page) => page.sortIndex);
    // A cloud strategy is made with its first page.
    if (pages.isEmpty) {
      pages.add(
        StrategyPage(
          id: const Uuid().v4(),
          name: 'Page 1',
          isAutoNamed: true,
          drawingData: const [],
          agentData: const [],
          abilityData: const [],
          textData: const [],
          imageData: const [],
          utilityData: const [],
          sortIndex: 0,
          isAttack: true,
          settings: StrategySettings(),
        ),
      );
    }
    final cloudPageIds = [for (final _ in pages) const Uuid().v4()];
    final ops = <StrategyOp>[];
    final ids = MovedItemIds();
    for (var i = 0; i < pages.length; i++) {
      appendMovedPageOps(ops, pages[i], cloudPageId: cloudPageIds[i], ids: ids);
    }
    return _Plan(pages, cloudPageIds, ops, ids);
  }

  /// Copies the pictures the moved content shows into the cloud strategy's
  /// image folder, under their cloud ids, where the upload queue reads them.
  /// A picture whose file is missing here shows as missing in the cloud
  /// too, as it does on this device.
  Future<List<({String assetPublicId, String fileExtension})>> _copyImageFiles({
    required String localId,
    required String cloudId,
    required Map<String, ({String cloudId, String fileExtension})> pictures,
  }) async {
    final copied = <({String assetPublicId, String fileExtension})>[];
    for (final MapEntry(key: localPicture, value: cloud) in pictures.entries) {
      if (imageFileName(localPicture, cloud.fileExtension) == null) continue;
      final source = await PlacedImageProvider.getImageFile(
        strategyID: localId,
        imageID: localPicture,
        fileExtension: cloud.fileExtension,
      );
      if (!await source.exists()) continue;
      final target = await PlacedImageProvider.getImageFile(
        strategyID: cloudId,
        imageID: cloud.cloudId,
        fileExtension: cloud.fileExtension,
      );
      await source.copy(target.path);
      copied.add(
        (assetPublicId: cloud.cloudId, fileExtension: cloud.fileExtension),
      );
    }
    return copied;
  }

  Future<void> _createCloudStrategy(
    StrategyData strategy,
    _Plan plan, {
    required String cloudId,
    required String? cloudFolderId,
    required String accountId,
  }) async {
    final repository = ref.read(convexStrategyRepositoryProvider);
    final first = plan.pages.first;
    final theme = _cloudTheme(strategy);
    _requireAccount(accountId);
    await repository.createStrategyWithInitialPage(
      publicId: cloudId,
      name: strategy.name,
      mapData: Maps.mapNames[strategy.mapData]!,
      initialPagePublicId: plan.cloudPageIds.first,
      initialPageName: first.name,
      initialPageIsAutoNamed: first.isAutoNamed,
      initialPageIsAttack: first.isAttack,
      initialPageSettings: first.settings.toJson(),
      folderPublicId: cloudFolderId,
      themeProfileId: theme.profileId,
      themeOverridePalette: theme.palette?.toJson(),
      unfinishedMove: true,
    );

    var revision = (await repository.fetchShell(cloudId)).header.revision;
    for (var i = 1; i < plan.pages.length; i++) {
      final page = plan.pages[i];
      _requireAccount(accountId);
      await repository.addPage(
        strategyPublicId: cloudId,
        pagePublicId: plan.cloudPageIds[i],
        name: page.name,
        isAutoNamed: page.isAutoNamed,
        sortIndex: i,
        isAttack: page.isAttack,
        settings: page.settings.toJson(),
        expectedRevision: revision,
      );
      revision++;
    }

    final clientId = const Uuid().v4();
    for (final batch in _batches(
      plan.ops,
      strategyPublicId: cloudId,
      clientId: clientId,
    )) {
      // Bound to the account that asked for the move: the server refuses
      // it under another sign-in.
      final acks = await repository.applyBatch(
        strategyPublicId: cloudId,
        clientId: clientId,
        ops: batch,
        accountSubject: accountId,
      );
      final refused = acks.where((ack) => !ack.isAck).toList();
      if (acks.length != batch.length || refused.isNotEmpty) {
        throw StateError(
          'The server did not accept every item: '
          '${refused.map((ack) => ack.reason ?? ack.status).toSet().join(', ')}',
        );
      }
    }
  }

  /// The map theme as the cloud keeps it. A built-in profile is on every
  /// device, so the strategy names it; a profile the user made lives only
  /// here, so its colors go with the strategy, as .ica export does.
  static ({String? profileId, MapThemePalette? palette}) _cloudTheme(
    StrategyData strategy,
  ) {
    final override = strategy.themeOverridePalette;
    final profileId = strategy.themeProfileId;
    if (override != null || profileId == null) {
      return (profileId: profileId, palette: override);
    }
    final profile = Hive.isBoxOpen(HiveBoxNames.mapThemeProfilesBox)
        ? Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox)
            .get(profileId)
        : null;
    if (profile == null || profile.isBuiltIn) {
      return (profileId: profileId, palette: null);
    }
    return (profileId: null, palette: profile.palette);
  }

  /// [ops] in batches the server accepts: at most [_maxOpsPerBatch] ops and
  /// [maxCloudBatchBytes] each. An op too large to send at all fails the
  /// move.
  static List<List<StrategyOp>> _batches(
    List<StrategyOp> ops, {
    required String strategyPublicId,
    required String clientId,
  }) {
    final batches = <List<StrategyOp>>[];
    var current = <StrategyOp>[];
    for (final op in ops) {
      if (cloudOperationExceedsPolicy(op)) {
        throw StateError(cloudOperationTooLargeMessage);
      }
      final candidate = [...current, op];
      final tooBig = candidate.length > _maxOpsPerBatch ||
          serializedCloudBatchUtf8Bytes(
                strategyPublicId: strategyPublicId,
                clientId: clientId,
                ops: candidate,
              ) >
              maxCloudBatchBytes;
      if (tooBig && current.isNotEmpty) {
        batches.add(current);
        current = [op];
      } else {
        current = candidate;
      }
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// Waits until the upload queue holds nothing more of [cloudId]. Throws
  /// when an upload keeps failing, when the cloud stays out of reach, or
  /// when the account changes and the uploads can no longer be watched.
  /// An empty queue proves nothing by itself: [_verify] checks what landed.
  Future<void> _waitForImages(
    String cloudId, {
    required String accountId,
  }) async {
    var lastOnline = DateTime.now();
    while (true) {
      if (ref.read(convexConnectionSnapshotProvider)) {
        lastOnline = DateTime.now();
      } else if (DateTime.now().difference(lastOnline) > _offlineGrace) {
        throw StateError('Went offline while images were uploading.');
      }
      if (ref.read(cloudMediaAccountIdProvider) != accountId) {
        throw StateError('The account changed while images were uploading.');
      }
      final jobs = ref.read(cloudMediaUploadQueueProvider).jobsForStrategy(
            cloudId,
          );
      if (jobs.isEmpty) return;
      final failing = jobs.where(
        (job) => job.isFailed && job.attempts >= _imageAttemptsBeforeFailing,
      );
      if (failing.isNotEmpty) {
        throw StateError('An image did not upload: ${failing.first.lastError}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Reads the cloud copy back and throws unless it holds everything that
  /// was sent: every page, item and lineup, and every uploaded picture.
  Future<void> _verify(
    String cloudId,
    _Plan plan,
    List<({String assetPublicId, String fileExtension})> uploads,
  ) async {
    final snapshot = await ref
        .read(convexStrategyRepositoryProvider)
        .fetchFullSnapshot(cloudId);
    final elements = snapshot.elementsByPage.values
        .expand((page) => page)
        .where((element) => !element.deleted)
        .length;
    final lineups = snapshot.lineupsByPage.values
        .expand((page) => page)
        .where((lineup) => !lineup.deleted)
        .length;
    final missingPictures = [
      for (final upload in uploads)
        if (snapshot.assetsById[upload.assetPublicId]?.uploadStatus != 'active')
          upload.assetPublicId,
    ];
    if (snapshot.pages.length != plan.pages.length ||
        elements != plan.ops.whereType<ElementAddOp>().length ||
        lineups != plan.ops.whereType<LineupAddOp>().length ||
        missingPictures.isNotEmpty) {
      throw StateError(
        'The cloud copy is incomplete: ${snapshot.pages.length} pages, '
        '$elements items, $lineups lineups, '
        '${missingPictures.length} pictures missing.',
      );
    }
  }

  /// Deletes what a move put in the cloud, unless the move finished, with
  /// its pictures' files here, and forgets the move. The server deletes the
  /// strategy only while it is unfinished, so a finished one (its move's
  /// last answer was lost, or the app stopped before forgetting it) stays,
  /// and says so. Null when the server could not be asked; the record then
  /// stays and the next cleanup tries again.
  Future<AbandonedMove?> _abandon(String cloudId) async {
    try {
      final outcome =
          await ref.read(convexStrategyRepositoryProvider).abandonMove(cloudId);
      if (outcome == AbandonedMove.finished) {
        await _forgetUnfinishedMove(cloudId);
        _unmarkMoving({cloudId});
        return outcome;
      }
      await ref
          .read(cloudMediaUploadQueueProvider.notifier)
          .clearJobsForStrategy(cloudId);
      try {
        // The strategy's folder, which holds its image folder.
        final images = await PlacedImageProvider.getImageFolder(cloudId);
        await images.parent.delete(recursive: true);
      } on FileSystemException {
        // Only disk space; nothing shows these files.
      }
      await _forgetUnfinishedMove(cloudId);
      _unmarkMoving({cloudId});
      return outcome;
    } catch (error, stackTrace) {
      // The copy stays locked until a later cleanup removes it.
      await _report('abandon_move', error, stackTrace);
      return null;
    }
  }

  /// Throws once the signed-in account is no longer the one that asked for
  /// the move, before anything more is written.
  void _requireAccount(String accountId) {
    if (ref.read(cloudMediaAccountIdProvider) != accountId) {
      throw StateError('The account changed during the move.');
    }
  }

  /// Deletes the cloud copies of moves that ended without finishing. Runs
  /// after any move in progress, so it only finds those. One whose move did
  /// finish stays (see [_abandon]); its original stays here too, since it
  /// may have changed since.
  Future<void> _cleanUpUnfinishedMoves() => _enqueue(() async {
        if (!ref.read(authProvider).isConvexUserReady) return;
        final accountId = ref.read(cloudMediaAccountIdProvider);
        final box = _movesBox;
        if (box == null || accountId == null) return;
        for (final MapEntry(:key, :value) in box.toMap().entries) {
          if (value is! Map || value['accountId'] != accountId) continue;
          await _abandon(key as String);
        }
      });

  Box<dynamic>? get _movesBox => Hive.isBoxOpen(HiveBoxNames.cloudMovesBox)
      ? Hive.box<dynamic>(HiveBoxNames.cloudMovesBox)
      : null;

  Future<void> _saveUnfinishedMove(
    String cloudId, {
    required String accountId,
    required String localId,
  }) async {
    final box = _movesBox;
    if (box == null) {
      throw StateError('Moves cannot be recorded on this device.');
    }
    await box.put(cloudId, {'accountId': accountId, 'localId': localId});
  }

  Future<void> _forgetUnfinishedMove(String cloudId) async {
    await _movesBox?.delete(cloudId);
  }

  bool _isMoving(String localId) =>
      ref.read(movingToCloudProvider).contains(localId);

  void _markMoving(Set<String> localIds) =>
      ref.read(movingToCloudProvider.notifier).add(localIds);

  void _unmarkMoving(Set<String> localIds) =>
      ref.read(movingToCloudProvider.notifier).remove(localIds);

  Future<void> _report(String step, Object error, StackTrace stackTrace) async {
    final source = 'move_to_cloud:$step';
    if (isConvexUnauthenticatedError(error)) {
      await ref.read(authProvider.notifier).reportConvexUnauthenticated(
            source: source,
            error: error,
            stackTrace: stackTrace,
          );
      return;
    }
    AppErrorReporter.reportError(
      'Moving to the cloud failed.',
      source: source,
      error: error,
      stackTrace: stackTrace,
      promptUser: false,
    );
  }

  void _showMessage(String message) =>
      ref.read(moveToCloudMessageProvider)(message);

  void _showFailure(String message) =>
      ref.read(moveToCloudMessageProvider)(message, failed: true);
}
