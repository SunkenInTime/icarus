import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/replay/replay_ability_audit.dart';
import 'package:icarus/replay/replay_track.dart';
import 'package:icarus/services/valorant_replay_import_service.dart';

final replayProvider = NotifierProvider<ReplayProvider, ReplayState>(
  ReplayProvider.new,
);

Future<ReplayTrack> loadReplayTrackFromFile(String filePath) {
  return Isolate.run(() {
    final content = File(filePath).readAsStringSync();
    return ReplayTrack.fromJsonString(content);
  });
}

class ReplayState {
  const ReplayState({
    this.track,
    this.currentTimeMs = 0,
    this.isPlaying = false,
    this.isImportingVrf = false,
    this.playbackSpeed = 1.0,
    this.reviewWindowStartMs = 0,
    this.showReviewTrails = true,
    this.visiblePlayerIds = const {},
    this.abilityAuditEnabled = false,
    this.abilityAuditEntries = const [],
    this.selectedAbilityAuditTarget,
    this.pendingAuditMapIssue,
    this.lastLoadedPath,
    this.importStatusMessage,
    this.errorMessage,
  });

  final ReplayTrack? track;
  final int currentTimeMs;
  final bool isPlaying;
  final bool isImportingVrf;
  final double playbackSpeed;
  final int reviewWindowStartMs;
  final bool showReviewTrails;
  final Set<String> visiblePlayerIds;
  final bool abilityAuditEnabled;
  final List<ReplayAbilityAuditEntry> abilityAuditEntries;
  final ReplayAbilityAuditTarget? selectedAbilityAuditTarget;
  final ReplayAbilityAuditIssue? pendingAuditMapIssue;
  final String? lastLoadedPath;
  final String? importStatusMessage;
  final String? errorMessage;

  static const int reviewWindowDurationMs = 60 * 1000;

  int get durationMs => track?.durationMs ?? 0;
  bool get hasTrack => track != null;
  int get reviewWindowEndMs => (reviewWindowStartMs + reviewWindowDurationMs)
      .clamp(0, durationMs)
      .toInt();

