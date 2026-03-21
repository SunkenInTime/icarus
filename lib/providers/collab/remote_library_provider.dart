import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/debug/agent_debug_log.dart';
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
  // #region agent log
  writeAgentDebugLog(
    hypothesisId: 'A',
    location: 'remote_library_provider.dart:cloudFoldersProvider',
    message: 'cloud folders query start',
    data: {
      'isCloud': isCloud,
      'hasAuthIncident': auth.hasActiveAuthIncident,
      'convexReady': auth.isConvexUserReady,
      'convexStatus': auth.convexAuthStatus.name,
      'parentFolderId': parentFolderId,
    },
  );
  // #endregion
  try {
    final folders = await repo.listFoldersForParent(parentFolderId);
    // #region agent log
    writeAgentDebugLog(
      hypothesisId: 'C',
      location: 'remote_library_provider.dart:cloudFoldersProvider',
      message: 'cloud folders query success',
      data: {
        'parentFolderId': parentFolderId,
        'count': folders.length,
      },
    );
    // #endregion
    return folders;
  } catch (error, stackTrace) {
    // #region agent log
    writeAgentDebugLog(
      hypothesisId: 'C',
      location: 'remote_library_provider.dart:cloudFoldersProvider',
      message: 'cloud folders query error',
      data: {
        'parentFolderId': parentFolderId,
        'error': error.toString(),
      },
    );
    // #endregion
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
  // #region agent log
  writeAgentDebugLog(
    hypothesisId: 'B',
    location: 'remote_library_provider.dart:cloudStrategiesProvider',
    message: 'cloud strategies query start',
    data: {
      'isCloud': isCloud,
      'hasAuthIncident': auth.hasActiveAuthIncident,
      'convexReady': auth.isConvexUserReady,
      'convexStatus': auth.convexAuthStatus.name,
      'folderId': folderId,
    },
  );
  // #endregion
  try {
    final strategies = await repo.listStrategiesForFolder(folderId);
    // #region agent log
    writeAgentDebugLog(
      hypothesisId: 'C',
      location: 'remote_library_provider.dart:cloudStrategiesProvider',
      message: 'cloud strategies query success',
      data: {
        'folderId': folderId,
        'count': strategies.length,
      },
    );
    // #endregion
    return strategies;
  } catch (error, stackTrace) {
    // #region agent log
    writeAgentDebugLog(
      hypothesisId: 'C',
      location: 'remote_library_provider.dart:cloudStrategiesProvider',
      message: 'cloud strategies query error',
      data: {
        'folderId': folderId,
        'error': error.toString(),
      },
    );
    // #endregion
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

bool _isInvalidFolderError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('folder not found') || message.contains('forbidden');
}
