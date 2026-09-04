import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';

final cloudFolderTreeProvider =
    StreamProvider.autoDispose<List<CloudFolderEntry>>((ref) async* {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    yield const <CloudFolderEntry>[];
    return;
  }

  final authNotifier = ref.read(authProvider.notifier);
  final repo = ref.watch(convexStrategyRepositoryProvider);
  try {
    await for (final folders in repo.watchAllFolders()) {
      yield folders;
    }
  } catch (error, stackTrace) {
    if (isConvexUnauthenticatedError(error)) {
      unawaited(
        authNotifier.reportConvexUnauthenticated(
          source: 'remote_library:folder_tree',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      yield const <CloudFolderEntry>[];
      return;
    }
    rethrow;
  }
});

// This is the same cached provider, retained for the widgets whose concern is
// the complete tree rather than the current folder's children.
final cloudAllFoldersProvider = cloudFolderTreeProvider;

/// The folders at the open level of the cloud library, derived from the
/// tree. A plain derivation (not a second stream) so the tree never loses its
/// listener between rebuilds; an auto-disposed tree that re-subscribes on
/// every emission looks like a library that never finishes loading.
final cloudFoldersProvider =
    Provider.autoDispose<AsyncValue<List<CloudFolderEntry>>>((ref) {
  final section = ref.watch(cloudLibrarySectionProvider);
  final parentFolderId = ref.watch(folderProvider);
  final folderNotifier = ref.read(folderProvider.notifier);
  return ref.watch(cloudFolderTreeProvider).whenData((allFolders) {
    final wantsShared = section == CloudLibrarySection.sharedWithMe;
    final scopedFolders = allFolders
        .where((entry) =>
            wantsShared ? entry.role != 'owner' : entry.role == 'owner')
        .toList(growable: false);
    if (parentFolderId != null &&
        !scopedFolders.any((entry) => entry.folder.id == parentFolderId)) {
      // The open folder is not in this scope (deleted elsewhere, or it is a
      // local folder while My Library shows both stores). Clear the cloud
      // slot once this build settles.
      Future.microtask(() {
        folderNotifier.updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
      });
      return const <CloudFolderEntry>[];
    }
    return scopedFolders
        .where((entry) => entry.folder.parentID == parentFolderId)
        .toList(growable: false);
  });
});

final cloudStrategiesProvider =
    StreamProvider.autoDispose<List<CloudStrategyEntry>>((ref) async* {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    yield const <CloudStrategyEntry>[];
    return;
  }

  final section = ref.watch(cloudLibrarySectionProvider);
  final folderId = ref.watch(folderProvider);
  final folderNotifier = ref.read(folderProvider.notifier);
  final authNotifier = ref.read(authProvider.notifier);
  final repo = ref.watch(convexStrategyRepositoryProvider);
  try {
    final stream = section == CloudLibrarySection.sharedWithMe
        ? (folderId == null
            ? repo.watchSharedStrategies()
            : repo.watchStrategiesForFolder(folderId, scope: 'shared'))
        : repo.watchStrategiesForFolder(folderId, scope: 'owned');
    await for (final strategies in stream) {
      yield strategies;
    }
  } catch (error, stackTrace) {
    if (section != CloudLibrarySection.sharedWithMe &&
        _isInvalidFolderError(error)) {
      folderNotifier.updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
      yield const <CloudStrategyEntry>[];
      return;
    }
    if (isConvexUnauthenticatedError(error)) {
      unawaited(
        authNotifier.reportConvexUnauthenticated(
          source: 'remote_library:strategies',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      yield const <CloudStrategyEntry>[];
      return;
    }
    rethrow;
  }
});

bool _isInvalidFolderError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('folder not found') || message.contains('forbidden');
}
