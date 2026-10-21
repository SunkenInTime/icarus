import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/collab/move_to_cloud_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:icarus/services/cloud_needs_connection.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:uuid/uuid.dart';

export 'package:icarus/domain/folder.dart' show Folder, FolderColor;

final folderProvider =
    NotifierProvider<FolderProvider, String?>(FolderProvider.new);

class FolderProvider extends Notifier<String?> {
  String? _localCurrentFolderId;
  String? _cloudCurrentFolderId;

  Future<Folder> createFolder({
    required String name,
    required int iconId,
    required FolderColor color,
    Color? customColor,
    String? parentID,
    LibraryWorkspace? workspace,
  }) async {
    final targetWorkspace = workspace ?? _currentWorkspace;
    final newFolder = Folder(
      iconId: iconId,
      name: name,
      id: const Uuid().v4(),
      dateCreated: DateTime.now(),
      parentID: parentID ?? _currentFolderIdForWorkspace(targetWorkspace),
      customColor: customColor,
      color: color,
    );

    if (targetWorkspace == LibraryWorkspace.cloud) {
      if (refuseCloudChangeWhileOffline(
        ref.read(cloudLibraryShowsCopyProvider),
      )) {
        throw StateError(cloudNeedsConnectionMessage);
      }
      final icon = FolderIconRegistry.resolve(newFolder.iconId).iconData;
      try {
        await ref.read(convexStrategyRepositoryProvider).createFolder(
              publicId: newFolder.id,
              name: name,
              parentFolderPublicId: newFolder.parentID,
              iconId: newFolder.iconId,
              iconCodePoint: icon?.codePoint,
              iconFontFamily: icon?.fontFamily,
              iconFontPackage: icon?.fontPackage,
              color: color.name,
              customColorValue: customColor?.toARGB32(),
            );
        ref.invalidate(cloudFolderTreeProvider);
        return newFolder;
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'folder:create',
          error: error,
          stackTrace: stackTrace,
        );
        // Do NOT fall through to the local write: that silently created a
        // local folder from the cloud view whenever the server call failed.
        Settings.showToast(
          message: "Couldn't create the cloud folder. Check your connection "
              'and try again.',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
        rethrow;
      }
    }

    if (!ref.read(platformPolicyProvider).allowsLocalLibrary) {
      // Refuse rather than save into a library this platform keeps hidden.
      throw StateError('Folders here are created in the cloud only.');
    }
    await Hive.box<Folder>(HiveBoxNames.foldersBox)
        .put(newFolder.id, newFolder);
    return newFolder;
  }

  void updateID(String? id) {
    updateWorkspaceFolderId(_currentWorkspace, id);
  }

  /// Enters [folderId], which lives in [store]. My Library shows folders from
  /// both stores side by side, so opening one also makes its store active.
  void openFolder({required String folderId, required LibraryWorkspace store}) {
    ref.read(libraryWorkspaceProvider.notifier).select(store);
    updateWorkspaceFolderId(store, folderId);
  }

  void clearID() {
    updateWorkspaceFolderId(_currentWorkspace, null);
  }

  void updateWorkspaceFolderId(LibraryWorkspace workspace, String? id) {
    _setFolderIdForWorkspace(workspace, id);
    if (_currentWorkspace == workspace) {
      state = id;
    }
  }

  String? currentFolderIdForWorkspace(LibraryWorkspace workspace) {
    return _currentFolderIdForWorkspace(workspace);
  }

  List<String> getFullPathIDs(Folder? folder) {
    List<String> pathIDs = [];
    Folder? currentFolder = folder;

    while (currentFolder != null) {
      pathIDs.insert(0, currentFolder.id);
      if (currentFolder.parentID != null) {
        currentFolder = findLocalFolderByID(currentFolder.parentID!);
      } else {
        currentFolder = null;
      }
    }

    return pathIDs;
  }

  List<Folder> findFolderChildren(String id) {
    return Hive.box<Folder>(HiveBoxNames.foldersBox)
        .values
        .where((f) => f.parentID == id)
        .toList();
  }

  Folder? findFolderByID(String id) {
    return _currentWorkspace == LibraryWorkspace.cloud
        ? null
        : findLocalFolderByID(id);
  }

  Folder? findLocalFolderByID(String id) {
    return Hive.box<Folder>(HiveBoxNames.foldersBox).get(id);
  }

  Folder? findCloudFolderByID(
    String id,
    Iterable<CloudFolderEntry> cloudFolders,
  ) {
    return cloudFolders
        .where((entry) => entry.folder.id == id)
        .map((entry) => entry.folder)
        .firstOrNull;
  }

  Future<CloudLibraryActionResult> deleteFolder(
    String folderID, {
    LibraryWorkspace? workspace,
  }) async {
    final targetWorkspace = workspace ?? _currentWorkspace;
    if (targetWorkspace == LibraryWorkspace.cloud) {
      return _deleteCloudFolder(folderID);
    }
    return _deleteLocalFolder(folderID);
  }

