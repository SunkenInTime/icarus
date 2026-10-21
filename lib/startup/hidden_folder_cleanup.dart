import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';

const _doneKey = 'hiddenFoldersDeleted';

/// Deletes, once, the folders earlier deletes left hidden on this device
/// (see [FolderProvider.deleteHiddenFolders]). Once only: a folder hidden by
/// some future bug stays on disk, where a fix can still bring it back.
Future<void> deleteFoldersHiddenByEarlierDeletes(
  ProviderContainer container,
) async {
  final box = await Hive.openBox<bool>(HiveBoxNames.libraryCleanupBox);
  if (box.get(_doneKey) == true) return;
  try {
    final result =
        await container.read(folderProvider.notifier).deleteHiddenFolders();
    AppErrorReporter.reportInfo(
      'Deleted ${result.deleted} folders earlier deletes left hidden',
      source: 'startup.hiddenFolders',
    );
    if (result.allWent) await box.put(_doneKey, true);
  } catch (error, stackTrace) {
    // Tried again next launch. The library opens either way.
    AppErrorReporter.reportError(
      "Couldn't delete the folders earlier deletes left hidden",
      source: 'startup.hiddenFolders',
      error: error,
      stackTrace: stackTrace,
      promptUser: false,
    );
  }
}
