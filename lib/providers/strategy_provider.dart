import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:convex_flutter/convex_flutter.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/migrations/ability_scale_migration.dart';
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
import 'package:icarus/const/bounding_box.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';

class StrategyData extends HiveObject {
  final String id;
  String name;
  final int versionNumber;

  @Deprecated('Use pages instead')
  final List<DrawingElement> drawingData;

  @Deprecated('Use pages instead')
  final List<PlacedAgent> agentData;

  @Deprecated('Use pages instead')
  final List<PlacedAbility> abilityData;

  @Deprecated('Use pages instead')
  final List<PlacedText> textData;

  @Deprecated('Use pages instead')
  final List<PlacedImage> imageData;

  @Deprecated('Use pages instead')
  final List<PlacedUtility> utilityData;

  @Deprecated('Use pages instead')
  final bool isAttack;

  @Deprecated('Use pages instead')
  final StrategySettings strategySettings;

  final List<StrategyPage> pages;
  final MapValue mapData;
  final DateTime lastEdited;
  final DateTime createdAt;

  String? folderID;
  final String? themeProfileId;
  final MapThemePalette? themeOverridePalette;

  StrategyData({
    @Deprecated('Use pages instead') this.isAttack = true,
    @Deprecated('Use pages instead') this.drawingData = const [],
    @Deprecated('Use pages instead') this.agentData = const [],
    @Deprecated('Use pages instead') this.abilityData = const [],
    @Deprecated('Use pages instead') this.textData = const [],
    @Deprecated('Use pages instead') this.imageData = const [],
    @Deprecated('Use pages instead') this.utilityData = const [],
    required this.id,
    required this.name,
    required this.mapData,
    required this.versionNumber,
    required this.lastEdited,
    required this.folderID,
    this.themeProfileId,
    this.themeOverridePalette,
    this.pages = const [],
    DateTime? createdAt,
    @Deprecated('Use pages instead') StrategySettings? strategySettings,
    // ignore: deprecated_member_use_from_same_package
  })  : strategySettings = strategySettings ?? StrategySettings(),
        createdAt = createdAt ?? lastEdited;

  StrategyData copyWith({
    String? id,
    String? name,
    int? versionNumber,
    List<DrawingElement>? drawingData,
    List<PlacedAgent>? agentData,
    List<PlacedAbility>? abilityData,
    List<PlacedText>? textData,
    List<PlacedImage>? imageData,
    List<PlacedUtility>? utilityData,
    List<StrategyPage>? pages,
    MapValue? mapData,
    DateTime? lastEdited,
    bool? isAttack,
    StrategySettings? strategySettings,
    String? folderID,
    DateTime? createdAt,
    String? themeProfileId,
    bool clearThemeProfileId = false,
    MapThemePalette? themeOverridePalette,
    bool clearThemeOverridePalette = false,
  }) {
    return StrategyData(
      id: id ?? this.id,
      name: name ?? this.name,
      versionNumber: versionNumber ?? this.versionNumber,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      drawingData: drawingData ?? this.drawingData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      agentData: agentData ?? this.agentData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      abilityData: abilityData ?? this.abilityData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      textData: textData ?? this.textData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      imageData: imageData ?? this.imageData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      utilityData: utilityData ?? this.utilityData,
      pages: pages ?? this.pages,
      mapData: mapData ?? this.mapData,
      lastEdited: lastEdited ?? this.lastEdited,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      isAttack: isAttack ?? this.isAttack,
      // ignore: deprecated_member_use_from_same_package
      strategySettings: strategySettings ?? this.strategySettings,
      createdAt: createdAt ?? this.createdAt,
      folderID: folderID ?? this.folderID,
      themeProfileId:
          clearThemeProfileId ? null : (themeProfileId ?? this.themeProfileId),
      themeOverridePalette: clearThemeOverridePalette
          ? null
          : (themeOverridePalette ?? this.themeOverridePalette),
    );
  }
}

class StrategyState {
  StrategyState({
    required this.isSaved,
    required this.stratName,
    required this.id,
    required this.storageDirectory,
    this.activePageId,
  });

  final bool isSaved;
  final String? stratName;
  final String id;
  final String? storageDirectory;
  final String? activePageId;

  StrategyState copyWith({
    bool? isSaved,
    String? stratName,
    String? id,
    String? storageDirectory,
    String? activePageId,
    bool clearActivePageId = false,
  }) {
    return StrategyState(
      isSaved: isSaved ?? this.isSaved,
      stratName: stratName ?? this.stratName,
      id: id ?? this.id,
      storageDirectory: storageDirectory ?? this.storageDirectory,
      activePageId:
          clearActivePageId ? null : (activePageId ?? this.activePageId),
    );
  }
}

final strategyProvider =
    NotifierProvider<StrategyProvider, StrategyState>(StrategyProvider.new);

class NewerVersionImportException implements Exception {
  const NewerVersionImportException({
    required this.importedVersion,
    required this.currentVersion,
  });

  final int importedVersion;
  final int currentVersion;