  /// The server deletes only an empty folder, so the strategies go first,
  /// then the folders, each before its parent. What went stays gone when a
  /// later step fails, and trying again finishes the rest.
  /// Each call names the folder being deleted, so the server refuses
  /// anything moved out of it since the library was read.
  Future<CloudLibraryActionResult> _deleteCloudFolder(String folderID) async {
    final repository = ref.read(convexStrategyRepositoryProvider);
    final deletedStrategies = <String>[];
    var tree = [folderID];
    final result = await _runCloudAction(
      action: () async {
        final inventory = await repository.fetchInventory();
        tree = folderAndDescendantIds(folderID, inventory.folders);
        final treeIds = tree.toSet();
        // All at once: each is its own round trip to the server.
        await Future.wait([
          for (final MapEntry(key: strategyId, value: strategyFolderId)
              in inventory.strategies.entries)
            if (treeIds.contains(strategyFolderId))
              () async {
                final shell = await repository.fetchShell(strategyId);
                await repository.deleteStrategy(
                  strategyPublicId: strategyId,
                  expectedRevision: shell.header.revision,
                  withinFolderPublicId: folderID,
                );
                deletedStrategies.add(strategyId);
              }(),
        ]);
        for (final id in tree.reversed) {
          await repository.deleteFolder(id, withinFolderPublicId: folderID);
        }
        return true;
      },
      source: 'folder:delete',
      failureMessage: "Couldn't delete this cloud folder. Try again.",
    );
    // Refused or offline before anything went: the library is as it was.
    if (!result.didSucceed && deletedStrategies.isEmpty) return result;

    for (final id in deletedStrategies) {
      await ref.read(strategyProvider.notifier).forgetDeletedCloudStrategy(id);
    }
    if (result.didSucceed) {
      for (final id in tree) {
        await ref.read(pinnedItemsProvider.notifier).removePin(id);
      }
      if (tree.contains(_currentFolderIdForWorkspace(LibraryWorkspace.cloud))) {
        updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
      }
    }
    ref.invalidate(cloudFoldersProvider);
    ref.invalidate(cloudFolderTreeProvider);
    ref.invalidate(cloudStrategiesProvider);
    return result;
  }

  /// Deletes the folder, its subfolders and every strategy in them. The
  /// folders go last, each before its parent, so however far this gets
  /// before it stops, nothing is left inside a folder that is gone.
  Future<CloudLibraryActionResult> _deleteLocalFolder(String folderID) async {
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
    final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final tree = folderAndDescendantIds(folderID, {
      for (final folder in folders.values) folder.id: folder.parentID,
    });
    final treeIds = tree.toSet();
    const movingMessage = 'Something in this folder is moving to the cloud. '
        'Delete it once the move ends.';

    // Deleting it would delete a strategy that is moving to the cloud.
    final moving = ref.read(movingToCloudProvider);
    if (treeIds.any(moving.contains) ||
        strategies.values.any(
          (s) => treeIds.contains(s.folderID) && moving.contains(s.id),
        )) {
      return CloudLibraryActionResult.failed(movingMessage);
    }

    // Asked again right before each removal: the dialog can close while
    // this runs, and what the user moves out of the folder meanwhile stays.
    bool inside(String? id) {
      final seen = <String>{};
      while (id != null && seen.add(id)) {
        if (id == folderID) return true;
        id = folders.get(id)?.parentID;
      }
      return false;
    }

    for (final strategy in strategies.values.toList()) {
      if (!inside(strategy.folderID)) continue;
      await ref.read(strategyProvider.notifier).deleteStrategy(
            strategy.id,
            source: StrategySource.local,
          );
    }
    // A strategy that started moving to the cloud meanwhile stays, and so
    // do the folders.
    if (strategies.values.any((s) => inside(s.folderID))) {
      return CloudLibraryActionResult.failed(movingMessage);
    }

    final remaining = folderAndDescendantIds(folderID, {
      for (final folder in folders.values) folder.id: folder.parentID,
    });
    for (final id in remaining.reversed) {
      if (!inside(id)) continue;
      await folders.delete(id);
      await ref.read(pinnedItemsProvider.notifier).removePin(id);
    }
    return CloudLibraryActionResult.succeeded;
  }

