import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart'
    show isShareLinkRevokedError;
import 'package:icarus/const/custom_icons.dart';
import 'package:icarus/const/form_factor.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/share_link_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/open_cloud_strategy_store.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/sidebar.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/canvas_paste.dart';
import 'package:icarus/widgets/delete_capture.dart';
import 'package:icarus/widgets/dot_matrix_loaders.dart';
import 'package:icarus/widgets/strategy_access_watcher.dart';
import 'package:icarus/widgets/strategy_view_skeleton.dart';
import 'package:icarus/widgets/strategy_edit_boundary.dart';
import 'package:icarus/widgets/strategy_quick_switcher.dart';
import 'package:icarus/widgets/touch_strategy_viewer.dart';
import 'package:icarus/widgets/turn_phone_notice.dart';
import 'package:icarus/widgets/map_selector.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:icarus/widgets/pages_bar.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:icarus/collab/community_models.dart';
import 'package:icarus/widgets/community/community_post_view.dart';
import 'package:icarus/widgets/community/community_review.dart';
import 'package:flutter/services.dart';
import 'package:icarus/widgets/strategy_presence.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:icarus/widgets/window_chrome.dart';
import 'package:window_manager/window_manager.dart';
import 'package:icarus/widgets/editor_operation_scope.dart';
import 'package:icarus/widgets/eased_route_transition.dart';

class StrategyView extends ConsumerStatefulWidget {
  const StrategyView({
    super.key,
    this.initialStrategyId,
    this.initialStrategyName,
    this.initialStrategySource = StrategySource.local,
    this.initialMapValue,
    this.initialIsAttack = true,
    this.initialPageId,
    this.backTooltip,
    this.communityPost,
    this.startExpanded = false,
  });

  final String? initialStrategyId;
  final String? initialStrategyName;
  final StrategySource initialStrategySource;
  final MapValue? initialMapValue;
  final bool initialIsAttack;

  /// The page to open on; the first when null.
  final String? initialPageId;

  /// Set when the editor was opened from somewhere other than the library
  /// (a replay's Capture): leaving goes back there, so the leading button is
  /// a back arrow with this tooltip instead of the house.
  final String? backTooltip;

  /// Set when the strategy is a Community post, read through its token
  /// (see showCommunityPost): the editor shows the post's controls instead
  /// of an editor's, first as a quick look over the Community tab.
  final CommunityPost? communityPost;

  /// Opens [communityPost] at full screen instead of as a quick look.
  final bool startExpanded;

  /// A Community post over the tab it was opened from: a sheet first, that
  /// opens out to the full view-only editor in place.
  static PageRoute<void> communityRoute(
    CommunityPost post, {
    bool expanded = false,
  }) {
    return PageRouteBuilder<void>(
      settings: const RouteSettings(name: Routes.strategyView),
      opaque: false,
      barrierColor: const Color(0x99000000),
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, animation, _) => StrategyView(
        initialStrategyId: post.strategyPublicId,
        initialStrategyName: post.title,
        initialStrategySource: StrategySource.cloud,
        initialMapValue: post.map,
        initialIsAttack: post.side != CommunitySide.defense,
        communityPost: post,
        startExpanded: expanded,
      ),
      transitionsBuilder: (context, animation, _, child) =>
          EasedRouteTransition(
        animation: animation,
        scaleFrom: 0.98,
        child: child,
      ),
    );
  }

  static PageRoute<void> route({
    String? initialStrategyId,
    String? initialStrategyName,
    StrategySource initialStrategySource = StrategySource.local,
    MapValue? initialMapValue,
    bool initialIsAttack = true,
    String? initialPageId,
    String? backTooltip,
  }) {
    return PageRouteBuilder<void>(
      settings: const RouteSettings(name: Routes.strategyView),
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, animation, _) => StrategyView(
        initialStrategyId: initialStrategyId,
        initialStrategyName: initialStrategyName,
        initialStrategySource: initialStrategySource,
        initialMapValue: initialMapValue,
        initialIsAttack: initialIsAttack,
        initialPageId: initialPageId,
        backTooltip: backTooltip,
      ),
      transitionsBuilder: (context, animation, _, child) =>
          EasedRouteTransition(
        animation: animation,
        scaleFrom: 0.96,
        child: child,
      ),
    );
  }

  /// The editor for the named route [Routes.strategyView], which is what a
  /// web page reload inside the editor restarts on. The route name carries no
  /// strategy, so this reopens the cloud strategy the tab last had open
  /// ([openCloudStrategyId]). With nothing to reopen it returns an empty
  /// editor only where a local library exists; elsewhere (the web beta) it
  /// returns null, and the navigator falls back to the library.
  static PageRoute<void>? restoredRoute({
    required String? openCloudStrategyId,
    required bool allowsLocalLibrary,
  }) {
    if (openCloudStrategyId != null) {
      return route(
        initialStrategyId: openCloudStrategyId,
        initialStrategySource: StrategySource.cloud,
      );
    }
    return allowsLocalLibrary ? route() : null;
  }

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _StrategyViewState();
}

