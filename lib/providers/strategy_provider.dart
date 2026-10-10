import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:math' show max;
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/sort_index_order.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auto_save_notifier.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/pinned_items_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/strategy_capabilities.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/services/analytics_service.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

export 'package:icarus/strategy/strategy_models.dart'
    show StrategyData, StrategyState;

final strategyProvider =
    NotifierProvider<StrategyProvider, StrategyState>(StrategyProvider.new);

/// What became of copying an item to the next or previous page.
enum PageCopyResult {
  copied,

  /// The page already has the item, or a copy of it.
  alreadyThere,

  /// The cloud page could not be read, so nothing was copied.
  unreachable,

  /// This device could not store the copy to send, so nothing was copied.
  notSaved,

  /// There was nothing to copy, or no page to copy it to.
  unavailable,
}

class StrategyProvider extends Notifier<StrategyState> {
  @override
  StrategyState build() {
    _registerPersistenceTrackingListeners();
    ref.listen<AppAuthState>(authProvider, (previous, next) {
      final strategyId = state.strategyId;
      if (state.source != StrategySource.cloud || strategyId == null) {
        return;
      }
      final becameReady =
          !(previous?.isConvexUserReady ?? false) && next.isConvexUserReady;
      if (!becameReady) {
        return;
      }
      unawaited(
        ref.read(cloudMediaUploadQueueProvider.notifier).retryNow(
              ignoreBackoff: true,
            ),
      );
    });

    return const StrategyState(
      strategyId: null,
      strategyName: null,
      source: null,
      storageDirectory: null,
      isOpen: false,
    );
  }

  Timer? _saveTimer;

  Future<void>? _activeSave;
  String? _pendingSaveId;
  bool _cloudMutationSyncScheduled = false;
  bool _cloudStrategyMutationSyncScheduled = false;
  int _persistenceTrackingSuspensionCount = 0;

  void _registerPersistenceTrackingListeners() {
    _listenForPageBackedState(agentProvider);
    _listenForPageBackedState(abilityProvider);
    _listenForPageBackedState(
      drawingProvider.select((drawing) => drawing.elements),
    );
    _listenForPageBackedState(textProvider);
    _listenForPageBackedState(
      placedImageProvider.select((images) => images.images),
    );
    _listenForPageBackedState(utilityProvider);
    _listenForPageBackedState(
      lineUpProvider.select(
        (lineups) => (lineups.origins, lineups.landings, lineups.links),
      ),
    );
    _listenForPageBackedState(strategySettingsProvider);
    _listenForPageBackedState(mapProvider.select((map) => map.isAttack));

    _listenForStrategyBackedState(mapProvider.select((map) => map.currentMap));
    _listenForStrategyBackedState(strategyThemeProvider);
  }

  void _listenForPageBackedState<T>(ProviderListenable<T> provider) {
    ref.listen<T>(provider, (_, __) {
      if (!_shouldTrackPersistedEditorMutation()) {
        return;
      }
      setUnsaved();
    });
  }

  void _listenForStrategyBackedState<T>(ProviderListenable<T> provider) {
    ref.listen<T>(provider, (_, __) {
      if (!_shouldTrackPersistedEditorMutation()) {
        return;
      }
      _markStrategyBackedStateUnsaved();
    });
  }

  bool _shouldTrackPersistedEditorMutation() {
    if (_persistenceTrackingSuspensionCount > 0) {
      return false;
    }
    if (!state.isOpen || state.strategyId == null || state.source == null) {
      return false;
    }
    return !ref.read(strategyPageSessionProvider).isApplyingPage &&
        _currentStrategyCanEditPages();
  }

  T _withoutPersistenceTracking<T>(T Function() callback) {
    _persistenceTrackingSuspensionCount += 1;
    try {
      return callback();
    } finally {
      _persistenceTrackingSuspensionCount -= 1;
    }
  }

  //Used For Images
  void setFromState(StrategyState newState) {
    final hasIdentity =
        newState.strategyId != null || newState.strategyName != null;
    state = newState.isOpen || !hasIdentity
        ? newState
        : newState.copyWith(isOpen: true);
    final activePageId = newState.activePageId;
    if (activePageId != null) {
      final session = ref.read(strategyPageSessionProvider);
      ref.read(strategyPageSessionProvider.notifier).setStateForTest(
            session.copyWith(
              activePageId: activePageId,
              availablePageIds: session.availablePageIds.contains(activePageId)
                  ? session.availablePageIds
                  : [...session.availablePageIds, activePageId],
            ),
          );
    }
  }

  @Deprecated('Use strategyPageSessionProvider instead.')
  set activePageID(String pageId) {
    state = state.copyWith(activePageId: pageId);
    final session = ref.read(strategyPageSessionProvider);
    ref.read(strategyPageSessionProvider.notifier).setStateForTest(
          session.copyWith(
            activePageId: pageId,
            availablePageIds: session.availablePageIds.contains(pageId)
                ? session.availablePageIds
                : [...session.availablePageIds, pageId],
          ),
        );
  }

  void cancelPendingSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  void refreshAutosaveScheduling() {
    cancelPendingSave();
    if (!state.isOpen || !ref.read(strategySaveStateProvider).isDirty) {
      return;
    }
    if (_currentStrategyIsCloud()) {
      return;
    }
    if (!ref.read(appPreferencesProvider).autosaveEnabled) {
      return;
    }

    _saveTimer = Timer(Settings.autoSaveOffset, () async {
      final strategyId = state.strategyId;
      if (strategyId == null) {
        return;
      }
      await _performSave(strategyId);
    });
  }

  Future<bool> flushPendingAutosaveBeforeExit() async {
    final strategyId = state.strategyId;
    if (strategyId == null || state.strategyName == null) {
      return true;
    }

    final hasTextDrafts = ref.read(textDraftProvider).isNotEmpty;
    final saveState = ref.read(strategySaveStateProvider);
    if (!saveState.isDirty && !hasTextDrafts) {
      return true;
    }

    if (!_currentStrategyIsCloud() &&
        !ref.read(appPreferencesProvider).autosaveEnabled) {
      return false;
    }

    await forceSaveNow(strategyId);
    return !ref.read(strategySaveStateProvider).isDirty;
  }

  bool _currentStrategyIsCloud() {
    return state.source == StrategySource.cloud;
  }

  bool _currentStrategyCanEditPages() {
    if (!_currentStrategyIsCloud()) {
      return true;
    }
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    final role = snapshot?.header.publicId == state.strategyId
        ? snapshot?.header.role
        : null;
    return StrategyCapabilities.fromCloudRole(role).canEditPages;
  }

  /// Fails loudly instead of reading or writing the on-device library where
  /// the platform policy keeps it hidden. Its records stay untouched until
  /// local access returns.
  void _requireLocalLibrary(String action) {
    if (ref.read(platformPolicyProvider).allowsLocalLibrary) return;
    throw StateError(
      'Cannot $action a local strategy: the local library is not available '
      'on this platform.',
    );
  }

  bool _selectedWorkspaceIsCloud() {
    return ref.read(libraryWorkspaceProvider) == LibraryWorkspace.cloud;
  }

  StrategySource _resolveLibraryMutationSource() {
    final currentSource = state.source;
    if (currentSource != null) {
      return currentSource;
    }
    return _selectedWorkspaceIsCloud()
        ? StrategySource.cloud
        : StrategySource.local;
  }

