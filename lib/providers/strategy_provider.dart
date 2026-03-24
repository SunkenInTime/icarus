import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

final strategyProvider =
    NotifierProvider<StrategyProvider, StrategyState>(StrategyProvider.new);

class StrategyProvider extends Notifier<StrategyState> {
  @override
  StrategyState build() {
    return const StrategyState(
      strategyId: null,
      strategyName: null,
      source: null,
      storageDirectory: null,
      isOpen: false,
    );
  }

  Timer? _saveTimer;

  bool _saveInProgress = false;
  bool _pendingSave = false;

  //Used For Images
  void setFromState(StrategyState newState) {
    final hasIdentity =
        newState.strategyId != null || newState.strategyName != null;
    state = newState.copyWith(
      isOpen: newState.isOpen || hasIdentity,
    );
  }

  void cancelPendingSave() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _pendingSave = false;
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

  bool _currentStrategyIsCloud() {
    return state.source == StrategySource.cloud;
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
        .read(remoteStrategySnapshotProvider.notifier)
        .openStrategy(strategyID);
    final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
    if (snapshot == null) {
      return;
    }

    state = state.copyWith(
      strategyId: snapshot.header.publicId,
      strategyName: snapshot.header.name,
      source: StrategySource.cloud,
      storageDirectory: null,
      isOpen: true,
    );

    await ref.read(strategyPageSessionProvider.notifier).initializeForStrategy(
          strategyId: snapshot.header.publicId,
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
  }

  Future<void> switchPage(String pageID) async {
    if (_currentStrategyIsCloud()) {
      await ref
          .read(strategyPageSessionProvider.notifier)
          .setActivePage(pageID);
      return;
    }

    await ref.read(strategyPageSessionProvider.notifier).setActivePageAnimated(
          pageID,
          direction: PageTransitionDirection.forward,
        );
  }

  Future<void> enqueueOps(
    List<StrategyOp> ops, {
    bool flushImmediately = false,
  }) async {
    if (!_currentStrategyIsCloud() || ops.isEmpty) {
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

  Future<void> notifyCloudMutation({bool flushImmediately = false}) async {
    if (!_currentStrategyIsCloud()) {
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

  void setUnsaved() async {
    if (ref.read(strategyPageSessionProvider).isApplyingPage) {
      return;
    }

    if (_currentStrategyIsCloud()) {
      unawaited(notifyCloudMutation(flushImmediately: false));
      return;
    }

    ref.read(strategySaveStateProvider.notifier).markDirty();
    refreshAutosaveScheduling();
  }

  Future<void> forceSaveNow(String id) async {
    cancelPendingSave();
    if (_currentStrategyIsCloud()) {
      ref.read(strategySaveStateProvider.notifier)
        ..markDirty()
        ..setPendingCloudSync(true);
    }
    await _performSave(id);
  }

  // Ensures only one save runs at a time; coalesces a pending one
  Future<void> _performSave(String id) async {
    if (_saveInProgress) {
      _pendingSave = true;
      return;
    }

    _saveInProgress = true;
    try {
      ref.read(autoSaveProvider.notifier).ping(); // UI: Saving...
      ref.read(strategySaveStateProvider.notifier).markSaving(true);
      if (_currentStrategyIsCloud()) {
        await ref
            .read(strategyPageSessionProvider.notifier)
            .flushCurrentPage(flushImmediately: true);
      } else {
        await saveToHive(id);
      }
    } finally {
      ref.read(strategySaveStateProvider.notifier).markSaving(false);
      _saveInProgress = false;
      if (_pendingSave) {
        _pendingSave = false;
        // Small debounce to coalesce rapid edits during the previous save
        _saveTimer?.cancel();
        // _saveTimer = Timer(const Duration(milliseconds: 500), () {
        //   _performSave(id);
        // });
      }
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
    ref.read(remoteStrategySnapshotProvider.notifier).clear();
  }

  // Switch active page: flush old page first, then hydrate new
  Future<void> setActivePage(String pageID) async {
    await ref.read(strategyPageSessionProvider.notifier).setActivePage(pageID);
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

  Future<void> reorderPage(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;

    if (_currentStrategyIsCloud()) {
      final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
      if (snapshot == null || snapshot.pages.isEmpty) return;
      final ordered = [...snapshot.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      if (oldIndex < 0 ||
          oldIndex >= ordered.length ||
          newIndex < 0 ||
          newIndex > ordered.length) {
        return;
      }

      var targetIndex = newIndex;
      if (targetIndex > oldIndex) targetIndex -= 1;

      final moved = ordered.removeAt(oldIndex);
      ordered.insert(targetIndex, moved);

      try {
        await ConvexClient.instance.mutation(name: "pages:reorder", args: {
          "strategyPublicId": state.strategyId,
          "orderedPagePublicIds": ordered.map((p) => p.publicId).toList(),
        });
      } catch (error, stackTrace) {
        final handled = await _reportCloudUnauthenticated(
          source: 'strategy:pages_reorder',
          error: error,
          stackTrace: stackTrace,
        );
        if (!handled) rethrow;
        return;
      }
      await ref.read(remoteStrategySnapshotProvider.notifier).refresh();
      return;
    }

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategyId = state.strategyId;
    if (strategyId == null) return;
    final strat = box.get(strategyId);
    if (strat == null || strat.pages.isEmpty) return;

    final ordered = [...strat.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

    if (oldIndex < 0 ||
        oldIndex >= ordered.length ||
        newIndex < 0 ||
        newIndex > ordered.length) {
      return;
    }

    var targetIndex = newIndex;
    if (targetIndex > oldIndex) targetIndex -= 1;

    final moved = ordered.removeAt(oldIndex);
    ordered.insert(targetIndex, moved);

    final reindexed = [
      for (var i = 0; i < ordered.length; i++)
        ordered[i].copyWith(sortIndex: i),
    ];

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
  }

  Future<void> addPage([String? name]) async {
    if (_currentStrategyIsCloud()) {
      final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
      if (snapshot == null) return;
      final pages = [...snapshot.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      final pageID = const Uuid().v4();
      final nextIndex = pages.length;
      try {
        await ConvexClient.instance.mutation(name: "pages:add", args: {
          "strategyPublicId": state.strategyId,
          "pagePublicId": pageID,
          "name": name ?? "Page ${pages.length + 1}",
          "sortIndex": nextIndex,
          "isAttack": pages.isNotEmpty ? pages.last.isAttack : true,
          "settings": ref.read(strategySettingsProvider.notifier).toJson(),
        });
      } catch (error, stackTrace) {
        final handled = await _reportCloudUnauthenticated(
          source: 'strategy:pages_add',
          error: error,
          stackTrace: stackTrace,
        );
        if (!handled) rethrow;
        return;
      }
      await ref.read(remoteStrategySnapshotProvider.notifier).refresh();
      await ref
          .read(strategyPageSessionProvider.notifier)
          .setActivePage(pageID);
      return;
    }

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    // Flush current page so its edits are not lost
    await _syncCurrentPageToHive();

    final strategyId = state.strategyId;
    if (strategyId == null) return;
    final strat = box.get(strategyId);
    if (strat == null) return;

    name ??= "Page ${strat.pages.length + 1}";
    //TODO Make this function of the index
    final newPage = strat.pages.last.copyWith(
      id: const Uuid().v4(),
      name: name,
      sortIndex: strat.pages.length,
    );

    // final newPage = StrategyPage(
    //   id: const Uuid().v4(),
    //   name: name,
    //   drawingData: ,
    //   agentData: const [],
    //   abilityData: const [],
    //   textData: const [],
    //   imageData: const [],
    //   utilityData: const [],
    //   sortIndex: strat.pages.length, // corrected
    // );

    final updated = strat.copyWith(
      pages: [...strat.pages, newPage],
      lastEdited: DateTime.now(),
    );
    await box.put(updated.id, updated);

    await setActivePageAnimated(newPage.id);
  }

  Future<void> renamePage(String pageId, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      return;
    }

    if (_currentStrategyIsCloud()) {
      try {
        await ConvexClient.instance.mutation(name: "pages:rename", args: {
          "strategyPublicId": state.strategyId,
          "pagePublicId": pageId,
          "name": trimmed,
        });
      } catch (error, stackTrace) {
        final handled = await _reportCloudUnauthenticated(
          source: 'strategy:pages_rename',
          error: error,
          stackTrace: stackTrace,
        );
        if (!handled) rethrow;
        return;
      }
      await ref.read(remoteStrategySnapshotProvider.notifier).refresh();
      return;
    }

    final strategyId = state.strategyId;
    if (strategyId == null) return;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(strategyId);
    if (strat == null) return;

    final updatedPages = [
      for (final page in strat.pages)
        if (page.id == pageId) page.copyWith(name: trimmed) else page,
    ];
    await box.put(
      strat.id,
      strat.copyWith(pages: updatedPages, lastEdited: DateTime.now()),
    );
  }

  Future<void> deletePage(String pageId) async {
    if (_currentStrategyIsCloud()) {
      final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
      if (snapshot == null || snapshot.pages.length <= 1) {
        return;
      }
      final pages = [...snapshot.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      final activePageId = ref.read(strategyPageSessionProvider).activePageId ??
          pages.first.publicId;
      final remaining =
          pages.where((page) => page.publicId != pageId).toList(growable: false);
      final nextActivePageId = activePageId == pageId && remaining.isNotEmpty
          ? remaining.first.publicId
          : activePageId;

      if (activePageId == pageId) {
        await ref.read(strategyPageSessionProvider.notifier).flushCurrentPage(
              flushImmediately: true,
            );
      }

      try {
        await ConvexClient.instance.mutation(name: "pages:delete", args: {
          "strategyPublicId": state.strategyId,
          "pagePublicId": pageId,
        });
      } catch (error, stackTrace) {
        final handled = await _reportCloudUnauthenticated(
          source: 'strategy:pages_delete',
          error: error,
          stackTrace: stackTrace,
        );
        if (!handled) rethrow;
        return;
      }

      await ref.read(remoteStrategySnapshotProvider.notifier).refresh();
      if (nextActivePageId != activePageId) {
        await ref
            .read(strategyPageSessionProvider.notifier)
            .setActivePage(nextActivePageId);
      }
      return;
    }

    final strategyId = state.strategyId;
    if (strategyId == null) return;
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(strategyId);
    if (strat == null || strat.pages.length <= 1) return;

    final remaining = [...strat.pages]..removeWhere((page) => page.id == pageId);
    final reindexed = [
      for (var i = 0; i < remaining.length; i++)
        remaining[i].copyWith(sortIndex: i),
    ];
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
  }

  Future<void> loadFromHive(String id) async {
    cancelPendingSave();
    final newStrat = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .where((StrategyData strategy) {
      return strategy.id == id;
    }).firstOrNull;

    if (newStrat == null) {
      return;
    }
    ref.read(actionProvider.notifier).resetActionState();

    List<PlacedImage> pageImageData = [];
    for (final page in newStrat.pages) {
      pageImageData.addAll(page.imageData);
    }
    if (!kIsWeb) {
      List<String> allImageIds = [];
      for (final page in newStrat.pages) {
        allImageIds.addAll(page.imageData.map((image) => image.id));
        for (final lineUp in page.lineUps) {
          List<String> lineUpImages = [];
          lineUpImages.addAll(lineUp.images.map((image) => image.id));
          allImageIds.addAll(lineUpImages);
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
        );
    ref.read(strategySaveStateProvider.notifier).markPersisted();
  }

  Future<String> createNewStrategy(String name) async {
    if (_selectedWorkspaceIsCloud()) {
      final newID = const Uuid().v4();
      final pageID = const Uuid().v4();
      final defaultThemeProfileId =
          ref.read(mapThemeProfilesProvider).defaultProfileIdForNewStrategies;
      try {
        await ref.read(convexStrategyRepositoryProvider).createStrategy(
              publicId: newID,
              name: name,
              mapData: Maps.mapNames[MapValue.ascent] ?? "ascent",
              folderPublicId: ref.read(folderProvider),
              themeProfileId: defaultThemeProfileId,
            );
        await ConvexClient.instance.mutation(name: "pages:add", args: {
          "strategyPublicId": newID,
          "pagePublicId": pageID,
          "name": "Page 1",
          "sortIndex": 0,
          "isAttack": true,
          "settings": ref.read(strategySettingsProvider.notifier).toJson(),
        });
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
      ref.invalidate(cloudFoldersProvider);
      await openCloudStrategy(newID);
      return newID;
    }
    final newID = const Uuid().v4();
    final pageID = const Uuid().v4();
    final defaultThemeProfileId =
        ref.read(mapThemeProfilesProvider).defaultProfileIdForNewStrategies;
    final newStrategy = StrategyData(
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      id: newID,
      name: name,
      pages: [
        StrategyPage(
          id: pageID,
          name: "Page 1",
          drawingData: [],
          agentData: [],
          abilityData: [],
          textData: [],
          imageData: [],
          utilityData: [],
          lineUps: [],
          sortIndex: 0,
          isAttack: true,
          settings: StrategySettings(),
        )
      ],
      lastEdited: DateTime.now(),

      // ignore: deprecated_member_use_from_same_package
      strategySettings: StrategySettings(),
      folderID: ref.read(folderProvider),
      themeProfileId: defaultThemeProfileId,
    );

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(newStrategy.id, newStrategy);

    return newStrategy.id;
  }

  void setThemeProfileForCurrentStrategy(String profileId) {
    ref.read(strategyThemeProvider.notifier).setProfile(profileId);
    setUnsaved();
  }

  void setThemeOverrideForCurrentStrategy(MapThemePalette palette) {
    ref.read(strategyThemeProvider.notifier).setOverride(palette);
    setUnsaved();
  }

  void clearThemeOverrideForCurrentStrategy() {
    ref.read(strategyThemeProvider.notifier).clearOverride();
    setUnsaved();
  }

  Future<void> renameStrategy(
    String strategyID,
    String newName, {
    StrategySource? source,
  }) async {
    final resolvedSource = source ?? _resolveLibraryMutationSource();
    if (resolvedSource == StrategySource.cloud) {
      try {
        await ConvexClient.instance.mutation(name: "strategies:update", args: {
          "strategyPublicId": strategyID,
          "name": newName,
        });
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
        await ref.read(remoteStrategySnapshotProvider.notifier).refresh();
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
      try {
        final snapshot = await ref
            .read(convexStrategyRepositoryProvider)
            .fetchSnapshot(strategyID);
        final newStrategyID = const Uuid().v4();
        await ref.read(convexStrategyRepositoryProvider).createStrategy(
              publicId: newStrategyID,
              name: "${snapshot.header.name} (Copy)",
              mapData: snapshot.header.mapData,
              folderPublicId: ref.read(folderProvider),
              themeProfileId: snapshot.header.themeProfileId,
              themeOverridePalette: snapshot.header.themeOverridePalette,
            );

        final pages = [...snapshot.pages]
          ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

        final pageIdMap = <String, String>{};
        for (final page in pages) {
          final newPageId = const Uuid().v4();
          pageIdMap[page.publicId] = newPageId;
          await ConvexClient.instance.mutation(name: "pages:add", args: {
            "strategyPublicId": newStrategyID,
            "pagePublicId": newPageId,
            "name": page.name,
            "sortIndex": page.sortIndex,
            "isAttack": page.isAttack,
            if (page.settings != null) "settings": page.settings,
          });
        }

        final ops = <StrategyOp>[];
        for (final page in pages) {
          final newPageId = pageIdMap[page.publicId];
          if (newPageId == null) continue;

          final elements = snapshot.elementsByPage[page.publicId] ?? const [];
          for (final element in elements) {
            if (element.deleted) continue;
            final payloadMap = element.decodedPayload();
            payloadMap.putIfAbsent("elementType", () => element.elementType);
            final newElementId = const Uuid().v4();
            payloadMap["id"] = newElementId;
            ops.add(StrategyOp(
              opId: const Uuid().v4(),
              kind: StrategyOpKind.add,
              entityType: StrategyOpEntityType.element,
              entityPublicId: newElementId,
              pagePublicId: newPageId,
              payload: jsonEncode(payloadMap),
              sortIndex: element.sortIndex,
            ));
          }

          final lineups = snapshot.lineupsByPage[page.publicId] ?? const [];
          for (final lineup in lineups) {
            if (lineup.deleted) continue;
            final newLineupId = const Uuid().v4();
            String lineupPayload = lineup.payload;
            try {
              final decoded = jsonDecode(lineup.payload);
              if (decoded is Map<String, dynamic>) {
                final payload = Map<String, dynamic>.from(decoded)
                  ..["id"] = newLineupId;
                lineupPayload = jsonEncode(payload);
              } else if (decoded is Map) {
                final payload = Map<String, dynamic>.from(decoded)
                  ..["id"] = newLineupId;
                lineupPayload = jsonEncode(payload);
              }
            } catch (_) {}
            ops.add(StrategyOp(
              opId: const Uuid().v4(),
              kind: StrategyOpKind.add,
              entityType: StrategyOpEntityType.lineup,
              entityPublicId: newLineupId,
              pagePublicId: newPageId,
              payload: lineupPayload,
              sortIndex: lineup.sortIndex,
            ));
          }
        }

        if (ops.isNotEmpty) {
          await ref.read(convexStrategyRepositoryProvider).applyBatch(
                strategyPublicId: newStrategyID,
                clientId: const Uuid().v4(),
                ops: ops,
              );
        }
      } catch (error, stackTrace) {
        final handled = await _reportCloudUnauthenticated(
          source: 'strategy:duplicate',
          error: error,
          stackTrace: stackTrace,
        );
        if (!handled) rethrow;
        return;
      }
      ref.invalidate(cloudStrategiesProvider);
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

  Future<void> deleteStrategy(
    String strategyID, {
    StrategySource? source,
  }) async {
    final resolvedSource = source ?? _resolveLibraryMutationSource();
    if (resolvedSource == StrategySource.cloud) {
      try {
        await ConvexClient.instance.mutation(name: "strategies:delete", args: {
          "strategyPublicId": strategyID,
        });
      } catch (error, stackTrace) {
        final handled = await _reportCloudUnauthenticated(
          source: 'strategy:delete',
          error: error,
          stackTrace: stackTrace,
        );
        if (!handled) rethrow;
      }
      ref.invalidate(cloudStrategiesProvider);
      return;
    }

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).delete(strategyID);

    final directory = await getApplicationSupportDirectory();

    final customDirectory = Directory(path.join(directory.path, strategyID));

    if (!await customDirectory.exists()) return;

    await customDirectory.delete(recursive: true);
  }

  Future<void> saveToHive(String id) async {
    if (_currentStrategyIsCloud()) {
      return;
    }
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
      lineUps: ref.read(lineUpProvider).lineUps,
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

    await _syncCurrentPageToHive();

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategyId = state.strategyId;
    if (strategyId == null) return;
    final strat = box.get(strategyId);
    if (strat == null || strat.pages.isEmpty) return;

    final target = ref.read(strategySettingsProvider);
    final newPages = [
      for (final page in strat.pages)
        page.copyWith(
          settings: page.settings.copyWith(
            agentSize: target.agentSize,
            abilitySize: target.abilitySize,
          ),
        ),
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

  void moveToFolder({
    required String strategyID,
    required String? parentID,
    StrategySource? source,
  }) {
    final resolvedSource = source ?? _resolveLibraryMutationSource();
    if (resolvedSource == StrategySource.cloud) {
      unawaited(() async {
        try {
          await ConvexClient.instance.mutation(name: "strategies:move", args: {
            "strategyPublicId": strategyID,
            if (parentID != null) "folderPublicId": parentID,
          });
        } catch (error, stackTrace) {
          await _reportCloudUnauthenticated(
            source: 'strategy:move',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }());
      ref.invalidate(cloudStrategiesProvider);
      return;
    }
    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategy = strategyBox.get(strategyID);

    if (strategy != null) {
      strategy.folderID = parentID;
      strategy.save();
    } else {
      log("Strategy with ID $strategyID not found.");
    }
  }
}
