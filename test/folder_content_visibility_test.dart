import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
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
}
