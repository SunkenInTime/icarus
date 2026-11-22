import 'dart:ui';

import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus_library/icarus_library.dart';

ReadableFolder folderToRow(Folder folder) => ReadableFolder(
      publicId: folder.id,
      name: folder.name,
      parentFolderPublicId: folder.parentID,
      iconId: folder.iconId,
      color: folder.color.name,
      customColorValue: folder.customColor?.toARGB32(),
      createdAt: folder.dateCreated,
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

final class FolderCreatedAtMissing extends FolderProblem {
  const FolderCreatedAtMissing();
}

FolderColor? _colorNamed(String? name) {
  for (final color in FolderColor.values) {
    if (color.name == name) return color;
  }
  return null;
}

int? _iconIdOf(ReadableFolder row) => switch (row) {
      ReadableFolder(:final iconId?)
          when FolderIconRegistry.isKnownId(iconId) =>
        iconId,
      ReadableFolder(:final iconCodePoint?) => folderIconIdFromCloud(
          iconId: null,
          codePoint: iconCodePoint,
          fontFamily: row.iconFontFamily,
          fontPackage: row.iconFontPackage,
        ),
      ReadableFolder(:final iconId) => iconId,
    };

FolderFromRow folderFromRow(ReadableFolder row) {
  final color = _colorNamed(row.color);
  final iconId = _iconIdOf(row);
  final dateCreated = row.createdAt;
  final problems = [
    if (color == null) UnknownFolderColor(row.color),
    if (iconId == null) UnknownFolderIcon(row.iconId),
    if (dateCreated == null) const FolderCreatedAtMissing(),
  ];
  if (color == null || iconId == null || dateCreated == null) {
    return FolderRefused(row.publicId, problems);
  }
  return FolderMade(
    Folder(
      name: row.name,
      id: row.publicId,
      dateCreated: dateCreated.toLocal(),
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
