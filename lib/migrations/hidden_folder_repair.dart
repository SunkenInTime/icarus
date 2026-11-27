import 'package:icarus/domain/folder.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_models.dart';

/// Puts every local folder and strategy whose folder no longer exists at the
/// top level of the library, and returns how many of each it moved.
///
/// The library lists a folder only under its parent, so a folder whose
/// parent is gone never showed. Deleting a folder used to leave its
/// subfolders behind this way, and an older import could leave a folder
/// under a cloud parent that never arrived here. Their strategies were still
/// on disk, and could still be opened from the editor's strategy switcher.
/// A strategy whose folder is gone already shows at the top level, but
/// library backups, which walk the tree from the top, left it out; a folder
/// delete that stopped between its two writes can leave one. Nothing is
/// deleted. Anything whose folder exists is left where it is, parent loops
/// included.
Future<({int folders, int strategies})> moveOrphansToTopLevel() async {
  const library = LocalLibrary();
  var movedFolders = 0;
  for (final folder in foldersUnderMissingParents(
      library.storedFolders.toList(), library.holdsFolder)) {
    (await library.moveFolder(folder, null)).orThrow();
    movedFolders++;
  }
  var movedStrategies = 0;
  for (final strategy in strategiesInMissingFolders(
    library.storedStrategies.toList(),
    library.holdsFolder,
  )) {
    (await library.moveStrategy(strategy, null)).orThrow();
    movedStrategies++;
  }
  return (folders: movedFolders, strategies: movedStrategies);
}

Iterable<Folder> foldersUnderMissingParents(
  Iterable<Folder> folders,
  bool Function(String id) holdsFolder,
) =>
    folders.where(
      (folder) => switch (folder.parentID) {
        final parentId? => !holdsFolder(parentId),
        null => false,
      },
    );

Iterable<StrategyData> strategiesInMissingFolders(
  Iterable<StrategyData> strategies,
  bool Function(String id) holdsFolder,
) =>
    strategies.where(
      (strategy) => switch (strategy.folderID) {
        final folderId? => !holdsFolder(folderId),
        null => false,
      },
    );
