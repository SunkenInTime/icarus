import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/folder_icons.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/services/archive_manifest.dart';
import 'package:icarus/providers/folder_provider.dart';

void main() {
  test('folder icon registry migration version matches app version', () {
    expect(folderIconRegistryVersion, Settings.versionNumber);
  });

  test('folder icon registry ids are unique and picker-safe', () {
    final ids = FolderIconRegistry.entries.map((entry) => entry.id).toList();
    expect(ids.toSet(), hasLength(ids.length));

    expect(
      FolderIconRegistry.pickerEntries.map((entry) => entry.id),
      isNot(contains(FolderIconRegistry.legacyFolderId)),
    );
    expect(
      FolderIconRegistry.pickerEntries.map((entry) => entry.id),
      containsAll([
        FolderIconRegistry.controllerRoleId,
        FolderIconRegistry.duelistRoleId,
        FolderIconRegistry.initiatorRoleId,
        FolderIconRegistry.sentinelRoleId,
      ]),
    );
  });

  test('folder icon registry keeps stable id signatures', () {
    expect(
      {
        for (final entry in FolderIconRegistry.entries)
          entry.id: entry.stableSignature,
      },
      {
        0: _materialSignature(Icons.folder),
        1: _materialSignature(Icons.star_rate_rounded),
        2: _materialSignature(Icons.ac_unit_sharp),
        3: _materialSignature(Icons.bug_report),
        4: _materialSignature(Icons.cake),
        5: _materialSignature(Icons.code),
        6: _materialSignature(Icons.add_shopping_cart_rounded),
        7: _materialSignature(Icons.airline_stops_sharp),
        8: _materialSignature(Icons.all_inclusive),
        9: _materialSignature(Icons.api_rounded),
        10: _materialSignature(Icons.drive_folder_upload),
        11: _materialSignature(Icons.folder_shared),
        12: _materialSignature(Icons.folder_special),
        13: _materialSignature(Icons.workspaces),
        14: _materialSignature(Icons.category),
        15: _materialSignature(Icons.collections_bookmark),
        16: _materialSignature(Icons.library_books),
        17: _materialSignature(Icons.archive),
        18: _materialSignature(Icons.assignment),
        19: _materialSignature(Icons.assignment_turned_in),
        20: _materialSignature(Icons.dashboard),
        21: _materialSignature(Icons.anchor),
        22: _materialSignature(Icons.hourglass_bottom_outlined),
        23: _materialSignature(Icons.image_search),
        24: _materialSignature(Icons.view_quilt),
        25: _materialSignature(Icons.map),
        26: _materialSignature(Icons.place),
        27: _materialSignature(Icons.explore),
        28: _materialSignature(Icons.explore_off),
        29: _materialSignature(Icons.flag),
        30: _materialSignature(Icons.outlined_flag),
        31: _materialSignature(Icons.emoji_objects),
        32: _materialSignature(Icons.lightbulb),
        33: _materialSignature(Icons.track_changes),
        34: _materialSignature(Icons.timeline),
        35: _materialSignature(Icons.sports_esports),
        36: _materialSignature(CustomIcons.sword),
        37: _materialSignature(Icons.military_tech),
        38: _materialSignature(Icons.shield),
        39: _materialSignature(Icons.security),
        40: _materialSignature(Icons.bolt),
        41: _materialSignature(Icons.psychology),
        1000: 'asset|assets/agents/controller.webp',
        1001: 'asset|assets/agents/duelist.webp',
        1002: 'asset|assets/agents/initiator.webp',
        1003: 'asset|assets/agents/sentinel.webp',
      },
    );
  });

  test('folder icon registry exposes filtered picker groups', () {
    expect(
      FolderIconRegistry.pickerEntriesFor(FolderIconCategory.symbol)
          .map((entry) => entry.category)
          .toSet(),
      {FolderIconCategory.symbol},
    );
    expect(
      FolderIconRegistry.pickerEntriesFor(FolderIconCategory.role)
          .map((entry) => entry.id),
      containsAll([
        FolderIconRegistry.controllerRoleId,
        FolderIconRegistry.duelistRoleId,
        FolderIconRegistry.initiatorRoleId,
        FolderIconRegistry.sentinelRoleId,
      ]),
    );
    expect(FolderIconRegistry.isKnownId(2000), isFalse);
    expect(FolderIconRegistry.resolve(2000).id, FolderIconRegistry.defaultId);
  });

  test('legacy IconData values migrate to registry ids', () {
    expect(
      FolderIconRegistry.idForLegacyIconData(Icons.flag),
      29,
    );
    expect(
      FolderIconRegistry.idForLegacyIconData(CustomIcons.sword),
      36,
    );
    expect(
      FolderIconRegistry.idForLegacyIconData(Icons.folder),
      FolderIconRegistry.legacyFolderId,
    );
  });

  test('legacy archive icon descriptor maps to icon id', () {
    final entry = ArchiveFolderEntry.fromJson({
      'manifestId': 'legacy',
      'name': 'Legacy',
      'parentManifestId': null,
      'archivePath': '',
      'icon': ArchiveIconDescriptor.fromIconData(Icons.lightbulb).toJson(),
      'color': FolderColor.red.name,
    });

    expect(
      entry.iconId,
      FolderIconRegistry.idForLegacyIconData(Icons.lightbulb),
    );
  });

  test('new archive folder entries write only canonical icon ids', () {
    final entry = ArchiveFolderEntry(
      manifestId: 'duelist',
      name: 'Duelist',
      parentManifestId: null,
      archivePath: '',
      iconId: FolderIconRegistry.duelistRoleId,
      color: FolderColor.red,
      customColorValue: null,
    );

    expect(entry.toJson(),
        containsPair('iconId', FolderIconRegistry.duelistRoleId));
    expect(entry.toJson(), isNot(contains('icon')));
  });

  test('role asset ids use material fallback for legacy archives', () {
    final entry = ArchiveFolderEntry(
      manifestId: 'duelist',
      name: 'Duelist',
      parentManifestId: null,
      archivePath: '',
      iconId: FolderIconRegistry.duelistRoleId,
      color: FolderColor.red,
      customColorValue: null,
    );

    expect(entry.iconId, FolderIconRegistry.duelistRoleId);
    expect(
      entry.icon.toJson(),
      ArchiveIconDescriptor.fromIconData(
        FolderIconRegistry.legacyIconDataForId(
            FolderIconRegistry.duelistRoleId),
      ).toJson(),
    );
  });
}

String _materialSignature(IconData icon) {
  return [
    'material',
    icon.codePoint,
    icon.fontFamily ?? '',
    icon.fontPackage ?? '',
    icon.matchTextDirection,
    icon.fontFamilyFallback?.join(',') ?? '',
  ].join('|');
}
