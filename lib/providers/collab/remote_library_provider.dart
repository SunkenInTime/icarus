import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';

final cloudFoldersProvider =
    StreamProvider.autoDispose<List<CloudFolderSummary>>((ref) async* {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    yield const <CloudFolderSummary>[];
    return;
  }

  final parentFolderId = ref.watch(folderProvider);
  final repo = ref.watch(convexStrategyRepositoryProvider);
  try {
    await for (final folders in repo.watchFoldersForParent(parentFolderId)) {
      yield folders;
    }
  } catch (error, stackTrace) {
    if (_isInvalidFolderError(error)) {
      ref
          .read(folderProvider.notifier)
          .updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
      yield const <CloudFolderSummary>[];
      return;
    }
    if (isConvexUnauthenticatedError(error)) {
      unawaited(
        ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: 'remote_library:folders',
              error: error,
              stackTrace: stackTrace,
            ),
      );
      yield const <CloudFolderSummary>[];
      return;
    }
    rethrow;
  }
});

final cloudStrategiesProvider =
    StreamProvider.autoDispose<List<CloudStrategySummary>>((ref) async* {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    yield const <CloudStrategySummary>[];
    return;
  }

  final folderId = ref.watch(folderProvider);
  final repo = ref.watch(convexStrategyRepositoryProvider);
  try {
    await for (final strategies in repo.watchStrategiesForFolder(folderId)) {
      yield strategies;
    }
  } catch (error, stackTrace) {
    if (_isInvalidFolderError(error)) {
      ref
          .read(folderProvider.notifier)
          .updateWorkspaceFolderId(LibraryWorkspace.cloud, null);
      yield const <CloudStrategySummary>[];
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
      yield const <CloudStrategySummary>[];
      return;
    }
    rethrow;
  }
});

final cloudAllFoldersProvider =
    StreamProvider.autoDispose<List<CloudFolderSummary>>((ref) async* {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    yield const <CloudFolderSummary>[];
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
              source: 'remote_library:all_folders',
              error: error,
              stackTrace: stackTrace,
            ),
      );
      yield const <CloudFolderSummary>[];
      return;
    }
    rethrow;
  }
});

bool _isInvalidFolderError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('folder not found') || message.contains('forbidden');
}
