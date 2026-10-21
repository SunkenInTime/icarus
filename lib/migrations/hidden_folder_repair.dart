import 'package:hive_ce/hive.dart';
import 'package:icarus/domain/folder.dart';
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
Future<({int folders, int strategies})> moveOrphansToTopLevel(
  Box<Folder> folders,
  Box<StrategyData> strategies,
) async {
  var movedFolders = 0;
  for (final folder in folders.values.toList()) {
    final parentId = folder.parentID;
    if (parentId == null || folders.containsKey(parentId)) continue;
    folder.parentID = null;
    await folder.save();
    movedFolders++;
  }
  var movedStrategies = 0;
  for (final strategy in strategies.values.toList()) {
    final folderId = strategy.folderID;
    if (folderId == null || folders.containsKey(folderId)) continue;
    strategy.folderID = null;
    await strategy.save();
    movedStrategies++;
  }
  return (folders: movedFolders, strategies: movedStrategies);
}
