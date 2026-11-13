import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/providers/collab/move_to_cloud_provider.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Tracks the live route stack so [MouseNavigation] can tell what is on top:
/// the library, the strategy view, a dialog, or an auxiliary screen.
final MouseNavigationRouteObserver mouseNavigationRouteObserver =
    MouseNavigationRouteObserver();

class MouseNavigationRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> _stack = [];

  Route<dynamic>? get topRoute => _stack.isEmpty ? null : _stack.last;

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
  }

  @override
  void dispose() {
    _folderSub?.close();
    _strategySub?.close();
    _sharedStrategySub?.close();
    super.dispose();
  }

  _NavLocation _deriveLocation() {
    final strategy = ref.read(strategyProvider);
    if (strategy.stratName != null) {
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
          // Folder or strategy has been deleted since; drop the stale entry.
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
            Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
                    .get(strategyId) !=
                null;
      case _StrategyLocation(source: StrategySource.cloud):
        return ref.read(isCloudWorkspaceAvailableProvider);
    }
  }

  Future<bool> _navigateTo(_NavLocation target) async {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null || !mounted) return false;

    final bool inStrategyRoute =
        mouseNavigationRouteObserver.topRoute?.settings.name ==
            Routes.strategyView;
    final bool strategyOpen = ref.read(strategyProvider).stratName != null;

    switch (target) {
      case _FolderLocation(:final folderId):
        if (strategyOpen || inStrategyRoute) {
          final bool left = await guardUnsavedStrategyExit(
            context: navigator.context,
            ref: ref,
            source: 'MouseNavigation.navigateToFolder',
            onContinue: () async {
              _resetStrategyUiState();
              await ref.read(strategyProvider.notifier).clearCurrentStrategy();
              if (inStrategyRoute && navigator.mounted) {
                navigator.pop();
              }
            },
          );
          if (!left || !mounted) return false;
        }
        ref.read(folderProvider.notifier).updateID(folderId);
        return true;

      case _StrategyLocation(:final strategyId, :final source):
        if (strategyOpen) {
          // Already in the strategy view; swap strategies in place, exactly
          // like the quick switcher does.
          // An open that gave way to a newer one (or to a close) did not
          // move here, and history must not record that it did.
          var opened = false;
          final bool switched = await guardUnsavedStrategyExit(
            context: navigator.context,
            ref: ref,
            source: 'MouseNavigation.navigateToStrategy',
            onContinue: () async {
              _resetStrategyUiState();
              final strategies = ref.read(strategyProvider.notifier);
              opened = switch (source) {
                StrategySource.local =>
                  await strategies.loadFromHive(strategyId),
                StrategySource.cloud =>
                  await _openCloudInPlace(strategyId, navigator),
              };
            },
          );
          return switched && opened && mounted;
        }

        if (source == StrategySource.cloud) {
          unawaited(
            navigator.push(
              StrategyView.route(
                initialStrategyId: strategyId,
                initialStrategySource: StrategySource.cloud,
              ),
            ),
          );
          return true;
        }
        final strategy =
            Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategyId);
        if (strategy == null) return false;
        unawaited(
          navigator.push(
            StrategyView.route(
              initialStrategyId: strategy.id,
              initialStrategyName: strategy.name,
              initialStrategySource: StrategySource.local,
              initialMapValue: strategy.mapData,
              initialIsAttack:
                  strategy.pages.isEmpty || strategy.pages.first.isAttack,
            ),
          ),
        );
        return true;
    }
  }

  /// Opens a cloud strategy in the editor that is showing another one. The
  /// open lets go of the one on screen before it reads the new one, so when
  /// that read fails there is nothing to stay on: the reader is told and
  /// goes back to the library, as when a strategy fails to open from there.
  Future<bool> _openCloudInPlace(
    String strategyId,
    NavigatorState navigator,
  ) async {
    final strategies = ref.read(strategyProvider.notifier);
    try {
      return await strategies.openCloudStrategy(strategyId);
    } catch (error, stackTrace) {
      AppErrorReporter.reportWarning(
        'Opening a cloud strategy over the open one failed.',
        source: 'MouseNavigation.openCloudInPlace',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return false;
      // Access taken away, or a share link disabled: the editor says which
      // and leads out itself (see StrategyAccessWatcher and StrategyView).
      final failure = ref.read(remoteEditorSnapshotProvider).error;
      if (ref.read(strategyAccessLostProvider) ||
          (failure != null && isShareLinkRevokedError(failure))) {
        return false;
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
      await strategies.clearCurrentStrategy();
      if (navigator.mounted &&
          mouseNavigationRouteObserver.topRoute?.settings.name ==
              Routes.strategyView) {
        navigator.pop();
      }
      return false;
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
