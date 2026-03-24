import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:uuid/uuid.dart';

enum FolderColor {
  generic,
  red,
  blue,
  green,
  orange,
  purple,
  custom,
}

class Folder extends HiveObject {
  String name;
  final String id;
  final DateTime dateCreated;
  String? parentID; // null for root folders, clearer than empty string
  IconData icon;
  FolderColor color;
  Color? customColor;

  Folder({
    required this.name,
    required this.id,
    required this.dateCreated,
    required this.icon,
    this.color = FolderColor.red,
    this.parentID, // Optional, defaults to null (root)
    this.customColor,
  });

  static Map<FolderColor, Color> folderColorMap = {
    FolderColor.red: Colors.red,
    FolderColor.blue: Colors.blue,
    FolderColor.green: Colors.green,
    FolderColor.orange: Colors.orange,
    FolderColor.purple: Colors.purple,
    FolderColor.generic: Settings.tacticalVioletTheme.card,
  };

  static List<FolderColor> folderColors = [
    FolderColor.red,
    FolderColor.blue,
    FolderColor.green,
    FolderColor.orange,
    FolderColor.purple,
    FolderColor.generic,
  ];

  static List<IconData> folderIcons = [
    // 📂 Folder & File Related

    Icons.star_rate_rounded,
    Icons.ac_unit_sharp,
    Icons.bug_report,
    Icons.cake,
    Icons.code,
    Icons.add_shopping_cart_rounded,
    Icons.airline_stops_sharp,
    Icons.all_inclusive,
    Icons.api_rounded,

    Icons.drive_folder_upload,
    Icons.folder_shared,
    Icons.folder_special,
    Icons.workspaces,

    // 🗂️ Organization & Structure
    Icons.category,
    Icons.collections_bookmark,
    Icons.library_books,
    Icons.archive,
    Icons.assignment,
    Icons.assignment_turned_in,
    Icons.dashboard,
    Icons.anchor,
    Icons.hourglass_bottom_outlined,
    Icons.image_search,
    Icons.view_quilt,

    // 🎯 Strategy & Planning
    Icons.map,
    Icons.place,
    Icons.explore,
    Icons.explore_off,
    Icons.flag,
    Icons.outlined_flag,
    Icons.emoji_objects,
    Icons.lightbulb,
    Icons.track_changes,
    Icons.timeline,

    // ⚔️ Valorant / Tactical Feel
    Icons.sports_esports,
    CustomIcons.sword,
    Icons.military_tech,
    Icons.shield,
    Icons.security,
    Icons.bolt,
    Icons.psychology,
  ];

  bool get isRoot => parentID == null;
}

final folderProvider =
    NotifierProvider<FolderProvider, String?>(FolderProvider.new);

class FolderProvider extends Notifier<String?> {
  String? _localCurrentFolderId;
  String? _cloudCurrentFolderId;

  static FolderColor decodeFolderColor(String? raw) {
    if (raw == null) {
      return FolderColor.generic;
    }
    for (final value in FolderColor.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return FolderColor.generic;
  }

  static IconData decodeFolderIcon(
    CloudFolderSummary folder, {
    IconData fallback = Icons.drive_folder_upload,
  }) {
    final codePoint = folder.iconCodePoint;
    if (codePoint == null) {
      return fallback;
    }
    return IconData(
      codePoint,
      fontFamily: folder.iconFontFamily,
      fontPackage: folder.iconFontPackage,
    );
  }

  static Folder cloudSummaryToFolder(CloudFolderSummary folder) {
    return Folder(
      name: folder.name,
      id: folder.publicId,
      dateCreated: folder.createdAt,
      icon: decodeFolderIcon(folder),
      color: decodeFolderColor(folder.color),
      parentID: folder.parentFolderPublicId,
      customColor: folder.customColorValue == null
          ? null
          : Color(folder.customColorValue!),
    );
  }

  Future<Folder> createFolder({
    required String name,
    required IconData icon,
    required FolderColor color,
    Color? customColor,
    String? parentID,
    LibraryWorkspace? workspace,
  }) async {
    final targetWorkspace = workspace ?? _currentWorkspace;
    final newFolder = Folder(
      icon: icon,
      name: name,
      id: const Uuid().v4(),
      dateCreated: DateTime.now(),
      parentID: parentID ?? _currentFolderIdForWorkspace(targetWorkspace),
      customColor: customColor,
      color: color,
    );

    if (targetWorkspace == LibraryWorkspace.cloud) {
      try {
        await ref.read(convexStrategyRepositoryProvider).createFolder(
              publicId: newFolder.id,
              name: name,
              parentFolderPublicId: newFolder.parentID,
              iconCodePoint: icon.codePoint,
              iconFontFamily: icon.fontFamily,
              iconFontPackage: icon.fontPackage,
              color: color.name,
              customColorValue: customColor?.toARGB32(),
            );
        ref.invalidate(cloudFoldersProvider);
        return newFolder;
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'folder:create',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    await Hive.box<Folder>(HiveBoxNames.foldersBox).put(newFolder.id, newFolder);
    return newFolder;
  }

  void updateID(String? id) {
    updateWorkspaceFolderId(_currentWorkspace, id);
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
    Iterable<CloudFolderSummary> cloudFolders,
  ) {
    return cloudFolders
        .where((folder) => folder.publicId == id)
        .map(cloudSummaryToFolder)
        .firstOrNull;
  }

  void deleteFolder(
    String folderID, {
    LibraryWorkspace? workspace,
  }) async {
    final targetWorkspace = workspace ?? _currentWorkspace;
    if (targetWorkspace == LibraryWorkspace.cloud) {
      try {
        await ConvexClient.instance.mutation(name: 'folders:delete', args: {
          'folderPublicId': folderID,
        });
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'folder:delete',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (_currentFolderIdForWorkspace(LibraryWorkspace.cloud) == folderID) {
        updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
      }
      return;
    }

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
    required IconData newIcon,
    required FolderColor newColor,
    required Color? newCustomColor,
    LibraryWorkspace? workspace,
  }) async {
    final targetWorkspace = workspace ?? _currentWorkspace;
    if (targetWorkspace == LibraryWorkspace.cloud) {
      try {
        final args = <String, Object>{
          'folderPublicId': folder.id,
          'name': newName,
          'iconCodePoint': newIcon.codePoint,
          if (newIcon.fontFamily != null) 'iconFontFamily': newIcon.fontFamily!,
          if (newIcon.fontFamily == null) 'clearIconFontFamily': true,
          if (newIcon.fontPackage != null)
            'iconFontPackage': newIcon.fontPackage!,
          if (newIcon.fontPackage == null) 'clearIconFontPackage': true,
          'color': newColor.name,
          if (newCustomColor != null)
            'customColorValue': newCustomColor.toARGB32(),
          if (newCustomColor == null) 'clearCustomColorValue': true,
        };
        await ConvexClient.instance.mutation(name: 'folders:update', args: args);
        ref.invalidate(cloudFoldersProvider);
        ref.invalidate(cloudAllFoldersProvider);
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
    folder.icon = newIcon;
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
        await ConvexClient.instance.mutation(name: 'folders:move', args: {
          'folderPublicId': folderID,
          if (parentID != null) 'parentFolderPublicId': parentID,
        });
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
    };
  }

  void _setFolderIdForWorkspace(LibraryWorkspace workspace, String? id) {
    if (workspace == LibraryWorkspace.local) {
      _localCurrentFolderId = id;
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