  Future<bool> _reportCloudUnauthenticated({
    required String source,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    if (!isConvexUnauthenticatedError(error)) {
      return false;
    }

    await ref.read(authProvider.notifier).reportConvexUnauthenticated(
          source: source,
          error: error,
          stackTrace: stackTrace,
        );
    return true;
  }

  Future<void> openStrategy(String strategyID) async {
    await openCloudStrategy(strategyID);
  }

  Future<void> openCloudStrategy(String strategyID) async {
    cancelPendingSave();
    ref.read(strategySaveStateProvider.notifier).reset();

    await ref
        .read(remoteEditorSnapshotProvider.notifier)
        .openStrategy(strategyID);
    final snapshotState = ref.read(remoteEditorSnapshotProvider);
    final snapshot = snapshotState.valueOrNull;
    if (snapshot == null) {
      // Returning silently here used to leave the editor on an eternal
      // skeleton with no feedback. Throw so callers can surface the failure
      // and back out.
      throw StateError(
        'Cloud strategy snapshot unavailable for $strategyID'
        '${snapshotState.hasError ? ': ${snapshotState.error}' : ''}',
      );
    }

    final storageDirectory = kIsWeb
        ? null
        : (await setStorageDirectory(snapshot.header.publicId)).path;
    state = state.copyWith(
      strategyId: snapshot.header.publicId,
      strategyName: snapshot.header.name,
      source: StrategySource.cloud,
      storageDirectory: storageDirectory,
      isOpen: true,
    );

    await ref.read(strategyPageSessionProvider.notifier).initializeForStrategy(
          strategyId: snapshot.header.publicId,
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    unawaited(
      ref.read(cloudMediaUploadQueueProvider.notifier).reconcilePageMedia(
            strategyPublicId: snapshot.header.publicId,
            placedImages: ref.read(placedImageProvider).images,
            assetsById: snapshot.assetsById,
          ),
    );
    unawaited(
      ref.read(cloudMediaUploadQueueProvider.notifier).setActiveStrategy(
            snapshot.header.publicId,
          ),
    );
  }

  Future<void> switchPage(String pageID) async {
    await ref.read(strategyPageSessionProvider.notifier).setActivePageAnimated(
          pageID,
          direction: PageTransitionDirection.forward,
        );
  }

  Future<void> enqueueOps(
    List<StrategyOp> ops, {
    bool flushImmediately = false,
  }) async {
    if (!_currentStrategyIsCloud() ||
        !_currentStrategyCanEditPages() ||
        ops.isEmpty) {
      return;
    }

    ref
        .read(strategyOpQueueProvider.notifier)
        .enqueueAll(ops, flushImmediately: flushImmediately);
    if (ref.read(strategyPageSessionProvider).isApplyingPage) {
      return;
    }

    ref.read(strategySaveStateProvider.notifier)
      ..markDirty()
      ..setPendingCloudSync(true)
      ..setCloudSyncError(null);
  }

  Future<OpAck?> _enqueueCloudPageDescriptorOp(StrategyOp op) async {
    await enqueueOps([op]);
    final queue = ref.read(strategyOpQueueProvider.notifier);
    await queue.flushNow();
    return ref
        .read(strategyOpQueueProvider)
        .lastAcks
        .where((ack) => ack.opId == op.opId)
        .firstOrNull;
  }

  Future<void> notifyCloudMutation({bool flushImmediately = false}) async {
    _cloudMutationSyncScheduled = false;
    if (!_currentStrategyIsCloud() || !_currentStrategyCanEditPages()) {
      return;
    }

    ref.read(strategySaveStateProvider.notifier)
      ..markDirty()
      ..setPendingCloudSync(true)
      ..setCloudSyncError(null);
    await ref
        .read(strategyPageSessionProvider.notifier)
        .flushCurrentPage(flushImmediately: flushImmediately);
  }

  Future<void> notifyCloudStrategyMutation({
    bool flushImmediately = false,
  }) async {
    _cloudStrategyMutationSyncScheduled = false;
    if (!_currentStrategyIsCloud() || !_currentStrategyCanEditPages()) {
      return;
    }

    ref.read(strategySaveStateProvider.notifier)
      ..markDirty()
      ..setPendingCloudSync(true)
      ..setCloudSyncError(null);

    final desiredOp = _buildDesiredStrategySyncOp();
    ref.read(strategyOpQueueProvider.notifier).syncDesiredGenericOp(
          entityKey: const EntitySyncKey.strategy(),
          desiredOp: desiredOp,
          flushImmediately: flushImmediately,
        );
    if (flushImmediately) {
      await ref.read(strategyOpQueueProvider.notifier).flushNow();
    }
  }

  void _scheduleCloudMutationSync() {
    if (_cloudMutationSyncScheduled) {
      return;
    }
    _cloudMutationSyncScheduled = true;
    scheduleMicrotask(() async {
      if (!_cloudMutationSyncScheduled) {
        return;
      }
      await notifyCloudMutation(flushImmediately: false);
    });
  }

  void consumeScheduledCloudPageSync() {
    _cloudMutationSyncScheduled = false;
  }

  void consumeScheduledCloudStrategySync() {
    _cloudStrategyMutationSyncScheduled = false;
  }

  void _scheduleCloudStrategySync() {
    if (_cloudStrategyMutationSyncScheduled) {
      return;
    }
    _cloudStrategyMutationSyncScheduled = true;
    scheduleMicrotask(() async {
      if (!_cloudStrategyMutationSyncScheduled) {
        return;
      }
      await notifyCloudStrategyMutation(flushImmediately: false);
    });
  }

  void _markStrategyBackedStateUnsaved() {
    if (!state.isOpen || state.strategyId == null || state.source == null) {
      return;
    }
    if (ref.read(strategyPageSessionProvider).isApplyingPage) {
      return;
    }
    if (!_currentStrategyCanEditPages()) {
      return;
    }

    if (_currentStrategyIsCloud()) {
      ref.read(strategySaveStateProvider.notifier)
        ..markDirty()
        ..setPendingCloudSync(true)
        ..setCloudSyncError(null);
      _scheduleCloudStrategySync();
      return;
    }

    ref.read(strategySaveStateProvider.notifier).markDirty();
    refreshAutosaveScheduling();
  }

  StrategyOp? _buildDesiredStrategySyncOp() {
    final strategyId = state.strategyId;
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    if (strategyId == null ||
        snapshot == null ||
        snapshot.header.publicId != strategyId) {
      return null;
    }

    final strategyTheme = ref.read(strategyThemeProvider);
    final localMapData = Maps.mapNames[ref.read(mapProvider).currentMap] ??
        snapshot.header.mapData;
    final localThemeProfileId = strategyTheme.profileId;
    final localThemeOverridePalette = strategyTheme.overridePalette?.toJson();

    final matchesRemote = snapshot.header.mapData == localMapData &&
        snapshot.header.themeProfileId == localThemeProfileId &&
        cloudJsonEquivalent(
          snapshot.header.themeOverridePalette,
          localThemeOverridePalette,
        );
    if (matchesRemote) {
      return null;
    }

    return StrategyPatchOp(
      opId: const Uuid().v4(),
      expectedStrategyRevision: snapshot.header.revision,
      payload: {
        'mapData': localMapData,
        if (localThemeProfileId != null) 'themeProfileId': localThemeProfileId,
        if (localThemeProfileId == null) 'clearThemeProfileId': true,
        if (localThemeOverridePalette != null)
          'themeOverridePalette': localThemeOverridePalette,
        if (localThemeOverridePalette == null)
          'clearThemeOverridePalette': true,
      },
    );
  }

  void setUnsaved() {
    if (!state.isOpen || state.strategyId == null || state.source == null) {
      return;
    }
    if (ref.read(strategyPageSessionProvider).isApplyingPage) {
      return;
    }
    if (!_currentStrategyCanEditPages()) {
      return;
    }

    state = state.copyWith(isSaved: false);

    if (_currentStrategyIsCloud()) {
      ref.read(strategySaveStateProvider.notifier)
        ..markDirty()
        ..setPendingCloudSync(true)
        ..setCloudSyncError(null);
      _scheduleCloudMutationSync();
      return;
    }

    ref.read(strategySaveStateProvider.notifier).markDirty();
    refreshAutosaveScheduling();
  }

  Future<void> forceSaveNow(String id) async {
    if (!_currentStrategyCanEditPages()) {
      return;
    }
    cancelPendingSave();
    if (_currentStrategyIsCloud()) {
      ref.read(strategySaveStateProvider.notifier)
        ..markDirty()
        ..setPendingCloudSync(true);
    }
    await _performSave(id);
  }

  // Calls made during an active save wait for one coalesced follow-up save.
  Future<void> _performSave(String id) {
    _pendingSaveId = id;
    return _activeSave ??= _drainPendingSaves();
  }

  Future<void> _drainPendingSaves() async {
    ref.read(strategySaveStateProvider.notifier).markSaving(true);
    try {
      while (_pendingSaveId != null) {
        final id = _pendingSaveId!;
        _pendingSaveId = null;
        ref.read(autoSaveProvider.notifier).ping();
        if (_currentStrategyIsCloud()) {
          await notifyCloudStrategyMutation(flushImmediately: true);
          await ref
              .read(strategyPageSessionProvider.notifier)
              .flushCurrentPage(flushImmediately: true);
        } else {
          await saveToHive(id);
        }
      }
    } finally {
      ref.read(strategySaveStateProvider.notifier).markSaving(false);
      _activeSave = null;
    }
  }

  Future<Directory> setStorageDirectory(String strategyID) async {
    // final strategyID = state.id;
    // Get the system's application support directory.
    final directory = await getApplicationSupportDirectory();

    // Create a custom directory inside the application support directory.

    final customDirectory = Directory(path.join(directory.path, strategyID));

    if (!await customDirectory.exists()) {
      await customDirectory.create(recursive: true);
    }

    return customDirectory;
  }

  Future<void> clearCurrentStrategy() async {
    cancelPendingSave();
    ref.read(strategyThemeProvider.notifier).fromStrategy();
    ref.read(strategySaveStateProvider.notifier).reset();
    ref.read(strategyPageSessionProvider.notifier).reset();
    state = StrategyState(
      strategyId: null,
      strategyName: null,
      source: null,
      storageDirectory: state.storageDirectory,
      isOpen: false,
    );
    ref.read(remoteEditorSnapshotProvider.notifier).clear();
    unawaited(
      ref.read(cloudMediaUploadQueueProvider.notifier).setActiveStrategy(null),
    );
  }

  // Switch active page: flush old page first, then hydrate new
  Future<void> setActivePage(String pageID) async {
    await ref.read(strategyPageSessionProvider.notifier).setActivePage(pageID);
    state = state.copyWith(activePageId: pageID);
  }

  Future<void> backwardPage() async {
    await ref
        .read(strategyPageSessionProvider.notifier)
        .switchRelativePage(PageSwitchDirection.previous);
  }

  Future<void> forwardPage() async {
    await ref
        .read(strategyPageSessionProvider.notifier)
        .switchRelativePage(PageSwitchDirection.next);
  }

  static List<StrategyPage> reindexPagesAfterStructuralChange(
    List<StrategyPage> orderedPages,
  ) {
    return [
      for (var i = 0; i < orderedPages.length; i++)
        orderedPages[i].copyWith(
          sortIndex: i,
          name: orderedPages[i].isAutoNamed == true
              ? 'Page ${i + 1}'
              : orderedPages[i].name,
        ),
    ];
  }

  Future<void> reorderPage(int oldIndex, int newIndex) async {
    if (!_currentStrategyCanEditPages()) return;
    if (oldIndex == newIndex) return;

    if (_currentStrategyIsCloud()) {
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      if (snapshot == null || snapshot.pages.isEmpty) return;
      final ordered = [...snapshot.pages]
        ..sortBySortIndex((item) => item.sortIndex);
      if (oldIndex < 0 ||
          oldIndex >= ordered.length ||
          newIndex < 0 ||
          newIndex > ordered.length) {
        return;
      }

      final moved = ordered.removeAt(oldIndex);
      final targetIndex = newIndex.clamp(0, ordered.length);
      ordered.insert(targetIndex, moved);

      final ack = await _enqueueCloudPageDescriptorOp(PageReorderOp(
        opId: const Uuid().v4(),
        pagePublicId: moved.publicId,
        sortIndex: targetIndex,
        expectedStrategyRevision: snapshot.header.revision,
      ));
      if (ack != null) {
        await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
      }
      return;
    }

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategyId = state.strategyId;
    if (strategyId == null) return;
    final strat = box.get(strategyId);
    if (strat == null || strat.pages.isEmpty) return;

    final ordered = [...strat.pages]..sortBySortIndex((item) => item.sortIndex);

    if (oldIndex < 0 ||
        oldIndex >= ordered.length ||
        newIndex < 0 ||
        newIndex > ordered.length) {
      return;
    }

    final moved = ordered.removeAt(oldIndex);
    final targetIndex = newIndex.clamp(0, ordered.length);
    ordered.insert(targetIndex, moved);

    final reindexed = reindexPagesAfterStructuralChange(ordered);

    final updated =
        strat.copyWith(pages: reindexed, lastEdited: DateTime.now());
    await box.put(updated.id, updated);
  }

  // Add these inside StrategyProvider
  Future<void> setActivePageAnimated(String pageID,
      {PageTransitionDirection? direction,
      Duration duration = kPageTransitionDuration}) async {
    await ref.read(strategyPageSessionProvider.notifier).setActivePageAnimated(
          pageID,
          direction: direction ?? PageTransitionDirection.forward,
          duration: duration,
        );
    state = state.copyWith(activePageId: pageID);
  }

  static StrategyData migrateToCurrentVersion(
    StrategyData strategy, {
    bool forceAbilityScale = false,
  }) {
    return StrategyMigrator.migrateToCurrentVersion(
      strategy,
      forceAbilityScale: forceAbilityScale,
    );
  }

  static StrategyData migrateAbilityVisionCones(
    StrategyData strategy, {
    bool force = false,
  }) {
    return StrategyMigrator.migrateAbilityVisionCones(
      strategy,
      force: force,
    );
  }

  static String sanitizeFileName(String input) {
    final sanitized = input.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return sanitized.isEmpty ? 'untitled' : sanitized;
  }

  List<PageTransitionDirection> copyDirectionsForPlacedWidget(
    String widgetId,
  ) {
    if (widgetId.isEmpty) return const [];
    if (_currentStrategyIsCloud()) return _cloudCopyDirections(widgetId);
    if (!Hive.isBoxOpen(HiveBoxNames.strategiesBox)) return const [];

    final strategyId = state.strategyId;
    if (strategyId == null) return const [];
    final strat = Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(
      strategyId,
    );
    if (strat == null || strat.pages.length < 2) return const [];

    final orderedPages = [...strat.pages]
      ..sortBySortIndex((item) => item.sortIndex);
    final currentPageId = ref.read(strategyPageSessionProvider).activePageId;
    final currentIndex = orderedPages.indexWhere(
      (page) => page.id == currentPageId,
    );
    if (currentIndex < 0) return const [];

    final directions = <PageTransitionDirection>[];
    if (currentIndex > 0 &&
        !_pageContainsPlacedWidget(orderedPages[currentIndex - 1], widgetId)) {
      directions.add(PageTransitionDirection.backward);
    }
    if (currentIndex < orderedPages.length - 1 &&
        !_pageContainsPlacedWidget(orderedPages[currentIndex + 1], widgetId)) {
      directions.add(PageTransitionDirection.forward);
    }
    return directions;
  }

  Future<PageCopyResult> copyPlacedWidgetToAdjacentPage({
    required String widgetId,
    required PageTransitionDirection direction,
  }) async {
    if (widgetId.isEmpty) return PageCopyResult.unavailable;
    if (_currentStrategyIsCloud()) {
      return _copyPlacedWidgetToAdjacentCloudPage(
        widgetId: widgetId,
        direction: direction,
      );
    }
    if (!Hive.isBoxOpen(HiveBoxNames.strategiesBox)) {
      return PageCopyResult.unavailable;
    }

    await _syncCurrentPageToHive();

    final strategyId = state.strategyId;
    if (strategyId == null) return PageCopyResult.unavailable;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(strategyId);
    if (strat == null || strat.pages.length < 2) {
      return PageCopyResult.unavailable;
    }

    final orderedPages = [...strat.pages]
      ..sortBySortIndex((item) => item.sortIndex);
    final currentPageId = ref.read(strategyPageSessionProvider).activePageId;
    final currentIndex = orderedPages.indexWhere(
      (page) => page.id == currentPageId,
    );
    if (currentIndex < 0) return PageCopyResult.unavailable;

    final targetIndex = switch (direction) {
      PageTransitionDirection.backward => currentIndex - 1,
      PageTransitionDirection.forward => currentIndex + 1,
    };
    if (targetIndex < 0 || targetIndex >= orderedPages.length) {
      return PageCopyResult.unavailable;
    }

    final sourcePage = orderedPages[currentIndex];
    final targetPage = orderedPages[targetIndex];
    if (_pageContainsPlacedWidget(targetPage, widgetId)) {
      return PageCopyResult.alreadyThere;
    }

    final updatedTarget = _copyPlacedWidgetBetweenPages(
      widgetId: widgetId,
      source: sourcePage,
      target: targetPage,
    );
    if (updatedTarget == null) return PageCopyResult.unavailable;

    final updatedPages = [
      for (final page in strat.pages)
        if (page.id == targetPage.id) updatedTarget else page,
    ];
    final updated = strat.copyWith(
      pages: updatedPages,
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);
    return PageCopyResult.copied;
  }

  /// Whether [page] has [widgetId] or a copy of the same item (see
  /// page_copy_id.dart).
  static bool _pageContainsPlacedWidget(
    StrategyPage page,
    String widgetId,
  ) {
    final root = pageCopyRoot(widgetId);
    bool same(PlacedWidget widget) => pageCopyRoot(widget.id) == root;
    return page.agentData.any(same) ||
        page.abilityData.any(same) ||
        page.textData.any(same) ||
        page.imageData.any(same) ||
        page.utilityData.any(same);
  }

  /// The pages before and after the one on screen in a cloud strategy. Only
  /// the page on screen is read, so whether a neighbour already has the item
  /// is checked when the copy is made.
  List<PageTransitionDirection> _cloudCopyDirections(String widgetId) {
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    if (snapshot == null ||
        !_currentStrategyCanEditPages() ||
        _cloudElementOnScreen(widgetId) == null) {
      return const [];
    }
    return [
      for (final direction in PageTransitionDirection.values)
        if (_adjacentCloudPageId(snapshot, direction) case final pageId?)
          if (_copyFitsOutbox(pageId, widgetId)) direction,
    ];
  }

  /// Whether a copy of [widgetId] onto [pageId] can be stored to send. Hive
  /// refuses keys over 255 characters, and an op is stored under one naming
  /// its account, strategy, page and item. Only an item imported with an
  /// unusually long id fails this, and it is then not offered.
  bool _copyFitsOutbox(String pageId, String widgetId) {
    final accountId = ref.read(strategyOpQueueProvider).accountId;
    final strategyId = state.strategyId;
    return accountId != null &&
        strategyId != null &&
        DurableOutboxRecord.createStorageKey(
              accountId: accountId,
              strategyPublicId: strategyId,
              entityKey: EntitySyncKey.element(pageId, newPageCopyId(widgetId)),
            ).length <=
            255;
  }

  String? _adjacentCloudPageId(
    RemoteEditorSnapshot snapshot,
    PageTransitionDirection direction,
  ) {
    final pages = [...snapshot.pages]
      ..sortBySortIndex((item) => item.sortIndex);
    final currentIndex = pages.indexWhere(
      (page) =>
          page.publicId == ref.read(strategyPageSessionProvider).activePageId,
    );
    if (currentIndex < 0) return null;
    final targetIndex = switch (direction) {
      PageTransitionDirection.backward => currentIndex - 1,
      PageTransitionDirection.forward => currentIndex + 1,
    };
    if (targetIndex < 0 || targetIndex >= pages.length) return null;
    return pages[targetIndex].publicId;
  }

  /// [widgetId] on the page on screen as cloud element data, or null when it
  /// cannot go to another cloud page. An image's id also names its file on
  /// the server, so a copy of one needs its own file; images stay local-only
  /// for now.
  ({String kind, Map<String, dynamic> data})? _cloudElementOnScreen(
    String widgetId,
  ) {
    ({String kind, Map<String, dynamic> data}) element(
      String kind,
      Map<String, dynamic> json,
    ) =>
        (
          kind: kind,
          data: Map<String, dynamic>.from(json)
            ..putIfAbsent('elementType', () => kind),
        );

    for (final agent in ref.read(agentProvider)) {
      if (agent.id == widgetId) return element('agent', agent.toJson());
    }
    for (final ability in ref.read(abilityProvider)) {
      if (ability.id == widgetId) return element('ability', ability.toJson());
    }
    for (final text
        in ref.read(textProvider.notifier).snapshotForPersistence()) {
      if (text.id == widgetId) return element('text', text.toJson());
    }
    for (final utility in ref.read(utilityProvider)) {
      if (utility.id == widgetId) return element('utility', utility.toJson());
    }
    return null;
  }

  /// Copies [widgetId] to the next or previous page of a cloud strategy, as
  /// a new item whose id carries the original's (see page_copy_id.dart).
  /// The target page is read from the server first: a copy goes after the
  /// page's items, and never beside the item or another copy of it. If the
  /// page cannot be read, nothing is copied. The item is taken as it is when
  /// the user asks; copies then run one at a time, so a second one sees the
  /// first already queued.
  Future<PageCopyResult> _copyPlacedWidgetToAdjacentCloudPage({
    required String widgetId,
    required PageTransitionDirection direction,
  }) {
    final strategyId = state.strategyId;
    final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
    final element = _cloudElementOnScreen(widgetId);
    final targetPageId =
        snapshot == null ? null : _adjacentCloudPageId(snapshot, direction);
    if (strategyId == null ||
        element == null ||
        targetPageId == null ||
        !_currentStrategyCanEditPages()) {
      return Future.value(PageCopyResult.unavailable);
    }
    final result = _cloudCopies.then(
      (_) => _copyToCloudPage(
        strategyId: strategyId,
        targetPageId: targetPageId,
        widgetId: widgetId,
        element: element,
      ),
    );
    _cloudCopies = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _cloudCopies = Future<void>.value();

  Future<PageCopyResult> _copyToCloudPage({
    required String strategyId,
    required String targetPageId,
    required String widgetId,
    required ({String kind, Map<String, dynamic> data}) element,
  }) async {
    if (state.strategyId != strategyId) return PageCopyResult.unavailable;
    final RemotePageSnapshot targetPage;
    try {
      targetPage =
          await ref.read(convexStrategyRepositoryProvider).fetchPageSnapshot(
                strategyPublicId: strategyId,
                pagePublicId: targetPageId,
              );
    } catch (error) {
      log('Could not read page $targetPageId to copy onto it: $error');
      return PageCopyResult.unreachable;
    }
    if (state.strategyId != strategyId) return PageCopyResult.unavailable;

    final onTarget = _cloudElementsOn(targetPage);
    final root = pageCopyRoot(widgetId);
    if (onTarget.keys.any((id) => pageCopyRoot(id) == root)) {
      return PageCopyResult.alreadyThere;
    }

    final accountId = ref.read(strategyOpQueueProvider).accountId;
    final copyId = newPageCopyId(widgetId);
    // Hive refuses keys over 255 characters, and an op is stored under one
    // naming its account, strategy, page and item. Only an imported item
    // with an unusually long id could get here.
    if (accountId == null ||
        DurableOutboxRecord.createStorageKey(
              accountId: accountId,
              strategyPublicId: strategyId,
              entityKey: EntitySyncKey.element(targetPageId, copyId),
            ).length >
            255) {
      return PageCopyResult.unavailable;
    }
    // The canvas never draws the copy: its page shows it from the server.
    final queued =
        await ref.read(strategyOpQueueProvider.notifier).enqueueOffCanvas(
              ElementAddOp(
                opId: const Uuid().v4(),
                elementPublicId: copyId,
                pagePublicId: targetPageId,
                payload: cloudElementPayload(
                  kind: element.kind,
                  data: {...element.data, 'id': copyId},
                ),
                sortIndex: 1 + onTarget.values.fold<int>(-1, max),
              ),
              flushImmediately: true,
            );
    if (!queued) return PageCopyResult.notSaved;
    ref.read(strategySaveStateProvider.notifier)
      ..markDirty()
      ..setPendingCloudSync(true)
      ..setCloudSyncError(null);
    return PageCopyResult.copied;
  }

  /// The items on [page] as the server has them with the work still queued
  /// for it laid over, refused work waiting for the user's choice included,
  /// by id, with their sortIndexes.
  Map<String, int> _cloudElementsOn(RemotePageSnapshot page) {
    final pageId = page.page.publicId;
    final elements = <String, int>{
      for (final element in page.elements)
        if (!element.deleted) element.publicId: element.sortIndex,
    };
    final queue = ref.read(strategyOpQueueProvider);
    // Later entries win: a sent op over a paused one, its successor over it.
    final queued = <EntitySyncKey, StrategyOp>{
      for (final (key, pending) in [
        for (final MapEntry(:key, :value) in queue.attentionByEntityKey.entries)
          (key, value.pending),
        for (final MapEntry(:key, :value) in queue.pausedByEntityKey.entries)
          (key, value.pending),
        for (final MapEntry(:key, :value) in queue.queuedByEntityKey.entries)
          (key, value.pending),
        for (final MapEntry(:key, :value) in queue.inFlightByEntityKey.entries)
          (key, value.pending),
        for (final MapEntry(:key, :value) in queue.successorByEntityKey.entries)
          (key, value.pending),
      ])
        if (key.kind == EntitySyncKeyKind.element && key.pageId == pageId)
          key: pending.op,
    };
    queued.forEach((key, op) {
      final id = key.entityId!;
      switch (op) {
        case ElementDeleteOp():
          elements.remove(id);
        case ElementAddOp(:final sortIndex):
          elements[id] = sortIndex;
        default:
          elements[id] = op.sortIndex ?? elements[id] ?? 0;
      }
    });
    return elements;
  }

  /// The pages next to the one on screen that the lineups [linkIds] can be
  /// copied to, as for a placed item: a local neighbour that already has
  /// one of them, or a copy of it, is left out. Only the page on screen of
  /// a cloud strategy is read, so there the check waits for the copy.
  List<PageTransitionDirection> copyDirectionsForLineUps(
    Set<String> linkIds,
  ) {
    if (linkIds.isEmpty) return const [];
    if (_currentStrategyIsCloud()) {
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      if (snapshot == null || !_currentStrategyCanEditPages()) return const [];
      return [
        for (final direction in PageTransitionDirection.values)
          if (_adjacentCloudPageId(snapshot, direction) case final pageId?)
            if (_lineUpCopyFitsOutbox(pageId, linkIds)) direction,
      ];
    }
    final pages = _orderedLocalPages();
    final currentIndex = pages.indexWhere(
      (page) => page.id == ref.read(strategyPageSessionProvider).activePageId,
    );
    if (currentIndex < 0) return const [];
    final roots = {for (final id in linkIds) pageCopyRoot(id)};
    bool has(StrategyPage page) =>
        page.lineUpLinks.any((link) => roots.contains(pageCopyRoot(link.id)));
    return [
      if (currentIndex > 0 && !has(pages[currentIndex - 1]))
        PageTransitionDirection.backward,
      if (currentIndex < pages.length - 1 && !has(pages[currentIndex + 1]))
        PageTransitionDirection.forward,
    ];
  }

  /// Whether a cloud copy of the lineups [linkIds] onto [pageId] can be
  /// stored to send. Hive refuses keys over 255 characters, and an op is
  /// stored under one naming its account, strategy, page and group, whose id
  /// is one of the copies' lineup ids. Only a lineup imported with an
  /// unusually long id fails this, and it is then not offered.
  bool _lineUpCopyFitsOutbox(String pageId, Set<String> linkIds) {
    final accountId = ref.read(strategyOpQueueProvider).accountId;
    final strategyId = state.strategyId;
    return accountId != null &&
        strategyId != null &&
        linkIds.every(
          (id) =>
              DurableOutboxRecord.createStorageKey(
                accountId: accountId,
                strategyPublicId: strategyId,
                entityKey: EntitySyncKey.lineup(pageId, newPageCopyId(id)),
              ).length <=
              255,
        );
  }

  /// The local strategy's pages in order, or none.
  List<StrategyPage> _orderedLocalPages() {
    final strategyId = state.strategyId;
    if (strategyId == null || !Hive.isBoxOpen(HiveBoxNames.strategiesBox)) {
      return const [];
    }
    final strat =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategyId);
    if (strat == null) return const [];
    return [...strat.pages]..sortBySortIndex((item) => item.sortIndex);
  }

  /// Copies the lineups [linkIds] on screen, and the spots they aim at, to
  /// the next or previous page, as copying a placed item does. Each copied
  /// lineup and spot gets an id that carries the original's (see
  /// page_copy_id.dart), so a page that already has one of them, or a copy
  /// of it, gets no other. [linkIds] share a spot, as the menus pick them;
  /// on a cloud strategy lineups that don't are not copied. The copies keep
  /// their media: an image is only cleaned up once nothing in the strategy
  /// shows it. The lineups are taken as they are when the user asks.
  Future<PageCopyResult> copyLineUpsToAdjacentPage({
    required Set<String> linkIds,
    required PageTransitionDirection direction,
  }) async {
    final strategyId = state.strategyId;
    final copy = ref.read(lineUpProvider).graph.copyOfLinks(linkIds);
    if (strategyId == null || copy.links.isEmpty) {
      return PageCopyResult.unavailable;
    }
    if (_currentStrategyIsCloud()) {
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      final pageId =
          snapshot == null ? null : _adjacentCloudPageId(snapshot, direction);
      if (pageId == null || !_currentStrategyCanEditPages()) {
        return PageCopyResult.unavailable;
      }
      final result = _cloudCopies.then(
        (_) => _copyLineUpsToCloudPage(
          strategyId: strategyId,
          pageId: pageId,
          lineUps: copy,
        ),
      );
      _cloudCopies = result.then((_) {}, onError: (_) {});
      return result;
    }
    return _copyLineUpsToLocalPage(
      strategyId: strategyId,
      direction: direction,
      lineUps: copy,
    );
  }

  /// Whether [links] holds one of [lineUps]' lineups, or a copy of it.
  static bool _hasAnyOf(Iterable<String> links, LineUpGraph lineUps) {
    final roots = {for (final link in lineUps.links) pageCopyRoot(link.id)};
    return links.any((id) => roots.contains(pageCopyRoot(id)));
  }

  Future<PageCopyResult> _copyLineUpsToLocalPage({
    required String strategyId,
    required PageTransitionDirection direction,
    required LineUpGraph lineUps,
  }) async {
    try {
      await _syncCurrentPageToHive();
    } catch (error) {
      log('Could not save the page before copying lineups: $error');
      return PageCopyResult.notSaved;
    }
    if (state.strategyId != strategyId) return PageCopyResult.unavailable;
    final pages = _orderedLocalPages();
    final currentIndex = pages.indexWhere(
      (page) => page.id == ref.read(strategyPageSessionProvider).activePageId,
    );
    final targetIndex = switch (direction) {
      PageTransitionDirection.backward => currentIndex - 1,
      PageTransitionDirection.forward => currentIndex + 1,
    };
    if (currentIndex < 0 || targetIndex < 0 || targetIndex >= pages.length) {
      return PageCopyResult.unavailable;
    }
    final target = pages[targetIndex];
    if (_hasAnyOf(target.lineUpLinks.map((link) => link.id), lineUps)) {
      return PageCopyResult.alreadyThere;
    }

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(strategyId);
    if (strat == null) return PageCopyResult.unavailable;
    final updated = strat.copyWith(
      pages: [
        for (final page in strat.pages)
          if (page.id == target.id)
            page.copyWith(
              lineUpGraph: LineUpGraph(
                origins: [...page.lineUpOrigins, ...lineUps.origins],
                landings: [...page.lineUpLandings, ...lineUps.landings],
                links: [...page.lineUpLinks, ...lineUps.links],
              ),
            )
          else
            page,
      ],
      lastEdited: DateTime.now(),
    );
    try {
      await box.put(updated.id, updated);
    } catch (error) {
      log('Writing lineups to page ${target.id} failed: $error');
      // Hive can store a write and then fail tidying its file, so what the
      // box holds decides whether the lineups are there.
      final stored = box.get(strategyId)?.pages.where((p) => p.id == target.id);
      final landed = stored != null &&
          stored.any((page) => page.lineUpLinks.any(
              (link) => lineUps.links.any((copied) => copied.id == link.id)));
      if (!landed) return PageCopyResult.notSaved;
    }
    return PageCopyResult.copied;
  }

  /// Queues [lineUps] onto cloud page [pageId] as one new lineup group after
  /// the page's own. The page is read from the server first, with the work
  /// still queued for it laid over: if it has one of the lineups, or a copy
  /// of it, nothing is queued, and if it cannot be read, neither.
  Future<PageCopyResult> _copyLineUpsToCloudPage({
    required String strategyId,
    required String pageId,
    required LineUpGraph lineUps,
  }) async {
    // The lineups at one spot share it, so they make one group, and the
    // copy is one write that lands whole or not at all. Its ids are new, so
    // the group's id (its smallest lineup id) is one no row has.
    final rows = cloudLineupRows(lineUps).rows;
    final accountId = ref.read(strategyOpQueueProvider).accountId;
    if (rows.length != 1 ||
        accountId == null ||
        state.strategyId != strategyId) {
      return PageCopyResult.unavailable;
    }
    final group = rows.single;
    // Hive refuses keys over 255 characters, and an op is stored under one
    // naming its account, strategy, page and group. Only a lineup imported
    // with an unusually long id could get here.
    if (DurableOutboxRecord.createStorageKey(
          accountId: accountId,
          strategyPublicId: strategyId,
          entityKey: EntitySyncKey.lineup(pageId, group.publicId),
        ).length >
        255) {
      return PageCopyResult.unavailable;
    }

    final RemotePageSnapshot targetPage;
    try {
      targetPage =
          await ref.read(convexStrategyRepositoryProvider).fetchPageSnapshot(
                strategyPublicId: strategyId,
                pagePublicId: pageId,
              );
    } catch (error) {
      log('Could not read page $pageId to copy lineups onto it: $error');
      return PageCopyResult.unreachable;
    }
    if (state.strategyId != strategyId) return PageCopyResult.unavailable;

    final onTarget = _cloudLineupGroupsOn(targetPage);
    final linksThere = [
      for (final payload in onTarget.values.map((group) => group.payload))
        if (payload != null)
          for (final link in cloudPayloadData(payload)['links'] as List? ?? [])
            if (link is Map && link['id'] is String) link['id'] as String,
    ];
    if (_hasAnyOf(linksThere, lineUps)) return PageCopyResult.alreadyThere;

    // The canvas never draws the group: its page shows it from the server.
    final queued =
        await ref.read(strategyOpQueueProvider.notifier).enqueueOffCanvas(
              LineupAddOp(
                opId: const Uuid().v4(),
                lineupPublicId: group.publicId,
                pagePublicId: pageId,
                payload: group.payload,
                sortIndex: 1 +
                    onTarget.values
                        .map((group) => group.sortIndex)
                        .fold<int>(-1, max),
              ),
              flushImmediately: true,
            );
    if (!queued) return PageCopyResult.notSaved;
    ref.read(strategySaveStateProvider.notifier)
      ..markDirty()
      ..setPendingCloudSync(true)
      ..setCloudSyncError(null);
    return PageCopyResult.copied;
  }

  /// The lineup groups on [page] as the server has them, with the work still
  /// queued for it laid over, refused work waiting for the user's choice
  /// included: by id, their sortIndexes and what they hold.
  Map<String, ({int sortIndex, CloudPayload? payload})> _cloudLineupGroupsOn(
    RemotePageSnapshot page,
  ) {
    final pageId = page.page.publicId;
    final groups = <String, ({int sortIndex, CloudPayload? payload})>{
      for (final lineup in page.lineups)
        if (!lineup.deleted)
          lineup.publicId: (
            sortIndex: lineup.sortIndex,
            payload: lineup.payload,
          ),
    };
    final queue = ref.read(strategyOpQueueProvider);
    // Later entries win: a sent op over a paused one, its successor over it.
    for (final pendingByKey in [
      queue.attentionByEntityKey.map((k, v) => MapEntry(k, v.pending)),
      queue.pausedByEntityKey.map((k, v) => MapEntry(k, v.pending)),
      queue.queuedByEntityKey.map((k, v) => MapEntry(k, v.pending)),
      queue.inFlightByEntityKey.map((k, v) => MapEntry(k, v.pending)),
      queue.successorByEntityKey.map((k, v) => MapEntry(k, v.pending)),
    ]) {
      pendingByKey.forEach((key, pending) {
        if (key.kind != EntitySyncKeyKind.lineup || key.pageId != pageId) {
          return;
        }
        final id = key.entityId!;
        switch (pending.op) {
          case LineupDeleteOp():
            groups.remove(id);
          case final op:
            groups[id] = (
              sortIndex: op.sortIndex ?? groups[id]?.sortIndex ?? 0,
              payload: op.payload as CloudPayload? ?? groups[id]?.payload,
            );
        }
      });
    }
    return groups;
  }

  static StrategyPage? _copyPlacedWidgetBetweenPages({
    required String widgetId,
    required StrategyPage source,
    required StrategyPage target,
  }) {
    final agentIndex = source.agentData.indexWhere(
      (widget) => widget.id == widgetId,
    );
    if (agentIndex >= 0) {
      return target.copyWith(
        agentData: [...target.agentData, source.agentData[agentIndex]],
      );
    }

    final abilityIndex = source.abilityData.indexWhere(
      (widget) => widget.id == widgetId,
    );
    if (abilityIndex >= 0) {
      return target.copyWith(
        abilityData: [...target.abilityData, source.abilityData[abilityIndex]],
      );
    }

    final textIndex = source.textData.indexWhere(
      (widget) => widget.id == widgetId,
    );
    if (textIndex >= 0) {
      return target.copyWith(
        textData: [...target.textData, source.textData[textIndex]],
      );
    }

    final imageIndex = source.imageData.indexWhere(
      (widget) => widget.id == widgetId,
    );
    if (imageIndex >= 0) {
      return target.copyWith(
        imageData: [...target.imageData, source.imageData[imageIndex]],
      );
    }

    final utilityIndex = source.utilityData.indexWhere(
      (widget) => widget.id == widgetId,
    );
    if (utilityIndex >= 0) {
      return target.copyWith(
        utilityData: [...target.utilityData, source.utilityData[utilityIndex]],
      );
    }

    return null;
  }

  Future<void> addPage([String? name]) async {
    if (!_currentStrategyCanEditPages()) return;
    if (_currentStrategyIsCloud()) {
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      if (snapshot == null) return;
      final pages = [...snapshot.pages]
        ..sortBySortIndex((item) => item.sortIndex);
      final pageID = const Uuid().v4();
      final activePageId = ref.read(strategyPageSessionProvider).activePageId;
      final activeIndex = pages.indexWhere(
        (page) => page.publicId == activePageId,
      );
      final sourceIndex = activeIndex >= 0 ? activeIndex : pages.length - 1;
      final nextIndex = sourceIndex + 1;
      final isAutoNamed = name == null;
      final ack = await _enqueueCloudPageDescriptorOp(PageAddOp(
        opId: const Uuid().v4(),
        pagePublicId: pageID,
        payload: {
          'name': name ?? 'Page ${nextIndex + 1}',
          'isAutoNamed': isAutoNamed,
          'isAttack': pages.isNotEmpty ? pages[sourceIndex].isAttack : true,
          'settings': ref.read(strategySettingsProvider).toJson(),
        },
        sortIndex: nextIndex,
        expectedStrategyRevision: snapshot.header.revision,
      ));
      if (ack?.isAck ?? false) {
        await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
        await ref
            .read(strategyPageSessionProvider.notifier)
            .setActivePageAnimated(
              pageID,
              direction: PageTransitionDirection.forward,
            );
      }
      return;
    }

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    // Flush current page so its edits are not lost
    await _syncCurrentPageToHive();

    final strategyId = state.strategyId;
    if (strategyId == null) return;
    final strat = box.get(strategyId);
    if (strat == null || strat.pages.isEmpty) return;

    final orderedPages = [...strat.pages]
      ..sortBySortIndex((item) => item.sortIndex);
    final currentPageId = ref.read(strategyPageSessionProvider).activePageId;
    final currentIndex = orderedPages.indexWhere(
      (page) => page.id == currentPageId,
    );
    final sourceIndex =
        currentIndex >= 0 ? currentIndex : orderedPages.length - 1;
    final insertionIndex = sourceIndex + 1;
    final isAutoNamed = name == null;
    name ??= 'Page ${insertionIndex + 1}';
    final newPage = orderedPages[sourceIndex].copyWith(
      id: const Uuid().v4(),
      name: name,
      isAutoNamed: isAutoNamed,
      sortIndex: insertionIndex,
    );

    orderedPages.insert(insertionIndex, newPage);
    final reindexed = reindexPagesAfterStructuralChange(orderedPages);

    final updated = strat.copyWith(
      pages: reindexed,
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);

    await setActivePageAnimated(newPage.id);
  }

  Future<void> renamePage(String pageId, String newName) async {
    if (!_currentStrategyCanEditPages()) return;
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      return;
    }

    if (_currentStrategyIsCloud()) {
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      final page = snapshot?.pages
          .where((candidate) => candidate.publicId == pageId)
          .firstOrNull;
      if (page == null) return;
      final ack = await _enqueueCloudPageDescriptorOp(PagePatchOp(
        opId: const Uuid().v4(),
        pagePublicId: pageId,
        payload: {'name': trimmed, 'isAutoNamed': false},
        expectedPageRevision: page.revision,
      ));
      if (ack != null) {
        await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
      }
      return;
    }

    final strategyId = state.strategyId;
    if (strategyId == null) return;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(strategyId);
    if (strat == null) return;

    final updatedPages = [
      for (final page in strat.pages)
        if (page.id == pageId)
          page.copyWith(name: trimmed, isAutoNamed: false)
        else
          page,
    ];
    await box.put(
      strat.id,
      strat.copyWith(pages: updatedPages, lastEdited: DateTime.now()),
    );
  }

  /// Whether this call deleted the page. A cloud page then sits in the
  /// server's trash, restorable for 30 days. A page someone else deleted
  /// first lands as a no-op and returns false: this call did not delete it.
  Future<bool> deletePage(String pageId) async {
    if (!_currentStrategyCanEditPages()) return false;
    if (_currentStrategyIsCloud()) {
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      if (snapshot == null || snapshot.pages.length <= 1) {
        return false;
      }
      final pages = [...snapshot.pages]
        ..sortBySortIndex((item) => item.sortIndex);
      final activePageId = ref.read(strategyPageSessionProvider).activePageId ??
          pages.first.publicId;
      final remaining = pages
          .where((page) => page.publicId != pageId)
          .toList(growable: false);
      final nextActivePageId = activePageId == pageId && remaining.isNotEmpty
          ? remaining.first.publicId
          : activePageId;

      if (activePageId == pageId) {
        await ref.read(strategyPageSessionProvider.notifier).flushCurrentPage(
              flushImmediately: true,
            );
      }

      final ack = await _enqueueCloudPageDescriptorOp(PageDeleteOp(
        opId: const Uuid().v4(),
        pagePublicId: pageId,
        expectedStrategyRevision: snapshot.header.revision,
      ));
      if (ack?.isAck ?? false) {
        await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
      }
      if ((ack?.isAck ?? false) && nextActivePageId != activePageId) {
        await ref
            .read(strategyPageSessionProvider.notifier)
            .setActivePageAnimated(
              nextActivePageId,
              direction: PageTransitionDirection.forward,
            );
      }
      return ack is AppliedOpAck;
    }

    final strategyId = state.strategyId;
    if (strategyId == null) return false;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(strategyId);
    if (strat == null || strat.pages.length <= 1) return false;

    final remaining = [...strat.pages]
      ..sortBySortIndex((item) => item.sortIndex)
      ..removeWhere((page) => page.id == pageId);
    final reindexed = reindexPagesAfterStructuralChange(remaining);
    final activePageId = ref.read(strategyPageSessionProvider).activePageId;
    final nextActivePageId =
        activePageId == pageId ? reindexed.first.id : activePageId;

    await box.put(
      strat.id,
      strat.copyWith(pages: reindexed, lastEdited: DateTime.now()),
    );
    if (nextActivePageId != null && nextActivePageId != activePageId) {
      await ref.read(strategyProvider.notifier).setActivePageAnimated(
            nextActivePageId,
          );
    }
    return true;
  }

  /// Opens strategy [id] on its first page, or on [pageId] when given.
  Future<void> loadFromHive(String id, {String? pageId}) async {
    _requireLocalLibrary('open');
    cancelPendingSave();
    final newStrat = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .where((StrategyData strategy) {
      return strategy.id == id;
    }).firstOrNull;

    if (newStrat == null) {
      return;
    }
    _withoutPersistenceTracking(() {
      ref.read(actionProvider.notifier).resetActionState();
    });

    List<PlacedImage> pageImageData = [];
    for (final page in newStrat.pages) {
      pageImageData.addAll(page.imageData);
    }
    if (!kIsWeb) {
      List<String> allImageIds = [];
      for (final page in newStrat.pages) {
        allImageIds.addAll(page.imageData.map((image) => image.pictureId));
        for (final link in page.lineUpLinks) {
          allImageIds.addAll(link.images.map((image) => image.id));
        }
      }
      await ref
          .read(placedImageProvider.notifier)
          .deleteUnusedImages(newStrat.id, allImageIds);
    }

    // We clear previous data to avoid artifacts when loading a new strategy
    final migratedStrategy = StrategyMigrator.migrateToCurrentVersion(newStrat);

    if (migratedStrategy != newStrat) {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(migratedStrategy.id, migratedStrategy);
    }

    final newDir =
        kIsWeb ? null : await setStorageDirectory(migratedStrategy.id);
    state = StrategyState(
      strategyId: migratedStrategy.id,
      strategyName: migratedStrategy.name,
      source: StrategySource.local,
      storageDirectory: newDir?.path,
      isOpen: true,
    );
    ref.read(strategySaveStateProvider.notifier).reset();
    await ref.read(strategyPageSessionProvider.notifier).initializeForStrategy(
          strategyId: migratedStrategy.id,
          source: StrategySource.local,
          selectFirstPageIfNeeded: true,
          preferredPageId: pageId,
        );
    ref.read(strategySaveStateProvider.notifier).markPersisted();
  }

  /// Creates an empty strategy on [map] and returns it. Without [name] it
  /// is auto-named after the map ("Haven", then "Haven 2", ...). In the cloud
  /// workspace the strategy is created on the server and opened; nothing is
  /// written to the local library. With [local] it goes to the local library
  /// (its open folder) whichever workspace is selected: a replay's Capture
  /// writes its pages there, from files on this computer.
  Future<StrategyData> createNewStrategy({
    required MapValue map,
    String? name,
    bool local = false,
  }) async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final isCloud = !local && _selectedWorkspaceIsCloud();
    if (!isCloud) _requireLocalLibrary('create');
    final existingNames = isCloud
        ? (ref.read(cloudStrategiesProvider).valueOrNull ?? const [])
            .map((entry) => entry.strategy.name)
        : box.values.map((strategy) => strategy.name);
    final strategyName = name ?? autoStrategyName(map, existingNames);
    final newID = const Uuid().v4();
    final pageID = const Uuid().v4();
    final defaultThemeProfileId =
        ref.read(mapThemeProfilesProvider).defaultProfileIdForNewStrategies;
    final appPreferences = ref.read(appPreferencesProvider);
    final defaultSettings = StrategySettings(
      agentSize: appPreferences.defaultAgentSizeForNewStrategies,
      abilitySize: appPreferences.defaultAbilitySizeForNewStrategies,
      useNeutralTeamColors:
          appPreferences.defaultNeutralTeamColorsForNewStrategies,
    );
    final newStrategy = StrategyData(
      mapData: map,
      versionNumber: Settings.versionNumber,
      id: newID,
      name: strategyName,
      pages: [
        StrategyPage(
          id: pageID,
          name: "Page 1",
          isAutoNamed: true,
          drawingData: [],
          agentData: [],
          abilityData: [],
          textData: [],
          imageData: [],
          utilityData: [],
          sortIndex: 0,
          isAttack: true,
          settings: defaultSettings,
        )
      ],
      lastEdited: DateTime.now(),

      // ignore: deprecated_member_use_from_same_package
      strategySettings: defaultSettings,
      folderID: local
          ? ref
              .read(folderProvider.notifier)
              .currentFolderIdForWorkspace(LibraryWorkspace.local)
          : ref.read(folderProvider),
      themeProfileId: defaultThemeProfileId,
    );

    if (isCloud) {
      try {
        await ref
            .read(convexStrategyRepositoryProvider)
            .createStrategyWithInitialPage(
              publicId: newID,
              name: strategyName,
              mapData: Maps.mapNames[map] ?? Maps.mapNames[MapValue.ascent]!,
              initialPagePublicId: pageID,
              initialPageName: "Page 1",
              initialPageIsAutoNamed: true,
              initialPageIsAttack: true,
              initialPageSettings: defaultSettings.toJson(),
              folderPublicId: ref.read(folderProvider),
              themeProfileId: defaultThemeProfileId,
            );
      } catch (error, stackTrace) {
        final handled = await _reportCloudUnauthenticated(
          source: 'strategy:create_new',
          error: error,
          stackTrace: stackTrace,
        );
        if (handled) {
          throw StateError('Cloud authentication required to create strategy.');
        }
        rethrow;
      }
      ref.invalidate(cloudStrategiesProvider);
      ref.invalidate(cloudFolderTreeProvider);
      try {
        await openCloudStrategy(newID);
      } catch (error, stackTrace) {
        // The strategy exists on the server but couldn't be opened — don't
        // rethrow, or the caller would falsely report that creation failed.
        // Creation succeeded; opening is what failed (the editor's own load
        // path surfaces that and backs out).
        log(
          'Created cloud strategy $newID but failed to open it: $error',
          name: 'strategy',
          error: error,
          stackTrace: stackTrace,
        );
        Settings.showToast(
          message: 'Strategy created, but it could not be opened. '
              'Open it from your cloud library.',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
      }
      unawaited(AnalyticsService.instance.capture('strategy_created'));
      return newStrategy;
    }

    await box.put(newStrategy.id, newStrategy);

    unawaited(AnalyticsService.instance.capture('strategy_created'));

    return newStrategy;
  }

  void setThemeProfileForCurrentStrategy(String profileId) {
    ref.read(strategyThemeProvider.notifier).setProfile(profileId);
  }

  void setThemeOverrideForCurrentStrategy(MapThemePalette palette) {
    ref.read(strategyThemeProvider.notifier).setOverride(palette);
  }

  void clearThemeOverrideForCurrentStrategy() {
    ref.read(strategyThemeProvider.notifier).clearOverride();
  }

  Future<void> renameStrategy(
    String strategyID,
    String newName, {
    StrategySource? source,
  }) async {
    final resolvedSource = source ?? _resolveLibraryMutationSource();
    if (resolvedSource == StrategySource.cloud) {
      try {
        final shell = state.strategyId == strategyID &&
                state.source == StrategySource.cloud
            ? ref.read(remoteEditorSnapshotProvider).valueOrNull?.shell
            : await ref
                .read(convexStrategyRepositoryProvider)
                .fetchShell(strategyID);
        if (shell == null) return;
        await ref.read(convexStrategyRepositoryProvider).updateStrategyName(
              strategyPublicId: strategyID,
              name: newName,
              expectedRevision: shell.header.revision,
            );
      } catch (error, stackTrace) {
        final handled = await _reportCloudUnauthenticated(
          source: 'strategy:rename',
          error: error,
          stackTrace: stackTrace,
        );
        if (!handled) rethrow;
        return;
      }
      if (state.strategyId == strategyID &&
          state.source == StrategySource.cloud) {
        // The editor title reads the open strategy's name from this state;
        // the refreshed snapshot does not feed it back.
        state = state.copyWith(strategyName: newName);
        await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
      } else {
        ref.invalidate(cloudStrategiesProvider);
      }
      return;
    }

    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategy = strategyBox.get(strategyID);

    if (strategy != null) {
      strategy.name = newName;
      await strategy.save();
      if (state.strategyId == strategyID) {
        state = state.copyWith(strategyName: newName);
      }
    } else {
      log("Strategy with ID $strategyID not found.");
    }
  }

  Future<void> duplicateStrategy(
    String strategyID, {
    StrategySource? source,
  }) async {
    final resolvedSource = source ?? _resolveLibraryMutationSource();
    if (resolvedSource == StrategySource.cloud) {
      // The server copies everything, images included, in one transaction:
      // a copy's images need asset rows of their own, which only the server
      // can create for bytes that are already uploaded.
      const sourceName = 'strategy:duplicate';
      final reporter = ref.read(cloudLibraryActionReporterProvider);
      // An image this device has not uploaded yet has nothing to copy, so
      // the copy would lack it for good. The server refuses the same case
      // for uploads started on other devices.
      final unsentImages = ref
          .read(cloudMediaUploadQueueProvider)
          .pendingCountForStrategy(strategyID);
      if (unsentImages > 0) {
        reporter.showMessage(
          "This strategy has images that haven't finished uploading. "
          "Duplicate it once it's synced.",
        );
        return;
      }
      final repository = ref.read(convexStrategyRepositoryProvider);
      final result = await reporter.run(
        action: () async {
          final shell = await repository.fetchShell(strategyID);
          try {
            await repository.duplicateStrategy(
              sourceStrategyPublicId: strategyID,
              publicId: const Uuid().v4(),
              name: "${shell.header.name} (Copy)",
              folderPublicId: ref.read(folderProvider),
            );
          } on Object catch (error) {
            // Not a failure to retry: the copy was refused whole, so nothing
            // was made. Say why.
            if (!isStrategyTooLargeToDuplicateError(error)) rethrow;
            reporter.showMessage(
              "This strategy is too large to duplicate.",
            );
            return false;
          }
          return true;
        },
        source: sourceName,
        failureMessage: "Couldn't duplicate this strategy. Try again.",
        showFailureMessage: true,
        reportAuthenticationFailure: (error, stackTrace) =>
            ref.read(authProvider.notifier).reportConvexUnauthenticated(
                  source: sourceName,
                  error: error,
                  stackTrace: stackTrace,
                ),
      );
      if (result.didSucceed) {
        ref.invalidate(cloudStrategiesProvider);
      }
      return;
    }

    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final originalStrategy = strategyBox.get(strategyID);
    if (originalStrategy == null) {
      log("Original strategy with ID $strategyID not found.");
      return;
    }
    final newPages = originalStrategy.pages
        .map((page) => page.copyWith(id: const Uuid().v4()))
        .toList();

    final newID = const Uuid().v4();

    final duplicatedStrategy = StrategyData(
      id: newID,
      name: "${originalStrategy.name} (Copy)",
      mapData: originalStrategy.mapData,
      versionNumber: originalStrategy.versionNumber,
      lastEdited: DateTime.now(),
      folderID: originalStrategy.folderID,
      pages: newPages,
      themeProfileId: originalStrategy.themeProfileId,
      themeOverridePalette: originalStrategy.themeOverridePalette,
    );

    await strategyBox.put(duplicatedStrategy.id, duplicatedStrategy);
  }

  Future<CloudLibraryActionResult> deleteStrategy(
    String strategyID, {
    StrategySource? source,
  }) async {
    final resolvedSource = source ?? _resolveLibraryMutationSource();
    if (resolvedSource == StrategySource.cloud) {
      const sourceName = 'strategy:delete';
      final result = await ref.read(cloudLibraryActionReporterProvider).run(
            action: () async {
              final shell = await ref
                  .read(convexStrategyRepositoryProvider)
                  .fetchShell(strategyID);
              await ref.read(convexStrategyRepositoryProvider).deleteStrategy(
                    strategyPublicId: strategyID,
                    expectedRevision: shell.header.revision,
                  );
              return true;
            },
            source: sourceName,
            failureMessage: "Couldn't delete this cloud strategy. Try again.",
            reportAuthenticationFailure: (error, stackTrace) =>
                ref.read(authProvider.notifier).reportConvexUnauthenticated(
                      source: sourceName,
                      error: error,
                      stackTrace: stackTrace,
                    ),
          );
      if (!result.didSucceed) return result;

      // Unsent edits to a strategy the user just deleted can never land.
      await ref
          .read(strategyOpQueueProvider.notifier)
          .discardDeletedStrategy(strategyID);
      await ref
          .read(cloudMediaUploadQueueProvider.notifier)
          .clearJobsForStrategy(strategyID);
      await ref.read(pinnedItemsProvider.notifier).removePin(strategyID);
      ref.invalidate(cloudStrategiesProvider);
      return result;
    }

    await ref.read(pinnedItemsProvider.notifier).removePin(strategyID);
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).delete(strategyID);

    final directory = await getApplicationSupportDirectory();

    final customDirectory = Directory(path.join(directory.path, strategyID));

    if (!await customDirectory.exists()) {
      return CloudLibraryActionResult.succeeded;
    }

    await customDirectory.delete(recursive: true);
    return CloudLibraryActionResult.succeeded;
  }

