import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_filter_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
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
        folder: root,
        allFolders: [root, child],
        allStrategies: [
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
      ),
      DateTime.utc(2026, 1, 5),
    );
  });

  test('empty folder last updated falls back to creation date', () {
    final empty = folder(
      id: 'empty',
      name: 'Empty',
      dateCreated: DateTime.utc(2026, 1, 4),
    );

    expect(
      folderLastUpdated(
        folder: empty,
        allFolders: [empty],
        allStrategies: const [],
      ),
      DateTime.utc(2026, 1, 4),
    );
  });

  test('folders sort by selected folder fields', () {
    final alpha = folder(
      id: 'a',
      name: 'Alpha',
      dateCreated: DateTime.utc(2026, 1, 3),
    );
    final zeta = folder(
      id: 'z',
      name: 'Zeta',
      dateCreated: DateTime.utc(2026, 1, 1),
    );
    final strategies = [
      strategy(
        id: 'latest',
        name: 'Latest',
        folderID: zeta.id,
        lastEdited: DateTime.utc(2026, 1, 6),
      ),
    ];

    expect(
      compareFoldersForSort(
        a: alpha,
        b: zeta,
        sortBy: SortBy.alphabetical,
        allFolders: [alpha, zeta],
        allStrategies: strategies,
      ),
      lessThan(0),
    );
    expect(
      compareFoldersForSort(
        a: alpha,
        b: zeta,
        sortBy: SortBy.dateCreated,
        allFolders: [alpha, zeta],
        allStrategies: strategies,
      ),
      greaterThan(0),
    );
    expect(
      compareFoldersForSort(
        a: alpha,
        b: zeta,
        sortBy: SortBy.dateUpdated,
        allFolders: [alpha, zeta],
        allStrategies: strategies,
      ),
      lessThan(0),
    );
  });
}
