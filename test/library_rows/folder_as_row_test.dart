import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/library_rows/folder_as_row.dart';
import 'package:icarus_library/icarus_library.dart';

import '../desktop_4_6_3_adapters_test_support.dart';

Folder folderBack(Folder folder) {
  final converted = folderToRow(folder);
  return switch (folderFromRow(converted.row, converted.dateCreated)) {
    FolderMade(:final folder) => folder,
    FolderRefused(:final problems) => throw TestFailure('refused: $problems'),
  };
}

void main() {
  test('a folder comes back the same, byte for byte as Hive saves it', () {
    final registry = currentRegistry();
    final folders = [
      for (final iconId in [
        FolderIconRegistry.defaultId,
        FolderIconRegistry.sentinelRoleId,
        FolderIconRegistry.premierModeId,
        9999,
      ])
        for (final color in FolderColor.values)
          Folder(
            id: 'folder-$iconId-${color.name}',
            name: 'Execs "B"',
            dateCreated: DateTime.utc(2026, 8, 30, 1, 2, 3),
            iconId: iconId,
            color: color,
            parentID: iconId.isEven ? 'parent' : null,
            customColor:
                color == FolderColor.custom ? const Color(0x8022C55E) : null,
          ),
    ];
    for (final folder in folders) {
      expect(
        writeRecord(registry, folderBack(folder)),
        writeRecord(registry, folder),
        reason: folder.id,
      );
    }
  });

  test(
      'a newer build\'s folder row with an icon id this build lacks reads '
      'its legacy icon', () {
    final legacy = StoredFolderIcon.fromIconData(Icons.map);
    final folder = switch (folderFromRow(
      ReadableFolder(
        publicId: 'f',
        name: 'F',
        iconId: 9999,
        iconCodePoint: legacy.codePoint,
        iconFontFamily: legacy.fontFamily,
        iconFontPackage: legacy.fontPackage,
        color: 'red',
      ),
      DateTime.utc(2026),
    )) {
      FolderMade(:final folder) => folder,
      FolderRefused(:final problems) => throw TestFailure('$problems'),
    };
    expect(folder.iconId, FolderIconRegistry.idForLegacyIconData(Icons.map));
    expect(folder.iconId, isNot(FolderIconRegistry.defaultId));
  });

  test(
      'a folder row with a colour or icon this build does not know is '
      'refused', () {
    final problems = switch (folderFromRow(
      ReadableFolder(publicId: 'f', name: 'F', color: 'teal'),
      DateTime.utc(2026),
    )) {
      FolderRefused(:final problems) => problems,
      FolderMade() => throw TestFailure('converted'),
    };
    expect(problems.map((problem) => problem.runtimeType), [
      UnknownFolderColor,
      UnknownFolderIcon,
    ]);
  });
}
