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

  final repo = ref.watch(convexStrategyRepositoryProvider);
  try {
    await for (final folders in repo.watchAllFolders()) {
      yield folders;
    }
  } catch (error, stackTrace) {
    if (isConvexUnauthenticatedError(error)) {
      unawaited(
        ref.read(authProvider.notifier).reportConvexUnauthenticated(
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

final cloudFoldersProvider =
    StreamProvider.autoDispose<List<CloudFolderEntry>>((ref) async* {
  final section = ref.watch(cloudLibrarySectionProvider);
  final parentFolderId = ref.watch(folderProvider);
  final tree = ref.watch(cloudFolderTreeProvider);
  final allFolders = switch (tree) {
    AsyncData(:final value) => value,
    AsyncError(:final error, :final stackTrace) =>
      Error.throwWithStackTrace(error, stackTrace),
    _ => null,
  };
  if (allFolders == null) return;

  final wantsShared = section == CloudLibrarySection.sharedWithMe;
  final scopedFolders = allFolders
      .where((entry) =>
          wantsShared ? entry.role != 'owner' : entry.role == 'owner')
      .toList(growable: false);
  if (parentFolderId != null &&
      !scopedFolders.any((entry) => entry.folder.id == parentFolderId)) {
    ref
        .read(folderProvider.notifier)
        .updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
    yield const <CloudFolderEntry>[];
    return;
  }
  yield scopedFolders
      .where((entry) => entry.folder.parentID == parentFolderId)
      .toList(growable: false);
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
      ref
          .read(folderProvider.notifier)
          .updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
      yield const <CloudStrategyEntry>[];
      return;
    }
    if (isConvexUnauthenticatedError(error)) {
      unawaited(
        ref.read(authProvider.notifier).reportConvexUnauthenticated(
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