  static const String userMessage =
      'This strategy was created in a newer version of Icarus. '
      'Please update the app and try again.';

  @override
  String toString() {
    return 'NewerVersionImportException('
        'importedVersion: $importedVersion, '
        'currentVersion: $currentVersion'
        ')';
  }
}

class StrategyProvider extends Notifier<StrategyState> {
  String? activePageID;
  int? _lastHydratedRemoteSequence;
  String? _lastHydratedRemoteStrategyId;
  String? _lastHydratedRemotePageId;

  @override
  StrategyState build() {
    ref.listen<StrategyOpQueueState>(strategyOpQueueProvider, (previous, next) {
      final previousAcks = previous?.lastAcks ?? const <OpAck>[];
      if (next.lastAcks.isEmpty || identical(previousAcks, next.lastAcks)) {
        return;
      }
      unawaited(reconcile(next.lastAcks));
    });
    ref.listen<AsyncValue<RemoteStrategySnapshot?>>(
      remoteStrategySnapshotProvider,
      (previous, next) {
        if (!_isCloudMode()) {
          return;
        }

        final snapshot = next.valueOrNull;
        if (snapshot == null || snapshot.pages.isEmpty) {
          return;
        }

        final activeRemoteStrategy = ref
            .read(remoteStrategySnapshotProvider.notifier)
            .activeStrategyPublicId;
        if (activeRemoteStrategy != snapshot.header.publicId ||
            state.id != snapshot.header.publicId) {
          return;
        }

        final queue = ref.read(strategyOpQueueProvider);
        if (queue.isFlushing || queue.pending.isNotEmpty || !state.isSaved) {
          return;
        }

        final prevSequence = previous?.valueOrNull?.header.sequence;
        final sequenceChanged =
            prevSequence == null || prevSequence != snapshot.header.sequence;
        final targetPageId = _resolveHydrationTargetPage(snapshot);
        if (!sequenceChanged || targetPageId == null) {
          return;
        }

        final alreadyHydratedForSequence =
            _lastHydratedRemoteStrategyId == snapshot.header.publicId &&
                _lastHydratedRemoteSequence == snapshot.header.sequence &&
                _lastHydratedRemotePageId == targetPageId;
        if (alreadyHydratedForSequence) {
          return;
        }

        unawaited(_hydrateFromRemotePage(snapshot, targetPageId));
      },
    );

    return StrategyState(
      isSaved: false,
      stratName: null,
      id: "testID",
      storageDirectory: null,
      activePageId: null,
    );
  }

  Timer? _saveTimer;

  bool _saveInProgress = false;
  bool _pendingSave = false;
  bool _skipQueueingDuringHydration = false;

