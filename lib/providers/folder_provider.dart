import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
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
  int iconId;
  FolderColor color;
  Color? customColor;

  Folder({
    required this.name,
    required this.id,
    required this.dateCreated,
    int? iconId,
    IconData? icon,
    this.color = FolderColor.red,
    this.parentID, // Optional, defaults to null (root)
    this.customColor,
  }) : iconId = iconId ??
            (icon == null
                ? FolderIconRegistry.defaultId
                : FolderIconRegistry.idForLegacyIconData(icon));

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

  @Deprecated('Use iconId and FolderIconRegistry instead.')
  IconData get icon => FolderIconRegistry.legacyIconDataForId(iconId);

  @Deprecated('Use iconId and FolderIconRegistry instead.')
  set icon(IconData icon) {
    iconId = FolderIconRegistry.idForLegacyIconData(icon);
  }

  @Deprecated('Use FolderIconRegistry.pickerEntries instead.')
  static List<IconData> get folderIcons => [
        for (final entry in FolderIconRegistry.pickerEntries)
          if (entry.iconData != null) entry.iconData!,
      ];

  bool get isRoot => parentID == null;
}

final folderProvider =
    NotifierProvider<FolderProvider, String?>(FolderProvider.new);

class FolderProvider extends Notifier<String?> {
  Future<Folder> createFolder({
    required String name,
    required int iconId,
    required FolderColor color,
    Color? customColor,
    String? parentID,
  }) async {
    final newFolder = Folder(
      iconId: iconId,
      name: name,
      id: const Uuid().v4(),
      dateCreated: DateTime.now(),
      parentID: parentID ?? state,
      customColor: customColor,
      color: color,
    );

    await Hive.box<Folder>(HiveBoxNames.foldersBox)
        .put(newFolder.id, newFolder);
    return newFolder;
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
    return Hive.box<Folder>(HiveBoxNames.foldersBox)
        .values
        .where((f) => f.parentID == id)
        .toList();
  }

  Folder? findFolderByID(String id) {
    return Hive.box<Folder>(HiveBoxNames.foldersBox).get(id);
  }

  void deleteFolder(String folderID) async {
    // state = state.where((folder) => folder.id != folderID).toList();

    final strategyList =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values.toList();
    List<String> idsToDelete = [];

    for (final strategy in strategyList) {
      if (strategy.folderID == folderID) {
        idsToDelete.add(strategy.id);
      }
    }

    for (final id in idsToDelete) {
      await ref.read(strategyProvider.notifier).deleteStrategy(id);
    }

    await Hive.box<Folder>(HiveBoxNames.foldersBox).delete(folderID);
  }

  void editFolder({
    required Folder folder,
    required String newName,
    required int newIconId,
    required FolderColor newColor,
    required Color? newCustomColor,
  }) async {
    folder.name = newName;
    folder.iconId = newIconId;
    folder.customColor = newCustomColor;
    folder.color = newColor;
    await folder.save();
  }

  void moveToFolder({required String folderID, String? parentID}) async {
    final folder = findFolderByID(folderID);

    if (folder != null) {
      folder.parentID = parentID;
      await folder.save();
    }
  }

  @override
  String? build() {
    return null;
  }
}