class _StrategyViewState extends ConsumerState<StrategyView>
    with WindowListener {
  bool _isClosingWindow = false;
  late bool _expanded = widget.startExpanded;

  /// Keeps the map's canvas mounted when a quick look opens out.
  final _communityCanvasKey = GlobalKey(debugLabel: 'community-canvas');
  bool _isInitialLoadPending = false;
  bool _hasInitialLoadCompleted = false;

  /// Set when the reader leaves for the library. The editor stays mounted
  /// while it animates out, so being mounted does not mean still wanted.
  bool _hasLeft = false;

  /// How the initial load waits. A reader who left meanwhile gets nothing
  /// more from it: the load ends at that wait. test/open_attempt_test.dart
  /// fails on an `await` in the load that does not go through here.
  Future<T> _unlessLeft<T>(Future<T> step) async {
    final result = await step;
    if (_hasLeft || !mounted) throw const _LeftWhileLoading();
    return result;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialStrategyId != null) {
      _isInitialLoadPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_loadInitialStrategy());
      });
    }
    if (!kIsWeb) {
      windowManager.addListener(this);
      _enableWindowCloseGuard();
    }
  }

  @override
  void dispose() {
    if (!kIsWeb) {
      windowManager.removeListener(this);
      windowManager.setPreventClose(false);
    }
    super.dispose();
  }

  Future<void> _enableWindowCloseGuard() async {
    await windowManager.setPreventClose(true);
  }

  Future<void> _loadInitialStrategy() async {
    final strategyId = widget.initialStrategyId;
    final source = widget.initialStrategySource;
    if (strategyId == null) {
      if (mounted) {
        setState(() => _isInitialLoadPending = false);
      }
      return;
    }

    // What was open before this load: only a strategy opened since then
    // means this load gave way to another.
    final openBefore = ref.read(strategyProvider).strategyId;
    try {
      switch (source) {
        case StrategySource.local:
          await _unlessLeft(
            ref
                .read(strategyProvider.notifier)
                .loadFromHive(strategyId, pageId: widget.initialPageId),
          );
        case StrategySource.cloud:
          final viewingThroughLink =
              ref.read(shareLinkViewProvider)?.strategyPublicId == strategyId;
          if (!viewingThroughLink &&
              !await _unlessLeft(_waitForCloudWorkspace())) {
            // Signed out, or the cloud is unreachable: nothing failed to
            // load, and the library says which, so go back without an error.
            _leaveAfterFailedLoad();
            return;
          }
          await _unlessLeft(
            ref.read(strategyProvider.notifier).openCloudStrategy(
                  strategyId,
                  pageId: widget.initialPageId,
                ),
          );
      }
      final loadedStrategy = ref.read(strategyProvider);
      if (loadedStrategy.strategyId != strategyId ||
          loadedStrategy.strategyName == null) {
        // Giving way to another strategy is not a failed load.
        if (_gaveWayTo(loadedStrategy.strategyId, openBefore)) return;
        throw StateError('Strategy "$strategyId" was not found.');
      }
      _hasInitialLoadCompleted = true;
    } on _LeftWhileLoading {
      // The home button works from the first frame; the load went with the
      // editor.
    } catch (error, stackTrace) {
      developer.log(
        'Error loading strategy: $error',
        name: 'strategy_view',
        error: error,
        stackTrace: stackTrace,
      );
      if (_hasLeft || !mounted) return;
      // Refused: the access-lost dialog says so over the skeleton, and
      // leads out (see StrategyAccessWatcher).
      if (ref.read(strategyAccessLostProvider)) return;
      // Another strategy was opened while this one loaded: nothing failed
      // that the reader should hear about.
      if (_gaveWayTo(ref.read(strategyProvider).strategyId, openBefore)) {
        return;
      }
      final notKept = ref.read(remoteEditorSnapshotProvider).error
          is StrategyNotKeptOffline;
      Settings.showToast(
        message: notKept
            ? context.l10n.syncStatusStrategyNeedsConnection
            : context.l10n.strategyViewLoadFailed,
        backgroundColor: notKept
            ? Settings.tacticalVioletTheme.secondary
            : Settings.tacticalVioletTheme.destructive,
      );
      _leaveAfterFailedLoad();
    } finally {
      if (mounted) {
        setState(() => _isInitialLoadPending = false);
      }
    }
  }

  /// Whether [open], the strategy open now, took this editor's place while
  /// its own was loading: it is another strategy, opened since the load
  /// began ([openBefore] is what was open then). If so, this settles where
  /// it shows.
  ///
  /// It shows in an editor of its own above this one when it was opened from
  /// outside (a share link arriving as this editor starts), and then this
  /// editor goes. Or it shows in this very editor, when a share link or
  /// back and forward swapped strategies in place: then this editor stays
  /// and shows it. Popping here would leave it open with nothing showing it.
  bool _gaveWayTo(String? open, String? openBefore) {
    if (open == null ||
        open == widget.initialStrategyId ||
        open == openBefore) {
      return false;
    }
    final route = ModalRoute.of(context);
    final top = mouseNavigationRouteObserver.topRoute;
    final anotherEditorShowsIt =
        top != route && top?.settings.name == Routes.strategyView;
    if (!anotherEditorShowsIt) {
      _hasInitialLoadCompleted = true;
    } else if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
    return true;
  }

  /// Takes this editor off the screen after its strategy failed to open.
  /// Another screen may have been pushed over it meanwhile (a share link
  /// opening its own editor), and a plain pop would close that one and
  /// leave this one behind it, showing its loading screen for good.
  void _leaveAfterFailedLoad() {
    final route = ModalRoute.of(context);
    if (route == null || route.isCurrent) {
      Navigator.maybePop(context);
    } else if (route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
  }

  /// Resolves [cloudWorkspaceOutcomeProvider] once it settles. After a page
  /// reload the editor can open before sign-in is restored, so a cloud
  /// strategy waits here rather than failing on an unready backend.
  Future<bool> _waitForCloudWorkspace() {
    final settled = Completer<bool>();
    final subscription = ref.listenManual<bool?>(
      cloudWorkspaceOutcomeProvider,
      (_, outcome) {
        if (outcome != null && !settled.isCompleted) settled.complete(outcome);
      },
      fireImmediately: true,
    );
    return settled.future.whenComplete(subscription.close);
  }

  /// Leaves the post for the reader's copy of it, [strategyPublicId].
  Future<void> _openCommunityCopy(String strategyPublicId) async {
    // Read before leaving: this view is gone once it has.
    final open = ref.read(sharedStrategyToOpenProvider.notifier);
    await _leaveToLibrary();
    if (_hasLeft) open.state = strategyPublicId;
  }

  Future<void> _leaveToLibrary() async {
    await guardUnsavedStrategyExit(
      context: context,
      ref: ref,
      source: 'StrategyView.leaveToLibrary',
      onContinue: () async {
        ref
            .read(interactionStateProvider.notifier)
            .update(InteractionState.navigation);
        ref
            .read(agentFilterProvider.notifier)
            .updateFilterState(FilterState.all);
        ref.read(deleteMenuProvider.notifier).requestClose();
        _hasLeft = true;
        if (mounted) {
          Navigator.pop(context);
        }
        await ref.read(strategyProvider.notifier).clearCurrentStrategy();
        forgetCommunityPost(ref, widget.communityPost?.strategyPublicId);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(openCloudStrategyRecorderProvider);
    // A reader who is here only through a share link loses the strategy the
    // moment its owner disables the link.
    ref.listen(remoteEditorSnapshotProvider, (_, next) {
      final error = next.error;
      if (error == null ||
          !isShareLinkRevokedError(error) ||
          ref.read(shareLinkViewProvider) == null) {
        return;
      }
      ref.read(shareLinkControllerProvider.notifier).forgetViewedLink();
      Settings.showToast(
        message: widget.communityPost != null
            ? context.l10n.communityPostTakenDown
            : context.l10n.strategyViewShareLinkDisabled,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
      );
      unawaited(_leaveToLibrary());
    });
    final strategyState = ref.watch(strategyProvider);
    final viewOnly = ref.watch(isViewOnlyStrategyProvider);
    final initialStrategyId = widget.initialStrategyId;
    final showSkeleton = _isInitialLoadPending ||
        (!_hasInitialLoadCompleted &&
            initialStrategyId != null &&
            (!strategyState.isOpen ||
                strategyState.strategyId != initialStrategyId));

    final formFactor = FormFactor.of(context);
    final touch = formFactor.isTouch;

    if (widget.communityPost case final post?) {
      return StrategyAccessWatcher(
        onLeave: _leaveToLibrary,
        child: _buildCommunityPost(context, post, loading: showSkeleton),
      );
    }

    if (showSkeleton) {
      // Watched from the first frame: opening can be refused outright.
      return StrategyAccessWatcher(
        onLeave: _leaveToLibrary,
        child: Scaffold(
          // The skeleton is the desktop editor's shape, panels and all.
          // The way back to the library works from the first frame: a load
          // that never finishes must not hold the reader here.
          body: touch
              ? Stack(
                  children: [
                    const Center(child: WingDotLoader()),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: _LeaveButton(
                          onPressed: _leaveToLibrary,
                          backTooltip: widget.backTooltip,
                        ),
                      ),
                    ),
                  ],
                )
              : StrategyViewSkeleton(
                  strategyName: widget.initialStrategyName,
                  mapValue: widget.initialMapValue,
                  isAttack: widget.initialIsAttack,
                  leading: _LeaveButton(
                    onPressed: _leaveToLibrary,
                    backTooltip: widget.backTooltip,
                  ),
                ),
        ),
      );
    }

    if (viewOnly && touch) {
      return StrategyAccessWatcher(
        onLeave: _leaveToLibrary,
        child: TouchStrategyViewer(
          onLeave: _leaveToLibrary,
          backTooltip: widget.backTooltip,
        ),
      );
    }

    final editor = Scaffold(
      body: Column(
        children: [
          // The same 40px strip as the library, so the traffic lights never
          // move: Library and the wordmark on the left, the strategy in the
          // middle, Discord on the right. The map card lives on the canvas
          // with the toolbar.
          AppWindowStrip(
            child: Stack(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 6),
                    _LeaveButton(
                      onPressed: _leaveToLibrary,
                      backTooltip: widget.backTooltip,
                    ),
                    const IcarusWordmark(),
                    const Expanded(
                      child: WindowDragArea(child: SizedBox.expand()),
                    ),
                    // Who else has this strategy open. Beside the strategy's
                    // own name, where you look to see what you're in.
                    const StrategyPresenceAvatars(),
                    const _DiscordLink(),
                    const SizedBox(width: 10),
                  ],
                ),
                const Center(child: StrategyQuickSwitcher()),
              ],
            ),
          ),
          // The canvas runs right up to the strip; each floating panel keeps
          // its own 8px of air so no bare band shows between the two.
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const Positioned.fill(
                  child: StrategyEditBoundary(child: DeleteCapture()),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: RepaintBoundary(child: InteractiveMap()),
                ),
                const Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CanvasChrome(
                          child: StrategyEditBoundary(
                            disabledOpacity: 0.55,
                            child: MapSelector(),
                          ),
                        ),
                        SizedBox(height: 8),
                        EditorToolbar(),
                      ],
                    ),
                  ),
                ),
                const Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: CanvasChrome(child: PagesBar()),
                  ),
                ),
                // Tools and agents only place things; a view-only reader
                // gets the map in their place.
                if (!viewOnly)
                  const Align(
                    alignment: Alignment.centerRight,
                    child: StrategyEditBoundary(
                      disabledOpacity: 0.55,
                      child: SideBarUI(),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final covered = formFactor.coversEditor(MediaQuery.sizeOf(context));
    return StrategyAccessWatcher(
      onLeave: _leaveToLibrary,
      // The same tree either way up, so turning the phone keeps the editor.
      child: Stack(
        fit: StackFit.expand,
        children: [
          ExcludeFocus(
            excluding: covered,
            child: ExcludeSemantics(
              excluding: covered,
              child: CanvasPaste(child: editor),
            ),
          ),
          if (covered)
            TurnPhoneNotice(
              onLeave: _leaveToLibrary,
              backTooltip: widget.backTooltip,
            ),
        ],
      ),
    );
  }

  /// A Community post: a sheet over the tab (the quick look) that opens out
  /// to the full view-only editor, the map staying where it is.
  Widget _buildCommunityPost(
    BuildContext context,
    CommunityPost post, {
    required bool loading,
  }) {
    const theme = Settings.tacticalVioletTheme;
    final l10n = context.l10n;
    final expanded = _expanded;
    final underReview = ref.watch(communityPostUnderReviewProvider);
    final width = MediaQuery.sizeOf(context).width;
    final side = width > 1000 ? 62.0 : 16.0;
    final canvas = KeyedSubtree(
      key: _communityCanvasKey,
      child: loading
          ? const Center(child: WingDotLoader())
          : Stack(
              clipBehavior: Clip.none,
              children: [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: RepaintBoundary(
                      child: InteractiveMap(dotsBeyondMap: true)),
                ),
                Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Says which map and side; a reader can't change it.
                        const CanvasChrome(
                          child: IgnorePointer(child: MapSelector()),
                        ),
                        if (expanded) ...[
                          const SizedBox(height: 8),
                          const EditorToolbar(),
                        ],
                      ],
                    ),
                  ),
                ),
                if (!expanded)
                  Align(
                    alignment: Alignment.topCenter,
                    // Centred between the map card and the window buttons,
                    // and cut short before it reaches either; a narrow sheet
                    // still leaves the title room for its name.
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final inset = ((constraints.maxWidth - 180) / 2)
                            .clamp(0.0, 276.0);
                        return Padding(
                          padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
                          child: CommunityPostTitle(post: post, height: 38),
                        );
                      },
                    ),
                  ),
                if (!expanded)
                  Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CommunityWindowButton(
                            icon: LucideIcons.maximize2,
                            tooltip: l10n.communityOpenFullScreen,
                            onPressed: () => setState(() => _expanded = true),
                          ),
                          const SizedBox(width: 8),
                          CommunityWindowButton(
                            icon: LucideIcons.x,
                            tooltip: l10n.communityClose,
                            onPressed: _leaveToLibrary,
                          ),
                        ],
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: expanded
                        ? const CanvasChrome(child: PagesBar())
                        : const CommunityPageStepper(),
                  ),
                ),
                if (underReview)
                  Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: CommunityReportsCard(post: post),
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: underReview
                        ? CommunityReviewActions(
                            post: post,
                            onDecided: _leaveToLibrary,
                          )
                        : CommunityPostActions(
                            post: post,
                            onOpenCopy: _openCommunityCopy,
                          ),
                  ),
                ),
              ],
            ),
    );
    final frame = Column(
      children: [
        if (expanded)
          AppWindowStrip(
            child: Stack(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 6),
                    _LeaveButton(onPressed: _leaveToLibrary),
                    const IcarusWordmark(),
                    const Expanded(
                      child: WindowDragArea(child: SizedBox.expand()),
                    ),
                    const _DiscordLink(),
                    const SizedBox(width: 10),
                  ],
                ),
                Center(
                  child: CommunityPostTitle(post: post, hidden: underReview),
                ),
              ],
            ),
          ),
        Expanded(child: canvas),
      ],
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (!_expanded) unawaited(_leaveToLibrary());
          },
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // A click beside the sheet closes it, as the X does.
              if (!expanded)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _leaveToLibrary,
                ),
              AnimatedPadding(
                duration: const Duration(milliseconds: 220),
                curve: Settings.easeOut,
                padding: expanded
                    ? EdgeInsets.zero
                    : EdgeInsets.fromLTRB(side, 56, side, 54),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Settings.easeOut,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: theme.background,
                    borderRadius: BorderRadius.circular(expanded ? 0 : 16),
                    border: Border.all(
                      color: expanded ? Colors.transparent : theme.border,
                    ),
                  ),
                  child: frame,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void onWindowClose() async {
    if (kIsWeb) {
      return;
    }
    if (_isClosingWindow) {
      return;
    }

    await guardUnsavedStrategyExit(
      context: context,
      ref: ref,
      source: 'StrategyView.onWindowClose',
      onContinue: () async {
        _isClosingWindow = true;
        await windowManager.setPreventClose(false);
        await windowManager.close();
      },
    );
  }
}

