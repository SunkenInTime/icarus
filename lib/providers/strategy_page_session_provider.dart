import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/strategy_page_apply.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy/strategy_page_source.dart';

enum PageTransitionState {
  idle,
  animatingForward,
  animatingBackward,
}

enum PageSwitchDirection { next, previous }

class StrategyPageSessionState {
  const StrategyPageSessionState({
    required this.activePageId,
    required this.availablePageIds,
    required this.transitionState,
    required this.isApplyingPage,
  });

  final String? activePageId;
  final List<String> availablePageIds;
  final PageTransitionState transitionState;
  final bool isApplyingPage;

  StrategyPageSessionState copyWith({
    String? activePageId,
    bool clearActivePageId = false,
    List<String>? availablePageIds,
    PageTransitionState? transitionState,
    bool? isApplyingPage,
  }) {
    return StrategyPageSessionState(
      activePageId:
          clearActivePageId ? null : (activePageId ?? this.activePageId),
      availablePageIds: availablePageIds ?? this.availablePageIds,
      transitionState: transitionState ?? this.transitionState,
      isApplyingPage: isApplyingPage ?? this.isApplyingPage,
    );
  }
}

final strategyPageSessionProvider =
    NotifierProvider<StrategyPageSessionNotifier, StrategyPageSessionState>(
  StrategyPageSessionNotifier.new,
);

class StrategyPageSessionNotifier extends Notifier<StrategyPageSessionState> {
  int? _lastHydratedRemoteSequence;
  String? _lastHydratedRemoteStrategyId;
  String? _lastHydratedRemotePageId;
  bool _pendingRemoteReapply = false;

  @override
  StrategyPageSessionState build() {
    ref.listen<AsyncValue<RemoteStrategySnapshot?>>(
      remoteStrategySnapshotProvider,
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
          ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
        final orderedIds =
            pageIds.map((page) => page.publicId).toList(growable: false);
        if (!listEquals(orderedIds, state.availablePageIds)) {
          state = state.copyWith(availablePageIds: orderedIds);
        }

        final prevSequence = previous?.valueOrNull?.header.sequence;
        final sequenceChanged =
            prevSequence == null || prevSequence != snapshot.header.sequence;
        if (!sequenceChanged) {
          return;
        }

        final targetPageId = _resolveHydrationTargetPage(snapshot);
        if (targetPageId == null) {
          return;
        }

        final alreadyHydrated =
            _lastHydratedRemoteStrategyId == snapshot.header.publicId &&
                _lastHydratedRemoteSequence == snapshot.header.sequence &&
                _lastHydratedRemotePageId == targetPageId;
        if (alreadyHydrated) {
          return;
        }

        if (_canSafelyReapplyRemotePage()) {
          unawaited(_rehydrateActivePageFromSource(targetPageId));
        } else {
          _pendingRemoteReapply = true;
        }
      },
    );

    ref.listen<StrategySaveState>(strategySaveStateProvider, (_, __) {
      if (_pendingRemoteReapply && _canSafelyReapplyRemotePage()) {
        _pendingRemoteReapply = false;
        final pageId = state.activePageId;
        if (pageId != null) {
          unawaited(_rehydrateActivePageFromSource(pageId));
        }
      }
    });

    ref.listen<StrategyOpQueueState>(strategyOpQueueProvider, (previous, next) {
      final previousAcks = previous?.lastAcks ?? const <OpAck>[];
      if (next.lastAcks.isEmpty || identical(previousAcks, next.lastAcks)) {
        return;
      }
      unawaited(_reconcileAcks(next.lastAcks));
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
    );

    if (selected != null) {
      await _rehydrateActivePageFromSource(selected);
    }
  }

  Future<void> setActivePage(String pageId) async {
    if (pageId == state.activePageId) {
      return;
    }
    await _switchToPage(pageId, animated: false);
  }

