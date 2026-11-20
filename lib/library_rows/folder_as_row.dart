import 'dart:ui';

import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus_library/icarus_library.dart';

final class FolderAsRow {
  const FolderAsRow({required this.row, required this.dateCreated});

  final FolderRow row;
  final DateTime dateCreated;
}

FolderAsRow folderToRow(Folder folder) => FolderAsRow(
      row: FolderRow(
        publicId: folder.id,
        name: folder.name,
        parentFolderPublicId: folder.parentID,
        iconId: folder.iconId,
        color: folder.color.name,
        customColorValue: folder.customColor?.toARGB32(),
      ),
      dateCreated: folder.dateCreated,
    );

sealed class FolderFromRow {
  const FolderFromRow();
}

final class FolderMade extends FolderFromRow {
  const FolderMade(this.folder);

  final Folder folder;
}

final class FolderRefused extends FolderFromRow {
  const FolderRefused(this.folderId, this.problems);

  final String folderId;
  final List<FolderProblem> problems;
}

sealed class FolderProblem {
  const FolderProblem();
}

final class UnknownFolderColor extends FolderProblem {
  const UnknownFolderColor(this.color);

  final String? color;
}

final class UnknownFolderIcon extends FolderProblem {
  const UnknownFolderIcon(this.iconId);

  final int? iconId;
}

FolderColor? _colorNamed(String? name) {
  for (final color in FolderColor.values) {
    if (color.name == name) return color;
  }
  return null;
}

int? _iconIdOf(FolderRow row) => switch (row) {
      FolderRow(:final iconId?) when FolderIconRegistry.isKnownId(iconId) =>
        iconId,
      FolderRow(:final iconCodePoint?) => folderIconIdFromCloud(
          iconId: null,
          codePoint: iconCodePoint,
          fontFamily: row.iconFontFamily,
          fontPackage: row.iconFontPackage,
        ),
      FolderRow(:final iconId) => iconId,
    };

FolderFromRow folderFromRow(FolderRow row, DateTime dateCreated) {
  final color = _colorNamed(row.color);
  final iconId = _iconIdOf(row);
  final problems = [
    if (color == null) UnknownFolderColor(row.color),
    if (iconId == null) UnknownFolderIcon(row.iconId),
  ];
  if (color == null || iconId == null) {
    return FolderRefused(row.publicId, problems);
  }
  return FolderMade(
    Folder(
      name: row.name,
      id: row.publicId,
      dateCreated: dateCreated,
      parentID: row.parentFolderPublicId,
      iconId: iconId,
      color: color,
      customColor: switch (row.customColorValue) {
        final value? => Color(value),
        null => null,
      },
    ),
  );
}
