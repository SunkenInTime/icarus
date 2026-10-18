import 'dart:async';
import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/page_changes.dart';
import 'package:icarus/collab/page_made_here.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_copy_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/strategy/copied_page_check.dart';

final remoteEditorSnapshotProvider =
    AsyncNotifierProvider<RemoteEditorSnapshotNotifier, RemoteEditorSnapshot?>(
  RemoteEditorSnapshotNotifier.new,
);

/// The error [remoteEditorSnapshotProvider] holds once the signed-in reader
/// has lost their access to the open strategy: the server refused a fresh
/// read of its shell (FORBIDDEN) after the reader had it open. The owner
/// removed them, or stopped sharing it. Nothing in the editor may change it
/// from then on (see currentStrategyCapabilitiesProvider), and only a read
/// that works again, or opening another strategy, clears it.
class StrategyAccessLost implements Exception {
  const StrategyAccessLost(this.strategyPublicId);

  final String strategyPublicId;

  @override
  String toString() => 'StrategyAccessLost($strategyPublicId)';
}

/// What a reader is told when they open a cloud strategy offline that this
/// computer keeps no copy of.
const strategyNeedsConnectionMessage =
    'This strategy needs a connection the first time you open it.';

/// The error [remoteEditorSnapshotProvider] holds when a cloud strategy is
/// opened while the server can't answer and this computer keeps no copy of
/// it: it has to be opened online once first.
class StrategyNotKeptOffline implements Exception {
  const StrategyNotKeptOffline(this.strategyPublicId);

  final String strategyPublicId;

  @override
  String toString() => 'StrategyNotKeptOffline($strategyPublicId)';
}

