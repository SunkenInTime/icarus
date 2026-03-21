import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/folder_provider.dart';

final cloudFoldersProvider =
    StreamProvider.autoDispose<List<CloudFolderSummary>>((ref) {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    return Stream<List<CloudFolderSummary>>.value(const []);
  }

  final parentFolderId = ref.watch(folderProvider);
  final repo = ref.watch(convexStrategyRepositoryProvider);
  final source = repo.watchFoldersForParent(parentFolderId);
  return _recoverInvalidFolderScope<List<CloudFolderSummary>>(
    ref: ref,
    folderId: parentFolderId,
    source: source,
    emptyValue: const <CloudFolderSummary>[],
  );
});

final cloudStrategiesProvider =
    StreamProvider.autoDispose<List<CloudStrategySummary>>((ref) {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    return Stream<List<CloudStrategySummary>>.value(const []);
  }

  final folderId = ref.watch(folderProvider);
  final repo = ref.watch(convexStrategyRepositoryProvider);
  final source = repo.watchStrategiesForFolder(folderId);
  return _recoverInvalidFolderScope<List<CloudStrategySummary>>(
    ref: ref,
    folderId: folderId,
    source: source,
    emptyValue: const <CloudStrategySummary>[],
  );
});

Stream<T> _recoverInvalidFolderScope<T>({
  required Ref ref,
  required String? folderId,
  required Stream<T> source,
  required T emptyValue,
}) {
  if (folderId == null) {
    return source;
  }

  return Stream.multi((controller) {
    late final StreamSubscription<T> subscription;
    subscription = source.listen(
      controller.add,
      onError: (Object error, StackTrace stackTrace) {
        if (_isInvalidFolderError(error)) {
          ref.read(folderProvider.notifier).clearID();
          controller.add(emptyValue);
          return;
        }
        if (isConvexUnauthenticatedError(error)) {
          unawaited(
            ref.read(authProvider.notifier).reportConvexUnauthenticated(
                  source: 'remote_library:folder_scope',
                  error: error,
                  stackTrace: stackTrace,
                ),
          );
          controller.add(emptyValue);
          return;
        }
        controller.addError(error, stackTrace);
      },
      onDone: controller.close,
    );

    controller.onCancel = () => subscription.cancel();
  });
}

bool _isInvalidFolderError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('folder not found') || message.contains('forbidden');
}
