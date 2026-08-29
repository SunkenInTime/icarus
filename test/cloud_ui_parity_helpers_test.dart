import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';

void main() {
  test('cloud folder values adapt to local folder model defaults', () {
    final folder = Folder(
      id: 'folder-1',
      name: 'Set Plays',
      dateCreated: DateTime(2026, 1, 1),
      parentID: 'parent-1',
      iconId: folderIconIdFromCloud(
        iconId: null,
        codePoint: null,
        fontFamily: null,
        fontPackage: null,
      ),
      color: folderColorFromWireName(null),
    );

    expect(folder.id, 'folder-1');
    expect(folder.name, 'Set Plays');
    expect(folder.parentID, 'parent-1');
    expect(folder.color, FolderColor.generic);
    expect(folder.icon.codePoint, Icons.drive_folder_upload.codePoint);
    expect(folder.customColor, isNull);
  });

  test('cloud folder values preserve icon and color metadata', () {
    final folder = Folder(
      id: 'folder-2',
      name: 'Execs',
      dateCreated: DateTime(2026, 1, 1),
      iconId: folderIconIdFromCloud(
        iconId: FolderIconRegistry.duelistRoleId,
        codePoint: null,
        fontFamily: null,
        fontPackage: null,
      ),
      color: folderColorFromWireName('red'),
      customColor: folderCustomColorFromCloud(0xFF123456),
    );

    expect(folder.iconId, FolderIconRegistry.duelistRoleId);
    expect(folder.color, FolderColor.red);
    expect(folder.customColor, const Color(0xFF123456));
  });

  test('viewer cloud capabilities disable mutations', () {
    final caps = StrategyCapabilities.fromCloudRole('viewer');

    expect(caps.canRenameStrategy, isFalse);
    expect(caps.canDeleteStrategy, isFalse);
    expect(caps.canAddPage, isFalse);
    expect(caps.canReorderPages, isFalse);
  });

  test('owner cloud capabilities allow destructive actions', () {
    final caps = StrategyCapabilities.fromCloudRole('owner');

    expect(caps.canRenameStrategy, isTrue);
    expect(caps.canDeleteStrategy, isTrue);
    expect(caps.canAddPage, isTrue);
    expect(caps.canReorderPages, isTrue);
  });
}