  Future<void> saveToHive(String id) async {
    if (_currentStrategyIsCloud()) {
      return;
    }
    _requireLocalLibrary('save');
    // final drawingData = ref.read(drawingProvider).elements;
    // final agentData = ref.read(agentProvider);
    // final abilityData = ref.read(abilityProvider);
    // final textData = ref.read(textProvider);
    // final mapData = ref.read(mapProvider);
    // final imageData = ref.read(placedImageProvider).images;
    // final utilityData = ref.read(utilityProvider);
    await _syncCurrentPageToHive();

    final StrategyData? savedStrat =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(id);

    if (savedStrat == null) return;

    final strategyTheme = ref.read(strategyThemeProvider);
    final currentStrategy = savedStrat.copyWith(
      mapData: ref.read(mapProvider).currentMap,
      lastEdited: DateTime.now(),
      themeProfileId: strategyTheme.profileId,
      clearThemeProfileId: strategyTheme.profileId == null,
      themeOverridePalette: strategyTheme.overridePalette,
      clearThemeOverridePalette: strategyTheme.overridePalette == null,
    );

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(currentStrategy.id, currentStrategy);

    ref.read(strategySaveStateProvider.notifier).markPersisted();
    state = state.copyWith(isSaved: true);
    log("Save to hive was called");
  }