  Future<CloudLibraryActionResult> editFolder({
    required Folder folder,
    required String newName,
    required int newIconId,
    required FolderColor newColor,
    required Color? newCustomColor,
    LibraryWorkspace? workspace,
  }) async {
    final targetWorkspace = workspace ?? _currentWorkspace;
    if (targetWorkspace == LibraryWorkspace.cloud) {
      final newIcon = FolderIconRegistry.resolve(newIconId).iconData;
      final iconFontFamily = newIcon?.fontFamily;
      final iconFontPackage = newIcon?.fontPackage;
      final result = await _runCloudAction(
        action: () async {
          await ref.read(convexStrategyRepositoryProvider).updateFolder(
                folderPublicId: folder.id,
                name: newName,
                iconId: newIconId,
                iconCodePoint: newIcon?.codePoint,
                iconFontFamily: iconFontFamily,
                clearIconFontFamily: iconFontFamily == null,
                iconFontPackage: iconFontPackage,
                clearIconFontPackage: iconFontPackage == null,
                color: newColor.name,
                customColorValue: newCustomColor?.toARGB32(),
                clearCustomColorValue: newCustomColor == null,
              );
          return true;
        },
        source: 'folder:update',
        failureMessage: "Couldn't update this cloud folder. Try again.",
      );
      if (!result.didSucceed) return result;

      ref.invalidate(cloudFoldersProvider);
      ref.invalidate(cloudFolderTreeProvider);
      return result;
    }

    folder.name = newName;
    folder.iconId = newIconId;
    folder.customColor = newCustomColor;
    folder.color = newColor;
    await folder.save();
    return CloudLibraryActionResult.succeeded;
  }

  Future<CloudLibraryActionResult> moveToFolder({
    required String folderID,
    String? parentID,
    LibraryWorkspace? workspace,
  }) async {
    final targetWorkspace = workspace ?? _currentWorkspace;
    if (targetWorkspace == LibraryWorkspace.cloud) {
      final result = await _runCloudAction(
        action: () async {
          await ref.read(convexStrategyRepositoryProvider).moveFolder(
                folderPublicId: folderID,
                parentFolderPublicId: parentID,
              );
          return true;
        },
        source: 'folder:move',
        failureMessage: "Couldn't move this cloud folder. Try again.",
        showFailureMessage: true,
      );
      if (!result.didSucceed) return result;

      ref.invalidate(cloudFoldersProvider);
      ref.invalidate(cloudFolderTreeProvider);
      return result;
    }

    final folder = findLocalFolderByID(folderID);

    if (folder != null) {
      folder.parentID = parentID;
      await folder.save();
    }
    return CloudLibraryActionResult.succeeded;
  }

  Future<CloudLibraryActionResult> _runCloudAction({
    required Future<bool> Function() action,
    required String source,
    required String failureMessage,
    bool showFailureMessage = false,
  }) async {
    if (refuseCloudChangeWhileOffline(
      ref.read(cloudLibraryShowsCopyProvider),
    )) {
      return CloudLibraryActionResult.cancelled;
    }
    return ref.read(cloudLibraryActionReporterProvider).run(
          action: action,
          source: source,
          failureMessage: failureMessage,
          showFailureMessage: showFailureMessage,
          reportAuthenticationFailure: (error, stackTrace) =>
              ref.read(authProvider.notifier).reportConvexUnauthenticated(
                    source: source,
                    error: error,
                    stackTrace: stackTrace,
                  ),
        );
  }

  LibraryWorkspace get _currentWorkspace => ref.read(libraryWorkspaceProvider);

  String? _currentFolderIdForWorkspace(LibraryWorkspace workspace) {
    return switch (workspace) {
      LibraryWorkspace.local => _localCurrentFolderId,
      LibraryWorkspace.cloud => _cloudCurrentFolderId,
      LibraryWorkspace.community => null,
    };
  }

  void _setFolderIdForWorkspace(LibraryWorkspace workspace, String? id) {
    if (workspace == LibraryWorkspace.local) {
      _localCurrentFolderId = id;
      return;
    }
    if (workspace == LibraryWorkspace.community) {
      return;
    }
    _cloudCurrentFolderId = id;
  }

  Future<void> _maybeReportCloudUnauthenticated({
    required String source,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    if (!isConvexUnauthenticatedError(error)) {
      return;
    }

    await ref.read(authProvider.notifier).reportConvexUnauthenticated(
          source: source,
          error: error,
          stackTrace: stackTrace,
        );
  }

  @override
  String? build() {
    ref.listen<LibraryWorkspace>(libraryWorkspaceProvider, (_, workspace) {
      state = _currentFolderIdForWorkspace(workspace);
    });
    return _currentFolderIdForWorkspace(ref.read(libraryWorkspaceProvider));
  }
}

/// [folderId] and every folder below it, each parent before its children.
/// [parentOf] maps every folder to its parent, null at the top level.
List<String> folderAndDescendantIds(
  String folderId,
  Map<String, String?> parentOf,
) {
  final tree = [folderId];
  final seen = {folderId};
  for (var i = 0; i < tree.length; i++) {
    for (final MapEntry(key: id, value: parentId) in parentOf.entries) {
      if (parentId == tree[i] && seen.add(id)) tree.add(id);
    }
  }
  return tree;
}

extension on Iterable<Folder> {
  Folder? get firstOrNull => isEmpty ? null : first;
}
