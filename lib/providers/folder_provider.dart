import 'dart:math';

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
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
    Icons.sports_esports,
    CustomIcons.sword,
    Icons.military_tech,
    Icons.shield,
    Icons.security,
    Icons.bolt,
    Icons.psychology,
  ];

  static int folderIconIndex(IconData icon) {
    final index = folderIcons.indexOf(icon);
    return index >= 0 ? index : 0;
  }

  static IconData iconFromIndex(int? index) {
    if (index == null || index < 0 || index >= folderIcons.length) {
      return folderIcons[0];
    }
    return folderIcons[index];
  }

  static String colorKey(FolderColor color) => color.name;

  static FolderColor colorFromKey(String? key) {
    if (key == null) {
      return FolderColor.generic;
    }

    for (final value in FolderColor.values) {
      if (value.name == key) {
        return value;
      }
    }

    return FolderColor.generic;
  }

  static Color? customColorFromValue(int? value) {
    if (value == null) {
      return null;
    }
    return Color(value);
  }

  bool get isRoot => parentID == null;
}

final folderProvider =
    NotifierProvider<FolderProvider, String?>(FolderProvider.new);

class FolderProvider extends Notifier<String?> {
  Future<void> createFolder({
    required String name,
    required IconData icon,
    required FolderColor color,
    Color? customColor,
  }) async {
    final newFolder = Folder(
      icon: icon,
      name: name,
      id: const Uuid().v4(),
      dateCreated: DateTime.now(),
      parentID: state,
      customColor: customColor,
      color: color,
    );

    if (ref.read(isCloudCollabEnabledProvider)) {
      try {
        await ref.read(convexStrategyRepositoryProvider).createFolder(
              publicId: newFolder.id,
              name: name,
              parentFolderPublicId: state,
              iconIndex: Folder.folderIconIndex(icon),
              colorKey: Folder.colorKey(color),
              customColorValue: customColor?.toARGB32(),
            );
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'folder:create',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return;
    }

    await Hive.box<Folder>(HiveBoxNames.foldersBox)
        .put(newFolder.id, newFolder);
  }

  void updateID(String? id) {
    state = id;
  }

  void clearID() {
    state = null;
  }

  List<String> getFullPathIDs(Folder? folder) {
    List<String> pathIDs = [];
    Folder? currentFolder = folder;

    while (currentFolder != null) {
      pathIDs.insert(0, currentFolder.id);
      if (currentFolder.parentID != null) {
        currentFolder = findFolderByID(currentFolder.parentID!);
      } else {
        currentFolder = null;
      }
    }

    return pathIDs;
  }

  List<Folder> findFolderChildren(String id) {
    if (ref.read(isCloudCollabEnabledProvider)) {
      return [];
    }
    return Hive.box<Folder>(HiveBoxNames.foldersBox)
        .values
        .where((f) => f.parentID == id)
        .toList();
  }

  Folder? findFolderByID(String id) {
    if (ref.read(isCloudCollabEnabledProvider)) {
      return null;
    }
    return Hive.box<Folder>(HiveBoxNames.foldersBox).get(id);
  }

  void deleteFolder(String folderID) async {
    if (ref.read(isCloudCollabEnabledProvider)) {
      try {
        await ConvexClient.instance.mutation(
          name: 'folders:deleteRecursive',
          args: {
            'folderPublicId': folderID,
          },
        );
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'folder:delete',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (state == folderID) {
        state = null;
      }
      return;
    }

    final strategyList =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values.toList();
    log(strategyList.length);
    List<String> idsToDelete = [];

    for (final strategy in strategyList) {
      if (strategy.folderID == folderID) {
        idsToDelete.add(strategy.id);
      }
    }

    for (final id in idsToDelete) {
      await ref.read(strategyProvider.notifier).deleteStrategy(id);
    }

    List<StrategyData> strategyListNew =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values.toList();
    log(strategyListNew.length);

    await Hive.box<Folder>(HiveBoxNames.foldersBox).delete(folderID);
  }

  void editFolder({
    required String folderID,
    required String newName,
    required IconData newIcon,
    required FolderColor newColor,
    required Color? newCustomColor,
  }) async {
    if (ref.read(isCloudCollabEnabledProvider)) {
      try {
        await ConvexClient.instance.mutation(name: 'folders:update', args: {
          'folderPublicId': folderID,
          'name': newName,
          'iconIndex': Folder.folderIconIndex(newIcon),
          'colorKey': Folder.colorKey(newColor),
          if (newCustomColor != null)
            'customColorValue': newCustomColor.toARGB32(),
          if (newCustomColor == null) 'clearCustomColorValue': true,
        });
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'folder:update',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return;
    }

    final folder = findFolderByID(folderID);
    if (folder == null) {
      return;
    }
    folder.name = newName;
    folder.icon = newIcon;
    folder.customColor = newCustomColor;
    folder.color = newColor;
    await folder.save();
  }

  void moveToFolder({required String folderID, String? parentID}) async {
    if (ref.read(isCloudCollabEnabledProvider)) {
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

    final folder = findFolderByID(folderID);

    if (folder != null) {
      folder.parentID = parentID;
      await folder.save();
    }
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
    return null;
  }
}