  // Flush currently active page into Hive. Safe if no active page is selected.
  Future<void> _syncCurrentPageToHive() async {
    if (_currentStrategyIsCloud()) {
      return;
    }
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategyId = state.strategyId;
    if (strategyId == null) {
      return;
    }
    log("Syncing current page to hive for strategy $strategyId");
    final strat = box.get(strategyId);
    if (strat == null || strat.pages.isEmpty) {
      log("No strategy or pages found for syncing.");
      return;
    }

    final pageId = ref.read(strategyPageSessionProvider).activePageId ??
        strat.pages.first.id;
    final idx = strat.pages.indexWhere((p) => p.id == pageId);
    if (idx == -1) {
      log("Active page ID $pageId not found in strategy ${strat.id}");
      return;
    }

    final updatedPage = strat.pages[idx].copyWith(
      drawingData: ref.read(drawingProvider).elements,
      agentData: ref.read(agentProvider),
      abilityData: ref.read(abilityProvider),
      textData: ref.read(textProvider.notifier).snapshotForPersistence(),
      imageData: ref.read(placedImageProvider).images,
      utilityData: ref.read(utilityProvider),
      isAttack: ref.read(mapProvider).isAttack,
      settings: ref.read(strategySettingsProvider),
      lineUpGraph: ref.read(lineUpProvider).graph,
    );

    final strategyTheme = ref.read(strategyThemeProvider);
    final newPages = [...strat.pages]..[idx] = updatedPage;
    final updated = strat.copyWith(
      pages: newPages,
      mapData: ref.read(mapProvider).currentMap,
      themeProfileId: strategyTheme.profileId,
      clearThemeProfileId: strategyTheme.profileId == null,
      themeOverridePalette: strategyTheme.overridePalette,
      clearThemeOverridePalette: strategyTheme.overridePalette == null,
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);
  }

