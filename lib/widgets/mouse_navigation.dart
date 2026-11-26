import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/strategy/local_library_view.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/collab/community_repository.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/move_to_cloud_provider.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:icarus/strategy_view.dart';
import 'package:icarus/widgets/community/community_link.dart';
import 'package:icarus/widgets/community/community_post_view.dart';
import 'package:icarus/widgets/community/open_community_post.dart';
import 'package:icarus/widgets/strategy_look.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Tracks the live route stack so [MouseNavigation] can tell what is on top:
/// the library, the strategy view, a dialog, or an auxiliary screen.
final MouseNavigationRouteObserver mouseNavigationRouteObserver =
    MouseNavigationRouteObserver();

class MouseNavigationRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> _stack = [];

  Route<dynamic>? get topRoute => _stack.isEmpty ? null : _stack.last;

  Route<dynamic>? get editorRoute => _stack
      .where((route) => route.settings.name == Routes.strategyView)
      .lastOrNull;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index == -1) {
      if (newRoute != null) _stack.add(newRoute);
      return;
    }
    if (newRoute == null) {
      _stack.removeAt(index);
    } else {
      _stack[index] = newRoute;
    }
  }
}

/// A place the user can be while browsing their library: a folder (null id is
/// the library root) or an open strategy.
sealed class _NavLocation {
  const _NavLocation();
}

class _FolderLocation extends _NavLocation {
  const _FolderLocation(this.folderId);

  final String? folderId;

  @override
  bool operator ==(Object other) =>
      other is _FolderLocation && other.folderId == folderId;

  @override
  int get hashCode => Object.hash(_FolderLocation, folderId);
}

class _StrategyLocation extends _NavLocation {
  const _StrategyLocation(this.strategyId, this.source);

  final String strategyId;

  /// Where the strategy was opened from. A local and a cloud strategy can
  /// share an id, so history reopens it through the same store.
  final StrategySource source;

  @override
  bool operator ==(Object other) =>
      other is _StrategyLocation &&
      other.strategyId == strategyId &&
      other.source == source;

  @override
  int get hashCode => Object.hash(_StrategyLocation, strategyId, source);
}

/// A Community post open over the library. Its strategy is the post's copy,
/// which only the post can open, so history reopens the post.
class _PostLocation extends _NavLocation {
  const _PostLocation(this.postPublicId);

  final String postPublicId;

  @override
  bool operator ==(Object other) =>
      other is _PostLocation && other.postPublicId == postPublicId;

  @override
  int get hashCode => Object.hash(_PostLocation, postPublicId);
}

