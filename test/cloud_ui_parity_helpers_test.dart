import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/folder_provider.dart';

void main() {
  test('cloud folder summary adapts to local folder model defaults', () {
    final summary = CloudFolderSummary(
      publicId: 'folder-1',
      name: 'Set Plays',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
      parentFolderPublicId: 'parent-1',
    );

    final folder = FolderProvider.cloudSummaryToFolder(summary);

    expect(folder.id, 'folder-1');
    expect(folder.name, 'Set Plays');
    expect(folder.parentID, 'parent-1');
    expect(folder.color, FolderColor.generic);
    expect(folder.icon.codePoint, Icons.drive_folder_upload.codePoint);
    expect(folder.customColor, isNull);
  });

  test('cloud folder summary preserves icon and color metadata', () {
    final summary = CloudFolderSummary(
      publicId: 'folder-2',
      name: 'Execs',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
      iconCodePoint: 0xe318,
      iconFontFamily: 'MaterialIcons',
      color: 'red',
      customColorValue: 0xFF123456,
    );

    final folder = FolderProvider.cloudSummaryToFolder(summary);

    expect(folder.icon.codePoint, 0xe318);
    expect(folder.icon.fontFamily, 'MaterialIcons');
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
