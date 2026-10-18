import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';

/// Writes every live answer a list provider gets to this computer's copy,
/// so the list can be shown while the cloud is out of reach. When the socket
/// drops, or the list stops being watched while connected, the last answer
/// is written again as still matching the server at that moment: it held
/// until then. A disconnect ends that: after it, nothing is marked until a
/// fresh answer arrives.
class _LiveCopyWriter<T> {
  _LiveCopyWriter(
    Ref ref, {
    required this.write,
  }) : _connected = ref.read(convexConnectionProvider).valueOrNull ?? false {
    ref.listen<AsyncValue<bool>>(convexConnectionProvider, (_, next) {
      final connected = next.valueOrNull ?? false;
      if (_connected && !connected) {
        _writeLastAnswer();
        _lastAnswer = null;
      }
      _connected = connected;
    });
    ref.onDispose(() {
      if (_connected) _writeLastAnswer();
    });
  }

  final Future<void> Function(
    List<T> entries, {
    required int answerOrder,
    required DateTime matchedAt,
  }) write;
  bool _connected;

  /// The last answer since the socket last connected, with its order.
  ({List<T> entries, int order})? _lastAnswer;

  void answer(List<T> entries) {
    _lastAnswer = (entries: entries, order: nextCloudLibraryAnswerOrder());
    _writeLastAnswer();
  }

  void _writeLastAnswer() {
    final answer = _lastAnswer;
    if (answer == null) return;
    unawaited(
      write(
        answer.entries,
        answerOrder: answer.order,
        matchedAt: DateTime.now(),
      ).catchError(_reportCopyWriteFailure),
    );
  }
}

void _reportCopyWriteFailure(Object error, StackTrace stackTrace) {
  AppErrorReporter.reportWarning(
    "Couldn't update this computer's copy of the cloud library",
    source: 'remote_library:copy',
    error: error,
    stackTrace: stackTrace,
  );
}

final cloudFolderTreeProvider =
    StreamProvider.autoDispose<List<CloudFolderEntry>>((ref) async* {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  final store = ref.watch(cloudLibraryCopyStoreProvider);
  final scope = ref.watch(cloudCopyScopeProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    if (ref.watch(cloudLibraryShowsCopyProvider) && scope != null) {
      yield store.readFolders(scope)?.entries ?? const <CloudFolderEntry>[];
      return;
    }
    yield const <CloudFolderEntry>[];
    return;
  }

  final authNotifier = ref.read(authProvider.notifier);
  final repo = ref.watch(convexStrategyRepositoryProvider);
  final copy = scope == null
      ? null
      : _LiveCopyWriter<CloudFolderEntry>(
          ref,
          write: (folders, {required answerOrder, required matchedAt}) =>
              store.writeFolders(
            scope,
            folders,
            answerOrder: answerOrder,
            matchedAt: matchedAt,
          ),
        );
  try {
    await for (final folders in repo.watchAllFolders()) {
      copy?.answer(folders);
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

/// The strategy list the library has open: My Library's own at the top
/// level or in a folder, or Shared's at its top or in a shared folder.
final cloudStrategyListingProvider = Provider<CloudStrategyListing>((ref) {
  final section = ref.watch(cloudLibrarySectionProvider);
  final folderId = ref.watch(folderProvider);
  return section == CloudLibrarySection.sharedWithMe
      ? CloudStrategyListing.shared(folderId)
      : CloudStrategyListing.owned(folderId);
});

final cloudStrategiesProvider =
    StreamProvider.autoDispose<List<CloudStrategyEntry>>((ref) async* {
  final isCloud = ref.watch(isCloudCollabEnabledProvider);
  final auth = ref.watch(authProvider);
  final store = ref.watch(cloudLibraryCopyStoreProvider);
  final scope = ref.watch(cloudCopyScopeProvider);
  final listing = ref.watch(cloudStrategyListingProvider);
  if (!isCloud || auth.hasActiveAuthIncident) {
    if (ref.watch(cloudLibraryShowsCopyProvider) && scope != null) {
      yield store.readStrategies(scope, listing)?.entries ??
          const <CloudStrategyEntry>[];
      return;
    }
    yield const <CloudStrategyEntry>[];
    return;
  }

  final folderId = listing.folderId;
  final folderNotifier = ref.read(folderProvider.notifier);
  final authNotifier = ref.read(authProvider.notifier);
  final repo = ref.watch(convexStrategyRepositoryProvider);
  final copy = scope == null
      ? null
      : _LiveCopyWriter<CloudStrategyEntry>(
          ref,
          write: (strategies, {required answerOrder, required matchedAt}) =>
              store.writeStrategies(
            scope,
            listing,
            strategies,
            answerOrder: answerOrder,
            matchedAt: matchedAt,
          ),
        );
  try {
    final stream = listing.shared
        ? (folderId == null
            ? repo.watchSharedStrategies()
            : repo.watchStrategiesForFolder(folderId, scope: 'shared'))
        : repo.watchStrategiesForFolder(folderId, scope: 'owned');
    await for (final strategies in stream) {
      copy?.answer(strategies);
      yield strategies;
    }
  } catch (error, stackTrace) {
    if (!listing.shared && _isInvalidFolderError(error)) {
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

/// When the cloud half the library shows from this computer's copy last
/// matched the server: the older of the folder tree and the open strategy
/// list. Null when the library isn't showing the copy, or the copy lacks
/// either of the two.
final cloudLibraryCopyMatchedAtProvider =
    Provider.autoDispose<DateTime?>((ref) {
  if (!ref.watch(cloudLibraryShowsCopyProvider)) return null;
  final scope = ref.watch(cloudCopyScopeProvider);
  if (scope == null) return null;
  final store = ref.watch(cloudLibraryCopyStoreProvider);
  final folders = store.readFolders(scope);
  final strategies =
      store.readStrategies(scope, ref.watch(cloudStrategyListingProvider));
  if (folders == null || strategies == null) return null;
  return folders.matchedAt.isBefore(strategies.matchedAt)
      ? folders.matchedAt
      : strategies.matchedAt;
});

final cloudStrategyNamesProvider = Provider<Map<String, String>>((ref) {
  final strategies = ref.watch(cloudStrategiesProvider).valueOrNull;
  if (strategies == null) return const <String, String>{};
  return <String, String>{
    for (final entry in strategies) entry.strategy.id: entry.strategy.name,
  };
});

bool _isInvalidFolderError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('folder not found') || message.contains('forbidden');
}