  /// Copies current [strategySettingsProvider] marker sizes to every page in
  /// the open strategy (after flushing the active page to Hive).
  Future<void> applyMarkerSizesToAllPages() async {
    if (state.strategyName == null) return;

    final target = ref.read(strategySettingsProvider);
    await _applySettingsToAllPages(
      (settings) => settings.copyWith(
        agentSize: target.agentSize,
        abilitySize: target.abilitySize,
      ),
    );
  }

  /// Flips the side the map is drawn from. Placements are stored
  /// attack-canonical, so the only thing that changes is each page's side.
  /// With [allPages] every page takes the active page's new side; otherwise
  /// only the active page changes and the strategy may become mixed.
  /// Flips the side of the active page, or of every page when [allPages].
  ///
  /// The active page's side lives in [mapProvider] and reaches Hive through
  /// the normal save, so "Don't save" still reverts it and none of its other
  /// pending edits are flushed here. The other pages are held in Hive
  /// between visits (a page switch writes there the same way), so they are
  /// flipped in place.
  Future<void> switchSide({required bool allPages}) async {
    final isAttack = !ref.read(mapProvider).isAttack;
    ref.read(mapProvider.notifier).setAttack(isAttack);
    setUnsaved();
    final strategyId = state.strategyId;
    if (!allPages || strategyId == null) return;
    if (!_currentStrategyCanEditPages()) return;
    final activeId = ref.read(strategyPageSessionProvider).activePageId;

    if (_currentStrategyIsCloud()) {
      // The active page's side reaches the server through live page sync.
      final snapshot = ref.read(remoteEditorSnapshotProvider).valueOrNull;
      if (snapshot == null) return;
      final ops = [
        for (final page in snapshot.pages)
          if (page.publicId != activeId && _intendedSide(page) != isAttack)
            PagePatchOp(
              opId: const Uuid().v4(),
              pagePublicId: page.publicId,
              payload: {'isAttack': isAttack},
              expectedPageRevision: page.revision,
            ),
      ];
      if (ops.isEmpty) return;
      final request = Object();
      for (final op in ops) {
        _requestedSides[op.pagePublicId] =
            (request: request, isAttack: isAttack);
      }
      try {
        await ref
            .read(strategyOpQueueProvider.notifier)
            .enqueueAll(ops, flushImmediately: true);
      } catch (error, stackTrace) {
        final handled = await _reportCloudUnauthenticated(
          source: 'strategy:switch_side_all_pages',
          error: error,
          stackTrace: stackTrace,
        );
        if (!handled) rethrow;
        return;
      } finally {
        _requestedSides
            .removeWhere((_, entry) => identical(entry.request, request));
      }
      await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
      return;
    }

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(strategyId);
    if (strat == null || strat.pages.isEmpty) return;

    final resolvedActiveId = activeId ?? strat.pages.first.id;
    final updated = strat.copyWith(
      pages: [
        for (final page in strat.pages)
          page.id == resolvedActiveId
              ? page
              : page.copyWith(isAttack: isAttack),
      ],
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);
  }