/// Ends the editor's initial load once the reader has left it.
class _LeftWhileLoading implements Exception {
  const _LeftWhileLoading();
}

/// The editor's way out, at the left of the window strip: the house back to
/// the library, or a back arrow when [backTooltip] names somewhere else.
class _LeaveButton extends StatelessWidget {
  const _LeaveButton({required this.onPressed, this.backTooltip});

  final VoidCallback onPressed;
  final String? backTooltip;

  @override
  Widget build(BuildContext context) {
    return ShadTooltip(
      builder: (context) => Text(
        backTooltip ?? context.l10n.strategyViewBackToLibraryTooltip,
      ),
      child: ShadIconButton.ghost(
        width: 28,
        height: 28,
        foregroundColor: Settings.tacticalVioletTheme.mutedForeground,
        hoverForegroundColor: Settings.tacticalVioletTheme.foreground,
        onPressed: onPressed,
        icon: Icon(
          backTooltip == null
              ? LucideIcons.house300
              : LucideIcons.chevronLeft300,
          size: 18,
        ),
      ),
    );
  }
}

/// The bug-report link at the end of the editor strip: text when there is
/// room, the glyph alone when there isn't.
class _DiscordLink extends StatelessWidget {
  const _DiscordLink();

  @override
  Widget build(BuildContext context) {
    const theme = Settings.tacticalVioletTheme;
    final showLabel = MediaQuery.sizeOf(context).width >= 1000;
    final button = ShadButton.ghost(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      foregroundColor: theme.mutedForeground,
      hoverForegroundColor: theme.foreground,
      onPressed: () async {
        await launchUrl(Settings.dicordLink);
      },
      leading: showLabel ? null : const Icon(CustomIcons.discord, size: 16),
      child: showLabel
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n.strategyViewDiscordPrompt,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(width: 8),
                const Icon(CustomIcons.discord, size: 16),
              ],
            )
          : const SizedBox.shrink(),
    );
    if (showLabel) return button;
    return ShadTooltip(
      builder: (context) => Text(context.l10n.strategyViewDiscordPrompt),
      child: button,
    );
  }
}
