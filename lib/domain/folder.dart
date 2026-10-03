// ignore_for_file: non_const_argument_for_const_parameter

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/settings.dart';

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
  Folder({
    required this.name,
    required this.id,
    required this.dateCreated,
    int? iconId,
    IconData? icon,
    this.color = FolderColor.red,
    this.parentID,
    this.customColor,
  }) : iconId = iconId ??
            (icon == null
                ? FolderIconRegistry.defaultId
                : FolderIconRegistry.idForLegacyIconData(icon));

  String name;
  final String id;
  final DateTime dateCreated;
  String? parentID;
  int iconId;
  FolderColor color;
  Color? customColor;

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

FolderColor folderColorFromWireName(String? value) {
  if (value == null) return FolderColor.generic;
  return FolderColor.values.firstWhere(
    (color) => color.name == value,
    orElse: () => FolderColor.generic,
  );
}

Color? folderCustomColorFromCloud(int? value) {
  return value == null ? null : Color(value);
}

int folderIconIdFromCloud({
  required int? iconId,
  required int? codePoint,
  required String? fontFamily,
  required String? fontPackage,
}) {
  if (iconId != null && FolderIconRegistry.isKnownId(iconId)) {
    return iconId;
  }
  final icon = codePoint == null
      ? Icons.drive_folder_upload
      : IconData(
          codePoint,
          fontFamily: fontFamily,
          fontPackage: fontPackage,
        );
  return FolderIconRegistry.idForLegacyIconData(icon);
}