/// Owns the editor's bounded live read set: one shell and one active page.
///
/// Every answer it gets from the server is also written to the copy on this
/// computer (see CloudStrategyCopyStore). While the server can't answer,
/// the shell and pages come from that copy instead, marked
/// [RemoteStrategyShell.fromCopy], and the live reads that answer later
/// replace them.
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

  /// The page last checked for images to upload, and the assets it had.
  ({String pageId, Map<String, RemoteImageAsset> assets})? _lastReconciled;

  /// The connection each page answer was received on (see
  /// StrategyOpQueueNotifier.liveStamp), keyed by the answer itself. None for
  /// an answer received while disconnected.
  final Expando<int> _receivedOn = Expando('receivedOn');

  /// Whether [page] is a live server answer received on the connection that
  /// is up now: none since its connection dropped, and none from this
  /// computer's copy. Work made on a page drawn from anything else keeps its
  /// conflict check when sent (see StrategyOp.forSend).
  bool answeredOnCurrentConnection(RemotePageSnapshot? page) {
    if (page == null || page.fromCopy) return false;
    final receivedOn = _receivedOn[page];
    return receivedOn != null && receivedOn == _connectionStamp;
  }

  int? get _connectionStamp =>
      ref.read(strategyOpQueueProvider.notifier).liveStamp;

  /// Records that [page] was received now.
  RemotePageSnapshot _received(RemotePageSnapshot page) {
    final stamp = _connectionStamp;
    if (stamp != null && !page.fromCopy) _receivedOn[page] = stamp;
    return page;
  }

  @override
  Future<RemoteEditorSnapshot?> build() async {
    ref.onDispose(_disposeSubscriptions);
    // The server accepts this build again: read what it refused.
    ref.listen<bool>(clientUpgradeRequiredProvider, (previous, next) {
      if (previous == true && !next) unawaited(refresh());
    });
    // Back online: what the copy showed is read live again.
    ref.listen<bool>(cloudOfflineProvider, (previous, next) {
      if (previous == true && !next && _showsCopy) unawaited(refresh());
    });
    return null;
  }

  bool get _showsCopy {
    final current = state.valueOrNull;
    return current != null &&
        (current.shell.fromCopy || (current.activePage?.fromCopy ?? false));
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
    _lastReconciled = null;
    ref.read(strategyOpQueueProvider.notifier).setActiveStrategy(
          strategyPublicId,
          accountId: ref.read(authProvider).user?.id,
        );
    state = const AsyncLoading();

    if (_keepsCopy && _serverCannotAnswer) {
      if (!_showCopy(strategyPublicId)) {
        state = AsyncError(
          StrategyNotKeptOffline(strategyPublicId),
          StackTrace.current,
        );
        return;
      }
    } else {
      await _refreshFromServer();
    }
    await _startShellSubscription(strategyPublicId);
    final pageId = _activePagePublicId;
    if (pageId != null) {
      await _startPageSubscription(strategyPublicId, pageId);
    }
    final opened = state.valueOrNull;
    if (opened != null &&
        !opened.shell.fromCopy &&
        _copyScope != null &&
        _activeStrategyPublicId == strategyPublicId) {
      ref
          .read(strategyCopyRefresherProvider.notifier)
          .keepOpenedStrategy(strategyPublicId);
    }
  }

  /// Reads [pagePublicId] of the open strategy without making it the active
  /// page, so a page the server can't send leaves the active one as it was.
  /// Throws when the page can't be read: at once while the connection is
  /// down, rather than after the read's timeout.
  Future<RemotePageSnapshot> fetchPage(String pagePublicId) async {
    final strategyPublicId = _activeStrategyPublicId;
    if (strategyPublicId == null) {
      throw StateError('No cloud strategy is open.');
    }
    final shell = _shellOf(strategyPublicId);
    final madeHere = shell == null
        ? null
        : _pageMadeHere(strategyPublicId, shell, pagePublicId);
    if (madeHere != null) return madeHere;
    // Without a copy, as before there was one: no wait for the read to time
    // out while the connection is down.
    if (!_keepsCopy && !ref.read(convexConnectionSnapshotProvider)) {
      throw StateError('Offline: page $pagePublicId was not read.');
    }
    try {
      return await _readPage(strategyPublicId, pagePublicId);
    } catch (error, stackTrace) {
      if (_readsAsSignedIn && isConvexUnauthenticatedError(error)) {
        unawaited(ref.read(authProvider.notifier).reportConvexUnauthenticated(
              source: 'remote_editor:page_fetch',
              error: error,
              stackTrace: stackTrace,
            ));
      } else {
        ref.read(clientUpgradeRequiredProvider.notifier).noteError(error);
      }
      rethrow;
    }
  }

  /// Makes [pagePublicId] the active page and reads it, unless [fetched]
  /// already holds it (see [fetchPage]).
  Future<RemotePageSnapshot?> setActivePage(
    String? pagePublicId, {
    RemotePageSnapshot? fetched,
  }) async {
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
      final page = fetched != null && fetched.page.publicId == pagePublicId
          ? fetched
          : await _readPage(strategyPublicId, pagePublicId);
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

  /// The pages of [shell] that can open, in the order the pages bar lists
  /// them: this device's page changes drawn over the shell's, without a
  /// page deleted here whose delete has not landed (it is gone from the
  /// list, and must not open for editing) or one not on the server yet.
  List<String> _pagesToOpen(RemoteStrategyShell shell) {
    final queue = ref.read(strategyOpQueueProvider.notifier);
    final listed = drawPages(
      shell.pages,
      queue.pageChangesToDraw(
          RemoteEditorSnapshot(shell: shell, activePage: null)),
    );
    return [
      for (final page in listed)
        if (page.opens) page.publicId,
    ];
  }

  /// Whether [pageId] of [shell] can open (see [_pagesToOpen]): a page of
  /// the shell, or one this computer made that the shell does not list yet
  /// (see [_madeHere]), unless it was deleted here.
  bool _opens(RemoteStrategyShell shell, String pageId) =>
      (shell.pages.any((page) => page.publicId == pageId) ||
          _madeHere(shell, pageId) != null) &&
      !ref.read(strategyOpQueueProvider.notifier).isDeletedHere(pageId);

  /// [pageId] when this device added it and [shell] does not list it: its
  /// add is still waiting, or landed after [shell] was read. With the add,
  /// the page as the pages bar draws it, and its place there.
  ({PageAddOp add, DrawnPage drawn, int index})? _madeHere(
    RemoteStrategyShell shell,
    String pageId,
  ) {
    if (shell.pages.any((page) => page.publicId == pageId)) return null;
    final queue = ref.read(strategyOpQueueProvider.notifier);
    final changes = queue.pageChangesToDraw(
      RemoteEditorSnapshot(shell: shell, activePage: null),
    );
    final add = changes
        .whereType<PageAddOp>()
        .where((add) => add.pagePublicId == pageId)
        .lastOrNull;
    if (add == null) return null;
    final drawn = drawPages(shell.pages, changes);
    final index = drawn.indexWhere((page) => page.publicId == pageId);
    if (index < 0) return null;
    return (add: add, drawn: drawn[index], index: index);
  }

  /// [pageId] as this computer shows it while the server does not have it
  /// (see pageMadeHere), or null when [shell] lists it or it was not made
  /// here. Its pictures are the ones the strategy's other pages show: a
  /// copy shows its original's.
  RemotePageSnapshot? _pageMadeHere(
    String strategyPublicId,
    RemoteStrategyShell shell,
    String pageId,
  ) {
    final made = _madeHere(shell, pageId);
    if (made == null) return null;
    final assets = <String, RemoteImageAsset>{};
    final scope = _copyScope;
    if (scope != null) {
      for (final page in shell.pages) {
        final kept = _copy.readPage(scope, strategyPublicId, page.publicId);
        if (kept != null) assets.addAll(kept.assetsById);
      }
    }
    final shown = state.valueOrNull;
    if (shown != null && shown.header.publicId == strategyPublicId) {
      assets.addAll(shown.assetsById);
    }
    return pageMadeHere(
      strategyPublicId: strategyPublicId,
      add: made.add,
      drawn: made.drawn,
      sortIndex: made.index,
      assetsById: assets,
    );
  }

  /// The shell held for [strategyPublicId], if any.
  RemoteStrategyShell? _shellOf(String strategyPublicId) {
    final current = state.valueOrNull;
    return current != null && current.header.publicId == strategyPublicId
        ? current.shell
        : null;
  }

  /// The page a strategy opens on when the one asked for can't: the first
  /// the pages bar lists.
  String? _firstPageToOpen(RemoteStrategyShell shell) =>
      _pagesToOpen(shell).firstOrNull ?? shell.pages.firstOrNull?.publicId;

  void clear() {
    _activeStrategyPublicId = null;
    _activePagePublicId = null;
    _shareToken = null;
    _lastReconciled = null;
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
    var shellRead = false;
    try {
      final repository = ref.read(convexStrategyRepositoryProvider);
      final scope = _copyScope;
      final shellAskedAt = DateTime.now();
      final shell = await repository.fetchShell(
        strategyPublicId,
        shareToken: _shareToken,
      );
      shellRead = true;
      _keepShell(shell, askedAt: shellAskedAt, scope: scope);
      if (epoch != _readEpoch || _holdsNewerShell(shell)) return;
      var pageId = _activePagePublicId;
      if (pageId == null || !_opens(shell, pageId)) {
        pageId = _firstPageToOpen(shell);
        _activePagePublicId = pageId;
      }
      final pageAskedAt = DateTime.now();
      final read = pageId == null
          ? null
          : _pageMadeHere(strategyPublicId, shell, pageId) ??
              _received(await repository.fetchPageSnapshot(
                strategyPublicId: strategyPublicId,
                pagePublicId: pageId,
                shareToken: _shareToken,
              ));
      if (read != null) _keepPage(read, askedAt: pageAskedAt, scope: scope);
      final page = read == null ? null : _upgraded(read, shell.header.mapData);
      if (epoch != _readEpoch || _holdsNewerShell(shell)) return;
      state = AsyncData(RemoteEditorSnapshot(shell: shell, activePage: page));
      if (page != null) _reconcilePageMedia(page);
    } catch (error, stackTrace) {
      if (epoch != _readEpoch) return;
      if (!shellRead && _refusesOpenStrategy(error, strategyPublicId)) {
        log('Access to strategy $strategyPublicId was removed',
            name: 'remote_editor', error: error, stackTrace: stackTrace);
        _disposeSubscriptions();
        _forgetCopy(strategyPublicId);
        state = AsyncError(StrategyAccessLost(strategyPublicId), stackTrace);
        return;
      }
      if (_keepsCopy &&
          isConvexReadUnanswered(error) &&
          _activeStrategyPublicId == strategyPublicId) {
        log('Remote editor read failed, reading the copy: $error',
            name: 'remote_editor', error: error, stackTrace: stackTrace);
        if (_showCopy(strategyPublicId)) return;
        if (state.valueOrNull == null && state.error is! StrategyAccessLost) {
          state = AsyncError(
            StrategyNotKeptOffline(strategyPublicId),
            stackTrace,
          );
          return;
        }
      }
      _handleReadError(
        source: 'remote_editor:refresh',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Whether [error], from a fresh read of the shell, means the signed-in
  /// reader cannot open [strategyPublicId], the strategy the editor is on:
  /// they lost it while it was open, or are opening one they lost (the
  /// library sends them to review its unsent work). A share link's refusals
  /// are the link's (see [_readsAsSignedIn]).
  bool _refusesOpenStrategy(Object error, String strategyPublicId) {
    return isTypedConvexForbiddenError(error) &&
        _shareToken == null &&
        ref.read(authProvider).isAuthenticated &&
        _activeStrategyPublicId == strategyPublicId;
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
    final scope = _copyScope;
    _shellSubscription = ref
        .read(convexStrategyRepositoryProvider)
        .watchShell(strategyPublicId, shareToken: _shareToken)
        .listen(
      (shell) {
        _keepShell(shell, askedAt: DateTime.now(), scope: scope);
        if (_activeStrategyPublicId != strategyPublicId ||
            ref.read(authProvider).hasActiveAuthIncident) return;
        final current = state.valueOrNull;
        if (_holdsNewerShell(shell)) return;
        state = AsyncData(RemoteEditorSnapshot(
          shell: shell,
          activePage: current?.activePage,
        ));
        final activePageId = _activePagePublicId;
        if (activePageId != null && !_opens(shell, activePageId)) {
          unawaited(setActivePage(_firstPageToOpen(shell)));
        } else if ((current?.activePage?.madeHere ?? false) &&
            shell.pages.any((page) => page.publicId == activePageId)) {
          // The add of the page on screen landed: it is read, and watched,
          // from the server from now on.
          unawaited(refresh());
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
    // A page the server does not have yet has nothing to watch: the shell
    // listing it reads it (see _startShellSubscription).
    final shown = state.valueOrNull?.activePage;
    if (shown != null &&
        shown.madeHere &&
        shown.page.publicId == pagePublicId) {
      return;
    }
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
    final scope = _copyScope;
    _pageSubscription = ref
        .read(convexStrategyRepositoryProvider)
        .watchPageSnapshot(
          strategyPublicId: strategyPublicId,
          pagePublicId: pagePublicId,
          shareToken: _shareToken,
        )
        .listen(
      (page) {
        _keepPage(page, askedAt: DateTime.now(), scope: scope);
        if (epoch != _pageEpoch ||
            _activeStrategyPublicId != strategyPublicId ||
            _activePagePublicId != pagePublicId ||
            ref.read(authProvider).hasActiveAuthIncident) return;
        _replacePage(_received(page));
      },
      onError: (Object error, StackTrace stackTrace) =>
          _handleSubscriptionError(
        source: 'remote_editor:page_subscription',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }

  /// Whether reads would go unanswered right now, so the copy is read
  /// rather than waiting for them to time out.
  bool get _serverCannotAnswer {
    if (ref.read(cloudOfflineProvider)) return true;
    try {
      return !ref.read(convexConnectionSnapshotProvider);
    } catch (_) {
      return false;
    }
  }

  /// The copy this reader keeps, or null when there is none to read or
  /// write: signed out, or reading through a share link.
  CloudCopyScope? get _copyScope =>
      _shareToken == null ? ref.read(cloudCopyScopeProvider) : null;

  CloudStrategyCopyStore get _copy => ref.read(cloudStrategyCopyStoreProvider);

  /// Whether this reader has a copy to fall back on. Where it doesn't (web,
  /// a share link, a run without cloud), every read goes to the server
  /// exactly as before the copy existed.
  bool get _keepsCopy =>
      _copyScope != null && _copy is! UnavailableCloudStrategyCopyStore;

  /// [pagePublicId] of the open strategy, read live, or from the copy when
  /// the server can't answer. Throws when neither has it. Without a copy it
  /// is always read live.
  Future<RemotePageSnapshot> _readPage(
    String strategyPublicId,
    String pagePublicId,
  ) async {
    final shell = _shellOf(strategyPublicId);
    final madeHere = shell == null
        ? null
        : _pageMadeHere(strategyPublicId, shell, pagePublicId);
    if (madeHere != null) return madeHere;
    if (_keepsCopy && _serverCannotAnswer) {
      return _keptPage(strategyPublicId, pagePublicId) ??
          (throw StateError('Offline: page $pagePublicId was not read.'));
    }
    try {
      final scope = _copyScope;
      final askedAt = DateTime.now();
      final page =
          await ref.read(convexStrategyRepositoryProvider).fetchPageSnapshot(
                strategyPublicId: strategyPublicId,
                pagePublicId: pagePublicId,
                shareToken: _shareToken,
              );
      _keepPage(page, askedAt: askedAt, scope: scope);
      return _received(page);
    } catch (error) {
      if (_keepsCopy && isConvexReadUnanswered(error)) {
        final kept = _keptPage(strategyPublicId, pagePublicId);
        if (kept != null) return kept;
      }
      rethrow;
    }
  }

  /// [pagePublicId] as the copy keeps it, if it keeps all of it in a form
  /// this build can draw (see [copiedPageIsDrawable]).
  RemotePageSnapshot? _keptPage(String strategyPublicId, String pagePublicId) {
    final scope = _copyScope;
    if (scope == null) return null;
    final page = _copy.readPage(scope, strategyPublicId, pagePublicId);
    return page != null && copiedPageIsDrawable(page) ? page : null;
  }

  /// Shows [strategyPublicId] from the copy: its shell and the active page,
  /// or its first kept page when the active one is not kept. False, changing
  /// nothing, when the copy can't show it.
  bool _showCopy(String strategyPublicId) {
    final scope = _copyScope;
    if (scope == null) return false;
    final shell = _copy.readShell(scope, strategyPublicId);
    if (shell == null) return false;
    final wanted = _activePagePublicId;
    RemotePageSnapshot? page;
    if (wanted != null && _opens(shell, wanted)) {
      page = _pageMadeHere(strategyPublicId, shell, wanted) ??
          _keptPage(strategyPublicId, wanted);
    }
    for (final candidate in _pagesToOpen(shell)) {
      if (page != null) break;
      page = _keptPage(strategyPublicId, candidate);
    }
    if (page == null) return false;
    _activePagePublicId = page.page.publicId;
    final shown = upgradeRemotePageSnapshot(page, shell.header.mapData);
    state = AsyncData(RemoteEditorSnapshot(shell: shell, activePage: shown));
    _reconcilePageMedia(shown);
    return true;
  }

  /// Keeps [shell] under [scope], the one its read was asked under (see
  /// [CloudCopyScope]): the store refuses it once that session has ended.
  void _keepShell(
    RemoteStrategyShell shell, {
    required DateTime askedAt,
    required CloudCopyScope? scope,
  }) {
    final answer = shell.serverAnswer;
    if (answer == null || scope == null) return;
    _keep(() => _copy.writeShell(
          scope,
          answer,
          askedAt: askedAt,
          arrivedAt: DateTime.now(),
        ));
  }

  /// See [_keepShell].
  void _keepPage(
    RemotePageSnapshot page, {
    required DateTime askedAt,
    required CloudCopyScope? scope,
  }) {
    final answer = page.serverAnswer;
    if (answer == null || scope == null) return;
    _keep(() => _copy.writePage(
          scope,
          page.page.strategyPublicId,
          answer,
          askedAt: askedAt,
          arrivedAt: DateTime.now(),
        ));
  }

  void _forgetCopy(String strategyPublicId) {
    final scope = _copyScope;
    if (scope == null) return;
    _keep(() => _copy.deleteStrategy(scope, strategyPublicId));
  }

  /// The copy is a cache: a write that fails is logged and the editor goes
  /// on.
  void _keep(Future<void> Function() write) {
    void report(Object error, StackTrace stackTrace) =>
        log('Keeping a cloud answer on this computer failed: $error',
            name: 'remote_editor', error: error, stackTrace: stackTrace);
    try {
      unawaited(write().catchError(report));
    } catch (error, stackTrace) {
      report(error, stackTrace);
    }
  }

  void _replacePage(RemotePageSnapshot page) {
    final current = state.valueOrNull;
    if (current == null || page.page.publicId != _activePagePublicId) return;
    state = AsyncData(current.copyWith(
      activePage: _upgraded(page, current.header.mapData),
    ));
    _reconcilePageMedia(page);
  }

  /// [page] as this build draws it, received when [page] was.
  RemotePageSnapshot _upgraded(RemotePageSnapshot page, String mapData) {
    final upgraded = upgradeRemotePageSnapshot(page, mapData);
    final receivedOn = _receivedOn[page];
    if (receivedOn != null) _receivedOn[upgraded] = receivedOn;
    return upgraded;
  }

  void _reconcilePageMedia(RemotePageSnapshot page) {
    if (!_shouldReconcilePageMedia(page)) return;
    final strategyPublicId = _activeStrategyPublicId;
    if (strategyPublicId == null) return;
    unawaited(
      ref.read(cloudMediaUploadQueueProvider.notifier).reconcilePageMedia(
            strategyPublicId: strategyPublicId,
            placedImages: _imagesOn(page),
            assetsById: page.assetsById,
          ),
    );
  }

  /// The images [page] places, as the server has them. Not the canvas's:
  /// a page switch reads the next page while the canvas still shows the one
  /// it leaves, whose pictures the next page's assets don't list.
  static List<PlacedImage> _imagesOn(RemotePageSnapshot page) {
    final images = <PlacedImage>[];
    for (final element in page.elements) {
      if (element.elementType != 'image' || element.deleted) continue;
      try {
        images.add(PlacedImage.fromJson(element.decodedPayload()));
      } catch (_) {
        // The editor skips a malformed image too, so it has nothing to send.
      }
    }
    return images;
  }

  /// Whether [page] needs checking: it is another page than the one last
  /// checked, or its assets changed since.
  bool _shouldReconcilePageMedia(RemotePageSnapshot page) {
    final pageId = page.page.publicId;
    final next = page.assetsById;
    final previous = _lastReconciled;
    if (previous != null &&
        previous.pageId == pageId &&
        previous.assets.length == next.length) {
      var same = true;
      for (final entry in next.entries) {
        final old = previous.assets[entry.key];
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
    _lastReconciled = (pageId: pageId, assets: Map.unmodifiable(next));
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
    // A read that failed for another reason (offline, say) says nothing
    // about access already confirmed gone.
    if (state.error is StrategyAccessLost) return;
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
    // Offline on the copy: coming back online reads again.
    if (_serverCannotAnswer && _showsCopy) return;
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