  //Used For Images
  void setFromState(StrategyState newState) {
    state = newState;
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
    if (!_isCloudMode()) {
      await loadFromHive(strategyID);
      return;
    }

    await ref
        .read(remoteStrategySnapshotProvider.notifier)
        .openStrategy(strategyID);
    final snapshotAsync = ref.read(remoteStrategySnapshotProvider);
    final snapshot = snapshotAsync.valueOrNull;
    if (snapshot == null || snapshot.pages.isEmpty) {
      return;
    }

    final firstPage = [...snapshot.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final page = firstPage.first;

    await _hydrateFromRemotePage(snapshot, page.publicId);
  }

  Future<void> switchPage(String pageID) async {
    if (_isCloudMode()) {
      await setActivePage(pageID);
      return;
    }

    await setActivePageAnimated(pageID);
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
    if (_skipQueueingDuringHydration) {
      return;
    }

    state = state.copyWith(isSaved: false);
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
      final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
      if (snapshot != null && state.activePageId != null) {
        await _hydrateFromRemotePage(snapshot, state.activePageId!);
      }
      return;
    }

    state = state.copyWith(isSaved: true);
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
      ref.read(actionProvider.notifier).clearAllActions();
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
        isSaved: true,
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

    final candidate = state.activePageId ?? activePageID;
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
    final activePageId = state.activePageId;
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

  void setUnsaved() async {
    log("Setting unsaved is being called");

    if (_skipQueueingDuringHydration) {
      return;
    }

    state = state.copyWith(isSaved: false);
    _saveTimer?.cancel();

    if (_isCloudMode()) {
      _saveTimer = Timer(Settings.autoSaveOffset, () async {
        await _queueCurrentPageOps(flushImmediately: false);
        await ref.read(strategyOpQueueProvider.notifier).flushNow();
      });
      return;
    }

    _saveTimer = Timer(Settings.autoSaveOffset, () async {
      if (state.stratName == null) return;
      await _performSave(state.id);
    });
  }

  // For manual save-now actions
  Future<void> forceSaveNow(String id) async {
    _saveTimer?.cancel();
    if (_isCloudMode()) {
      await _queueCurrentPageOps(flushImmediately: false);
      await ref.read(strategyOpQueueProvider.notifier).flushNow();
      return;
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
      if (_isCloudMode()) {
        await _queueCurrentPageOps(flushImmediately: false);
        await ref.read(strategyOpQueueProvider.notifier).flushNow();
      } else {
        await saveToHive(id);
      }
    } finally {
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

    log(customDirectory.path);
    return customDirectory;
  }

  Future<void> clearCurrentStrategy() async {
    activePageID = null;
    ref.read(strategyThemeProvider.notifier).fromStrategy();
    state = StrategyState(
      isSaved: true,
      stratName: null,
      id: "testID",
      storageDirectory: state.storageDirectory,
      activePageId: null,
    );
  }
  // --- MIGRATION: create a first page from legacy flat fields ----------------

  static Future<void> migrateAllStrategies() async {
    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    for (final strat in box.values) {
      final legacyMigrated = await migrateLegacyData(strat);
      final worldMigrated = migrateToWorld16x9(legacyMigrated);
      final abilityScaleMigrated = migrateAbilityScale(worldMigrated);
      final squareAoeMigrated = migrateSquareAoeCenter(abilityScaleMigrated);
      if (squareAoeMigrated != abilityScaleMigrated) {
        await box.put(squareAoeMigrated.id, squareAoeMigrated);
      } else if (abilityScaleMigrated != worldMigrated) {
        await box.put(abilityScaleMigrated.id, abilityScaleMigrated);
      } else if (worldMigrated != legacyMigrated) {
        await box.put(worldMigrated.id, worldMigrated);
      } else if (legacyMigrated != strat) {
        await box.put(legacyMigrated.id, legacyMigrated);
      }
    }
  }

  static StrategyData migrateAbilityScale(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= AbilityScaleMigration.version) {
      return strat;
    }

    final migratedPages = AbilityScaleMigration.migratePages(
      pages: strat.pages,
      map: strat.mapData,
    );

    final hasPageChanged = migratedPages.length == strat.pages.length &&
        migratedPages.asMap().entries.any((entry) {
          final index = entry.key;
          return entry.value != strat.pages[index];
        });

    if (!hasPageChanged && !force) {
      return strat;
    }

    return strat.copyWith(
      pages: migratedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );
  }

  static StrategyData migrateSquareAoeCenter(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= SquareAoeCenterMigration.version) {
      return strat;
    }

    final migratedPages = SquareAoeCenterMigration.migratePages(
      pages: strat.pages,
    );

    final hasPageChanged = migratedPages.length == strat.pages.length &&
        migratedPages.asMap().entries.any((entry) {
          final index = entry.key;
          return entry.value != strat.pages[index];
        });

    if (!hasPageChanged && !force) {
      return strat;
    }

    return strat.copyWith(
      pages: migratedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );
  }

  static StrategyData migrateToCurrentVersion(StrategyData strat,
      {bool forceAbilityScale = false}) {
    final worldMigrated = migrateToWorld16x9(strat);
    final abilityScaleMigrated =
        migrateAbilityScale(worldMigrated, force: forceAbilityScale);
    return migrateSquareAoeCenter(abilityScaleMigrated);
  }