  ReplayState copyWith({
    ReplayTrack? track,
    int? currentTimeMs,
    bool? isPlaying,
    bool? isImportingVrf,
    double? playbackSpeed,
    int? reviewWindowStartMs,
    bool? showReviewTrails,
    Set<String>? visiblePlayerIds,
    bool? abilityAuditEnabled,
    List<ReplayAbilityAuditEntry>? abilityAuditEntries,
    ReplayAbilityAuditTarget? selectedAbilityAuditTarget,
    ReplayAbilityAuditIssue? pendingAuditMapIssue,
    String? lastLoadedPath,
    String? importStatusMessage,
    String? errorMessage,
    bool clearError = false,
    bool clearImportStatus = false,
    bool clearSelectedAbilityAuditTarget = false,
    bool clearPendingAuditMapIssue = false,
  }) {
    return ReplayState(
      track: track ?? this.track,
      currentTimeMs: currentTimeMs ?? this.currentTimeMs,
      isPlaying: isPlaying ?? this.isPlaying,
      isImportingVrf: isImportingVrf ?? this.isImportingVrf,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      reviewWindowStartMs: reviewWindowStartMs ?? this.reviewWindowStartMs,
      showReviewTrails: showReviewTrails ?? this.showReviewTrails,
      visiblePlayerIds: visiblePlayerIds ?? this.visiblePlayerIds,
      abilityAuditEnabled: abilityAuditEnabled ?? this.abilityAuditEnabled,
      abilityAuditEntries: abilityAuditEntries ?? this.abilityAuditEntries,
      selectedAbilityAuditTarget: clearSelectedAbilityAuditTarget
          ? null
          : selectedAbilityAuditTarget ?? this.selectedAbilityAuditTarget,
      pendingAuditMapIssue: clearPendingAuditMapIssue
          ? null
          : pendingAuditMapIssue ?? this.pendingAuditMapIssue,
      lastLoadedPath: lastLoadedPath ?? this.lastLoadedPath,
      importStatusMessage: clearImportStatus
          ? null
          : importStatusMessage ?? this.importStatusMessage,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class ReplayProvider extends Notifier<ReplayState> {
  @override
  ReplayState build() => const ReplayState();

  Future<void> loadDemoTrack() async {
    try {
      final json = await rootBundle.loadString(
        'assets/replays/ascent_demo_track.json',
      );
      setTrack(
        ReplayTrack.fromJsonString(json),
        sourcePath: 'assets/replays/ascent_demo_track.json',
      );
    } catch (error) {
      state = state.copyWith(
        isPlaying: false,
        errorMessage: 'Failed to load demo replay track: $error',
      );
    }
  }

  Future<void> loadFromFilePicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    try {
      final path = file.path;
      if (path == null) {
        throw const FormatException('Selected file has no readable path.');
      }
      final track = await loadReplayTrackFromFile(path);
      setTrack(track, sourcePath: file.path);
    } catch (error) {
      state = state.copyWith(
        isPlaying: false,
        errorMessage: 'Failed to load replay track JSON: $error',
      );
    }
  }

  Future<void> loadVrfFromFilePicker() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['vrf'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;

    final path = result.files.single.path;
    if (path == null) {
      state = state.copyWith(
        isPlaying: false,
        errorMessage: 'Selected replay has no readable path.',
        clearImportStatus: true,
      );
      return;
    }

    state = state.copyWith(
      isPlaying: false,
      isImportingVrf: true,
      importStatusMessage: 'Extracting replay movement...',
      clearError: true,
    );

    final importService = ValorantReplayImportService();
    ValorantReplayImportResult? importResult;
    try {
      importResult = await importService.extractNativeTrack(
        path,
        onProgress: (message) {
          if (!state.isImportingVrf) return;
          state = state.copyWith(importStatusMessage: message);
        },
      );
      state = state.copyWith(importStatusMessage: 'Loading decoded track...');
      state = state.copyWith(importStatusMessage: 'Preparing replay viewer...');
      final track = await loadReplayTrackFromFile(importResult.trackPath);
      await importService.markTrackAccepted(importResult);
      setTrack(
        track,
        sourcePath: path,
      );
    } catch (error) {
      if (importResult != null) {
        await importService.invalidateCachedTrack(importResult);
      }
      state = state.copyWith(
        isPlaying: false,
        isImportingVrf: false,
        errorMessage: 'Failed to import VRF replay: $error',
        clearImportStatus: true,
      );
    }
  }

  void setTrack(ReplayTrack track, {String? sourcePath}) {
    state = ReplayState(
      track: track,
      currentTimeMs: 0,
      isImportingVrf: false,
      reviewWindowStartMs: 0,
      showReviewTrails: true,
      visiblePlayerIds: track.players.map((player) => player.id).toSet(),
      lastLoadedPath: sourcePath ?? track.sourceLabel,
    );
  }

  void togglePlayback() {
    if (!state.hasTrack) return;
    state = state.copyWith(isPlaying: !state.isPlaying, clearError: true);
  }

  void pause() {
    if (!state.isPlaying) return;
    state = state.copyWith(isPlaying: false);
  }

  void seek(int timeMs) {
    final duration = state.durationMs;
    state = state.copyWith(
      currentTimeMs: timeMs.clamp(0, duration),
      isPlaying: duration == 0 ? false : state.isPlaying,
      clearError: true,
    );
  }

  void seekToPreviousAbilityEvent() {
    final track = state.track;
    if (track == null) return;
    final events = track.abilityCasts;
    if (events.isEmpty) return;

    final currentTimeMs = state.currentTimeMs;
    ReplayAbilityCast target = events.last;
    for (final event in events.reversed) {
      if (event.timeMs < currentTimeMs) {
        target = event;
        break;
      }
    }
    seek(target.timeMs);
    setReviewWindowStart(target.timeMs);
  }

  void seekToNextAbilityEvent() {
    final track = state.track;
    if (track == null) return;
    final events = track.abilityCasts;
    if (events.isEmpty) return;

    final currentTimeMs = state.currentTimeMs;
    ReplayAbilityCast target = events.first;
    for (final event in events) {
      if (event.timeMs > currentTimeMs) {
        target = event;
        break;
      }
    }
    seek(target.timeMs);
    setReviewWindowStart(target.timeMs);
  }

  void advanceBy(int deltaMs) {
    if (!state.isPlaying || !state.hasTrack) return;
    final next = state.currentTimeMs + (deltaMs * state.playbackSpeed).round();
    if (next >= state.durationMs) {
      state = state.copyWith(currentTimeMs: state.durationMs, isPlaying: false);
      return;
    }
    seek(next);
  }

  void setPlaybackSpeed(double speed) {
    state = state.copyWith(playbackSpeed: speed.clamp(0.25, 4.0));
  }

  void setReviewWindowStart(int startMs) {
    final maxStart = (state.durationMs - ReplayState.reviewWindowDurationMs)
        .clamp(0, state.durationMs)
        .toInt();
    state = state.copyWith(
      reviewWindowStartMs: startMs.clamp(0, maxStart).toInt(),
      clearError: true,
    );
  }

  void shiftReviewWindow(int deltaMs) {
    setReviewWindowStart(state.reviewWindowStartMs + deltaMs);
  }

  void setShowReviewTrails(bool value) {
    state = state.copyWith(showReviewTrails: value, clearError: true);
  }

  void togglePlayerVisibility(String playerId) {
    final visible = Set<String>.from(state.visiblePlayerIds);
    if (visible.contains(playerId)) {
      visible.remove(playerId);
    } else {
      visible.add(playerId);
    }
    state = state.copyWith(visiblePlayerIds: visible);
  }

  void setAbilityAuditEnabled(bool value) {
    state = state.copyWith(
      abilityAuditEnabled: value,
      isPlaying: value ? false : state.isPlaying,
      clearPendingAuditMapIssue: !value,
      clearSelectedAbilityAuditTarget: !value,
      clearError: true,
    );
  }

  void selectAbilityCast(String castId) {
    if (!state.abilityAuditEnabled) return;
    ReplayAbilityCast? selected;
    for (final cast
        in state.track?.abilityCasts ?? const <ReplayAbilityCast>[]) {
      if (cast.id == castId) {
        selected = cast;
        break;
      }
    }
    if (selected == null) return;
    state = state.copyWith(
      selectedAbilityAuditTarget: ReplayAbilityAuditTarget(
        type: ReplayAbilityAuditTargetType.abilityCast,
        id: selected.id,
        label: selected.label,
        evidence: _abilityCastAuditEvidence(selected),
      ),
      isPlaying: false,
      clearPendingAuditMapIssue: true,
    );
  }

  void selectUtilityActor(String actorId) {
    if (!state.abilityAuditEnabled) return;
    ReplayUtilityActor? selected;
    for (final actor
        in state.track?.utilityActors ?? const <ReplayUtilityActor>[]) {
      if (actor.stableId == actorId) {
        selected = actor;
        break;
      }
    }
    if (selected == null) return;
    state = state.copyWith(
      selectedAbilityAuditTarget: ReplayAbilityAuditTarget(
        type: ReplayAbilityAuditTargetType.utilityActor,
        id: selected.stableId,
        label: selected.label,
        evidence: _utilityActorAuditEvidence(
          selected,
          selectedAtTimeMs: state.currentTimeMs,
        ),
      ),
      isPlaying: false,
      clearPendingAuditMapIssue: true,
    );
  }

  void beginMapAudit(ReplayAbilityAuditIssue issue) {
    if (!state.abilityAuditEnabled || !issue.needsMapPoint) return;
    if (issue == ReplayAbilityAuditIssue.wrongPosition &&
        state.selectedAbilityAuditTarget == null) {
      state = state.copyWith(
        errorMessage: 'Select the misplaced ability on the map first.',
      );
      return;
    }
    state = state.copyWith(
      isPlaying: false,
      pendingAuditMapIssue: issue,
      clearError: true,
    );
  }

  void cancelPendingMapAudit() {
    state = state.copyWith(clearPendingAuditMapIssue: true);
  }

  void placePendingMapAudit(Offset icarusPosition) {
    final issue = state.pendingAuditMapIssue;
    if (issue == null) return;
    _addAbilityAuditEntry(issue, icarusPosition: icarusPosition);
  }

  void addAbilityAuditEntry(ReplayAbilityAuditIssue issue) {
    if (!state.abilityAuditEnabled || issue.needsMapPoint) return;
    if (issue != ReplayAbilityAuditIssue.missing &&
        state.selectedAbilityAuditTarget == null) {
      state = state.copyWith(
        errorMessage: 'Select an ability on the map before marking it.',
      );
      return;
    }
    _addAbilityAuditEntry(issue);
  }

  void addCustomAbilityAuditNote(String note) {
    final normalized = note.trim();
    if (!state.abilityAuditEnabled || normalized.isEmpty) return;
    _addAbilityAuditEntry(
      ReplayAbilityAuditIssue.customNote,
      note: normalized,
    );
  }

  void _addAbilityAuditEntry(
    ReplayAbilityAuditIssue issue, {
    Offset? icarusPosition,
    String? note,
  }) {
    final target = state.selectedAbilityAuditTarget;
    final entries = [...state.abilityAuditEntries];
    entries.add(
      ReplayAbilityAuditEntry(
        id: 'audit-${DateTime.now().microsecondsSinceEpoch}',
        issue: issue,
        timeMs: state.currentTimeMs,
        castId: target?.type == ReplayAbilityAuditTargetType.abilityCast
            ? target?.id
            : null,
        targetType: target?.type,
        targetId: target?.id,
        parsedLabel: target?.label,
        targetEvidence: target?.snapshotEvidence(),
        icarusPosition: icarusPosition,
        note: note,
      ),
    );
    state = state.copyWith(
      abilityAuditEntries: entries,
      clearPendingAuditMapIssue: true,
      clearError: true,
    );
  }

  void undoLastAbilityAuditEntry() {
    if (state.abilityAuditEntries.isEmpty) return;
    state = state.copyWith(
      abilityAuditEntries: state.abilityAuditEntries
          .take(state.abilityAuditEntries.length - 1)
          .toList(),
      clearError: true,
    );
  }

  Future<void> exportAbilityAudit() async {
    if (state.abilityAuditEntries.isEmpty) return;
    final suggestedName =
        '${state.track?.map.name ?? 'replay'}_ability_audit.json';
    final outputPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export ability audit',
      fileName: suggestedName,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (outputPath == null) return;

    final reportJson = _abilityAuditReportJson();
    try {
      await File(outputPath).writeAsString(reportJson);
      state = state.copyWith(
        importStatusMessage:
            'Exported ${state.abilityAuditEntries.length} audit notes to JSON.',
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(errorMessage: 'Failed to export audit: $error');
    }
  }

  Future<void> copyAbilityAuditJson() async {
    if (state.abilityAuditEntries.isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: _abilityAuditReportJson()));
      state = state.copyWith(
        importStatusMessage:
            'Audit JSON copied. Paste it directly into the Codex thread.',
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(errorMessage: 'Failed to copy audit JSON: $error');
    }
  }

  String _abilityAuditReportJson() {
    final report = {
      'schemaVersion': 1,
      'source': state.lastLoadedPath ?? state.track?.sourceLabel,
      'map': state.track?.map.name,
      'durationMs': state.durationMs,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'entries':
          state.abilityAuditEntries.map((entry) => entry.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(report);
  }
}

Map<String, dynamic> _abilityCastAuditEvidence(ReplayAbilityCast cast) {
  return Map<String, dynamic>.unmodifiable({
    'castId': cast.id,
    'timeMs': cast.timeMs,
    'replicationTimeMs': cast.replicationTimeMs,
    'playerNetGuid': cast.playerNetGuid,
    'playerSubject': cast.playerSubject,
    'agent': cast.agent,
    'icarusAgentType': cast.icarusAgentType,
    'abilityName': cast.abilityName,
    'abilitySlot': cast.abilitySlot,
    'abilityIndex': cast.abilityIndex,
    'slotEnum': cast.slotEnum,
    'slotEnumValue': cast.slotEnumValue,
    'castTimeSeconds': cast.castTimeSeconds,
    'roundIndex': cast.roundIndex,
    'roundPhaseValue': cast.roundPhaseValue,
    'roundPhase': cast.roundPhase,
    'timeSource': cast.timeSource,
    'phaseTimeCandidateMs': cast.phaseTimeCandidateMs,
    'timeAnchorUtilityActorId': cast.timeAnchorUtilityActorId,
    'abilityIdentitySource': cast.abilityIdentitySource,
    'sourceAbilityClass': cast.sourceAbilityClass,
    'sourceAbilityAssetPath': cast.sourceAbilityAssetPath,
    'castLocation': cast.castLocation == null
        ? null
        : _auditPositionJson(cast.castLocation!),
    'effectLocations':
        cast.effectLocations.map(_auditPositionJson).toList(growable: false),
    'placementLocations':
        cast.placementLocations.map(_auditPositionJson).toList(growable: false),
    'destroyedCount': cast.destroyedCount,
    'effects': cast.effects.map((effect) => effect.toJson()).toList(),
    'displayLifetimeMs': cast.displayLifetimeMs,
    'endTimeMs': cast.endTimeMs,
    'linkedUtilityActorIds':
        List<String>.unmodifiable(cast.linkedUtilityActorIds),
    'linkedUltimateEventIds':
        List<String>.unmodifiable(cast.linkedUltimateEventIds),
    'confidence': cast.confidence,
    'evidenceRoles': List<String>.unmodifiable(cast.evidenceRoles),
  });
}

Map<String, dynamic> _utilityActorAuditEvidence(
  ReplayUtilityActor actor, {
  required int selectedAtTimeMs,
}) {
  final selectedPosition = actor.positionAt(selectedAtTimeMs);
  return Map<String, dynamic>.unmodifiable({
    'stableId': actor.stableId,
    'actorNetGuid': actor.actorNetGuid,
    'chIndex': actor.chIndex,
    'className': actor.className,
    'archetypePath': actor.archetypePath,
    'openTimeMs': actor.timeMs,
    'closeTimeMs': actor.closedAtMs,
    'lifetimeMs': actor.lifetimeMs,
    'observedLifetimeMs': actor.observedLifetimeMs,
    'observedStartMs': actor.observedStartMs,
    'observedEndMs': actor.observedEndMs,
    'fallbackLifetimeMs': actor.fallbackLifetimeMs,
    'fallbackEndMs': actor.fallbackEndMs,
    'effectiveEndMs': actor.effectiveEndMs,
    'closeReason': actor.closeReason,
    'dormant': actor.dormant,
    'endReason': actor.endReason,
    'endReasonEvidence': actor.endReasonEvidence,
    'lifecycleEvidence': actor.lifecycleEvidence,
    'roundTeardownAtMs': actor.roundTeardownAtMs,
    'roundTeardownEventId': actor.roundTeardownEventId,
    'censoredAtMs': actor.censoredAtMs,
    'lifecyclePolicy': actor.lifecyclePolicy,
    'lifecyclePolicySource': actor.lifecyclePolicySource,
    'verifiedAbilityId': actor.verifiedAbilityId,
    'fallbackDurationSource': actor.fallbackDurationSource,
    'agent': actor.agent,
    'icarusAgentType': actor.icarusAgentType,
    'abilityName': actor.abilityName,
    'abilitySlot': actor.abilitySlot,
    'abilityIndex': actor.abilityIndex,
    'utilityKind': actor.utilityKind,
    'contentKind': actor.contentKind,
    'phase': actor.phase,
    'sourceAbilityClass': actor.sourceAbilityClass,
    'sourceAbilitySlot': actor.sourceAbilitySlot,
    'sourceAbilityName': actor.sourceAbilityName,
    'sourceAbilityAssetPath': actor.sourceAbilityAssetPath,
    'sourceContentKind': actor.sourceContentKind,
    'sourceCastId': actor.sourceCastId,
    'sourceCastLinkEvidence': actor.sourceCastLinkEvidence,
    'sourceCastLinkConfidence': actor.sourceCastLinkConfidence,
    'candidateSourceCastId': actor.candidateSourceCastId,
    'candidateSourceCastEvidence': actor.candidateSourceCastEvidence,
    'candidateSourceCastConfidence': actor.candidateSourceCastConfidence,
    'parentActorNetGuid': actor.parentActorNetGuid,
    'parentUtilityActorId': actor.parentUtilityActorId,
    'phaseGroupId': actor.phaseGroupId,
    'sequenceIndex': actor.sequenceIndex,
    'ownerPlayerNetGuid': actor.ownerPlayerNetGuid,
    'ownerSubject': actor.ownerSubject,
    'ownerSource': actor.ownerSource,
    'ownerConfidence': actor.ownerConfidence,
    'staticAssetPath': actor.staticAssetPath,
    'staticAssetKind': actor.staticAssetKind,
    'identitySource': actor.identitySource,
    'identityConfidence': actor.identityConfidence,
    'selectedAtTimeMs': selectedAtTimeMs,
    'position': _auditPositionJson(actor.position),
    'selectedPosition': _auditPositionJson(selectedPosition),
    'confidence': actor.confidence,
    'durationSource': actor.durationSource,
    'evidenceRoles': List<String>.unmodifiable(actor.evidenceRoles),
  });
}

Map<String, dynamic> _auditPositionJson(ReplayActorPosition position) =>
    Map<String, dynamic>.unmodifiable({
      'x': position.x,
      'y': position.y,
      if (position.z != null) 'z': position.z,
    });
