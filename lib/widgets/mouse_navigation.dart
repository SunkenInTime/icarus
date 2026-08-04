import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
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
  const _StrategyLocation(this.strategyId);

  final String strategyId;

  @override
  bool operator ==(Object other) =>
      other is _StrategyLocation && other.strategyId == strategyId;

  @override
  int get hashCode => Object.hash(_StrategyLocation, strategyId);
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
  }

  @override
  void dispose() {
    _folderSub?.close();
    _strategySub?.close();
    super.dispose();
  }

  _NavLocation _deriveLocation() {
    final strategy = ref.read(strategyProvider);
    if (strategy.stratName != null) {
      return _StrategyLocation(strategy.id);
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
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;

    final contextMenu =
        focusContext.findAncestorStateOfType<ShadContextMenuState>();
    if (contextMenu?.controller.isOpen ?? false) return true;

    final popover = focusContext.findAncestorWidgetOfExactType<ShadPopover>();
    return popover?.controller?.isOpen ?? popover?.visible ?? false;
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
    try {
      while (from.isNotEmpty) {
        final target = from.removeLast();
        if (!_isLocationAvailable(target)) {
          // Folder or strategy has been deleted since; drop the stale entry.
          continue;
        }
        final bool moved = await _navigateTo(target);
        if (!moved) {
          // The user cancelled the unsaved-changes dialog; keep history as-is.
          from.add(target);
          return;
        }
        to.add(_currentLocation);
        _currentLocation = target;
        return;
      }
    } finally {
      _isNavigating = false;
    }
  }

  bool _isLocationAvailable(_NavLocation location) {
    switch (location) {
      case _FolderLocation(:final folderId):
        return folderId == null ||
            ref.read(folderProvider.notifier).findFolderByID(folderId) != null;
      case _StrategyLocation(:final strategyId):
        return Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
                .get(strategyId) !=
            null;
    }
  }

  Future<bool> _navigateTo(_NavLocation target) async {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null || !mounted) return false;

    final bool inStrategyRoute = mouseNavigationRouteObserver
            .topRoute?.settings.name ==
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

      case _StrategyLocation(:final strategyId):
        if (strategyOpen) {
          // Already in the strategy view; swap strategies in place, exactly
          // like the quick switcher does.
          final bool switched = await guardUnsavedStrategyExit(
            context: navigator.context,
            ref: ref,
            source: 'MouseNavigation.navigateToStrategy',
            onContinue: () async {
              _resetStrategyUiState();
              await ref
                  .read(strategyProvider.notifier)
                  .loadFromHive(strategyId);
            },
          );
          return switched && mounted;
        }

        final strategy = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
            .get(strategyId);
        if (strategy == null) return false;
        unawaited(
          navigator.push(
            StrategyView.route(
              initialStrategyId: strategy.id,
              initialStrategyName: strategy.name,
              initialMapValue: strategy.mapData,
              initialIsAttack:
                  strategy.pages.isEmpty || strategy.pages.first.isAttack,
            ),
          ),
        );
        return true;
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
