import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, listEquals;
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/transition_provider.dart';
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
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart'
    as strategy_page_session;
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

final strategyProvider =
    NotifierProvider<StrategyProvider, StrategyState>(StrategyProvider.new);

class StrategyProvider extends Notifier<StrategyState> {
  int? _lastHydratedRemoteSequence;
  String? _lastHydratedRemoteStrategyId;
  String? _lastHydratedRemotePageId;

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
  bool _skipQueueingDuringHydration = false;

  //Used For Images
  void setFromState(StrategyState newState) {
    final hasIdentity = newState.strategyId != null ||
        newState.id != 'testID' ||
        newState.stratName != null;
    state = newState.copyWith(
      source: newState.source ??
          (newState.isCloudBacked
              ? StrategySource.cloud
              : (hasIdentity ? StrategySource.local : null)),
      isOpen: newState.isOpen || hasIdentity,
    );
  }

  String? get activePageID =>
      ref.read(strategyPageSessionProvider).activePageId;

  set activePageID(String? value) {
    final session = ref.read(strategyPageSessionProvider);
    ref.read(strategyPageSessionProvider.notifier).setStateForTest(
          session.copyWith(
            activePageId: value,
            clearActivePageId: value == null,
          ),
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
    if (_isCloudMode()) {
      return;
    }
    if (!ref.read(appPreferencesProvider).autosaveEnabled) {
      return;
    }

    _saveTimer = Timer(Settings.autoSaveOffset, () async {
      await _performSave(state.id);
    });
  }

  bool _isCloudMode() {
    return ref.read(isCloudCollabEnabledProvider);
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
    cancelPendingSave();
    ref.read(strategySaveStateProvider.notifier).reset();

    if (!_isCloudMode()) {
      await loadFromHive(strategyID);
      return;
    }

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
    if (_isCloudMode()) {
      await ref.read(strategyPageSessionProvider.notifier).setActivePage(pageID);
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
    if (!_isCloudMode() || ops.isEmpty) {
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

  Future<void> reconcile(List<OpAck> acks) async {
    if (!_isCloudMode() || acks.isEmpty) {
      return;
    }

    bool hasReject = false;
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
        } catch (_) {}
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

    if (hasReject) {
      await ref.read(remoteStrategySnapshotProvider.notifier).refresh();
      final activePageId = ref.read(strategyPageSessionProvider).activePageId;
      if (activePageId != null) {
        await ref.read(strategyPageSessionProvider.notifier).setActivePage(
              activePageId,
            );
      }
      return;
    }

    ref.read(strategySaveStateProvider.notifier).markPersisted();
  }

  Future<void> _hydrateFromRemotePage(
    RemoteStrategySnapshot snapshot,
    String pagePublicId,
  ) async {
    final page = snapshot.pages.firstWhere(
      (p) => p.publicId == pagePublicId,
      orElse: () => snapshot.pages.first,
    );

    final pageElements = snapshot.elementsByPage[page.publicId] ?? const [];
    final pageLineups = snapshot.lineupsByPage[page.publicId] ?? const [];

    final agents = <PlacedAgent>[];
    final abilities = <PlacedAbility>[];
    final drawings = <DrawingElement>[];
    final texts = <PlacedText>[];
    final images = <PlacedImage>[];
    final utilities = <PlacedUtility>[];

    for (final element in pageElements) {
      if (element.deleted) continue;
      final payload = element.decodedPayload();

      try {
        switch (element.elementType) {
          case 'agent':
            agents.add(PlacedAgent.fromJson(payload));
            break;
          case 'ability':
            abilities.add(PlacedAbility.fromJson(payload));
            break;
          case 'drawing':
            final asList = DrawingProvider.fromJson(jsonEncode([payload]));
            if (asList.isNotEmpty) {
              drawings.add(asList.first);
            }
            break;
          case 'text':
            texts.add(PlacedText.fromJson(payload));
            break;
          case 'image':
            images.add(PlacedImage.fromJson(payload));
            break;
          case 'utility':
            utilities.add(PlacedUtility.fromJson(payload));
            break;
          default:
            break;
        }
      } catch (_) {
        // Ignore malformed remote element payloads.
      }
    }

    final lineUps = <LineUp>[];
    for (final remoteLineup in pageLineups) {
      if (remoteLineup.deleted) continue;
      try {
        final decoded = jsonDecode(remoteLineup.payload);
        if (decoded is Map<String, dynamic>) {
          lineUps.add(LineUp.fromJson(decoded));
        }
      } catch (_) {}
    }

    final mapEntry = Maps.mapNames.entries.firstWhere(
      (entry) => entry.value == snapshot.header.mapData,
      orElse: () => const MapEntry(MapValue.ascent, 'ascent'),
    );

    StrategySettings pageSettings = StrategySettings();
    if (page.settings != null && page.settings!.isNotEmpty) {
      try {
        pageSettings = ref
            .read(strategySettingsProvider.notifier)
            .fromJson(page.settings!);
      } catch (_) {}
    }

    MapThemePalette? overridePalette;
    if (snapshot.header.themeOverridePalette != null &&
        snapshot.header.themeOverridePalette!.isNotEmpty) {
      try {
        final decoded = jsonDecode(snapshot.header.themeOverridePalette!);
        if (decoded is Map<String, dynamic>) {
          overridePalette = MapThemePalette.fromJson(decoded);
        } else if (decoded is Map) {
          overridePalette =
              MapThemePalette.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {}
    }

    activePageID = page.publicId;

    _skipQueueingDuringHydration = true;
    try {
      ref.read(actionProvider.notifier).clearAllAsAction();
      ref.read(agentProvider.notifier).fromHive(agents);
      ref.read(abilityProvider.notifier).fromHive(abilities);
      ref.read(drawingProvider.notifier).fromHive(drawings);
      ref.read(textProvider.notifier).fromHive(texts);
      ref.read(placedImageProvider.notifier).fromHive(images);
      ref.read(utilityProvider.notifier).fromHive(utilities);
      ref.read(lineUpProvider.notifier).fromHive(lineUps);

      ref.read(mapProvider.notifier).fromHive(mapEntry.key, page.isAttack);
      ref.read(strategySettingsProvider.notifier).fromHive(pageSettings);
      ref.read(strategyThemeProvider.notifier).fromStrategy(
            profileId: snapshot.header.themeProfileId ??
                MapThemeProfilesProvider.immutableDefaultProfileId,
            overridePalette: overridePalette,
          );

      state = state.copyWith(
        id: snapshot.header.publicId,
        stratName: snapshot.header.name,
        activePageId: page.publicId,
        isCloudBacked: true,
        hasPendingCloudSync: false,
        isSaved: true,
        clearCloudSyncError: true,
        storageDirectory: null,
      );
      _lastHydratedRemoteStrategyId = snapshot.header.publicId;
      _lastHydratedRemoteSequence = snapshot.header.sequence;
      _lastHydratedRemotePageId = page.publicId;
    } finally {
      _skipQueueingDuringHydration = false;
    }
  }

  String? _resolveHydrationTargetPage(RemoteStrategySnapshot snapshot) {
    if (snapshot.pages.isEmpty) {
      return null;
    }

    final candidate =
        ref.read(strategyPageSessionProvider).activePageId ?? activePageID;
    if (candidate != null &&
        snapshot.pages.any((page) => page.publicId == candidate)) {
      return candidate;
    }

    final orderedPages = [...snapshot.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    return orderedPages.first.publicId;
  }

  List<_CollabElementEnvelope> _collectLocalElementEnvelopes() {
    final envelopes = <_CollabElementEnvelope>[];

    for (final agent in ref.read(agentProvider)) {
      final payload = Map<String, dynamic>.from(agent.toJson())
        ..putIfAbsent('elementType', () => 'agent');
      envelopes.add(_CollabElementEnvelope(
        publicId: agent.id,
        elementType: 'agent',
        payload: payload,
      ));
    }

    for (final ability in ref.read(abilityProvider)) {
      final payload = Map<String, dynamic>.from(ability.toJson())
        ..putIfAbsent('elementType', () => 'ability');
      envelopes.add(_CollabElementEnvelope(
        publicId: ability.id,
        elementType: 'ability',
        payload: payload,
      ));
    }

    for (final drawing in ref.read(drawingProvider).elements) {
      final encodedList = jsonDecode(
        DrawingProvider.objectToJson([drawing]),
      ) as List<dynamic>;
      final payload = Map<String, dynamic>.from(
        (encodedList.isNotEmpty ? encodedList.first : <String, dynamic>{})
            as Map,
      )..putIfAbsent('elementType', () => 'drawing');
      envelopes.add(_CollabElementEnvelope(
        publicId: drawing.id,
        elementType: 'drawing',
        payload: payload,
      ));
    }

    for (final text in ref.read(textProvider)) {
      final payload = Map<String, dynamic>.from(text.toJson())
        ..putIfAbsent('elementType', () => 'text');
      envelopes.add(_CollabElementEnvelope(
        publicId: text.id,
        elementType: 'text',
        payload: payload,
      ));
    }

    for (final image in ref.read(placedImageProvider).images) {
      final payload = Map<String, dynamic>.from(image.toJson())
        ..putIfAbsent('elementType', () => 'image');
      envelopes.add(_CollabElementEnvelope(
        publicId: image.id,
        elementType: 'image',
        payload: payload,
      ));
    }

    for (final utility in ref.read(utilityProvider)) {
      final payload = Map<String, dynamic>.from(utility.toJson())
        ..putIfAbsent('elementType', () => 'utility');
      envelopes.add(_CollabElementEnvelope(
        publicId: utility.id,
        elementType: 'utility',
        payload: payload,
      ));
    }

    return envelopes;
  }

  List<StrategyOp> _buildOpsFromCurrentPageSnapshot() {
    final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
    final activePageId = ref.read(strategyPageSessionProvider).activePageId;
    if (snapshot == null || activePageId == null) {
      return const <StrategyOp>[];
    }

    final remoteElements =
        snapshot.elementsByPage[activePageId] ?? const <RemoteElement>[];
    final remoteById = {
      for (final element in remoteElements) element.publicId: element,
    };

    final local = _collectLocalElementEnvelopes();
    final localById = {
      for (var i = 0; i < local.length; i++) local[i].publicId: (local[i], i),
    };

    final ops = <StrategyOp>[];

    for (final entry in localById.entries) {
      final localEnvelope = entry.value.$1;
      final localIndex = entry.value.$2;
      final remote = remoteById[entry.key];
      final payloadString = jsonEncode(localEnvelope.payload);

      if (remote == null || remote.deleted) {
        ops.add(StrategyOp(
          opId: const Uuid().v4(),
          kind: StrategyOpKind.add,
          entityType: StrategyOpEntityType.element,
          entityPublicId: localEnvelope.publicId,
          pagePublicId: activePageId,
          payload: payloadString,
          sortIndex: localIndex,
        ));
        continue;
      }

      final sortChanged = remote.sortIndex != localIndex;
      final payloadChanged = remote.payload != payloadString;
      final typeChanged = remote.elementType != localEnvelope.elementType;

      if (sortChanged || payloadChanged || typeChanged || remote.deleted) {
        ops.add(StrategyOp(
          opId: const Uuid().v4(),
          kind: StrategyOpKind.patch,
          entityType: StrategyOpEntityType.element,
          entityPublicId: localEnvelope.publicId,
          pagePublicId: activePageId,
          payload: payloadString,
          sortIndex: localIndex,
        ));
      }
    }

    for (final remote in remoteElements) {
      if (remote.deleted) continue;
      if (localById.containsKey(remote.publicId)) continue;
      ops.add(StrategyOp(
        opId: const Uuid().v4(),
        kind: StrategyOpKind.delete,
        entityType: StrategyOpEntityType.element,
        entityPublicId: remote.publicId,
      ));
    }

    final remoteLineups =
        snapshot.lineupsByPage[activePageId] ?? const <RemoteLineup>[];
    final remoteLineupById = {
      for (final lineup in remoteLineups) lineup.publicId: lineup,
    };
    final localLineups = ref.read(lineUpProvider).lineUps;

    for (var i = 0; i < localLineups.length; i++) {
      final lineup = localLineups[i];
      final payload = jsonEncode(lineup.toJson());
      final remote = remoteLineupById[lineup.id];
      if (remote == null || remote.deleted) {
        ops.add(StrategyOp(
          opId: const Uuid().v4(),
          kind: StrategyOpKind.add,
          entityType: StrategyOpEntityType.lineup,
          entityPublicId: lineup.id,
          pagePublicId: activePageId,
          payload: payload,
          sortIndex: i,
        ));
        continue;
      }

      if (remote.payload != payload || remote.sortIndex != i) {
        ops.add(StrategyOp(
          opId: const Uuid().v4(),
          kind: StrategyOpKind.patch,
          entityType: StrategyOpEntityType.lineup,
          entityPublicId: lineup.id,
          pagePublicId: activePageId,
          payload: payload,
          sortIndex: i,
        ));
      }
    }

    for (final remote in remoteLineups) {
      if (remote.deleted) continue;
      if (localLineups.any((lineup) => lineup.id == remote.publicId)) continue;
      ops.add(StrategyOp(
        opId: const Uuid().v4(),
        kind: StrategyOpKind.delete,
        entityType: StrategyOpEntityType.lineup,
        entityPublicId: remote.publicId,
      ));
    }

    final activePage = snapshot.pages.firstWhere(
      (page) => page.publicId == activePageId,
      orElse: () => snapshot.pages.first,
    );

    final localSettingsJson =
        ref.read(strategySettingsProvider.notifier).toJson();
    final localIsAttack = ref.read(mapProvider).isAttack;
    if (activePage.settings != localSettingsJson ||
        activePage.isAttack != localIsAttack) {
      ops.add(StrategyOp(
        opId: const Uuid().v4(),
        kind: StrategyOpKind.patch,
        entityType: StrategyOpEntityType.page,
        entityPublicId: activePage.publicId,
        payload: jsonEncode({
          'isAttack': localIsAttack,
          'settings': localSettingsJson,
        }),
      ));
    }

    final localMapName = Maps.mapNames[ref.read(mapProvider).currentMap] ??
        snapshot.header.mapData;
    final localTheme = ref.read(strategyThemeProvider);
    final localThemeOverride = localTheme.overridePalette == null
        ? null
        : jsonEncode(localTheme.overridePalette!.toJson());
    final themeChanged =
        snapshot.header.themeProfileId != localTheme.profileId ||
            snapshot.header.themeOverridePalette != localThemeOverride;
    if (snapshot.header.mapData != localMapName || themeChanged) {
      ops.add(StrategyOp(
        opId: const Uuid().v4(),
        kind: StrategyOpKind.patch,
        entityType: StrategyOpEntityType.strategy,
        payload: jsonEncode({
          'mapData': localMapName,
          'themeProfileId': localTheme.profileId,
          'clearThemeProfileId': localTheme.profileId == null,
          'themeOverridePalette': localThemeOverride,
          'clearThemeOverridePalette': localTheme.overridePalette == null,
        }),
      ));
    }
    return ops;
  }

  Future<void> _queueCurrentPageOps({bool flushImmediately = false}) async {
    if (!_isCloudMode()) {
      return;
    }

    final ops = _buildOpsFromCurrentPageSnapshot();
    if (ops.isEmpty) {
      return;
    }

    await enqueueOps(ops, flushImmediately: flushImmediately);
  }

  Future<void> notifyCloudMutation({bool flushImmediately = false}) async {
    if (!_isCloudMode() || _skipQueueingDuringHydration) {
      return;
    }

    ref.read(strategySaveStateProvider.notifier)
      ..markDirty()
      ..setPendingCloudSync(true)
      ..setCloudSyncError(null);
    await _queueCurrentPageOps(flushImmediately: flushImmediately);
  }

  void setUnsaved() async {
    if (_skipQueueingDuringHydration ||
        ref.read(strategyPageSessionProvider).isApplyingPage) {
      return;
    }

    if (_isCloudMode()) {
      unawaited(notifyCloudMutation(flushImmediately: false));
      return;
    }

    ref.read(strategySaveStateProvider.notifier).markDirty();
    refreshAutosaveScheduling();
  }

  Future<void> forceSaveNow(String id) async {
    cancelPendingSave();
    if (_isCloudMode()) {
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
      if (_isCloudMode()) {
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
    activePageID = null;
    ref.read(strategyThemeProvider.notifier).fromStrategy();
    ref.read(strategySaveStateProvider.notifier).reset();
    ref.read(strategyPageSessionProvider.notifier).setStateForTest(
          const StrategyPageSessionState(
            activePageId: null,
            availablePageIds: [],
            transitionState: strategy_page_session.PageTransitionState.idle,
            isApplyingPage: false,
          ),
        );
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

  Future<void> _setActivePageCloud(String pageID) async {
    await _queueCurrentPageOps(flushImmediately: false);
    await ref.read(strategyOpQueueProvider.notifier).flushNow();

    final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
    if (snapshot == null) {
      return;
    }

    await _hydrateFromRemotePage(snapshot, pageID);
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

    if (_isCloudMode()) {
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
        "strategyPublicId": state.id,
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
    final strat = box.get(state.id);
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

  PageTransitionDirection _resolveDirectionForPage(
      String pageID, List<StrategyPage> orderedPages) {
    if (activePageID == null) return PageTransitionDirection.forward;

    final currentIndex = orderedPages.indexWhere((p) => p.id == activePageID);
    final targetIndex = orderedPages.indexWhere((p) => p.id == pageID);
    if (currentIndex < 0 || targetIndex < 0) {
      return PageTransitionDirection.forward;
    }

    final length = orderedPages.length;
    final forwardSteps = (targetIndex - currentIndex + length) % length;
    final backwardSteps = (currentIndex - targetIndex + length) % length;
    return forwardSteps <= backwardSteps
        ? PageTransitionDirection.forward
        : PageTransitionDirection.backward;
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

  Map<String, PlacedWidget> _snapshotAllPlaced() {
    final map = <String, PlacedWidget>{};
    for (final a in ref.read(agentProvider)) map[a.id] = a;
    for (final ab in ref.read(abilityProvider)) map[ab.id] = ab;
    for (final t in ref.read(textProvider)) map[t.id] = t;
    for (final img in ref.read(placedImageProvider).images) map[img.id] = img;
    for (final u in ref.read(utilityProvider)) map[u.id] = u;
    return map;
  }

  List<PageTransitionEntry> _diffToTransitions(
    Map<String, PlacedWidget> prev,
    Map<String, PlacedWidget> next,
  ) {
    final entries = <PageTransitionEntry>[];
    var order = 0;

    // Move / appear
    next.forEach((id, to) {
      final from = prev[id];
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
          // Unchanged: include as 'none' so it stays visible while base view is hidden
          entries.add(PageTransitionEntry.none(to: to, order: order));
        }
      } else {
        entries.add(PageTransitionEntry.appear(to: to, order: order));
      }
      order++;
    });

    // Disappear
    prev.forEach((id, from) {
      if (!next.containsKey(id)) {
        entries.add(PageTransitionEntry.disappear(from: from, order: order));
        order++;
      }
    });

    return entries;
  }

  Future<void> addPage([String? name]) async {
    if (_isCloudMode()) {
      final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
      if (snapshot == null) return;
      final pages = [...snapshot.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      final pageID = const Uuid().v4();
      final nextIndex = pages.length;
      try {
      await ConvexClient.instance.mutation(name: "pages:add", args: {
        "strategyPublicId": state.id,
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
      final refreshed = ref.read(remoteStrategySnapshotProvider).valueOrNull;
      if (refreshed != null) {
        await _hydrateFromRemotePage(refreshed, pageID);
      }
      return;
    }

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);

    // Flush current page so its edits are not lost
    await _syncCurrentPageToHive();

    final strat = box.get(state.id);
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

  Future<void> loadFromHive(String id) async {
    cancelPendingSave();
    if (_isCloudMode()) {
      await openStrategy(id);
      return;
    }
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

    final newDir = kIsWeb ? null : await setStorageDirectory(migratedStrategy.id);
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
    if (_isCloudMode()) {
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
      await openStrategy(newID);
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

  Future<void> renameStrategy(String strategyID, String newName) async {
    if (_isCloudMode()) {
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
      await ref.read(remoteStrategySnapshotProvider.notifier).refresh();
      return;
    }

    final strategyBox = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strategy = strategyBox.get(strategyID);

    if (strategy != null) {
      strategy.name = newName;
      await strategy.save();
      if (state.id == strategyID) {
        state = state.copyWith(stratName: newName);
      }
    } else {
      log("Strategy with ID $strategyID not found.");
    }
  }

  Future<void> duplicateStrategy(String strategyID) async {
    if (_isCloudMode()) {
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

  Future<void> deleteStrategy(String strategyID) async {
    if (_isCloudMode()) {
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
      return;
    }

    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).delete(strategyID);

    final directory = await getApplicationSupportDirectory();

    final customDirectory = Directory(path.join(directory.path, strategyID));

    if (!await customDirectory.exists()) return;

    await customDirectory.delete(recursive: true);
  }

  Future<void> saveToHive(String id) async {
    if (_isCloudMode()) {
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

  // Flush currently active page (uses activePageID). Safe if null/missing.
  Future<void> _syncCurrentPageToHive() async {
    if (_isCloudMode()) {
      return;
    }
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    log("Syncing current page to hive for strategy ${state.id}");
    final strat = box.get(state.id);
    if (strat == null || strat.pages.isEmpty) {
      log("No strategy or pages found for syncing.");
      return;
    }

    final pageId = activePageID ?? strat.pages.first.id;
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
    if (state.stratName == null) return;

    await _syncCurrentPageToHive();

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final strat = box.get(state.id);
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

  void moveToFolder({required String strategyID, required String? parentID}) {
    if (_isCloudMode()) {
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

class _CollabElementEnvelope {
  const _CollabElementEnvelope({
    required this.publicId,
    required this.elementType,
    required this.payload,
  });

  final String publicId;
  final String elementType;
  final Map<String, dynamic> payload;
}