  static Future<StrategyData> migrateLegacyData(StrategyData strat) async {
    // Already migrated
    if (strat.pages.isNotEmpty) {
      return migrateToCurrentVersion(strat);
    }
    if (strat.versionNumber > 15) {
      return migrateToCurrentVersion(strat);
    }
    final originalVersion = strat.versionNumber;
    log("Migrating legacy strategy to single page");
    // ignore: deprecated_member_use, deprecated_member_use_from_same_package
    final abilityData = [...strat.abilityData];
    if (strat.versionNumber < 7) {
      for (final a in abilityData) {
        if (a.data.abilityData! is SquareAbility) {
          a.position = a.position.translate(0, -7.5);
        }
      }
    }

    final firstPage = StrategyPage(
      id: const Uuid().v4(),
      name: "Page 1",
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      drawingData: [...strat.drawingData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      agentData: [...strat.agentData],
      abilityData: abilityData,
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      textData: [...strat.textData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      imageData: [...strat.imageData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      utilityData: [...strat.utilityData],
      // ignore: deprecated_member_use, deprecated_member_use_from_same_package
      isAttack: strat.isAttack,
      // ignore: deprecated_member_use_from_same_package
      settings: strat.strategySettings,
      sortIndex: 0,
    );

    final updated = strat.copyWith(
      pages: [firstPage],
      agentData: [],
      abilityData: [],
      drawingData: [],
      utilityData: [],
      textData: [],
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );

    final worldMigrated = migrateToWorld16x9(updated,
        force: originalVersion < Settings.versionNumber);
    final abilityScaleMigrated = migrateAbilityScale(
      worldMigrated,
      force: originalVersion < AbilityScaleMigration.version,
    );
    return migrateSquareAoeCenter(
      abilityScaleMigrated,
      force: originalVersion < SquareAoeCenterMigration.version,
    );
  }

  static StrategyData migrateToWorld16x9(StrategyData strat,
      {bool force = false}) {
    if (!force && strat.versionNumber >= 38) return strat;

    const double normalizedHeight = 1000.0;
    const double mapAspectRatio = 1.24;
    const double worldAspectRatio = 16 / 9;
    const mapWidth = normalizedHeight * mapAspectRatio;
    const worldWidth = normalizedHeight * worldAspectRatio;
    const padding = (worldWidth - mapWidth) / 2;

    Offset shift(Offset offset) => offset.translate(padding, 0);

    List<PlacedAgent> shiftAgents(List<PlacedAgent> agents) {
      return [
        for (final agent in agents)
          agent.copyWith(position: shift(agent.position))
            ..isDeleted = agent.isDeleted
      ];
    }

    List<PlacedAbility> shiftAbilities(List<PlacedAbility> abilities) {
      return [
        for (final ability in abilities)
          ability.copyWith(position: shift(ability.position))
            ..isDeleted = ability.isDeleted
      ];
    }

    List<PlacedText> shiftTexts(List<PlacedText> texts) {
      return [
        for (final text in texts)
          PlacedText(
            position: shift(text.position),
            id: text.id,
            size: text.size,
          )
            ..text = text.text
            ..isDeleted = text.isDeleted
      ];
    }

    List<PlacedImage> shiftImages(List<PlacedImage> images) {
      return [
        for (final image in images)
          image.copyWith(position: shift(image.position))
            ..isDeleted = image.isDeleted
      ];
    }

    List<PlacedUtility> shiftUtilities(List<PlacedUtility> utilities) {
      return [
        for (final utility in utilities)
          PlacedUtility(
            type: utility.type,
            position: shift(utility.position),
            id: utility.id,
            angle: utility.angle,
            attachedAgentId: utility.attachedAgentId,
            customDiameter: utility.customDiameter,
            customWidth: utility.customWidth,
            customLength: utility.customLength,
            customColorValue: utility.customColorValue,
            customOpacityPercent: utility.customOpacityPercent,
          )
            ..rotation = utility.rotation
            ..length = utility.length
            ..isDeleted = utility.isDeleted
      ];
    }

    List<LineUp> shiftLineUps(List<LineUp> lineUps) {
      return [
        for (final lineUp in lineUps)
          () {
            final shiftedAgent = lineUp.agent.copyWith(
              position: shift(lineUp.agent.position),
            )..isDeleted = lineUp.agent.isDeleted;
            final shiftedAbility = lineUp.ability.copyWith(
              position: shift(lineUp.ability.position),
            )..isDeleted = lineUp.ability.isDeleted;
            return lineUp.copyWith(
              agent: shiftedAgent,
              ability: shiftedAbility,
            );
          }()
      ];
    }

    List<DrawingElement> shiftDrawings(List<DrawingElement> drawings) {
      return drawings
          .map((element) {
            if (element is Line) {
              return Line(
                lineStart: shift(element.lineStart),
                lineEnd: shift(element.lineEnd),
                color: element.color,
                isDotted: element.isDotted,
                hasArrow: element.hasArrow,
                id: element.id,
              );
            }
            if (element is FreeDrawing) {
              final shiftedPoints =
                  element.listOfPoints.map(shift).toList(growable: false);
              final shiftedBoundingBox = element.boundingBox == null
                  ? null
                  : BoundingBox(
                      min: shift(element.boundingBox!.min),
                      max: shift(element.boundingBox!.max),
                    );

              return FreeDrawing(
                listOfPoints: shiftedPoints,
                color: element.color,
                boundingBox: shiftedBoundingBox,
                isDotted: element.isDotted,
                hasArrow: element.hasArrow,
                id: element.id,
              );
            }
            return element;
          })
          .cast<DrawingElement>()
          .toList(growable: false);
    }

    final updatedPages = strat.pages
        .map((page) => page.copyWith(
              sortIndex: page.sortIndex,
              name: page.name,
              id: page.id,
              agentData: shiftAgents(page.agentData),
              abilityData: shiftAbilities(page.abilityData),
              textData: shiftTexts(page.textData),
              imageData: shiftImages(page.imageData),
              utilityData: shiftUtilities(page.utilityData),
              drawingData: shiftDrawings(page.drawingData),
              lineUps: shiftLineUps(page.lineUps),
            ))
        .toList(growable: false);

    final migrated = strat.copyWith(
      pages: updatedPages,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.now(),
    );

    return migrated;
  }

  // Switch active page: flush old page first, then hydrate new
  Future<void> setActivePage(String pageID) async {
    if (pageID == activePageID) return;

    if (_isCloudMode()) {
      await _setActivePageCloud(pageID);
      return;
    }

    // Flush current before switching
    await _syncCurrentPageToHive();

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final doc = box.get(state.id);
    if (doc == null) return;

    final page = doc.pages.firstWhere(
      (p) => p.id == pageID,
      orElse: () => doc.pages.first,
    );

    activePageID = page.id;
    state = state.copyWith(activePageId: page.id);

    ref.read(actionProvider.notifier).clearAllActions();
    final migrated = migrateToCurrentVersion(doc);
    final migratedPage = migrated.pages.firstWhere(
      (p) => p.id == page.id,
      orElse: () => migrated.pages.first,
    );
    if (migrated != doc) {
      await box.put(migrated.id, migrated);
    }

    ref.read(agentProvider.notifier).fromHive(migratedPage.agentData);
    ref.read(abilityProvider.notifier).fromHive(migratedPage.abilityData);
    ref.read(drawingProvider.notifier).fromHive(migratedPage.drawingData);
    ref.read(textProvider.notifier).fromHive(migratedPage.textData);
    ref.read(placedImageProvider.notifier).fromHive(migratedPage.imageData);
    ref.read(utilityProvider.notifier).fromHive(migratedPage.utilityData);
    ref.read(mapProvider.notifier).setAttack(migratedPage.isAttack);
    ref.read(strategySettingsProvider.notifier).fromHive(migratedPage.settings);
    ref.read(strategyThemeProvider.notifier).fromStrategy(
          profileId: migrated.themeProfileId ??
              MapThemeProfilesProvider.immutableDefaultProfileId,
          overridePalette: migrated.themeOverridePalette,
        );
    ref.read(lineUpProvider.notifier).fromHive(migratedPage.lineUps);

    // Defer path rebuild until next frame (layout complete)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(drawingProvider.notifier)
          .rebuildAllPaths(CoordinateSystem.instance);
    });
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
    if (_isCloudMode()) {
      final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
      if (snapshot == null || snapshot.pages.isEmpty) return;
      final pages = [...snapshot.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      final activeId = activePageID ?? pages.first.publicId;
      final currentIndex = pages.indexWhere((p) => p.publicId == activeId);
      if (currentIndex < 0) return;
      var nextIndex = currentIndex - 1;
      if (nextIndex < 0) nextIndex = pages.length - 1;
      await setActivePage(pages[nextIndex].publicId);
      return;
    }

    if (activePageID == null) return;

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final doc = box.get(state.id);
    if (doc == null || doc.pages.isEmpty) return;

    final pages = [...doc.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

    final currentIndex = pages.indexWhere((p) => p.id == activePageID);
    if (currentIndex == -1) return;
    int nextIndex = currentIndex - 1;
    if (nextIndex < 0) nextIndex = pages.length - 1;

    final nextPage = pages[nextIndex];
    await setActivePageAnimated(
      nextPage.id,
      direction: PageTransitionDirection.backward,
    );
  }

  Future<void> forwardPage() async {
    if (_isCloudMode()) {
      final snapshot = ref.read(remoteStrategySnapshotProvider).valueOrNull;
      if (snapshot == null || snapshot.pages.isEmpty) return;
      final pages = [...snapshot.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      final activeId = activePageID ?? pages.first.publicId;
      final currentIndex = pages.indexWhere((p) => p.publicId == activeId);
      if (currentIndex < 0) return;
      var nextIndex = currentIndex + 1;
      if (nextIndex >= pages.length) nextIndex = 0;
      await setActivePage(pages[nextIndex].publicId);
      return;
    }

    if (activePageID == null) return;

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final doc = box.get(state.id);
    if (doc == null || doc.pages.isEmpty) return;

    final pages = [...doc.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

    final currentIndex = pages.indexWhere((p) => p.id == activePageID);
    if (currentIndex == -1) return;

    int nextIndex = currentIndex + 1;
    if (nextIndex >= pages.length) nextIndex = 0;

    final nextPage = pages[nextIndex];
    await setActivePageAnimated(
      nextPage.id,
      direction: PageTransitionDirection.forward,
    );
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
    if (pageID == activePageID) return;
    if (_isCloudMode()) {
      await setActivePage(pageID);
      return;
    }

    final transitionState = ref.read(transitionProvider);
    final transitionNotifier = ref.read(transitionProvider.notifier);
    if (transitionState.active ||
        transitionState.phase == PageTransitionPhase.preparing) {
      transitionNotifier.complete();
    }

    final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
    final doc = box.get(state.id);
    if (doc == null || doc.pages.isEmpty) return;

    final orderedPages = [...doc.pages]
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
    final resolvedDirection =
        direction ?? _resolveDirectionForPage(pageID, orderedPages);
    final startSettings = ref.read(strategySettingsProvider);

    final prev = _snapshotAllPlaced();
    transitionNotifier.prepare(prev.values.toList(),
        direction: resolvedDirection,
        startAgentSize: startSettings.agentSize,
        startAbilitySize: startSettings.abilitySize);

    // Load target page (hydrates providers)
    await setActivePage(pageID);
    final endSettings = ref.read(strategySettingsProvider);

    // After layout, snapshot next and start transition
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final next = _snapshotAllPlaced();
      final entries = _diffToTransitions(prev, next);
      if (entries.isNotEmpty) {
        transitionNotifier.start(
          entries,
          duration: duration,
          direction: resolvedDirection,
          startAgentSize: startSettings.agentSize,
          endAgentSize: endSettings.agentSize,
          startAbilitySize: startSettings.abilitySize,
          endAbilitySize: endSettings.abilitySize,
        );
      } else {
        transitionNotifier.complete();
      }
    });
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
            PageTransitionEntry.scaleOf(from) !=
                PageTransitionEntry.scaleOf(to) ||
            PageTransitionEntry.textSizeOf(from) !=
                PageTransitionEntry.textSizeOf(to)) {
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
      log("Couldn't find save");
      return;
    }
    ref.read(actionProvider.notifier).clearAllActions();

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
    log(newStrat.pages.first.toString());
    final migratedStrategy = migrateToCurrentVersion(newStrat);
    final page = migratedStrategy.pages.first;

    if (migratedStrategy != newStrat) {
      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(migratedStrategy.id, migratedStrategy);
    }

    ref.read(agentProvider.notifier).fromHive(page.agentData);
    ref.read(abilityProvider.notifier).fromHive(page.abilityData);
    ref.read(drawingProvider.notifier).fromHive(page.drawingData);

    ref
        .read(mapProvider.notifier)
        .fromHive(migratedStrategy.mapData, page.isAttack);
    ref.read(textProvider.notifier).fromHive(page.textData);
    ref.read(placedImageProvider.notifier).fromHive(page.imageData);
    ref.read(lineUpProvider.notifier).fromHive(page.lineUps);
    ref.read(strategySettingsProvider.notifier).fromHive(page.settings);
    ref.read(strategyThemeProvider.notifier).fromStrategy(
          profileId: migratedStrategy.themeProfileId ??
              MapThemeProfilesProvider.immutableDefaultProfileId,
          overridePalette: migratedStrategy.themeOverridePalette,
        );
    ref.read(utilityProvider.notifier).fromHive(page.utilityData);
    activePageID = page.id;

    if (kIsWeb) {
      state = StrategyState(
        isSaved: true,
        stratName: migratedStrategy.name,
        id: migratedStrategy.id,
        storageDirectory: null,
        activePageId: page.id,
      );
      return;
    }
    final newDir = await setStorageDirectory(migratedStrategy.id);

    state = StrategyState(
      isSaved: true,
      stratName: migratedStrategy.name,
      id: migratedStrategy.id,
      storageDirectory: newDir.path,
      activePageId: page.id,
    );
  }

  Future<void> loadFromFilePath(String filePath) async {
    await _loadFromXFile(XFile(filePath));
  }

  Future<void> loadFromFilePicker() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: ["ica"],
    );

    if (result == null) return;

    for (PlatformFile file in result.files) {
      await _loadFromXFile(file.xFile);
    }
  }