/// Makes the mouse side buttons (back/forward) walk the user's browsing
/// history, browser-style: folders visited in the library and strategies
/// opened. Back from an open strategy returns to the library (respecting the
/// unsaved-changes guard); forward re-opens it.
class MouseNavigation extends ConsumerStatefulWidget {
  const MouseNavigation({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MouseNavigation> createState() => _MouseNavigationState();
}

class _MouseNavigationState extends ConsumerState<MouseNavigation> {
  static const int _maxHistoryEntries = 50;

  final List<_NavLocation> _backStack = [];
  final List<_NavLocation> _forwardStack = [];
  _NavLocation _currentLocation = const _FolderLocation(null);
  bool _isNavigating = false;

  ProviderSubscription<String?>? _folderSub;
  ProviderSubscription<StrategyState>? _strategySub;
  ProviderSubscription<String?>? _sharedStrategySub;
  ProviderSubscription<String?>? _communityPostSub;

  @override
  void initState() {
    super.initState();
    _folderSub = ref.listenManual(
      folderProvider,
      (_, __) => _recordLocationChange(),
    );
    _strategySub = ref.listenManual(
      strategyProvider,
      (_, __) => _recordLocationChange(),
    );
    // A redeemed share link opens its strategy the way any other navigation
    // does here: guarded when an editor is open, recorded in history.
    _sharedStrategySub = ref.listenManual(
      sharedStrategyToOpenProvider,
      (_, strategyPublicId) {
        if (strategyPublicId == null) return;
        ref.read(sharedStrategyToOpenProvider.notifier).state = null;
        unawaited(_navigateTo(
          _StrategyLocation(strategyPublicId, StrategySource.cloud),
        ));
      },
    );
    _communityPostSub = ref.listenManual(
      communityPostToOpenProvider,
      (_, postPublicId) {
        if (postPublicId == null) return;
        ref.read(communityPostToOpenProvider.notifier).state = null;
        unawaited(_openCommunityPostLink(postPublicId));
      },
      fireImmediately: true,
    );
  }

  Future<void> _authSettled() async {
    bool settled(AppAuthState auth) =>
        !auth.isLoading && (!auth.isAuthenticated || auth.isConvexUserReady);
    if (settled(ref.read(authProvider))) return;
    final done = Completer<void>();
    final sub = ref.listenManual(authProvider, (_, auth) {
      if (settled(auth) && !done.isCompleted) done.complete();
    });
    await done.future.timeout(const Duration(seconds: 10), onTimeout: () {});
    sub.close();
  }

  /// Opens the post a link names over the Community tab. False when it
  /// didn't open: the user stayed where they were, or the post is gone.
  Future<bool> _openCommunityPostLink(String postPublicId) async {
    final arrived = ref.read(strategyProvider.notifier).askedByTheUserNow();
    final navigator = appNavigatorKey.currentState;
    if (navigator == null || !mounted) return false;
    final left =
        await _leaveOpenStrategy(navigator, 'openCommunityPost', arrived);
    if (left == null) return false;
    ref.read(libraryNavigationProvider).showCommunity();
    // A reviewer sees a hidden post only once the server knows who they
    // are, so a link the app opened with waits for sign-in to settle.
    await _authSettled();
    if (!mounted) return false;
    final l10n = ref.read(l10nProvider);
    final ({CommunityPost post, CommunityPostStatus status})? found;
    try {
      found =
          await ref.read(communityRepositoryProvider).fetchPost(postPublicId);
    } catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        'Reading a linked Community post failed.',
        source: 'MouseNavigation.openCommunityPost',
        error: error,
        stackTrace: stackTrace,
      );
      Settings.showToast(
        message: l10n.communityLoadFailedTitle,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      return false;
    }
    if (!mounted) return false;
    if (found == null || found.status == CommunityPostStatus.removed) {
      Settings.showToast(
        message: l10n.communityPostTakenDown,
        backgroundColor: Settings.tacticalVioletTheme.secondary,
      );
      return false;
    }
    // A strategy opened during the waits above is left the same way, so the
    // post never opens over work that isn't saved.
    final leftAgain =
        await _leaveOpenStrategy(navigator, 'openCommunityPost', left);
    if (leftAgain == null) return false;
    // Not waited for: it ends when the post is closed.
    unawaited(
      openCommunityPost(
        ref,
        found.post,
        asked: leftAgain,
        underReview: found.status == CommunityPostStatus.hidden,
      ),
    );
    return true;
  }

  /// Leaves the strategy or Community post that is open, if one is, asking
  /// first when it has unsaved work. Null when the user stays in it.
  Future<OpenSeen?> _leaveOpenStrategy(
    NavigatorState navigator,
    String source,
    OpenSeen asked,
  ) async {
    final editor = mouseNavigationRouteObserver.editorRoute;
    final bool strategyOpen = ref.read(strategyProvider).stratName != null;
    if (!strategyOpen && editor == null) return mounted ? asked : null;
    final answer = await guardUnsavedStrategyExit(
      context: navigator.context,
      ref: ref,
      source: 'MouseNavigation.$source',
    );
    switch (answer) {
      case Stay():
        return null;
      case Leave(:final seen):
        switch (
            ref.read(strategyProvider.notifier).closeStrategy(asked: seen)) {
          case GaveWay():
            return null;
          case Changed(:final after):
            _resetStrategyUiState();
            _closeEditor(navigator, editor);
            forgetCommunityPost(ref, null);
            return mounted ? after : null;
        }
    }
  }

  void _closeEditor(NavigatorState navigator, Route<dynamic>? editor) {
    if (editor == null || !editor.isActive || !navigator.mounted) return;
    navigator.popUntil((route) => route == editor);
    navigator.pop();
  }

  @override
  void dispose() {
    _folderSub?.close();
    _strategySub?.close();
    _sharedStrategySub?.close();
    _communityPostSub?.close();
    super.dispose();
  }

  /// The Community post open over the library, if the open strategy is its.
  CommunityPost? _openPost() {
    final post = ref.read(communityPostViewProvider);
    final strategy = ref.read(strategyProvider);
    if (post == null || strategy.stratName == null) return null;
    return strategy.id == post.strategyPublicId ? post : null;
  }

  _NavLocation _deriveLocation() {
    final strategy = ref.read(strategyProvider);
    if (strategy.stratName != null) {
      final post = _openPost();
      if (post != null) return _PostLocation(post.publicId);
      return _StrategyLocation(
        strategy.id,
        strategy.source ?? StrategySource.local,
      );
    }
    return _FolderLocation(ref.read(folderProvider));
  }

  /// Records navigation the user performs by any other means (folder tiles,
  /// breadcrumb, opening a strategy, the quick switcher, ...).
  void _recordLocationChange() {
    if (_isNavigating) return;
    final next = _deriveLocation();
    if (next == _currentLocation) return;

    _backStack.add(_currentLocation);
    if (_backStack.length > _maxHistoryEntries) {
      _backStack.removeAt(0);
    }
    _forwardStack.clear();
    _currentLocation = next;
  }

  bool _hasOpenShadMenu() {
    bool found = false;

    void visit(Element element) {
      if (found) return;

      final widget = element.widget;
      if (widget is ShadPopover &&
          (widget.controller?.isOpen ?? widget.visible ?? false)) {
        found = true;
        return;
      }

      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return found;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    final bool isBack = event.buttons & kBackMouseButton != 0;
    final bool isForward = event.buttons & kForwardMouseButton != 0;
    if (!isBack && !isForward) return;

    final topRoute = mouseNavigationRouteObserver.topRoute;
    if (topRoute is PopupRoute || _hasOpenShadMenu()) {
      // A dialog or menu owns the screen; never navigate underneath it.
      return;
    }

    final String? name = topRoute?.settings.name;
    final bool onKnownScreen = topRoute == null ||
        name == Navigator.defaultRouteName ||
        name == Routes.strategyView;
    if (!onKnownScreen) {
      // Auxiliary screens (e.g. the fullscreen image viewer): back closes
      // them, forward is a no-op.
      if (isBack) {
        appNavigatorKey.currentState?.maybePop();
      }
      return;
    }

    if (isBack) {
      unawaited(_goBack());
    } else {
      unawaited(_goForward());
    }
  }

  Future<void> _goBack() => _walkHistory(from: _backStack, to: _forwardStack);

  Future<void> _goForward() =>
      _walkHistory(from: _forwardStack, to: _backStack);

  Future<void> _walkHistory({
    required List<_NavLocation> from,
    required List<_NavLocation> to,
  }) async {
    if (_isNavigating) return;
    _isNavigating = true;
    var arrived = false;
    try {
      while (from.isNotEmpty) {
        final target = from.removeLast();
        if (!_isLocationAvailable(target)) {
          continue;
        }
        final bool moved = await _navigateTo(target);
        if (!moved) {
          // The reader cancelled the unsaved-changes dialog, or the open
          // gave way or failed: the entry stays.
          from.add(target);
          return;
        }
        to.add(_currentLocation);
        _currentLocation = target;
        arrived = true;
        return;
      }
    } finally {
      _isNavigating = false;
      // Nothing was recorded while the walk was under way. One that did not
      // arrive can still end somewhere new: the reader went home, or opened
      // another strategy, while its strategy was loading.
      if (!arrived) _recordLocationChange();
    }
  }

  bool _isLocationAvailable(_NavLocation location) {
    switch (location) {
      case _FolderLocation(:final folderId):
        return folderId == null ||
            ref.read(folderProvider.notifier).findFolderByID(folderId) != null;
      case _StrategyLocation(:final strategyId, source: StrategySource.local):
        return ref.read(platformPolicyProvider).allowsLocalLibrary &&
            // Moving to the cloud, it can't be opened until the move ends.
            !ref.read(movingToCloudProvider).contains(strategyId) &&
            ref.read(localLibraryViewProvider).strategy(strategyId) != null;
      case _StrategyLocation(source: StrategySource.cloud):
        return ref.read(isCloudWorkspaceAvailableProvider);
      case _PostLocation():
        return true;
    }
  }

  Future<bool> _navigateTo(_NavLocation target) async {
    final asked = ref.read(strategyProvider.notifier).askedByTheUserNow();
    final navigator = appNavigatorKey.currentState;
    if (navigator == null || !mounted) return false;

    final editor = mouseNavigationRouteObserver.editorRoute;
    final bool strategyOpen = ref.read(strategyProvider).stratName != null;

    switch (target) {
      case _FolderLocation(:final folderId):
        if (strategyOpen || editor != null) {
          final answer = await guardUnsavedStrategyExit(
            context: navigator.context,
            ref: ref,
            source: 'MouseNavigation.navigateToFolder',
          );
          if (answer is! Leave) return false;
          switch (ref
              .read(strategyProvider.notifier)
              .closeStrategy(asked: answer.seen)) {
            case GaveWay():
              return false;
            case Changed():
              _resetStrategyUiState();
              _closeEditor(navigator, editor);
          }
          if (!mounted) return false;
        }
        ref.read(folderProvider.notifier).updateID(folderId);
        return true;

      case _PostLocation(:final postPublicId):
        // Read again, like a link to it: it may have been taken down since.
        return await _openCommunityPostLink(postPublicId) && mounted;

      case _StrategyLocation(:final strategyId, :final source):
        // A Community post's view is the post's own, so a strategy never
        // swaps into it: the post closes and the strategy opens in its own.
        var over = asked;
        if (_openPost() != null) {
          final left =
              await _leaveOpenStrategy(navigator, 'navigateToStrategy', asked);
          if (left == null) return false;
          over = left;
        } else if (strategyOpen) {
          // Already in the strategy view; swap strategies in place, exactly
          // like the quick switcher does.
          // An open that gave way to a newer one (or to a close) did not
          // move here, and history must not record that it did.
          final answer = await guardUnsavedStrategyExit(
            context: navigator.context,
            ref: ref,
            source: 'MouseNavigation.navigateToStrategy',
          );
          if (answer is! Leave) return false;
          _resetStrategyUiState();
          final opened = switch (source) {
            StrategySource.local => await ref
                .read(strategyProvider.notifier)
                .openLocal(strategyId, asked: answer.seen),
            StrategySource.cloud =>
              await _openCloudInPlace(strategyId, navigator, answer.seen),
          };
          return opened is Changed && mounted;
        }

        if (source == StrategySource.cloud) {
          final look = strategyLookFor(ref, strategyId, StrategySource.cloud);
          unawaited(
            StrategyView.open(
              navigator,
              asked: over,
              initialStrategyId: strategyId,
              initialStrategyName: look.name,
              initialStrategySource: StrategySource.cloud,
              initialMapValue: look.map,
              initialIsAttack: look.isAttack,
            ),
          );
          return true;
        }
        final strategy =
            ref.read(localLibraryViewProvider).strategy(strategyId);
        if (strategy == null) return false;
        unawaited(
          StrategyView.open(
            navigator,
            asked: over,
            initialStrategyId: strategy.id,
            initialStrategyName: strategy.name,
            initialStrategySource: StrategySource.local,
            initialMapValue: strategy.mapData,
            initialIsAttack: strategy.opensOnAttack,
          ),
        );
        return true;
    }
  }

  /// Opens a cloud strategy in the editor that is showing another one. The
  /// open lets go of the one on screen before it reads the new one, so when
  /// that read fails there is nothing to stay on: the reader is told and
  /// goes back to the library, as when a strategy fails to open from there.
  Future<OpenChange> _openCloudInPlace(
    String strategyId,
    NavigatorState navigator,
    OpenSeen asked,
  ) async {
    final strategies = ref.read(strategyProvider.notifier);
    try {
      return await strategies.openCloud(strategyId, asked: asked);
    } catch (error, stackTrace) {
      final now = strategies.askedByTheUserNow();
      final onlyThisOpenSince = now.opens == asked.opens + 1;
      AppErrorReporter.reportWarning(
        'Opening a cloud strategy over the open one failed.',
        source: 'MouseNavigation.openCloudInPlace',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return const GaveWay();
      // Access taken away, or a share link disabled: the editor says which
      // and leads out itself (see StrategyAccessWatcher and StrategyView).
      final failure = ref.read(remoteEditorSnapshotProvider).error;
      if (ref.read(strategyAccessLostProvider) ||
          (failure != null && isShareLinkRevokedError(failure))) {
        return const GaveWay();
      }
      final notKept = failure is StrategyNotKeptOffline;
      Settings.showToast(
        message: notKept
            ? context.l10n.syncStatusStrategyNeedsConnection
            : context.l10n.strategyViewLoadFailed,
        backgroundColor: notKept
            ? Settings.tacticalVioletTheme.secondary
            : Settings.tacticalVioletTheme.destructive,
      );
      if (!onlyThisOpenSince) return const GaveWay();
      switch (strategies.closeStrategy(asked: now)) {
        case GaveWay():
          break;
        case Changed():
          if (navigator.mounted &&
              mouseNavigationRouteObserver.topRoute?.settings.name ==
                  Routes.strategyView) {
            navigator.pop();
          }
      }
      return const GaveWay();
    }
  }

  void _resetStrategyUiState() {
    ref
        .read(interactionStateProvider.notifier)
        .update(InteractionState.navigation);
    ref.read(agentFilterProvider.notifier).updateFilterState(FilterState.all);
    ref.read(deleteMenuProvider.notifier).requestClose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      child: widget.child,
    );
  }
}