  /// Side changes asked for by a switchSide call whose enqueue has not
  /// finished. The op queue shows an op only after its durable write, so a
  /// second toggle starting in between would otherwise read the older side.
  /// Each entry is cleared by the call that set it, unless a later call has
  /// replaced it.
  final Map<String, ({Object request, bool isAttack})> _requestedSides = {};

  /// The side a cloud page is headed to: a side change still being queued,
  /// the newest one waiting in the op queue, or the server's side. Comparing
  /// against the server alone would skip a page whose queued change points
  /// the other way, and that change would then win.
  bool _intendedSide(RemotePage page) {
    final requested = _requestedSides[page.publicId];
    if (requested != null) return requested.isAttack;
    final key = EntitySyncKey.pageDescriptor(page.publicId);
    final queue = ref.read(strategyOpQueueProvider);
    final pendingOps = [
      queue.successorByEntityKey[key]?.pending.op,
      queue.queuedByEntityKey[key]?.pending.op,
      queue.pausedByEntityKey[key]?.pending.op,
      queue.inFlightByEntityKey[key]?.pending.op,
    ];
    for (final op in pendingOps) {
      if (op is PagePatchOp && op.payload['isAttack'] is bool) {
        return op.payload['isAttack'] as bool;
      }
    }
    return page.isAttack;
  }