  Future<void> setActivePageAnimated(
    String pageId, {
    required PageTransitionDirection direction,
    Duration duration = kPageTransitionDuration,
  }) async {
    if (pageId == state.activePageId) {
      return;
    }

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
    transitionNotifier.prepare(
      previous.values.toList(),
      direction: direction,
      startAgentSize: startSettings.agentSize,
      startAbilitySize: startSettings.abilitySize,
    );

    await _switchToPage(
      pageId,
      animated: true,
      direction: direction,
    );
    final endSettings = ref.read(strategySettingsProvider);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final next = _snapshotAllPlaced();
      final entries = _diffToTransitions(previous, next);
      if (entries.isNotEmpty) {
        transitionNotifier.start(
          entries,
          duration: duration,
          direction: direction,
          startAgentSize: startSettings.agentSize,
          endAgentSize: endSettings.agentSize,
          startAbilitySize: startSettings.abilitySize,
          endAbilitySize: endSettings.abilitySize,
        );
      } else {
        transitionNotifier.complete();
      }
      state = state.copyWith(transitionState: PageTransitionState.idle);
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
    await source.flushCurrentPage();
    if (flushImmediately && strategyState.source == StrategySource.cloud) {
      await ref.read(strategyOpQueueProvider.notifier).flushNow();
    }
  }

  bool get isApplyingPage => state.isApplyingPage;

  void setStateForTest(StrategyPageSessionState newState) {
    state = newState;
  }

  void reset() {
    state = const StrategyPageSessionState(
      activePageId: null,
      availablePageIds: [],
      transitionState: PageTransitionState.idle,
      isApplyingPage: false,
    );
    _lastHydratedRemoteSequence = null;
    _lastHydratedRemoteStrategyId = null;
    _lastHydratedRemotePageId = null;
    _pendingRemoteReapply = false;
  }

  Future<void> _switchToPage(
    String pageId, {
    required bool animated,
    PageTransitionDirection? direction,
  }) async {
    final strategyState = ref.read(strategyProvider);
    final strategyId = strategyState.strategyId;
    final source = strategyState.source;
    if (strategyId == null || source == null) {
      return;
    }

    final pageSource = _resolvePageSource(strategyId, source);
    await pageSource.flushCurrentPage();
    if (source == StrategySource.cloud) {
      await ref.read(strategyOpQueueProvider.notifier).flushNow();
    }

    final pageData = await pageSource.loadPage(pageId);
    await _applyLoadedPageData(
      pageData,
      strategyId: strategyId,
      source: source,
    );

    if (animated && direction != null) {
      _updateHydrationBookkeeping(pageData.pageId);
    }
  }

  Future<void> _rehydrateActivePageFromSource(String pageId) async {
    final strategyState = ref.read(strategyProvider);
    final strategyId = strategyState.strategyId;
    final source = strategyState.source;
    if (strategyId == null || source == null) {
      return;
    }

    final pageData =
        await _resolvePageSource(strategyId, source).loadPage(pageId);
    await _applyLoadedPageData(
      pageData,
      strategyId: strategyId,
      source: source,
    );
  }

  Future<void> _applyLoadedPageData(
    StrategyEditorPageData pageData, {
    required String strategyId,
    required StrategySource source,
  }) async {
    final preserveHistory = source == StrategySource.cloud &&
        _lastHydratedRemoteStrategyId == strategyId &&
        _lastHydratedRemotePageId == pageData.pageId;
    final themeProfileId = _resolveThemeProfileId(source, strategyId);
    final themeOverridePalette =
        _resolveThemeOverridePalette(source, strategyId);

    state = state.copyWith(
      isApplyingPage: true,
      activePageId: pageData.pageId,
      availablePageIds:
          await _resolvePageSource(strategyId, source).listPageIds(),
    );

    try {
      await applyStrategyEditorPageData(
        ref,
        pageData,
        themeProfileId: themeProfileId,
        themeOverridePalette: themeOverridePalette,
        preserveHistory: preserveHistory,
      );
      _updateHydrationBookkeeping(pageData.pageId);
    } finally {
      state = state.copyWith(
        activePageId: pageData.pageId,
        isApplyingPage: false,
      );
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
      final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
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
          .read(remoteStrategySnapshotProvider)
          .valueOrNull
          ?.header
          .themeOverridePalette;
      if (payload == null || payload.isEmpty) {
        return null;
      }
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          return MapThemePalette.fromJson(decoded);
        }
        if (decoded is Map) {
          return MapThemePalette.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        return null;
      }
      return null;
    }

