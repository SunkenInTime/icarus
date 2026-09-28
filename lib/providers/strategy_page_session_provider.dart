import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/page_transition/agent_path.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';
import 'package:icarus/page_transition/transition_planner.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/editor_operation_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/providers/navigation_geometry_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/strategy/strategy_page_apply.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy/strategy_page_source.dart';
import 'package:icarus/view_cone/vision_geometry.dart';

enum PageTransitionState {
  idle,
  animatingForward,
  animatingBackward,
}

enum PageSwitchDirection { next, previous }

/// The page on screen, which a teammate deleted while it held work the server
/// never got. [name] is its name when it was last loaded.
typedef DeletedPage = ({String pageId, String name});

class StrategyPageSessionState {
  const StrategyPageSessionState({
    required this.activePageId,
    required this.availablePageIds,
    required this.transitionState,
    required this.isApplyingPage,
    this.deletedPage,
  });

  final String? activePageId;
  final List<String> availablePageIds;
  final PageTransitionState transitionState;
  final bool isApplyingPage;

  /// Set until the user has read that their unsaved work on the deleted page
  /// on screen cannot be saved. The canvas stays on it until then.
  final DeletedPage? deletedPage;

  StrategyPageSessionState copyWith({
    String? activePageId,
    bool clearActivePageId = false,
    List<String>? availablePageIds,
    PageTransitionState? transitionState,
    bool? isApplyingPage,
    DeletedPage? deletedPage,
    bool clearDeletedPage = false,
  }) {
    return StrategyPageSessionState(
      activePageId:
          clearActivePageId ? null : (activePageId ?? this.activePageId),
      availablePageIds: availablePageIds ?? this.availablePageIds,
      transitionState: transitionState ?? this.transitionState,
      isApplyingPage: isApplyingPage ?? this.isApplyingPage,
      deletedPage: clearDeletedPage ? null : (deletedPage ?? this.deletedPage),
    );
  }
}

class _RemotePageHydrationKey {
  const _RemotePageHydrationKey({
    required this.strategyPublicId,
    required this.pageId,
    required this.fingerprint,
  });

  final String strategyPublicId;
  final String pageId;
  final String fingerprint;

  @override
  bool operator ==(Object other) {
    return other is _RemotePageHydrationKey &&
        strategyPublicId == other.strategyPublicId &&
        pageId == other.pageId &&
        fingerprint == other.fingerprint;
  }

  @override
  int get hashCode => Object.hash(
        strategyPublicId,
        pageId,
        fingerprint,
      );
}

final strategyPageSessionProvider =
    NotifierProvider<StrategyPageSessionNotifier, StrategyPageSessionState>(
  StrategyPageSessionNotifier.new,
);

class StrategyPageSessionNotifier extends Notifier<StrategyPageSessionState> {
  _RemotePageHydrationKey? _lastHydratedRemotePageKey;
  RemoteEditorSnapshot? _lastAppliedRemoteSnapshot;
  bool _pendingRemoteReapply = false;
  bool _isResolvingConflicts = false;
  bool _remoteReapplyInFlight = false;

  /// A remote change is waiting for the user to finish what it touches.
  /// Retried when the editor's holds change, not before: they may last a
  /// while, and retrying sooner would only hold the change back again.
  bool _remoteChangeWaitsForEditor = false;
  bool _disposed = false;
  int _pageSessionGeneration = 0;

  @override
  StrategyPageSessionState build() {
    ref.onDispose(() => _disposed = true);
    ref.listen<AsyncValue<RemoteEditorSnapshot?>>(
      remoteEditorSnapshotProvider,
      (previous, next) {
        final strategyState = ref.read(strategyProvider);
        if (strategyState.source != StrategySource.cloud ||
            !strategyState.isOpen) {
          return;
        }

        final snapshot = next.valueOrNull;
        if (snapshot == null || snapshot.pages.isEmpty) {
          return;
        }

        final pageIds = [...snapshot.pages]
          ..sortBySortIndex((item) => item.sortIndex);
        final orderedIds =
            pageIds.map((page) => page.publicId).toList(growable: false);
        if (!listEquals(orderedIds, state.availablePageIds)) {
          state = state.copyWith(availablePageIds: orderedIds);
        }

        final targetPageId = _resolveHydrationTargetPage(snapshot);
        if (targetPageId == null) {
          return;
        }

        final hydrationKey =
            _buildRemotePageHydrationKey(snapshot, targetPageId);
        if (hydrationKey == null) {
          return;
        }

        if (_lastHydratedRemotePageKey != hydrationKey) {
          _requestRemoteRehydrate(targetPageId);
        }
      },
    );

    ref.listen<StrategySaveState>(strategySaveStateProvider, (_, __) {
      _resumePendingRemoteReapplyIfPossible();
    });

    void editorChanged() {
      if (_remoteChangeWaitsForEditor) {
        _remoteChangeWaitsForEditor = false;
        _pendingRemoteReapply = true;
      }
      // Draft completion publishes its saved value and history in the same
      // call stack. Let those writes finish before inspecting save state.
      scheduleMicrotask(_resumePendingRemoteReapplyIfPossible);
    }

    ref.listen<bool>(editorBusyProvider, (_, __) => editorChanged());
    ref.listen<Set<String>?>(
        editorHeldEntitiesProvider, (_, __) => editorChanged());

    ref.listen<StrategyOpQueueState>(strategyOpQueueProvider, (previous, next) {
      final previousAckBatch =
          previous?.lastAckBatch ?? const <AckedEntityIntent>[];
      if (next.lastAckBatch.isEmpty ||
          identical(previousAckBatch, next.lastAckBatch)) {
        return;
      }
      unawaited(_reconcileAcks(next.lastAcks, next.lastAckBatch));
    });

    return const StrategyPageSessionState(
      activePageId: null,
      availablePageIds: [],
      transitionState: PageTransitionState.idle,
      isApplyingPage: false,
    );
  }