  Future<void> loadFromFileDrop(List<XFile> files) async {
    for (XFile file in files) {
      await _loadFromXFile(file);
    }
  }

  Future<Directory> getTempDirectory(String strategyID) async {
    final tempDirectory = await getTemporaryDirectory();

    Directory tempDir = await Directory(
            path.join(tempDirectory.path, "xyz.icarus-strats", strategyID))
        .create(recursive: true);
    return tempDir;
  }

  Future<void> cleanUpTempDirectory(String strategyID) async {
    final tempDirectory = await getTempDirectory(strategyID);
    await tempDirectory.delete(recursive: true);
  }

  /// Returns true if the file is a ZIP (by checking the magic number)
  Future<bool> isZipFile(File file) async {
    // Read the first 4 bytes of the file
    final raf = file.openSync(mode: FileMode.read);
    final header = raf.readSync(4);
    await raf.close();

    // ZIP files start with 'PK\x03\x04'
    return header.length == 4 &&
        header[0] == 0x50 && // 'P'
        header[1] == 0x4B && // 'K'
        header[2] == 0x03 &&
        header[3] == 0x04;
  }

  Future<void> _loadFromXFile(XFile xFile) async {
    final newID = const Uuid().v4();
    final bool isZip = await isZipFile(File(xFile.path));

    log("Is ZIP file: $isZip");
    final bytes = await xFile.readAsBytes();
    String jsonData = "";

    try {
      if (isZip) {
        // Decode the Zip file
        final archive = ZipDecoder().decodeBytes(bytes);

        final imageFolder = await PlacedImageProvider.getImageFolder(newID);
        final tempDirectory = await getTempDirectory(newID);

        await extractArchiveToDisk(archive, tempDirectory.path);

        final tempDirectoryList = tempDirectory.listSync();
        log("Temp directory list: ${tempDirectoryList.length}.");

        for (final fileEntity in tempDirectoryList) {
          if (fileEntity is File) {
            log(fileEntity.path);
            if (path.extension(fileEntity.path) == ".json") {
              log("Found JSON file");
              jsonData = await fileEntity.readAsString();
            } else if (path.extension(fileEntity.path) != ".ica") {
              final fileName = path.basename(fileEntity.path);
              await fileEntity.copy(path.join(imageFolder.path, fileName));
            }
          }
        }
        if (jsonData.isEmpty) {
          throw Exception("No .ica file found");
        }
      } else {
        jsonData = await xFile.readAsString();
      }

      Map<String, dynamic> json = jsonDecode(jsonData);
      final versionNumber = int.tryParse(json["versionNumber"].toString()) ??
          Settings.versionNumber;
      _throwIfImportedVersionIsTooNew(versionNumber);

      final List<DrawingElement> drawingData =
          DrawingProvider.fromJson(jsonEncode(json["drawingData"] ?? []));
      List<PlacedAgent> agentData =
          AgentProvider.fromJson(jsonEncode(json["agentData"] ?? []));

      final List<PlacedAbility> abilityData =
          AbilityProvider.fromJson(jsonEncode(json["abilityData"] ?? []));

      final mapData = MapProvider.fromJson(jsonEncode(json["mapData"]));
      final textData =
          TextProvider.fromJson(jsonEncode(json["textData"] ?? []));

      List<PlacedImage> imageData = [];
      if (!kIsWeb) {
        if (isZip) {
          imageData = await PlacedImageProvider.fromJson(
              jsonString: jsonEncode(json["imageData"] ?? []),
              strategyID: newID);
        } else {
          log('Legacy image data loading');
          imageData = await PlacedImageProvider.legacyFromJson(
              jsonString: jsonEncode(json["imageData"] ?? []),
              strategyID: newID);
        }
      }

      final StrategySettings settingsData;
      final bool isAttack;
      final List<PlacedUtility> utilityData;

      if (json["settingsData"] != null) {
        settingsData = ref
            .read(strategySettingsProvider.notifier)
            .fromJson(jsonEncode(json["settingsData"]));
      } else {
        settingsData = StrategySettings();
      }

      if (json["isAttack"] != null) {
        isAttack = json["isAttack"] == "true" ? true : false;
      } else {
        isAttack = true;
      }

      if (json["utilityData"] != null) {
        utilityData = UtilityProvider.fromJson(jsonEncode(json["utilityData"]));
      } else {
        utilityData = [];
      }
      final MapThemePalette? importedThemeOverridePalette =
          json["themePalette"] is Map<String, dynamic>
              ? MapThemePalette.fromJson(json["themePalette"])
              : (json["themePalette"] is Map
                  ? MapThemePalette.fromJson(
                      Map<String, dynamic>.from(json["themePalette"]))
                  : null);

      // bool needsMigration = (versionNumber < 15);
      final List<StrategyPage> pages = json["pages"] != null
          ? await StrategyPage.listFromJson(
              json: jsonEncode(json["pages"]),
              strategyID: newID,
              isZip: isZip,
            )
          : [];

      StrategyData newStrategy = StrategyData(
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        drawingData: drawingData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        agentData: agentData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        abilityData: abilityData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        textData: textData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        imageData: imageData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        utilityData: utilityData,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        isAttack: isAttack,
        // ignore: deprecated_member_use_from_same_package, deprecated_member_use
        strategySettings: settingsData,

        pages: pages,
        id: newID,
        name: path.basenameWithoutExtension(xFile.name),
        mapData: mapData,
        versionNumber: versionNumber,
        lastEdited: DateTime.now(),

        folderID: null,
        themeOverridePalette: importedThemeOverridePalette,
      );

      newStrategy = await migrateLegacyData(newStrategy);

      await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
          .put(newStrategy.id, newStrategy);
    } finally {
      if (isZip) {
        try {
          await cleanUpTempDirectory(newID);
        } catch (_) {}
      }
    }
  }