  Future<void> applyNeutralTeamColorsToAllPages(bool value) async {
    if (state.strategyName == null) return;

    await _applySettingsToAllPages(
      (settings) => settings.copyWith(useNeutralTeamColors: value),
    );
  }

  Future<void> _applySettingsToAllPages(
    StrategySettings Function(StrategySettings settings) transform,
  ) async {
    if (!_currentStrategyCanEditPages()) return;
    if (_currentStrategyIsCloud()) {
      final strategyId = state.strategyId;
      if (strategyId == null) {
        return;
      }
      final snapshot = await ref
          .read(convexStrategyRepositoryProvider)
          .fetchFullSnapshot(strategyId);
      if (snapshot.pages.isEmpty) return;

      final ops = [
        for (final fullPage in snapshot.pages)
          PageContentPatchOp(
            opId: const Uuid().v4(),
            pagePublicId: fullPage.page.publicId,
            settings: transform(_settingsFromPayloadOrDefault(
              fullPage.content.settings,
            )).toJson(),
            expectedPageContentRevision: fullPage.content.revision,
          ),
      ];

      try {
        await ref
            .read(strategyOpQueueProvider.notifier)
            .enqueueAll(ops, flushImmediately: true);
      } catch (error, stackTrace) {
        final handled = await _reportCloudUnauthenticated(
          source: 'strategy:apply_settings_to_all_pages',
          error: error,
          stackTrace: stackTrace,
        );
        if (!handled) rethrow;
        return;
      }
      await ref.read(remoteEditorSnapshotProvider.notifier).refresh();
      return;
    }

    await _syncCurrentPageToHive();

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategyId = state.strategyId;
    if (strategyId == null) return;
    final strat = box.get(strategyId);
    if (strat == null || strat.pages.isEmpty) return;

    final newPages = [
      for (final page in strat.pages)
        page.copyWith(settings: transform(page.settings)),
    ];

    final strategyTheme = ref.read(strategyThemeProvider);
    final updated = strat.copyWith(
      pages: newPages,
      mapData: ref.read(mapProvider).currentMap,
      themeProfileId: strategyTheme.profileId,
      clearThemeProfileId: strategyTheme.profileId == null,
      themeOverridePalette: strategyTheme.overridePalette,
      clearThemeOverridePalette: strategyTheme.overridePalette == null,
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);
    setUnsaved();
  }

