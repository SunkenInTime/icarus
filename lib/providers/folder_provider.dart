import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
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

  Future<void> deleteFolder(
    String folderID, {
    LibraryWorkspace? workspace,
  }) async {
    final targetWorkspace = workspace ?? _currentWorkspace;
    if (targetWorkspace == LibraryWorkspace.cloud) {
      try {
        await ref.read(convexStrategyRepositoryProvider).deleteFolder(folderID);
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'folder:delete',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }
      if (_currentFolderIdForWorkspace(LibraryWorkspace.cloud) == folderID) {
        updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
      }
      return;
    }

    await ref.read(pinnedItemsProvider.notifier).removePin(folderID);

    final strategyList =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values.toList();
    List<String> idsToDelete = [];

    for (final strategy in strategyList) {
      if (strategy.folderID == folderID) {
        idsToDelete.add(strategy.id);
      }
    }

    for (final id in idsToDelete) {
      await ref.read(strategyProvider.notifier).deleteStrategy(
            id,
            source: StrategySource.local,
          );
    }

    await Hive.box<Folder>(HiveBoxNames.foldersBox).delete(folderID);
  }

  void editFolder({
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
      try {
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
        ref.invalidate(cloudFolderTreeProvider);
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'folder:update',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return;
    }

    folder.name = newName;
    folder.iconId = newIconId;
    folder.customColor = newCustomColor;
    folder.color = newColor;
    await folder.save();
  }

  void moveToFolder({
    required String folderID,
    String? parentID,
    LibraryWorkspace? workspace,
  }) async {
    final targetWorkspace = workspace ?? _currentWorkspace;
    if (targetWorkspace == LibraryWorkspace.cloud) {
      try {
        await ref.read(convexStrategyRepositoryProvider).moveFolder(
              folderPublicId: folderID,
              parentFolderPublicId: parentID,
            );
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'folder:move',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return;
    }

    final folder = findLocalFolderByID(folderID);

    if (folder != null) {
      folder.parentID = parentID;
      await folder.save();
    }
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

extension on Iterable<Folder> {
  Folder? get firstOrNull => isEmpty ? null : first;
}
