import 'dart:async';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';

final remoteEditorSnapshotProvider =
    AsyncNotifierProvider<RemoteEditorSnapshotNotifier, RemoteEditorSnapshot?>(
  RemoteEditorSnapshotNotifier.new,
);

/// Owns the editor's bounded live read set: one shell and one active page.
class RemoteEditorSnapshotNotifier
    extends AsyncNotifier<RemoteEditorSnapshot?> {
  String? _activeStrategyPublicId;
  String? _activePagePublicId;

  /// The share link the open strategy is read through, when the reader has
  /// no access of their own (see [shareLinkViewProvider]).
  String? _shareToken;
  StreamSubscription<RemoteStrategyShell>? _shellSubscription;
  StreamSubscription<RemotePageSnapshot>? _pageSubscription;
  String? _subscribedPagePublicId;
  Timer? _refreshDebounce;
  int _pageEpoch = 0;

  /// Bumped by every read of the shell and page, and by a page selection:
  /// a read that finishes after a newer one started changes nothing.
  int _readEpoch = 0;
  Map<String, RemoteImageAsset>? _lastReconciledAssetsById;

  @override
  Future<RemoteEditorSnapshot?> build() async {
    ref.onDispose(_disposeSubscriptions);
    return null;
  }

  String? get activeStrategyPublicId => _activeStrategyPublicId;
  String? get activePagePublicId => _activePagePublicId;

  Future<void> openStrategy(
    String strategyPublicId, {
    String? activePagePublicId,
  }) async {
    _disposeSubscriptions();
    _activeStrategyPublicId = strategyPublicId;
    _activePagePublicId = activePagePublicId;
    final linkView = ref.read(shareLinkViewProvider);
    _shareToken =
        linkView?.strategyPublicId == strategyPublicId ? linkView!.token : null;
    _lastReconciledAssetsById = null;
    ref.read(strategyOpQueueProvider.notifier).setActiveStrategy(
          strategyPublicId,
          accountId: ref.read(authProvider).user?.id,
        );
    state = const AsyncLoading();

    await _refreshFromServer();
    await _startShellSubscription(strategyPublicId);
    final pageId = _activePagePublicId;
    if (pageId != null) {
      await _startPageSubscription(strategyPublicId, pageId);
    }
  }

  Future<RemotePageSnapshot?> setActivePage(String? pagePublicId) async {
    final strategyPublicId = _activeStrategyPublicId;
    if (strategyPublicId == null || pagePublicId == _activePagePublicId) {
      return state.valueOrNull?.activePage;
    }

    _activePagePublicId = pagePublicId;
    _readEpoch += 1;
    final epoch = ++_pageEpoch;
    await _pageSubscription?.cancel();
    _pageSubscription = null;
    _subscribedPagePublicId = null;

    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(current.copyWith(clearActivePage: true));
    }
    if (pagePublicId == null) return null;

    try {
      final page =
          await ref.read(convexStrategyRepositoryProvider).fetchPageSnapshot(
                strategyPublicId: strategyPublicId,
                pagePublicId: pagePublicId,
                shareToken: _shareToken,
              );
      if (epoch != _pageEpoch || pagePublicId != _activePagePublicId) {
        return null;
      }
      _replacePage(page);
      await _startPageSubscription(strategyPublicId, pagePublicId);
      return state.valueOrNull?.activePage;
    } catch (error, stackTrace) {
      // A newer selection or read took over; its outcome stands.
      if (epoch != _pageEpoch || pagePublicId != _activePagePublicId) {
        return null;
      }
      _handleReadError(
        source: 'remote_editor:page_refresh',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> refresh() async {
    final strategyPublicId = _activeStrategyPublicId;
    if (strategyPublicId == null) return;
    await _refreshFromServer();
    // A page whose selection failed, or that the refresh moved to, has no
    // live read yet: a read that worked starts one.
    final pageId = _activePagePublicId;
    if (pageId != null &&
        pageId != _subscribedPagePublicId &&
        strategyPublicId == _activeStrategyPublicId &&
        state.valueOrNull?.activePage?.page.publicId == pageId) {
      await _startPageSubscription(strategyPublicId, pageId);
    }
  }

  /// Shows [pagePublicId], which the server has just restored from its
  /// trash, and watches it: read fresh along with the shell, since the shell
  /// last watched may not list it yet.
  Future<void> showRestoredPage(String pagePublicId) async {
    if (_activeStrategyPublicId == null) return;
    _activePagePublicId = pagePublicId;
    await refresh();
  }

  void clear() {
    _activeStrategyPublicId = null;
    _activePagePublicId = null;
    _shareToken = null;
    _lastReconciledAssetsById = null;
    _disposeSubscriptions();
    ref.read(strategyOpQueueProvider.notifier).setActiveStrategy(
          null,
          accountId: ref.read(authProvider).user?.id,
        );
    state = const AsyncData(null);
  }

  Future<void> _refreshFromServer() async {
    final strategyPublicId = _activeStrategyPublicId;
    if (strategyPublicId == null) return;
    if (ref.read(authProvider).hasActiveAuthIncident) {
      state = const AsyncData(null);
      return;
    }

    final epoch = ++_readEpoch;
    try {
      final repository = ref.read(convexStrategyRepositoryProvider);
      final shell = await repository.fetchShell(
        strategyPublicId,
        shareToken: _shareToken,
      );
      if (epoch != _readEpoch || _holdsNewerShell(shell)) return;
      var pageId = _activePagePublicId;
      if (pageId == null ||
          !shell.pages.any((page) => page.publicId == pageId)) {
        pageId = shell.pages.firstOrNull?.publicId;
        _activePagePublicId = pageId;
      }
      final page = pageId == null
          ? null
          : upgradeRemotePageSnapshot(
              await repository.fetchPageSnapshot(
                strategyPublicId: strategyPublicId,
                pagePublicId: pageId,
                shareToken: _shareToken,
              ),
              shell.header.mapData,
            );
      if (epoch != _readEpoch || _holdsNewerShell(shell)) return;
      state = AsyncData(RemoteEditorSnapshot(shell: shell, activePage: page));
      if (page != null) _reconcilePageMedia(page);
    } catch (error, stackTrace) {
      if (epoch != _readEpoch) return;
      _handleReadError(
        source: 'remote_editor:refresh',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Whether the shell held is newer than [shell]: a page just restored, say.
  /// An older shell arriving late, from a read or the live one, must not
  /// undo it.
  bool _holdsNewerShell(RemoteStrategyShell shell) {
    final current = state.valueOrNull;
    return current != null &&
        current.header.publicId == shell.header.publicId &&
        shell.header.revision < current.header.revision;
  }

  Future<void> _startShellSubscription(String strategyPublicId) async {
    await _shellSubscription?.cancel();
    _shellSubscription = ref
        .read(convexStrategyRepositoryProvider)
        .watchShell(strategyPublicId, shareToken: _shareToken)
        .listen(
      (shell) {
        if (_activeStrategyPublicId != strategyPublicId ||
            ref.read(authProvider).hasActiveAuthIncident) return;
        final current = state.valueOrNull;
        if (_holdsNewerShell(shell)) return;
        state = AsyncData(RemoteEditorSnapshot(
          shell: shell,
          activePage: current?.activePage,
        ));
        final activePageId = _activePagePublicId;
        if (activePageId != null &&
            !shell.pages.any((page) => page.publicId == activePageId)) {
          unawaited(setActivePage(shell.pages.firstOrNull?.publicId));
        }
      },
      onError: (Object error, StackTrace stackTrace) =>
          _handleSubscriptionError(
        source: 'remote_editor:shell_subscription',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  Future<void> _startPageSubscription(
    String strategyPublicId,
    String pagePublicId,
  ) async {
    // Claimed before the await: a start that overlaps this one wins, and
    // this one must not install a second watcher.
    final epoch = ++_pageEpoch;
    await _pageSubscription?.cancel();
    if (epoch != _pageEpoch ||
        _activeStrategyPublicId != strategyPublicId ||
        _activePagePublicId != pagePublicId) {
      return;
    }
    _subscribedPagePublicId = pagePublicId;
    _pageSubscription = ref
        .read(convexStrategyRepositoryProvider)
        .watchPageSnapshot(
          strategyPublicId: strategyPublicId,
          pagePublicId: pagePublicId,
          shareToken: _shareToken,
        )
        .listen(
      (page) {
        if (epoch != _pageEpoch ||
            _activeStrategyPublicId != strategyPublicId ||
            _activePagePublicId != pagePublicId ||
            ref.read(authProvider).hasActiveAuthIncident) return;
        _replacePage(page);
      },
      onError: (Object error, StackTrace stackTrace) =>
          _handleSubscriptionError(
        source: 'remote_editor:page_subscription',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  void _replacePage(RemotePageSnapshot page) {
    final current = state.valueOrNull;
    if (current == null || page.page.publicId != _activePagePublicId) return;
    state = AsyncData(current.copyWith(
      activePage: upgradeRemotePageSnapshot(page, current.header.mapData),
    ));
    _reconcilePageMedia(page);
  }

  void _reconcilePageMedia(RemotePageSnapshot page) {
    if (!_shouldReconcilePageMedia(page.assetsById)) return;
    final strategyPublicId = _activeStrategyPublicId;
    if (strategyPublicId == null) return;
    unawaited(
      ref.read(cloudMediaUploadQueueProvider.notifier).reconcilePageMedia(
            strategyPublicId: strategyPublicId,
            placedImages: ref.read(placedImageProvider).images,
            assetsById: page.assetsById,
          ),
    );
  }

  bool _shouldReconcilePageMedia(Map<String, RemoteImageAsset> next) {
    final previous = _lastReconciledAssetsById;
    if (previous != null && previous.length == next.length) {
      var same = true;
      for (final entry in next.entries) {
        final old = previous[entry.key];
        if (old == null ||
            old.publicId != entry.value.publicId ||
            old.url != entry.value.url ||
            old.uploadStatus != entry.value.uploadStatus) {
          same = false;
          break;
        }
      }
      if (same) return false;
    }
    _lastReconciledAssetsById = Map.unmodifiable(next);
    return true;
  }

  void _handleReadError({
    required String source,
    required Object error,
    required StackTrace stackTrace,
  }) {
    if (_readsAsSignedIn && isConvexUnauthenticatedError(error)) {
      unawaited(ref.read(authProvider.notifier).reportConvexUnauthenticated(
            source: source,
            error: error,
            stackTrace: stackTrace,
          ));
      state = const AsyncData(null);
      return;
    }
    ref.read(clientUpgradeRequiredProvider.notifier).noteError(error);
    log('Remote editor read failed: $error',
        name: 'remote_editor', error: error, stackTrace: stackTrace);
    state = AsyncError(error, stackTrace);
  }

  void _handleSubscriptionError({
    required String source,
    required Object error,
    StackTrace? stackTrace,
  }) {
    if (_readsAsSignedIn && isConvexUnauthenticatedError(error)) {
      unawaited(ref.read(authProvider.notifier).reportConvexUnauthenticated(
            source: source,
            error: error,
            stackTrace: stackTrace,
          ));
      return;
    }
    log('Remote editor subscription failed: $error',
        name: 'remote_editor', error: error, stackTrace: stackTrace);
    // A read again would be refused again; the sync button says why.
    if (ref.read(clientUpgradeRequiredProvider.notifier).noteError(error)) {
      return;
    }
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(
      const Duration(milliseconds: 120),
      () => unawaited(_refreshFromServer()),
    );
  }

  /// Whether a refused read means the session broke. A signed-out reader on
  /// a share link has no session to repair: their refusals are the link's
  /// (disabled, or never theirs), and the editor shows those itself.
  bool get _readsAsSignedIn =>
      _shareToken == null || ref.read(authProvider).isAuthenticated;

  void _disposeSubscriptions() {
    _refreshDebounce?.cancel();
    _refreshDebounce = null;
    _pageEpoch += 1;
    unawaited(_shellSubscription?.cancel());
    unawaited(_pageSubscription?.cancel());
    _shellSubscription = null;
    _pageSubscription = null;
    _subscribedPagePublicId = null;
  }
}