  StrategySettings _settingsFromPayloadOrDefault(Object? payload) {
    if (payload == null) {
      return StrategySettings();
    }
    try {
      final decoded = cloudObjectPayloadOrNull(payload);
      if (decoded != null) {
        return StrategySettings.fromJson(decoded);
      }
    } catch (_) {}
    return StrategySettings();
  }

  Future<CloudLibraryActionResult> moveToFolder({
    required String strategyID,
    required String? parentID,
    StrategySource? source,
  }) async {
    final resolvedSource = source ?? _resolveLibraryMutationSource();
    if (resolvedSource == StrategySource.cloud) {
      const sourceName = 'strategy:move';
      final result = await ref.read(cloudLibraryActionReporterProvider).run(
            action: () async {
              final shell = await ref
                  .read(convexStrategyRepositoryProvider)
                  .fetchShell(strategyID);
              await ref.read(convexStrategyRepositoryProvider).moveStrategy(
                    strategyPublicId: strategyID,
                    folderPublicId: parentID,
                    expectedRevision: shell.header.revision,
                  );
              return true;
            },
            source: sourceName,
            failureMessage: "Couldn't move this cloud strategy. Try again.",
            showFailureMessage: true,
            reportAuthenticationFailure: (error, stackTrace) =>
                ref.read(authProvider.notifier).reportConvexUnauthenticated(
                      source: sourceName,
                      error: error,
                      stackTrace: stackTrace,
                    ),
          );
      if (!result.didSucceed) return result;

      ref.invalidate(cloudStrategiesProvider);
      return result;
    }
    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategy = strategyBox.get(strategyID);

    if (strategy != null) {
      strategy.folderID = parentID;
      await strategy.save();
      return CloudLibraryActionResult.succeeded;
    } else {
      log("Strategy with ID $strategyID not found.");
      return CloudLibraryActionResult.failed(
        "Couldn't move this strategy. Try again.",
      );
    }
  }
}

/// The name a new strategy gets when the user doesn't type one: the map's
/// name, with the first free number appended if that name is already taken.
@visibleForTesting
String autoStrategyName(MapValue map, Iterable<String> existingNames) {
  final base = Maps.displayName(map);
  final taken = existingNames.map((name) => name.trim().toLowerCase()).toSet();
  if (!taken.contains(base.toLowerCase())) return base;
  for (var n = 2;; n++) {
    final candidate = '$base $n';
    if (!taken.contains(candidate.toLowerCase())) return candidate;
  }
}