    return Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .get(strategyId)
        ?.themeOverridePalette;
  }

  bool _canSafelyReapplyRemotePage() {
    final saveState = ref.read(strategySaveStateProvider);
    return !state.isApplyingPage &&
        state.transitionState == PageTransitionState.idle &&
        !saveState.isDirty &&
        !saveState.hasPendingCloudSync &&
        !saveState.isSaving;
  }

  String? _resolveHydrationTargetPage(RemoteStrategySnapshot snapshot) {
    if (snapshot.pages.isEmpty) {
      return null;
    }

    final activePageId = state.activePageId;
    if (activePageId != null &&
        snapshot.pages.any((page) => page.publicId == activePageId)) {
      return activePageId;
    }

    final pages = [...snapshot.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    return pages.first.publicId;
  }

  void _updateHydrationBookkeeping(String pageId) {
    final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
    if (snapshot == null) {
      return;
    }
    _lastHydratedRemoteStrategyId = snapshot.header.publicId;
    _lastHydratedRemoteSequence = snapshot.header.sequence;
    _lastHydratedRemotePageId = pageId;
  }

  Future<void> _reconcileAcks(List<OpAck> acks) async {
    final strategyState = ref.read(strategyProvider);
    if (strategyState.source != StrategySource.cloud || acks.isEmpty) {
      return;
    }

    var hasReject = false;
    for (final ack in acks) {
      if (ack.isAck) {
        continue;
      }
      hasReject = true;
      Map<String, dynamic>? serverPayload;
      if (ack.latestPayload != null && ack.latestPayload!.isNotEmpty) {
        try {
          final decoded = jsonDecode(ack.latestPayload!);
          if (decoded is Map<String, dynamic>) {
            serverPayload = decoded;
          }
        } catch (_) {
          serverPayload = null;
        }
      }

      ref.read(strategyConflictProvider.notifier).push(
            ConflictResolution(
              type: ConflictResolutionType.rebase,
              opId: ack.opId,
              message: ack.reason,
              serverPayload: serverPayload,
              serverRevision: ack.latestRevision,
              serverSequence: ack.latestSequence,
            ),
          );
    }

    if (!hasReject) {
      return;
    }

    await ref.read(remoteStrategySnapshotProvider.notifier).refresh();
    if (_canSafelyReapplyRemotePage() && state.activePageId != null) {
      await _rehydrateActivePageFromSource(state.activePageId!);
    } else {
      _pendingRemoteReapply = true;
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
  ) {
    final entries = <PageTransitionEntry>[];
    var order = 0;

    next.forEach((id, to) {
      final from = previous[id];
      if (from != null) {
        if (from.position != to.position ||
            PageTransitionEntry.rotationOf(from) !=
                PageTransitionEntry.rotationOf(to) ||
            PageTransitionEntry.lengthOf(from) !=
                PageTransitionEntry.lengthOf(to) ||
            !listEquals(
              PageTransitionEntry.armLengthsOf(from),
              PageTransitionEntry.armLengthsOf(to),
            ) ||
            PageTransitionEntry.scaleOf(from) !=
                PageTransitionEntry.scaleOf(to) ||
            PageTransitionEntry.textSizeOf(from) !=
                PageTransitionEntry.textSizeOf(to) ||
            PageTransitionEntry.agentStateOf(from) !=
                PageTransitionEntry.agentStateOf(to) ||
            PageTransitionEntry.customDiameterOf(from) !=
                PageTransitionEntry.customDiameterOf(to) ||
            PageTransitionEntry.customWidthOf(from) !=
                PageTransitionEntry.customWidthOf(to) ||
            PageTransitionEntry.customLengthOf(from) !=
                PageTransitionEntry.customLengthOf(to)) {
          entries
              .add(PageTransitionEntry.move(from: from, to: to, order: order));
        } else {
          entries.add(PageTransitionEntry.none(to: to, order: order));
        }
      } else {
        entries.add(PageTransitionEntry.appear(to: to, order: order));
      }
      order++;
    });

    previous.forEach((id, from) {
      if (!next.containsKey(id)) {
        entries.add(PageTransitionEntry.disappear(from: from, order: order));
        order++;
      }
    });

    return entries;
  }
}