  String? get activePageId => state.activePageId;

  Future<void> initializeForStrategy({
    required String strategyId,
    required StrategySource source,
    required bool selectFirstPageIfNeeded,
  }) async {
    _pageSessionGeneration++;
    final pageSource = _resolvePageSource(strategyId, source);
    final pageIds = await pageSource.listPageIds();
    final initialPageId =
        pageIds.contains(state.activePageId) ? state.activePageId : null;
    final selected = initialPageId ??
        (selectFirstPageIfNeeded && pageIds.isNotEmpty ? pageIds.first : null);

    state = state.copyWith(
      availablePageIds: pageIds,
      activePageId: selected,
      clearActivePageId: selected == null,
      transitionState: PageTransitionState.idle,
      isApplyingPage: false,
      clearDeletedPage: true,
    );
    ref.read(activePageLiveSyncProvider.notifier).setContext(
          strategyPublicId: strategyId,
          activePageId: selected,
        );

    if (selected != null) {
      await _rehydrateActivePageFromSource(selected);
    }
  }

  Future<void> setActivePage(String pageId) async {
    if (pageId == state.activePageId || _deletedPageHoldsWork()) {
      return;
    }
    await _switchToPage(pageId, animated: false);
  }

  Future<void> setActivePageAnimated(
    String pageId, {
    required PageTransitionDirection direction,
    Duration duration = kPageTransitionDuration,
  }) async {
    if (pageId == state.activePageId || _deletedPageHoldsWork()) {
      return;
    }
    final previousPageId = state.activePageId;

    final transitionState = ref.read(transitionProvider);
    final transitionNotifier = ref.read(transitionProvider.notifier);
    if (transitionState.active ||
        transitionState.phase == PageTransitionPhase.preparing) {
      transitionNotifier.complete();
    }

    state = state.copyWith(
      transitionState: direction == PageTransitionDirection.forward
          ? PageTransitionState.animatingForward
          : PageTransitionState.animatingBackward,
    );

    final startSettings = ref.read(strategySettingsProvider);
    final previous = _snapshotAllPlaced();
    final strategyState = ref.read(strategyProvider);
    final sourcePageId = state.activePageId;
    var fadeInDrawings = false;
    if (strategyState.source == StrategySource.local &&
        strategyState.strategyId != null) {
      final strategy = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .get(strategyState.strategyId);
      final targetPage =
          strategy?.pages.where((page) => page.id == pageId).firstOrNull;
      if (targetPage != null) {
        fadeInDrawings = TransitionPlanner.drawingsChanged(
          ref.read(drawingProvider).elements,
          targetPage.drawingData,
        );
      }
    }
    transitionNotifier.prepare(
      previous.values.toList(),
      direction: direction,
      startAgentSize: startSettings.agentSize,
      startAbilitySize: startSettings.abilitySize,
      sourcePageId: sourcePageId,
      targetPageId: pageId,
      fadeInDrawings: fadeInDrawings,
    );

    try {
      final switched = await _switchToPage(
        pageId,
        animated: true,
        direction: direction,
      );
      if (!switched) {
        transitionNotifier.complete();
        state = state.copyWith(transitionState: PageTransitionState.idle);
        return;
      }
    } catch (error, stackTrace) {
      transitionNotifier.complete();
      final strategyState = ref.read(strategyProvider);
      state = state.copyWith(
        activePageId: previousPageId,
        clearActivePageId: previousPageId == null,
        transitionState: PageTransitionState.idle,
      );
      ref.read(activePageLiveSyncProvider.notifier).setContext(
            strategyPublicId: strategyState.strategyId,
            activePageId: previousPageId,
          );
      if (strategyState.source == StrategySource.cloud) {
        try {
          await ref
              .read(remoteEditorSnapshotProvider.notifier)
              .setActivePage(previousPageId);
          final strategyId = strategyState.strategyId;
          if (strategyId != null && previousPageId != null) {
            final snapshot = _lastAppliedRemoteSnapshot;
            if (snapshot != null &&
                snapshot.header.publicId == strategyId &&
                snapshot.activePage?.page.publicId == previousPageId) {
              ref.read(activePageLiveSyncProvider.notifier).markPageHydrated(
                    strategyPublicId: strategyId,
                    pageId: previousPageId,
                    snapshot: snapshot,
                  );
            }
          }
        } catch (_) {
          // Preserve the original switch failure; the live read can recover
          // independently without leaving the transition state stuck.
        }
      }
      _resumePendingRemoteReapplyIfPossible();
      Error.throwWithStackTrace(error, stackTrace);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final preliminaryNext = _snapshotAllPlaced();
      final preliminaryEntries = _diffToTransitions(previous, preliminaryNext);
      if (preliminaryEntries.isEmpty && !fadeInDrawings) {
        transitionNotifier.complete();
        state = state.copyWith(transitionState: PageTransitionState.idle);
        _resumePendingRemoteReapplyIfPossible();
        return;
      }

      final needsAgentRouting = preliminaryEntries.any(
        (entry) =>
            entry.kind == TransitionKind.move &&
            entry.visualWidget is PlacedAgentNode,
      );
      // Agent routes load the small movement mesh independently of sightlines.
      // Unchanged agents, abilities and drawings need no route initialization.
      VisionGeometryMap? transitionGeometry;
      NavigationGeometryMap? transitionNavigation;
      final map = ref.read(mapProvider).currentMap;
      final requireNavigation = ref.read(worldGeometryEnabledProvider(map));
      if (needsAgentRouting) {
        try {
          if (requireNavigation) {
            transitionNavigation =
                await ref.read(navigationGeometryProvider(map).future);
          } else {
            transitionGeometry =
                await ref.read(viewConeGeometryProvider(map).future);
          }
        } on Object {
          // The provider reports the failure. Required native routes hold at
          // their sources, so changing pages cannot invent movement through walls.
        }
      }

      final currentTransition = ref.read(transitionProvider);
      if (currentTransition.phase != PageTransitionPhase.preparing ||
          currentTransition.sourcePageId != sourcePageId ||
          currentTransition.targetPageId != pageId) {
        return;
      }

      final next = _snapshotAllPlaced();
      final entries = _diffToTransitions(previous, next);
      if (entries.isEmpty && !fadeInDrawings) {
        transitionNotifier.complete();
        state = state.copyWith(transitionState: PageTransitionState.idle);
        _resumePendingRemoteReapplyIfPossible();
        return;
      }

      final endSettings = ref.read(strategySettingsProvider);
      final agentPaths = AgentTransitionPathPlanner.plan(
        entries: entries,
        geometry: transitionGeometry,
        navigation: transitionNavigation,
        requireNavigation: requireNavigation,
        startAgentSize: startSettings.agentSize,
        endAgentSize: endSettings.agentSize,
        coordinateSystem: CoordinateSystem.instance,
      );
      transitionNotifier.start(
        entries,
        duration: duration,
        direction: direction,
        startAgentSize: startSettings.agentSize,
        endAgentSize: endSettings.agentSize,
        startAbilitySize: startSettings.abilitySize,
        endAbilitySize: endSettings.abilitySize,
        sourcePageId: sourcePageId,
        targetPageId: pageId,
        agentPaths: agentPaths,
        fadeInDrawings: fadeInDrawings,
      );
      state = state.copyWith(transitionState: PageTransitionState.idle);
      _resumePendingRemoteReapplyIfPossible();
    });
  }

  Future<void> switchRelativePage(PageSwitchDirection direction) async {
    if (state.availablePageIds.isEmpty) {
      return;
    }

    final active = state.activePageId ?? state.availablePageIds.first;
    final currentIndex = state.availablePageIds.indexOf(active);
    if (currentIndex < 0) {
      return;
    }

    final nextIndex = direction == PageSwitchDirection.next
        ? (currentIndex + 1) % state.availablePageIds.length
        : (currentIndex - 1 + state.availablePageIds.length) %
            state.availablePageIds.length;
    final nextPageId = state.availablePageIds[nextIndex];
    await setActivePageAnimated(
      nextPageId,
      direction: direction == PageSwitchDirection.next
          ? PageTransitionDirection.forward
          : PageTransitionDirection.backward,
    );
  }

  Future<void> flushCurrentPage({bool flushImmediately = false}) async {
    final strategyState = ref.read(strategyProvider);
    if (!strategyState.isOpen || strategyState.strategyId == null) {
      return;
    }

    final source = _resolvePageSource(
      strategyState.strategyId!,
      strategyState.source ?? StrategySource.local,
    );
    if (strategyState.source == StrategySource.cloud) {
      ref.read(strategyProvider.notifier).consumeScheduledCloudPageSync();
    }
    await source.flushCurrentPage();
    if (flushImmediately && strategyState.source == StrategySource.cloud) {
      await ref.read(strategyOpQueueProvider.notifier).flushNow();
    }
  }

  /// Adopts the cloud version for every current conflict in this strategy.
  ///
  /// The authoritative page is loaded before any local intent is discarded.
  /// A failed load therefore leaves the durable conflict available to retry.
  Future<bool> useCloudVersionsForRejected() async {
    final strategyState = ref.read(strategyProvider);
    final strategyId = strategyState.strategyId;
    if (strategyState.source != StrategySource.cloud || strategyId == null) {
      return false;
    }

    _isResolvingConflicts = true;
    try {
      await _resolvePageSource(strategyId, StrategySource.cloud)
          .flushCurrentPage();
      final strategyNotifier = ref.read(strategyProvider.notifier);
      strategyNotifier.consumeScheduledCloudPageSync();
      strategyNotifier.consumeScheduledCloudStrategySync();
      final rejected = Map<EntitySyncKey, QueuedEntityIntent>.from(
        ref.read(strategyOpQueueProvider).attentionByEntityKey,
      );
      if (rejected.isEmpty) return true;

      await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      if (snapshot == null || snapshot.header.publicId != strategyId) {
        return false;
      }

      final targetPageId = _resolveHydrationTargetPage(snapshot);
      final localMetadata = _unsentLocalMetadata();
      if (targetPageId != null) {
        final pageSource = CloudStrategyPageSource(
          ref,
          strategyId: strategyId,
          activePageId: () => state.activePageId,
        );
        final pageData = await pageSource.loadAuthoritativePage(
          targetPageId,
          discardedEntities: rejected.keys.toSet(),
        );
        await _applyLoadedPageData(
          pageData,
          strategyId: strategyId,
          source: StrategySource.cloud,
          hydrationKey: _buildRemotePageHydrationKey(snapshot, targetPageId),
          preserveTextDrafts: true,
          loadedRemoteSnapshot: pageSource.loadedRemoteSnapshot,
          preservedMetadata:
              rejected.containsKey(const EntitySyncKey.strategy())
                  ? null
                  : localMetadata,
        );
      }

      final discarded = await ref
          .read(strategyOpQueueProvider.notifier)
          .discardRejected(rejected.keys.toSet());
      // A failed durable delete keeps its overlay and conflict. Restore those
      // entities if only part of the requested adoption could be saved.
      if (discarded.length != rejected.length && targetPageId != null) {
        final pageSource = CloudStrategyPageSource(
          ref,
          strategyId: strategyId,
          activePageId: () => state.activePageId,
        );
        final pageData = await pageSource.loadAuthoritativePage(
          targetPageId,
          discardedEntities: discarded,
        );
        await _applyLoadedPageData(
          pageData,
          strategyId: strategyId,
          source: StrategySource.cloud,
          preserveTextDrafts: true,
          loadedRemoteSnapshot: pageSource.loadedRemoteSnapshot,
          preservedMetadata: discarded.contains(const EntitySyncKey.strategy())
              ? null
              : localMetadata,
        );
      }
      if (discarded.isEmpty) return false;

      ref.read(activePageLiveSyncProvider.notifier).adoptRemoteForEntities(
            discarded,
            hydratedPageId: targetPageId,
          );
      for (final entry in rejected.entries) {
        if (discarded.contains(entry.key)) {
          ref
              .read(strategyConflictProvider.notifier)
              .clear(entry.value.pending.op.opId);
        }
      }
      for (final key in discarded) {
        if (key.kind == EntitySyncKeyKind.element && key.entityId != null) {
          ref.read(textDraftProvider.notifier).clearDraft(key.entityId!);
        }
      }
      ref
          .read(strategyOpQueueProvider.notifier)
          .completeRemoteAdoption(discarded);
      _pendingRemoteReapply = false;
      return discarded.length == rejected.length;
    } finally {
      _isResolvingConflicts = false;
    }
  }

  /// The strategy's map and theme on screen, while a change to them is still
  /// on its way: loading a page must keep them rather than take the older
  /// server copy (and so drop the change).
  ({MapValue map, StrategyThemeState theme})? _unsentLocalMetadata() {
    final hasPendingMetadata = ref.read(strategyOpQueueProvider).pending.any(
      (pending) {
        final op = pending.op;
        return op is StrategyPatchOp &&
            op.payload.keys.any((key) =>
                key == 'mapData' ||
                key == 'themeProfileId' ||
                key == 'clearThemeProfileId' ||
                key == 'themeOverridePalette' ||
                key == 'clearThemeOverridePalette');
      },
    );
    return hasPendingMetadata
        ? (
            map: ref.read(mapProvider).currentMap,
            theme: ref.read(strategyThemeProvider),
          )
        : null;
  }

  bool get isApplyingPage => state.isApplyingPage;

  void setStateForTest(StrategyPageSessionState newState) {
    state = newState;
  }

  void reset() {
    _remoteChangeWaitsForEditor = false;
    _pageSessionGeneration++;
    state = const StrategyPageSessionState(
      activePageId: null,
      availablePageIds: [],
      transitionState: PageTransitionState.idle,
      isApplyingPage: false,
    );
    _lastHydratedRemotePageKey = null;
    _lastAppliedRemoteSnapshot = null;
    _pendingRemoteReapply = false;
    _isResolvingConflicts = false;
    ref.read(activePageLiveSyncProvider.notifier).reset();
  }

  /// Returns false, leaving the page on screen, if a teammate deleted it
  /// while its work was being flushed.
  Future<bool> _switchToPage(
    String pageId, {
    required bool animated,
    PageTransitionDirection? direction,
  }) async {
    _pageSessionGeneration++;
    final strategyState = ref.read(strategyProvider);
    final strategyId = strategyState.strategyId;
    final source = strategyState.source;
    if (strategyId == null || source == null) {
      return true;
    }

    final pageSource = _resolvePageSource(strategyId, source);
    if (source == StrategySource.cloud) {
      ref.read(strategyProvider.notifier).consumeScheduledCloudPageSync();
    }
    await pageSource.flushCurrentPage();
    if (source == StrategySource.cloud) {
      await ref
          .read(strategyOpQueueProvider.notifier)
          .flushNow()
          .timeout(const Duration(milliseconds: 750), onTimeout: () {});
      // The page may have been deleted while its work was flushed.
      if (_deletedPageHoldsWork()) return false;
      state = state.copyWith(activePageId: pageId);
      ref.read(activePageLiveSyncProvider.notifier).setContext(
            strategyPublicId: strategyId,
            activePageId: pageId,
          );
      await ref
          .read(remoteEditorSnapshotProvider.notifier)
          .setActivePage(pageId);
    }

    final pageData = await pageSource.loadPage(pageId);
    await _applyLoadedPageData(
      pageData,
      strategyId: strategyId,
      source: source,
      loadedRemoteSnapshot: pageSource.loadedRemoteSnapshot,
    );

    if (animated && direction != null) {
      _updateHydrationBookkeeping(pageData.pageId);
    }
    return true;
  }

  Future<void> _rehydrateActivePageFromSource(
    String pageId, {
    _RemotePageHydrationKey? hydrationKey,
    bool preserveTextDrafts = false,
  }) async {
    final strategyState = ref.read(strategyProvider);
    final strategyId = strategyState.strategyId;
    final source = strategyState.source;
    if (strategyId == null || source == null) {
      return;
    }

    ref.read(activePageLiveSyncProvider.notifier).setContext(
          strategyPublicId: strategyId,
          activePageId: pageId,
        );
    if (source == StrategySource.cloud) {
      ref.read(activePageLiveSyncProvider.notifier).markPageUnhydrated(
            strategyPublicId: strategyId,
            pageId: pageId,
          );
    }
    final pageSource = _resolvePageSource(strategyId, source);
    final pageData = await pageSource.loadPage(pageId);
    await _applyLoadedPageData(
      pageData,
      strategyId: strategyId,
      source: source,
      hydrationKey: hydrationKey,
      preserveTextDrafts: preserveTextDrafts,
      loadedRemoteSnapshot: pageSource.loadedRemoteSnapshot,
    );
  }

  Future<void> _applyLoadedPageData(
    StrategyEditorPageData pageData, {
    required String strategyId,
    required StrategySource source,
    _RemotePageHydrationKey? hydrationKey,
    bool preserveTextDrafts = false,
    RemoteEditorSnapshot? loadedRemoteSnapshot,
    ({MapValue map, StrategyThemeState theme})? preservedMetadata,
    bool Function()? canApply,
  }) async {
    final availablePageIds =
        await _resolvePageSource(strategyId, source).listPageIds();
    if (canApply != null && !canApply()) return;
    final preserveHistory = source == StrategySource.cloud &&
        _lastHydratedRemotePageKey?.strategyPublicId == strategyId &&
        _lastHydratedRemotePageKey?.pageId == pageData.pageId;
    final themeProfileId = preservedMetadata != null
        ? preservedMetadata.theme.profileId
        : _resolveThemeProfileId(source, strategyId);
    final themeOverridePalette = preservedMetadata != null
        ? preservedMetadata.theme.overridePalette
        : _resolveThemeOverridePalette(source, strategyId);

    state = state.copyWith(
      isApplyingPage: true,
      activePageId: pageData.pageId,
      availablePageIds: availablePageIds,
    );

    final retainedTextDrafts = preserveTextDrafts
        ? Map<String, String>.from(ref.read(textDraftProvider))
        : const <String, String>{};
    try {
      await applyStrategyEditorPageData(
        ref,
        pageData,
        themeProfileId: themeProfileId,
        themeOverridePalette: themeOverridePalette,
        preserveHistory: preserveHistory,
        mapOverride: preservedMetadata?.map,
      );
      for (final entry in retainedTextDrafts.entries) {
        ref.read(textDraftProvider.notifier).setDraft(entry.key, entry.value);
      }
      if (source == StrategySource.cloud) {
        if (loadedRemoteSnapshot == null) {
          throw StateError(
            'Cloud page loaded without its source snapshot.',
          );
        }
        ref.read(activePageLiveSyncProvider.notifier).markPageHydrated(
              strategyPublicId: strategyId,
              pageId: pageData.pageId,
              snapshot: loadedRemoteSnapshot,
            );
        _lastAppliedRemoteSnapshot = loadedRemoteSnapshot;
      }
      _updateHydrationBookkeeping(
        pageData.pageId,
        hydrationKey: source == StrategySource.cloud
            ? _buildRemotePageHydrationKey(
                loadedRemoteSnapshot!,
                pageData.pageId,
              )
            : hydrationKey,
      );
    } finally {
      state = state.copyWith(
        activePageId: pageData.pageId,
        isApplyingPage: false,
      );
      _resumePendingRemoteReapplyIfPossible();
    }
  }

  StrategyPageSource _resolvePageSource(
    String strategyId,
    StrategySource source,
  ) {
    switch (source) {
      case StrategySource.local:
        return LocalStrategyPageSource(
          ref,
          strategyId: strategyId,
          activePageId: () => state.activePageId,
        );
      case StrategySource.cloud:
        return CloudStrategyPageSource(
          ref,
          strategyId: strategyId,
          activePageId: () => state.activePageId,
        );
    }
  }

  String _resolveThemeProfileId(StrategySource source, String strategyId) {
    if (source == StrategySource.cloud) {
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      return snapshot?.header.themeProfileId ??
          MapThemeProfilesProvider.immutableDefaultProfileId;
    }

    final strategy = Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(
      strategyId,
    );
    return strategy?.themeProfileId ??
        MapThemeProfilesProvider.immutableDefaultProfileId;
  }

  MapThemePalette? _resolveThemeOverridePalette(
    StrategySource source,
    String strategyId,
  ) {
    if (source == StrategySource.cloud) {
      final payload = ref
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.header
          .themeOverridePalette;
      if (payload == null || payload.isEmpty) {
        return null;
      }
      try {
        return MapThemePalette.fromJson(payload);
      } catch (_) {
        return null;
      }
    }

    return Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .get(strategyId)
        ?.themeOverridePalette;
  }

  bool _canSafelyReapplyRemotePage() {
    final saveState = ref.read(strategySaveStateProvider);
    return !_isResolvingConflicts &&
        state.deletedPage == null &&
        !state.isApplyingPage &&
        state.transitionState == PageTransitionState.idle &&
        ref.read(editorHeldEntitiesProvider) != null &&
        !saveState.isDirty &&
        !saveState.isSaving &&
        !saveState.hasPendingCloudSync;
  }

  void _requestRemoteRehydrate(String pageId) {
    if (_canSafelyReapplyRemotePage()) {
      unawaited(_reapplyRemotePage(pageId));
    } else {
      _pendingRemoteReapply = true;
      _checkActivePageOnServer();
    }
  }

  /// A replace of the page on screen is waiting. If it waits on work for a
  /// page a teammate deleted, the user is told now, unless they are
  /// mid-gesture: the gesture ending asks again.
  void _checkActivePageOnServer() {
    if (_isResolvingConflicts ||
        state.isApplyingPage ||
        state.transitionState != PageTransitionState.idle ||
        ref.read(editorBusyProvider)) {
      return;
    }
    _deletedPageHoldsWork();
  }

  /// Whether the canvas is on a page a teammate deleted, holding work the
  /// server never got. That work can never be sent, so waiting for it would
  /// wait forever and replacing the page would drop it unseen: the user is
  /// told first ([StrategyPageSessionState.deletedPage]). Checked before the
  /// canvas leaves the page, and while a replace of it waits. With nothing
  /// unsent, the unsaved mark its edits left is stale and is dropped.
  bool _deletedPageHoldsWork() {
    if (state.deletedPage != null) return true;
    final pageId = state.activePageId;
    final strategy = ref.read(strategyProvider);
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    if (pageId == null ||
        !strategy.isOpen ||
        strategy.source != StrategySource.cloud ||
        snapshot == null ||
        snapshot.header.publicId != strategy.strategyId ||
        snapshot.pages.any((page) => page.publicId == pageId) ||
        _lastHydratedRemotePageKey?.pageId != pageId) {
      return false;
    }
    // The user deleted it here: their delete is still on its way.
    final queue = ref.read(strategyOpQueueProvider);
    final descriptor = EntitySyncKey.pageDescriptor(pageId);
    if ([
      queue.queuedByEntityKey[descriptor]?.pending.op,
      queue.inFlightByEntityKey[descriptor]?.pending.op,
      queue.successorByEntityKey[descriptor]?.pending.op,
    ].any((op) => op is PageDeleteOp)) {
      return false;
    }
    if (!ref.read(activePageLiveSyncProvider.notifier).hasUnsentWork(pageId)) {
      ref.read(strategySaveStateProvider.notifier).clearStaleCloudMark();
      return false;
    }
    final lastSeen = _lastAppliedRemoteSnapshot?.pages
        .where((page) => page.publicId == pageId)
        .firstOrNull;
    state = state.copyWith(
      deletedPage: (pageId: pageId, name: lastSeen?.name ?? 'This page'),
    );
    return true;
  }

  /// Lets the deleted page on screen go, with the unsaved work on it, and
  /// puts a page the server has on screen. Returns false, staying on the
  /// deleted page, while some of that work is still on its way and cannot be
  /// taken back, or if no other page could be loaded.
  Future<bool> leaveDeletedPage() async {
    final deleted = state.deletedPage;
    final strategyId = ref.read(strategyProvider).strategyId;
    if (deleted == null || strategyId == null) return false;
    if (!await _withdrawPageWork(deleted.pageId) ||
        state.deletedPage != deleted) {
      return false;
    }
    // A read that failed earlier would otherwise fail every retry.
    final remote = ref.read(remoteEditorSnapshotProvider.notifier);
    await remote.refresh();
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    final target =
        snapshot == null ? null : _resolveHydrationTargetPage(snapshot);
    if (target == null ||
        target == deleted.pageId ||
        state.deletedPage != deleted) {
      return false;
    }
    // Loaded here, not through the reapply that waits for pending cloud
    // work: work queued for other pages is not on this canvas, and the
    // deleted page must not stay editable while it waits.
    try {
      await remote.setActivePage(target);
      final source = _resolvePageSource(strategyId, StrategySource.cloud);
      final pageData = await source.loadPage(target);
      if (state.deletedPage != deleted) return false;
      await _applyLoadedPageData(
        pageData,
        strategyId: strategyId,
        source: StrategySource.cloud,
        loadedRemoteSnapshot: source.loadedRemoteSnapshot,
        preservedMetadata: _unsentLocalMetadata(),
      );
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        'Could not load a page to replace the deleted one.',
        error: error,
        stackTrace: stackTrace,
        source: 'strategy_page_session:leave_deleted_page',
        promptUser: false,
      );
      return false;
    }
    ref.read(strategySaveStateProvider.notifier).clearStaleCloudMark();
    state = state.copyWith(clearDeletedPage: true);
    return true;
  }

  Future<void> _reapplyRemotePage(String pageId) async {
    if (_remoteReapplyInFlight || !_canSafelyReapplyRemotePage()) {
      _pendingRemoteReapply = true;
      return;
    }
    final strategy = ref.read(strategyProvider);
    final strategyId = strategy.strategyId;
    if (!strategy.isOpen ||
        strategy.source != StrategySource.cloud ||
        strategyId == null) return;
    final generation = _pageSessionGeneration;
    final startingPageId = state.activePageId;
    // The clean canvas is about to consume the server copy. A previously
    // scheduled diff must not re-author that already-saved work while loading.
    ref.read(strategyProvider.notifier).consumeScheduledCloudPageSync();
    _remoteReapplyInFlight = true;
    _pendingRemoteReapply = false;
    try {
      final source = _resolvePageSource(strategyId, StrategySource.cloud);
      final pageData = await source.loadPage(pageId);
      if (_disposed || generation != _pageSessionGeneration) return;
      bool canApply() {
        if (_disposed || generation != _pageSessionGeneration) return false;
        final current = ref.read(strategyProvider);
        if (!current.isOpen ||
            current.strategyId != strategyId ||
            current.source != StrategySource.cloud ||
            state.activePageId != startingPageId) return false;
        // Loading yields. A new gesture, local commit, or newer remote
        // snapshot may have arrived since the request started.
        final loadedKey = _buildRemotePageHydrationKey(
          source.loadedRemoteSnapshot!,
          pageId,
        );
        if (!_canSafelyReapplyRemotePage() ||
            loadedKey != _currentRemotePageHydrationKey(pageId)) {
          _pendingRemoteReapply = true;
          return false;
        }
        return true;
      }

      final loadedSnapshot = source.loadedRemoteSnapshot!;
      final alreadyOnScreen =
          _lastHydratedRemotePageKey?.strategyPublicId == strategyId &&
              _lastHydratedRemotePageKey?.pageId == pageId &&
              ref.read(activePageLiveSyncProvider).hydratedPageId == pageId;
      if (alreadyOnScreen) {
        if (canApply()) {
          _mergeRemotePage(
            pageData,
            strategyId: strategyId,
            snapshot: loadedSnapshot,
          );
        }
        return;
      }
      await _applyLoadedPageData(
        pageData,
        strategyId: strategyId,
        source: StrategySource.cloud,
        loadedRemoteSnapshot: loadedSnapshot,
        // Replacing the page (say a teammate deleted the one on screen)
        // clears everything, so it waits until nothing is mid-way.
        canApply: () {
          if (ref.read(editorBusyProvider)) {
            _remoteChangeWaitsForEditor = true;
            return false;
          }
          if (_deletedPageHoldsWork()) return false;
          return canApply();
        },
      );
    } finally {
      _remoteReapplyInFlight = false;
      if (!_disposed) _resumePendingRemoteReapplyIfPossible();
    }
  }

  /// Brings the page on screen up to [snapshot] item by item, leaving what
  /// the user is in the middle of changing. A held item's change applies once
  /// the hold ends.
  void _mergeRemotePage(
    StrategyEditorPageData pageData, {
    required String strategyId,
    required RemoteEditorSnapshot snapshot,
  }) {
    final pageId = pageData.pageId;
    final liveSync = ref.read(activePageLiveSyncProvider.notifier);
    // Marks these writes as the server's, not edits to send back.
    state = state.copyWith(isApplyingPage: true);
    final Set<EntitySyncKey> heldBack;
    try {
      heldBack = mergeRemoteStrategyEditorPageData(
        ref,
        pageData,
        changed: liveSync.remoteChangesSinceHydration(snapshot, pageId),
        holding: ref.read(editorHeldEntitiesProvider)!,
        themeProfileId:
            _resolveThemeProfileId(StrategySource.cloud, strategyId),
        themeOverridePalette: _resolveThemeOverridePalette(
          StrategySource.cloud,
          strategyId,
        ),
      );
    } finally {
      state = state.copyWith(isApplyingPage: false);
    }
    liveSync.markPageHydrated(
      strategyPublicId: strategyId,
      pageId: pageId,
      snapshot: snapshot,
      keepBaseFor: heldBack,
    );
    _lastAppliedRemoteSnapshot = snapshot;
    _updateHydrationBookkeeping(
      pageId,
      hydrationKey: _buildRemotePageHydrationKey(snapshot, pageId),
    );
    if (heldBack.isNotEmpty) _remoteChangeWaitsForEditor = true;
  }

  String? _resolveHydrationTargetPage(RemoteEditorSnapshot snapshot) {
    if (snapshot.pages.isEmpty) {
      return null;
    }

    final activePageId = state.activePageId;
    if (activePageId != null &&
        snapshot.pages.any((page) => page.publicId == activePageId)) {
      return activePageId;
    }

    final pages = [...snapshot.pages]
      ..sortBySortIndex((item) => item.sortIndex);
    return pages.first.publicId;
  }

  void _updateHydrationBookkeeping(
    String pageId, {
    _RemotePageHydrationKey? hydrationKey,
  }) {
    final key = hydrationKey ?? _currentRemotePageHydrationKey(pageId);
    if (key == null) {
      return;
    }
    _lastHydratedRemotePageKey = key;
  }

  _RemotePageHydrationKey? _currentRemotePageHydrationKey(String pageId) {
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    if (snapshot == null) {
      return null;
    }
    return _buildRemotePageHydrationKey(snapshot, pageId);
  }

  _RemotePageHydrationKey? _buildRemotePageHydrationKey(
    RemoteEditorSnapshot snapshot,
    String pageId,
  ) {
    RemotePage? page;
    for (final candidate in snapshot.pages) {
      if (candidate.publicId == pageId) {
        page = candidate;
        break;
      }
    }
    if (page == null) {
      return null;
    }
    final pageSnapshot = snapshot.activePage;
    if (pageSnapshot == null || pageSnapshot.page.publicId != pageId) {
      return null;
    }

    final elements = [
      ...snapshot.elementsByPage[pageId] ?? const <RemoteElement>[]
    ]..sort(_compareRemoteElements);
    final lineups = [
      ...snapshot.lineupsByPage[pageId] ?? const <RemoteLineup>[]
    ]..sort(_compareRemoteLineups);
    final assets = snapshot.assetsById.values.toList()
      ..sort((a, b) => a.publicId.compareTo(b.publicId));

    final fingerprint = jsonEncode({
      'page': {
        'publicId': page.publicId,
        'name': page.name,
        'sortIndex': page.sortIndex,
        'isAttack': page.isAttack,
        'revision': page.revision,
        'contentRevision': pageSnapshot.content.revision,
        'settings': pageSnapshot.content.settings,
      },
      'elements': [
        for (final element in elements)
          {
            'publicId': element.publicId,
            'elementType': element.elementType,
            'payload': element.payload,
            'sortIndex': element.sortIndex,
            'revision': element.revision,
            'deleted': element.deleted,
          },
      ],
      'lineups': [
        for (final lineup in lineups)
          {
            'publicId': lineup.publicId,
            'payload': lineup.payload,
            'sortIndex': lineup.sortIndex,
            'revision': lineup.revision,
            'deleted': lineup.deleted,
          },
      ],
      'assets': [
        for (final asset in assets)
          {
            'publicId': asset.publicId,
            'fileExtension': asset.fileExtension,
            'mimeType': asset.mimeType,
            'width': asset.width,
            'height': asset.height,
            'url': asset.url,
            'legacyStoragePath': asset.legacyStoragePath,
          },
      ],
    });

    return _RemotePageHydrationKey(
      strategyPublicId: snapshot.header.publicId,
      pageId: pageId,
      fingerprint: fingerprint,
    );
  }

  int _compareRemoteElements(RemoteElement a, RemoteElement b) {
    final sortCompare = a.sortIndex.compareTo(b.sortIndex);
    if (sortCompare != 0) {
      return sortCompare;
    }
    return a.publicId.compareTo(b.publicId);
  }

  int _compareRemoteLineups(RemoteLineup a, RemoteLineup b) {
    final sortCompare = a.sortIndex.compareTo(b.sortIndex);
    if (sortCompare != 0) {
      return sortCompare;
    }
    return a.publicId.compareTo(b.publicId);
  }

  Future<void> _reconcileAcks(
    List<OpAck> acks,
    List<AckedEntityIntent> ackBatch,
  ) async {
    final strategyState = ref.read(strategyProvider);
    if (strategyState.source != StrategySource.cloud || acks.isEmpty) {
      return;
    }

    ref.read(activePageLiveSyncProvider.notifier).recordAckBatch(ackBatch);
    var hasReject = false;
    for (final ack in acks) {
      if (ack.isAck) {
        continue;
      }
      hasReject = true;
      Map<String, dynamic>? serverPayload;
      if (ack.latestPayload != null && ack.latestPayload!.isNotEmpty) {
        serverPayload = cloudPayloadData(ack.latestPayload);
      }

      ref.read(strategyConflictProvider.notifier).push(
            ConflictResolution(
              type: ConflictResolutionType.rebase,
              opId: ack.opId,
              message: ack.reason,
              serverPayload: serverPayload,
              serverRevision: ack.latestRevision,
            ),
          );
    }

    await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
    if (_remoteReapplyInFlight || !_canSafelyReapplyRemotePage()) {
      _pendingRemoteReapply = true;
      return;
    }
    final activePageId = state.activePageId;
    final strategyId = strategyState.strategyId;
    if (activePageId != null && strategyId != null) {
      ref.read(strategyProvider.notifier).consumeScheduledCloudPageSync();
      final desiredOpsByEntityKey =
          ref.read(activePageLiveSyncProvider.notifier).syncLocalPage(
                strategyPublicId: strategyId,
                pageId: activePageId,
              );
      if (desiredOpsByEntityKey != null) {
        await ref.read(strategyOpQueueProvider.notifier).syncDesiredOpsForPage(
              pageId: activePageId,
              desiredOpsByEntityKey: desiredOpsByEntityKey,
              flushImmediately: false,
            );
      }
      if (_canSafelyReapplyRemotePage()) {
        await _reapplyRemotePage(activePageId);
      } else {
        _pendingRemoteReapply = true;
      }
    } else if (hasReject) {
      _pendingRemoteReapply = true;
    }
  }

  /// How long leaving a deleted page waits on work already sent for it.
  @visibleForTesting
  Duration pageWorkSettleTimeout = const Duration(seconds: 10);

  /// Takes every op for [pageId] out of the queue, with the local intent
  /// (overlays) they carried. An op already sent cannot be taken back, so
  /// this waits for it to be answered, then takes out what it left. Returns
  /// whether the queue holds nothing for the page.
  Future<bool> _withdrawPageWork(String pageId) async {
    final queue = ref.read(strategyOpQueueProvider.notifier);
    if (!await queue.discardDeletedPage(pageId)) {
      await _queueSettles((state) =>
          !state.inFlightByEntityKey.keys.any((key) => key.pageId == pageId));
      await queue.discardDeletedPage(pageId);
    }
    ref.read(activePageLiveSyncProvider.notifier).dropSatisfiedOverlays(pageId);
    final state = ref.read(strategyOpQueueProvider);
    return ![
      state.queuedByEntityKey,
      state.inFlightByEntityKey,
      state.successorByEntityKey,
      state.pausedByEntityKey,
      state.attentionByEntityKey,
    ].any((intents) => intents.keys.any((key) => key.pageId == pageId));
  }

  /// Waits, at most [pageWorkSettleTimeout], for the op queue to satisfy
  /// [settled].
  Future<void> _queueSettles(
    bool Function(StrategyOpQueueState queue) settled,
  ) async {
    if (settled(ref.read(strategyOpQueueProvider))) return;
    final done = Completer<void>();
    final subscription = ref.listen<StrategyOpQueueState>(
      strategyOpQueueProvider,
      (_, next) {
        if (settled(next) && !done.isCompleted) done.complete();
      },
    );
    try {
      await done.future.timeout(pageWorkSettleTimeout, onTimeout: () {});
    } finally {
      subscription.close();
    }
  }

  void _resumePendingRemoteReapplyIfPossible() {
    if (_disposed || _remoteReapplyInFlight || !_pendingRemoteReapply) {
      return;
    }
    if (!_canSafelyReapplyRemotePage()) {
      _checkActivePageOnServer();
      return;
    }
    _pendingRemoteReapply = false;
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    final pageId =
        snapshot == null ? null : _resolveHydrationTargetPage(snapshot);
    if (pageId != null) {
      unawaited(
        _reapplyRemotePage(pageId),
      );
    }
  }

  Map<String, PlacedWidget> _snapshotAllPlaced() {
    final map = <String, PlacedWidget>{};
    for (final agent in ref.read(agentProvider)) {
      map[agent.id] = agent;
    }
    for (final ability in ref.read(abilityProvider)) {
      map[ability.id] = ability;
    }
    for (final text in ref.read(textProvider)) {
      map[text.id] = text;
    }
    for (final image in ref.read(placedImageProvider).images) {
      map[image.id] = image;
    }
    for (final utility in ref.read(utilityProvider)) {
      map[utility.id] = utility;
    }
    return map;
  }

  List<PageTransitionEntry> _diffToTransitions(
    Map<String, PlacedWidget> previous,
    Map<String, PlacedWidget> next,
  ) =>
      TransitionPlanner.diff(previous, next);
}