  static bool isNewerVersionImportError(Object error) {
    return error is NewerVersionImportException;
  }

  @visibleForTesting
  static void throwIfImportedVersionIsTooNewForTest(int importedVersion) {
    _throwIfImportedVersionIsTooNew(importedVersion);
  }

  static void _throwIfImportedVersionIsTooNew(int importedVersion) {
    if (importedVersion <= Settings.versionNumber) {
      return;
    }

    throw NewerVersionImportException(
      importedVersion: importedVersion,
      currentVersion: Settings.versionNumber,
    );
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

  //Get all of the stratgies in the folder
  // Stop if there's nothing there
  // Call export and get the individual files
  // and then we put them all into one massive zip file

  Future<void> exportFolder(String folderID) async {
    final folder = Hive.box<Folder>(HiveBoxNames.foldersBox).get(folderID);
    if (folder == null) {
      log("Couldn't find folder to export");
      return;
    }

    final directoryToZip =
        await Directory.systemTemp.createTemp('strategy_export');

    try {
      await zipFolder(directoryToZip, folderID);

      final outputFile = await FilePicker.platform.saveFile(
        type: FileType.custom,
        dialogTitle: 'Please select an output file:',
        fileName: "${sanitizeFileName(folder.name)}.zip",
        allowedExtensions: ['zip'], // no leading dot
      );

      if (outputFile == null) return;

      final encoder = ZipFileEncoder();
      encoder.create(outputFile);
      await encoder.addDirectory(directoryToZip, includeDirName: false);
      await encoder.close();
    } finally {
      // Best-effort cleanup
      try {
        await directoryToZip.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> zipFolder(Directory directoryToZip, String folderID) async {
    final Folder? currentFolder =
        ref.read(folderProvider.notifier).findFolderByID(folderID);
    if (currentFolder == null) return;
    final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .values
        .where((strategy) => strategy.folderID == folderID)
        .toList();

    final subFolders =
        ref.read(folderProvider.notifier).findFolderChildren(folderID);
    final sanitizedName = sanitizeFileName(currentFolder.name);
    Directory folderExportDirectory =
        Directory(path.join(directoryToZip.path, sanitizedName));
    int counter = 1;
    while (await folderExportDirectory.exists()) {
      folderExportDirectory = Directory(
          path.join(directoryToZip.path, "${sanitizedName}_$counter"));
      counter++;
    }

    // Create the folder
    await folderExportDirectory.create(recursive: true);

    // Export each strategy
    for (final strategy in strategies) {
      await zipStrategy(id: strategy.id, saveDir: folderExportDirectory);
    }

    for (final subFolder in subFolders) {
      await zipFolder(folderExportDirectory, subFolder.id);
    }
  }

  static String sanitizeFileName(String input) {
    final sanitized = input.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return sanitized.isEmpty ? 'untitled' : sanitized;
  }

  MapThemePalette _resolveThemePaletteForExport(StrategyData strategy) {
    if (strategy.themeOverridePalette != null) {
      return strategy.themeOverridePalette!;
    }

    final profiles =
        Hive.box<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    final assignedProfile = strategy.themeProfileId == null
        ? null
        : profiles.get(strategy.themeProfileId!);
    if (assignedProfile != null) {
      return assignedProfile.palette;
    }

    return MapThemeProfilesProvider.immutableDefaultPalette;
  }

  Future<void> zipStrategy({
    required String id,
    Directory? saveDir, // used when outputFilePath is not provided
    String? outputFilePath, // exact .ica path from FilePicker
  }) async {
    final strategy = Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(id);
    if (strategy == null) {
      log("Couldn't find strategy to export");
      return;
    }

    final pages = strategy.pages.map((p) => p.toJson(strategy.id)).toList();
    final pageJson = jsonEncode(pages);
    final exportPalette = _resolveThemePaletteForExport(strategy);
    final paletteJson = jsonEncode(exportPalette.toJson());

    final data = '''
                  {
                  "versionNumber": "${Settings.versionNumber}",
                  "mapData": "${Maps.mapNames[strategy.mapData]}",
                  "themePalette": $paletteJson,
                  "pages": $pageJson
                  }
                ''';

    final sanitizedStrategyName = sanitizeFileName(strategy.name);

    // Resolve output path and base name
    late final String outPath;
    late final String archiveBase;
    if (outputFilePath != null) {
      outPath = outputFilePath;
      archiveBase = path.basenameWithoutExtension(outPath);
    } else {
      final base = sanitizedStrategyName;
      var candidate = base;
      var n = 1;
      while (File(path.join(saveDir!.path, "$candidate.ica")).existsSync()) {
        candidate = "${base}_$n";
        n++;
      }
      archiveBase = candidate;
      outPath = path.join(saveDir.path, "$archiveBase.ica");
    }

    final jsonArchiveFile =
        ArchiveFile.bytes("$archiveBase.json", utf8.encode(data));

    final zipEncoder = ZipFileEncoder()..create(outPath);

    final supportDirectory = await getApplicationSupportDirectory();
    final customDirectory =
        Directory(path.join(supportDirectory.path, strategy.id));
    final imagesDirectory =
        Directory(path.join(customDirectory.path, 'images'));
    await imagesDirectory.create(recursive: true);

    await for (final entity in imagesDirectory.list()) {
      if (entity is File) {
        await zipEncoder.addFile(entity);
      }
    }

    zipEncoder.addArchiveFile(jsonArchiveFile);
    await zipEncoder.close();
  }

  Future<void> exportFile(String id) async {
    await forceSaveNow(id);

    final outputFile = await FilePicker.platform.saveFile(
      type: FileType.custom,
      dialogTitle: 'Please select an output file:',
      fileName: "${sanitizeFileName(state.stratName ?? "new strategy")}.ica",
      allowedExtensions: [".ica"],
    );

    if (outputFile == null) return;
    await zipStrategy(id: id, outputFilePath: outputFile);
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

    state = state.copyWith(
      isSaved: true,
    );
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
      textData: ref.read(textProvider),
      imageData: ref.read(placedImageProvider).images,
      utilityData: ref.read(utilityProvider),
      isAttack: ref.read(mapProvider).isAttack,
      settings: ref.read(strategySettingsProvider),
      lineUps: ref.read(lineUpProvider).lineUps,
    );

    final newPages = [...strat.pages]..[idx] = updatedPage;
    final updated = strat.copyWith(pages: newPages, lastEdited: DateTime.now());
    await box.put(updated.id, updated);
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
