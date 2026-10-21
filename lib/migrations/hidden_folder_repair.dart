import 'package:hive_ce/hive.dart';
import 'package:icarus/domain/folder.dart';

/// Puts every local folder whose parent no longer exists at the top level of
/// the library, with everything in it, and returns how many it moved.
///
/// The library lists a folder only under its parent, so such a folder never
/// showed. Deleting a folder used to leave its subfolders behind this way,
/// and an older import could leave a folder under a cloud parent that never
/// arrived here. Their strategies were still on disk, and could still be
/// opened from the editor's strategy switcher. Nothing is deleted. A folder
/// whose parent exists is left where it is, parent loops included.
Future<int> showFoldersWithMissingParent(Box<Folder> folders) async {
  var shown = 0;
  for (final folder in folders.values.toList()) {
    final parentId = folder.parentID;
    if (parentId == null || folders.containsKey(parentId)) continue;
    folder.parentID = null;
    await folder.save();
    shown++;
  }
  return shown;
}
