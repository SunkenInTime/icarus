import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/folder_provider.dart';

final cloudFoldersProvider =
    FutureProvider.autoDispose<List<CloudFolderSummary>>((ref) async {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    return const <CloudFolderSummary>[];
  }

  final parentFolderId = ref.watch(folderProvider);
  final repo = ref.watch(convexStrategyRepositoryProvider);
  try {
    return await repo.listFoldersForParent(parentFolderId);
  } catch (error, stackTrace) {
    if (_isInvalidFolderError(error)) {
      ref.read(folderProvider.notifier).clearID();
      return const <CloudFolderSummary>[];
    }
    if (isConvexUnauthenticatedError(error)) {
      unawaited(
        ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: 'remote_library:folders',
              error: error,
              stackTrace: stackTrace,
            ),
      );
      return const <CloudFolderSummary>[];
    }
    rethrow;
  }
});

final cloudStrategiesProvider =
    FutureProvider.autoDispose<List<CloudStrategySummary>>((ref) async {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    return const <CloudStrategySummary>[];
  }

  final folderId = ref.watch(folderProvider);
  final repo = ref.watch(convexStrategyRepositoryProvider);
  try {
    return await repo.listStrategiesForFolder(folderId);
  } catch (error, stackTrace) {
    if (_isInvalidFolderError(error)) {
      ref.read(folderProvider.notifier).clearID();
      return const <CloudStrategySummary>[];
    }
    if (isConvexUnauthenticatedError(error)) {
      unawaited(
        ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: 'remote_library:strategies',
              error: error,
              stackTrace: stackTrace,
            ),
      );
      return const <CloudStrategySummary>[];
    }
    rethrow;
  }
});

final cloudAllFoldersProvider =
    FutureProvider.autoDispose<List<CloudFolderSummary>>((ref) async {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    return const <CloudFolderSummary>[];
  }

  final repo = ref.watch(convexStrategyRepositoryProvider);
  try {
    return await repo.listAllFolders();
  } catch (error, stackTrace) {
    if (isConvexUnauthenticatedError(error)) {
      unawaited(
        ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: 'remote_library:all_folders',
              error: error,
              stackTrace: stackTrace,
            ),
      );
      return const <CloudFolderSummary>[];
    }
    rethrow;
  }
});

bool _isInvalidFolderError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('folder not found') || message.contains('forbidden');
}
