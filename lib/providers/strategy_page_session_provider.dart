import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
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
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
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
import 'package:icarus/strategy/lineup_group_changes.dart';
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

/// How Keep both ended (see StrategyPageSessionNotifier.keepBothForRejected).
enum KeepBothOutcome {
  /// The cloud's versions stand, and the user's are beside them as copies.
  kept,

  /// The cloud's versions could not be loaded. Nothing changed.
  unchanged,

  /// The user's versions were added as copies, but something failed before
  /// the conflicts were resolved (the cloud's versions stopped loading, a
  /// copy could not be saved, or the waiting work changed), so they still
  /// wait.
  copiesOnly,
}

/// How an attempt to restore a deleted page ended.
enum DeletedPageRestore {
  /// The page is back on the server, and the work on it is saving as usual.
  /// The deleted page on screen is back on screen too.
  restored,

  /// The server can no longer restore the page: its time in the trash is
  /// over. Work on it cannot be saved.
  gone,

  /// The page could not be restored, or not loaded once it was. Nothing on
  /// this device changed; trying again is safe.
  failed,
}

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

  /// Pages whose delete from this device the server applied, with the
  /// strategy revision the delete made. See [_deletedHere].
  final Map<String, int> _pagesDeletedHere = {};

  /// The latest strategy revision at which each page was seen live.
  final Map<String, int> _pagesSeenLiveAt = {};

  /// Waiting work Keep both already put a copy of on the canvas, by
  /// [_waitingWork] entry: pressing it again finishes the job instead of
  /// copying the same version twice.
  final Set<(EntitySyncKey, (String, String?))> _keptAsCopy = {};

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
        if (snapshot.header.publicId == strategyState.strategyId) {
          for (final page in snapshot.pages) {
            _pagesSeenLiveAt.update(
              page.publicId,
              (seen) => max(seen, snapshot.header.revision),
              ifAbsent: () => snapshot.header.revision,
            );
          }
          _resendEditsForPagesBack(snapshot);
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
      _notePagesDeletedHere(next);
      unawaited(_reconcileAcks(next.lastAcks, next.lastAckBatch));
    });

    return const StrategyPageSessionState(
      activePageId: null,
      availablePageIds: [],
      transitionState: PageTransitionState.idle,
      isApplyingPage: false,
    );
  }

  /// Edits the server refused because their page was deleted go out again
  /// once the page is live: restored here, by a teammate, or while this
  /// strategy was closed. A refusal refreshes the snapshot, which then no
  /// longer lists the page, so this cannot loop.
  void _resendEditsForPagesBack(RemoteEditorSnapshot snapshot) {
    // A "Use cloud" in progress decides this work's fate. ("Keep mine" goes
    // through the same serialized retry, which only takes what is still in
    // attention, so the two cannot send it twice.)
    if (_isResolvingConflicts) return;
    final live = {for (final page in snapshot.pages) page.publicId};
    final waiting = ref
        .read(strategyOpQueueProvider)
        .attentionByEntityKey
        .keys
        .any((key) => live.contains(key.pageId));
    if (!waiting) return;
    unawaited(
      ref.read(strategyOpQueueProvider.notifier).retryRestoredPages(live),
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
    // Snapshots that arrived while the strategy was opening went unheard:
    // catch up on pages that came back while it was closed.
    if (source == StrategySource.cloud) {
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      if (snapshot != null && snapshot.header.publicId == strategyId) {
        _resendEditsForPagesBack(snapshot);
      }
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

  /// Keeps both versions of every conflicting lineup group: the cloud's
  /// stays the group, and the user's goes beside it as a copy under fresh
  /// ids (see forkLineUpGraph), so neither side's work is lost. A version
  /// that deletes the group, or only reorders it, holds nothing to copy.
  ///
  /// Only for conflicts that are all lineup groups on the page on screen
  /// (see lineupConflictsProvider); anything else is a [StateError].
  ///
  /// Nothing is discarded unless everything still matches what was copied:
  /// the cloud's version loads, the page on screen is the same one, the
  /// waiting work is the same (an edit made meanwhile would not be in the
  /// copy), and the copy itself saved. When the cloud's version cannot be
  /// loaded, or the work changed before the copy was made, nothing changes.
  /// When something fails after, the copy stays and the conflicts still
  /// wait; pressing Keep both again resolves them without a second copy.
  Future<KeepBothOutcome> keepBothForRejected() async {
    final strategyState = ref.read(strategyProvider);
    final strategyId = strategyState.strategyId;
    final queue = ref.read(strategyOpQueueProvider);
    final attention = queue.attentionByEntityKey;
    final activePageId = state.activePageId;
    if (strategyState.source != StrategySource.cloud ||
        strategyId == null ||
        attention.isEmpty ||
        attention.keys.any((key) =>
            key.kind != EntitySyncKeyKind.lineup ||
            key.pageId != activePageId)) {
      throw StateError('Keep both is only for lineup groups on this page');
    }
    // A copy is only kept if it can be saved; while this device cannot
    // save outbox records, nothing is copied and nothing discarded.
    if (queue.hasDurabilityFailure) return KeepBothOutcome.unchanged;
    final generation = _pageSessionGeneration;
    final waiting = _waitingWork(attention.keys);
    final copies = <LineUpGraph>[];
    for (final MapEntry(:key, value: refused) in attention.entries) {
      final newest = (queue.successorByEntityKey[key] ?? refused).pending.op;
      final payload = switch (newest) {
        LineupAddOp(:final payload) => payload,
        LineupPatchOp(:final payload?) => payload,
        _ => null,
      };
      if (payload == null || _keptAsCopy.contains((key, waiting[key]!))) {
        continue;
      }
      copies.add(forkLineUpGraph(lineUpGraphFromCloudRows([
        CloudLineupRow(publicId: key.entityId!, payload: payload),
      ]).graph));
    }
    bool unchangedSince() =>
        !_disposed &&
        generation == _pageSessionGeneration &&
        _sameWaitingWork(waiting);

    await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    if (snapshot == null || snapshot.header.publicId != strategyId) {
      return KeepBothOutcome.unchanged;
    }
    // Edits made while the cloud's version loaded are saved first; one to
    // a conflicting group is newer than the copy, so nothing goes ahead.
    final pageSource = _resolvePageSource(strategyId, StrategySource.cloud);
    await pageSource.flushCurrentPage();
    if (!unchangedSince()) return KeepBothOutcome.unchanged;

    final lineUps = ref.read(lineUpProvider.notifier);
    for (final copy in copies) {
      lineUps.addRecovered(copy);
    }
    final copyLineupIds = [
      for (final copy in copies)
        if (copy.links.isNotEmpty) copy.links.first.id,
    ];
    _keptAsCopy
        .addAll(waiting.entries.map((entry) => (entry.key, entry.value)));
    await pageSource.flushCurrentPage();
    // A copy that could not be saved leaves the outbox failing (and waits in
    // attention itself): nothing may be discarded on its behalf.
    final afterCopy = ref.read(strategyOpQueueProvider);
    final liveSync = ref.read(activePageLiveSyncProvider.notifier);
    final queuedKeys = {
      for (final pending in afterCopy.pending)
        EntitySyncKey.forStrategyOp(pending.op),
    };
    // Each copy's group must be queued (or already on the server): a save
    // skipped without failing, say after edit access was lost, leaves the
    // copy on the canvas alone.
    final copiesQueued = copyLineupIds.every((lineupId) {
      final group = liveSync.lineupGroupOf(activePageId!, lineupId);
      if (group == null) return false;
      final key = EntitySyncKey.lineup(activePageId, group);
      return queuedKeys.contains(key) || liveSync.hydratedBase(key) != null;
    });
    final saved = copiesQueued &&
        !afterCopy.hasDurabilityFailure &&
        afterCopy.attentionByEntityKey.keys.every(waiting.containsKey);
    if (!saved || !unchangedSince()) return KeepBothOutcome.copiesOnly;
    return await _useCloudVersionsFor(waiting)
        ? KeepBothOutcome.kept
        : KeepBothOutcome.copiesOnly;
  }

  /// The refused op, and the newer one queued behind it if any, of each of
  /// [keys]: what is waiting for the user's choice.
  Map<EntitySyncKey, (String, String?)> _waitingWork(
    Iterable<EntitySyncKey> keys,
  ) {
    final queue = ref.read(strategyOpQueueProvider);
    return {
      for (final key in keys)
        if (queue.attentionByEntityKey[key] case final refused?)
          key: (
            refused.pending.op.opId,
            queue.successorByEntityKey[key]?.pending.op.opId,
          ),
    };
  }

  /// The canvas's content, one state object per kind of item on it. Every
  /// edit replaces its kind's object, so comparing them by identity tells
  /// whether anything changed in between.
  List<Object?> _canvasStates() => [
        ref.read(agentProvider),
        ref.read(abilityProvider),
        ref.read(drawingProvider),
        ref.read(textProvider),
        ref.read(placedImageProvider),
        ref.read(utilityProvider),
        ref.read(lineUpProvider),
      ];

  bool _sameCanvas(List<Object?> saved) {
    final now = _canvasStates();
    for (var i = 0; i < saved.length; i++) {
      if (!identical(saved[i], now[i])) return false;
    }
    return true;
  }

  /// Whether exactly [waiting] still waits, nothing changed or gone.
  bool _sameWaitingWork(Map<EntitySyncKey, (String, String?)> waiting) {
    final now = _waitingWork(waiting.keys);
    return now.length == waiting.length &&
        waiting.entries.every((entry) => now[entry.key] == entry.value);
  }

  /// Adopts the cloud version for every current conflict in this strategy.
  ///
  /// The authoritative page is loaded before any local intent is discarded.
  /// A failed load therefore leaves the durable conflict available to retry.
  Future<bool> useCloudVersionsForRejected() => _useCloudVersionsFor(null);

  /// [useCloudVersionsForRejected], for exactly the conflicts in [waiting]
  /// (by default, every conflict once the page's edits are saved). If they
  /// no longer wait as they were, or the canvas changed after its last
  /// save, nothing is discarded or redrawn: the newer work stays.
  Future<bool> _useCloudVersionsFor(
    Map<EntitySyncKey, (String, String?)>? waiting,
  ) async {
    final strategyState = ref.read(strategyProvider);
    final strategyId = strategyState.strategyId;
    if (strategyState.source != StrategySource.cloud || strategyId == null) {
      return false;
    }

    final generation = _pageSessionGeneration;
    late Map<EntitySyncKey, (String, String?)> resolving;
    bool waitingChanged() =>
        _disposed ||
        generation != _pageSessionGeneration ||
        !_sameWaitingWork(resolving);

    _isResolvingConflicts = true;
    try {
      final currentPageSource =
          _resolvePageSource(strategyId, StrategySource.cloud);
      await currentPageSource.flushCurrentPage();
      final strategyNotifier = ref.read(strategyProvider.notifier);
      strategyNotifier.consumeScheduledCloudPageSync();
      strategyNotifier.consumeScheduledCloudStrategySync();
      resolving = waiting ??
          _waitingWork(
            ref.read(strategyOpQueueProvider).attentionByEntityKey.keys,
          );
      if (waitingChanged()) return false;
      final rejected = Map<EntitySyncKey, QueuedEntityIntent>.from(
        ref.read(strategyOpQueueProvider).attentionByEntityKey,
      )..removeWhere((key, _) => !resolving.containsKey(key));
      if (rejected.isEmpty) return true;

      await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      if (snapshot == null || snapshot.header.publicId != strategyId) {
        return false;
      }

      // Edits made while the cloud's version loaded are saved, and one to
      // the waiting work stops the resolution: the page drawn next would
      // replace that edit on screen. The canvas is noted before that save,
      // so an edit made while it is being written counts as a change too.
      final savedCanvas = _canvasStates();
      await currentPageSource.flushCurrentPage();
      if (waitingChanged()) return false;
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
        // Nothing awaits between this check and the redraw: an edit since
        // the last save is still only on the canvas, and stops it.
        if (waitingChanged() || !_sameCanvas(savedCanvas)) return false;
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
          .discardRejected(rejected.keys.toSet(), onlyIf: resolving);
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
    // The user deleted it here: their delete landed, or is still on its way.
    // Work on it the server paused or refused stays in the sync status.
    final queue = ref.read(strategyOpQueueProvider);
    _notePagesDeletedHere(queue);
    if (_deletedHere(pageId)) return false;
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

  /// Records the pages whose delete the server just accepted from [queue].
  /// Called from the check as well as the queue listener: a listener
  /// registered earlier (save state) can run the check first.
  void _notePagesDeletedHere(StrategyOpQueueState queue) {
    for (final acked in queue.lastAckBatch) {
      // Only a delete the server applied took the page away. A no-op says
      // it was already gone, not by whom: a teammate may have deleted it
      // since, and their delete must still show the notice.
      if ((acked.op, acked.ack)
          case (
            PageDeleteOp(:final pagePublicId),
            AppliedOpAck(:final revision),
          )) {
        _pagesDeletedHere[pagePublicId] = revision;
      }
    }
  }

  /// Whether [pageId]'s disappearing is this device's delete: one the server
  /// applied that is newer than the page was last seen live. Seen live at
  /// the delete's revision or later, the page was restored after it (the
  /// delete's own revision never lists it), and a later delete is someone's
  /// new one, whichever order the ack and the reads arrive in.
  bool _deletedHere(String pageId) {
    final deletedAt = _pagesDeletedHere[pageId];
    return deletedAt != null && (_pagesSeenLiveAt[pageId] ?? -1) < deletedAt;
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
    // Images only that work placed have nothing left to show them.
    unawaited(ref
        .read(cloudMediaUploadQueueProvider.notifier)
        .recheckAfterDiscardedWork(strategyId));
    // A read that failed earlier would otherwise fail every retry.
    final remote = ref.read(remoteEditorSnapshotProvider.notifier);
    await remote.refresh();
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    final target =
        snapshot == null ? null : _resolveHydrationTargetPage(snapshot);
    if (target == null || state.deletedPage != deleted) return false;
    // Loaded here, not through the reapply that waits for pending cloud
    // work: work queued for other pages is not on this canvas, and the
    // deleted page must not stay editable while it waits. If the page is
    // back (restored meanwhile), this is its server copy, without the
    // discarded work.
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

  /// Brings the deleted page on screen back from the server's trash, with
  /// everything it had there, so the unsaved work on it saves as usual: the
  /// changes the server refused while it was in the trash are sent again,
  /// and the canvas's other edits are queued against the restored copy. The
  /// notice stays until the page is back on screen, read live.
  Future<DeletedPageRestore> restoreDeletedPage() async {
    final deleted = state.deletedPage;
    final strategyId = ref.read(strategyProvider).strategyId;
    if (deleted == null || strategyId == null) {
      return DeletedPageRestore.failed;
    }
    final outcome = await _restoreOnServer(strategyId, deleted.pageId);
    if (outcome != DeletedPageRestore.restored) return outcome;
    // A change still on its way when the page came back may yet be refused;
    // its answer comes before the refused changes are sent again.
    final settled = await _queueSettles((queue) => !queue
        .inFlightByEntityKey.keys
        .any((key) => key.pageId == deleted.pageId));
    // Its answer never came: a refusal still on its way would miss the
    // retry below. Restoring again is safe once it has.
    if (!settled) return DeletedPageRestore.failed;
    await ref
        .read(remoteEditorSnapshotProvider.notifier)
        .showRestoredPage(deleted.pageId);
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    if (state.deletedPage != deleted ||
        snapshot == null ||
        snapshot.activePage?.page.publicId != deleted.pageId ||
        !snapshot.pages.any((page) => page.publicId == deleted.pageId)) {
      return DeletedPageRestore.failed;
    }
    // Loading the page that was to replace it moved live sync off it.
    ref
        .read(activePageLiveSyncProvider.notifier)
        .resumePage(strategyPublicId: strategyId, pageId: deleted.pageId);
    state = state.copyWith(clearDeletedPage: true);
    await ref
        .read(strategyOpQueueProvider.notifier)
        .retryRestoredPage(deleted.pageId);
    await flushCurrentPage(flushImmediately: true);
    // A send whose answer was lost replays under its own op id, and may be
    // answered with the refusal the server recorded while the page was in
    // the trash: once the page's sends are answered, those go again too.
    // Sends still unanswered after the wait stay queued, saving as usual;
    // a late refusal among them shows in the sync status, where Keep mine
    // sends it again.
    if (await _queueSettles((queue) => ![
          queue.queuedByEntityKey,
          queue.inFlightByEntityKey,
        ].any((sends) =>
            sends.keys.any((key) => key.pageId == deleted.pageId)))) {
      await ref
          .read(strategyOpQueueProvider.notifier)
          .retryRestoredPage(deleted.pageId);
    }
    // A later read may have shown the page gone again.
    return state.deletedPage == null && state.activePageId == deleted.pageId
        ? DeletedPageRestore.restored
        : DeletedPageRestore.failed;
  }

  /// Brings [pageId] back from the server's trash, from Recently deleted: at
  /// the place it was deleted from, with everything on it. Changes to it the
  /// server refused while it was in the trash are sent again, once any
  /// still on their way have been answered, and again once the page's
  /// queued sends have gone: a send whose answer was lost replays under its
  /// own op id, and may bring back the refusal. Refusals not answered in
  /// time stay in the sync status, where Keep mine sends them.
  Future<DeletedPageRestore> restorePageFromTrash(String pageId) async {
    final strategyId = ref.read(strategyProvider).strategyId;
    if (strategyId == null) return DeletedPageRestore.failed;
    final outcome = await _restoreOnServer(strategyId, pageId);
    if (outcome != DeletedPageRestore.restored) return outcome;
    final queue = ref.read(strategyOpQueueProvider.notifier);
    bool onPage(EntitySyncKey key) => key.pageId == pageId;
    if (await _queueSettles(
        (state) => !state.inFlightByEntityKey.keys.any(onPage))) {
      await queue.retryRestoredPage(pageId);
    }
    if (await _queueSettles((state) => ![
          state.queuedByEntityKey,
          state.inFlightByEntityKey,
        ].any((sends) => sends.keys.any(onPage)))) {
      await queue.retryRestoredPage(pageId);
    }
    return DeletedPageRestore.restored;
  }

  /// Asks the server to take [pageId] out of its trash.
  Future<DeletedPageRestore> _restoreOnServer(
    String strategyId,
    String pageId,
  ) async {
    try {
      await ref.read(convexStrategyRepositoryProvider).restorePage(
            strategyPublicId: strategyId,
            pagePublicId: pageId,
          );
      return DeletedPageRestore.restored;
    } catch (error, stackTrace) {
      if (isTypedConvexNotFoundError(error)) return DeletedPageRestore.gone;
      AppErrorReporter.reportError(
        'Could not restore a deleted page.',
        error: error,
        stackTrace: stackTrace,
        source: 'strategy_page_session:restore_page',
        promptUser: false,
      );
      return DeletedPageRestore.failed;
    }
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
  /// [settled]. Returns whether it did.
  Future<bool> _queueSettles(
    bool Function(StrategyOpQueueState queue) settled,
  ) async {
    if (settled(ref.read(strategyOpQueueProvider))) return true;
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
    return done.isCompleted;
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
