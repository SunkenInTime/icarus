import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/folder_card.dart';
import 'package:icarus/widgets/folder_content.dart';

void main() {
  StrategyData strategyWithFolder(String? folderId) {
    return StrategyData(
      id: 'strategy-id',
      name: 'Strategy',
      mapData: MapValue.ascent,
      versionNumber: 1,
      lastEdited: DateTime(2026),
      folderID: folderId,
    );
  }

  Folder folder({
    required String id,
    required String name,
    required DateTime dateCreated,
    String? parentID,
  }) {
    return Folder(
      id: id,
      name: name,
      dateCreated: dateCreated,
      parentID: parentID,
    );
  }

  StrategyData strategy({
    required String id,
    required String name,
    required String? folderID,
    required DateTime lastEdited,
    DateTime? createdAt,
  }) {
    return StrategyData(
      id: id,
      name: name,
      mapData: MapValue.ascent,
      versionNumber: 1,
      lastEdited: lastEdited,
      createdAt: createdAt,
      folderID: folderID,
    );
  }

  test('root includes strategies without a folder', () {
    expect(
      strategyBelongsToVisibleFolder(
        strategy: strategyWithFolder(null),
        currentFolderId: null,
        existingFolderIds: {'folder-a'},
      ),
      isTrue,
    );
  });

  test('root includes strategies whose folder no longer exists', () {
    expect(
      strategyBelongsToVisibleFolder(
        strategy: strategyWithFolder('missing-folder'),
        currentFolderId: null,
        existingFolderIds: {'folder-a'},
      ),
      isTrue,
    );
  });

  test('root excludes strategies in an existing folder', () {
    expect(
      strategyBelongsToVisibleFolder(
        strategy: strategyWithFolder('folder-a'),
        currentFolderId: null,
        existingFolderIds: {'folder-a'},
      ),
      isFalse,
    );
  });

  test('folder includes only its own strategies', () {
    expect(
      strategyBelongsToVisibleFolder(
        strategy: strategyWithFolder('folder-a'),
        currentFolderId: 'folder-a',
        existingFolderIds: {'folder-a'},
      ),
      isTrue,
    );
    expect(
      strategyBelongsToVisibleFolder(
        strategy: strategyWithFolder('missing-folder'),
        currentFolderId: 'folder-a',
        existingFolderIds: {'folder-a'},
      ),
      isFalse,
    );
  });

  test('root includes only top-level folders', () {
    expect(
      folderBelongsToVisibleParent(
        folder: folder(
          id: 'root-folder',
          name: 'Root Folder',
          dateCreated: DateTime.utc(2026),
        ),
        currentFolderId: null,
      ),
      isTrue,
    );
    expect(
      folderBelongsToVisibleParent(
        folder: folder(
          id: 'child-folder',
          name: 'Child Folder',
          dateCreated: DateTime.utc(2026),
          parentID: 'root-folder',
        ),
        currentFolderId: null,
      ),
      isFalse,
    );
  });

  test('folder includes only direct child folders', () {
    expect(
      folderBelongsToVisibleParent(
        folder: folder(
          id: 'child-folder',
          name: 'Child Folder',
          dateCreated: DateTime.utc(2026),
          parentID: 'root-folder',
        ),
        currentFolderId: 'root-folder',
      ),
      isTrue,
    );
    expect(
      folderBelongsToVisibleParent(
        folder: folder(
          id: 'sibling-folder',
          name: 'Sibling Folder',
          dateCreated: DateTime.utc(2026),
          parentID: 'other-folder',
        ),
        currentFolderId: 'root-folder',
      ),
      isFalse,
    );
  });

  test('folder last updated uses newest nested strategy edit', () {
    final root = folder(
      id: 'root',
      name: 'Root',
      dateCreated: DateTime.utc(2026, 1, 1),
    );
    final child = folder(
      id: 'child',
      name: 'Child',
      dateCreated: DateTime.utc(2026, 1, 2),
      parentID: root.id,
    );

    expect(
      folderLastUpdated(
        root,
        LocalFolderIndex(
          folders: [root, child],
          strategies: [
            strategy(
              id: 'older',
              name: 'Older',
              folderID: root.id,
              lastEdited: DateTime.utc(2026, 1, 3),
            ),
            strategy(
              id: 'newer',
              name: 'Newer',
              folderID: child.id,
              lastEdited: DateTime.utc(2026, 1, 5),
            ),
          ],
        ).strategiesInTree(root),
      ),
      DateTime.utc(2026, 1, 5),
    );
  });

  test('folder card summary includes descendant folder strategies', () {
    final root = folder(
      id: 'root',
      name: 'Root',
      dateCreated: DateTime.utc(2026, 1, 1),
    );
    final child = folder(
      id: 'child',
      name: 'Child',
      dateCreated: DateTime.utc(2026, 1, 2),
      parentID: root.id,
    );
    final grandchild = folder(
      id: 'grandchild',
      name: 'Grandchild',
      dateCreated: DateTime.utc(2026, 1, 3),
      parentID: child.id,
    );
    final sibling = folder(
      id: 'sibling',
      name: 'Sibling',
      dateCreated: DateTime.utc(2026, 1, 4),
    );

    final summaryStrategies = LocalFolderIndex(
      folders: [root, child, grandchild, sibling],
      strategies: [
        strategy(
          id: 'direct',
          name: 'Direct',
          folderID: root.id,
          lastEdited: DateTime.utc(2026, 1, 5),
        ),
        strategy(
          id: 'nested',
          name: 'Nested',
          folderID: child.id,
          lastEdited: DateTime.utc(2026, 1, 6),
        ),
        strategy(
          id: 'deep',
          name: 'Deep',
          folderID: grandchild.id,
          lastEdited: DateTime.utc(2026, 1, 7),
        ),
        strategy(
          id: 'sibling-strategy',
          name: 'Sibling Strategy',
          folderID: sibling.id,
          lastEdited: DateTime.utc(2026, 1, 8),
        ),
      ],
    ).strategiesInTree(root);

    final viewData = FolderCardViewData(
      folder: root,
      strategies: summaryStrategies,
      folderCount: 1,
    );

    expect(summaryStrategies.map((strategy) => strategy.id), [
      'direct',
      'nested',
      'deep',
    ]);
    expect(viewData.strategyCount, 3);
  });

  test('folder card agents follow tactical role order', () {
    final previewFolder = folder(
      id: 'preview',
      name: 'Preview',
      dateCreated: DateTime.utc(2026, 1, 1),
    );
    final previewStrategy = StrategyData(
      id: 'preview-strategy',
      name: 'Preview Strategy',
      mapData: MapValue.ascent,
      versionNumber: 1,
      lastEdited: DateTime.utc(2026, 1, 2),
      folderID: previewFolder.id,
      pages: [
        StrategyPage(
          id: 'page',
          name: 'Page',
          drawingData: const [],
          agentData: [
            PlacedAgent(
              type: AgentType.killjoy,
              position: Offset.zero,
              id: 'sentinel',
            ),
            PlacedAgent(
              type: AgentType.omen,
              position: Offset.zero,
              id: 'controller',
            ),
            PlacedAgent(
              type: AgentType.sova,
              position: Offset.zero,
              id: 'initiator',
            ),
            PlacedAgent(
              type: AgentType.jett,
              position: Offset.zero,
              id: 'duelist',
            ),
          ],
          abilityData: const [],
          textData: const [],
          imageData: const [],
          utilityData: const [],
          sortIndex: 0,
          isAttack: true,
          settings: StrategySettings(),
        ),
      ],
    );

    final viewData = FolderCardViewData(
      folder: previewFolder,
      strategies: [previewStrategy],
      folderCount: 0,
    );

    expect(viewData.agentTypes, [
      AgentType.jett,
      AgentType.sova,
      AgentType.omen,
      AgentType.killjoy,
    ]);
  });

  test('empty folder last updated falls back to creation date', () {
    final empty = folder(
      id: 'empty',
      name: 'Empty',
      dateCreated: DateTime.utc(2026, 1, 4),
    );

    expect(
      folderLastUpdated(
        empty,
        LocalFolderIndex(folders: [empty], strategies: const [])
            .strategiesInTree(empty),
      ),
      DateTime.utc(2026, 1, 4),
    );
  });

  test('folder index matches a full scan of the library', () {
    // A messy library: nesting, orphans whose parent is gone, a parent cycle,
    // and strategies whose folder is gone. The index must give every folder
    // the same strategies, in the same order, as scanning everything.
    final random = math.Random(7);
    final folders = [
      for (var i = 0; i < 60; i++)
        folder(
          id: 'f$i',
          name: 'Folder $i',
          dateCreated: DateTime.utc(2026, 1, 1 + i % 28),
          parentID: switch (random.nextInt(4)) {
            0 => null,
            1 => 'gone-${random.nextInt(3)}',
            _ => 'f${random.nextInt(60)}',
          },
        ),
    ];
    final strategies = [
      for (var i = 0; i < 400; i++)
        strategy(
          id: 's$i',
          name: 'Strategy $i',
          folderID: switch (random.nextInt(8)) {
            0 => null,
            1 => 'gone-folder',
            _ => 'f${random.nextInt(60)}',
          },
          lastEdited: DateTime.utc(2026, 2, 1).add(
            Duration(hours: random.nextInt(2000)),
          ),
        ),
    ];

    List<String> fullScan(Folder root) {
      final ids = <String>{};
      final pending = [root];
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        if (!ids.add(current.id)) continue;
        pending.addAll(folders.where((item) => item.parentID == current.id));
      }
      return [
        for (final item in strategies)
          if (ids.contains(item.folderID)) item.id,
      ];
    }

    final index = LocalFolderIndex(folders: folders, strategies: strategies);
    for (final item in folders) {
      expect(
        index.strategiesInTree(item).map((strategy) => strategy.id),
        fullScan(item),
        reason: item.id,
      );
      expect(
        index.childFolderCount(item.id),
        folders.where((child) => child.parentID == item.id).length,
        reason: item.id,
      );
    }
  });
}
