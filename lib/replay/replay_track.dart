import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/replay/valorant_map_transform.dart';

enum ReplayCoordinateSpace { game, icarus, percent }

const int _maxReplayUtilityActorDisplayLifetimeMs = 180000;
const int _maxReplayUtilitySampleInterpolationGapMs = 1200;

class ReplayTrack {
  const ReplayTrack({
    required this.map,
    required this.players,
    this.abilitySchemaVersion = 1,
    this.abilityCasts = const <ReplayAbilityCast>[],
    this.abilityActions = const <ReplayAbilityAction>[],
    this.utilityActors = const <ReplayUtilityActor>[],
    this.deathEvents = const <ReplayDeathEvent>[],
    this.roundStartEvents = const <ReplayRoundStartEvent>[],
    this.sideSwitchEvents = const <ReplaySideSwitchEvent>[],
    this.ultimateEvents = const <ReplayUltimateEvent>[],
    this.inputEvents = const <ReplayInputEvent>[],
    this.abilityStateEvents = const <ReplayAbilityStateEvent>[],
    this.abilityRpcEvents = const <ReplayAbilityRpcEvent>[],
    this.abilityCapabilities = const <String, bool>{},
    this.sourceLabel,
    this.coordinateSpace = ReplayCoordinateSpace.game,
    this.notes,
    this.recordedDurationMs,
  });

  final MapValue map;
  final List<ReplayPlayerTrack> players;
  final int abilitySchemaVersion;
  final List<ReplayAbilityCast> abilityCasts;
  final List<ReplayAbilityAction> abilityActions;
  final List<ReplayUtilityActor> utilityActors;
  final List<ReplayDeathEvent> deathEvents;
  final List<ReplayRoundStartEvent> roundStartEvents;
  final List<ReplaySideSwitchEvent> sideSwitchEvents;
  final List<ReplayUltimateEvent> ultimateEvents;
  final List<ReplayInputEvent> inputEvents;
  final List<ReplayAbilityStateEvent> abilityStateEvents;
  final List<ReplayAbilityRpcEvent> abilityRpcEvents;
  final Map<String, bool> abilityCapabilities;
  final String? sourceLabel;
  final ReplayCoordinateSpace coordinateSpace;
  final String? notes;
  final int? recordedDurationMs;

  int get durationMs {
    // Native tracks carry the exact replay timeline end. Utility lifetimes are
    // display heuristics and must not add an artificial tail after the match.
    final recordedDuration = recordedDurationMs;
    if (recordedDuration != null && recordedDuration >= 0) {
      return recordedDuration;
    }

    var duration = 0;
    for (final player in players) {
      if (player.samples.isNotEmpty) {
        duration = math.max(duration, player.samples.last.timeMs);
      }
    }
    for (final event in roundStartEvents) {
      duration = math.max(duration, event.timeMs);
    }
    for (final event in deathEvents) {
      duration = math.max(duration, event.timeMs);
    }
    for (final event in sideSwitchEvents) {
      duration = math.max(duration, event.timeMs);
    }
    for (final event in ultimateEvents) {
      duration = math.max(duration, event.timeMs);
    }
    for (final event in inputEvents) {
      duration = math.max(duration, event.timeMs);
    }
    for (final event in abilityStateEvents) {
      duration = math.max(duration, event.timeMs);
    }
    for (final event in abilityRpcEvents) {
      duration = math.max(duration, event.timeMs);
    }
    for (final cast in abilityCasts) {
      duration = math.max(duration, cast.endTimeMs ?? cast.timeMs);
    }
    for (final action in abilityActions) {
      duration = math.max(
        duration,
        action.endTimeMs ?? action.startTimeMs ?? 0,
      );
    }
    for (final actor in utilityActors) {
      duration = math.max(
        duration,
        actor.resolvedEffectiveEndMs ?? actor.timeMs,
      );
    }
    return duration;
  }

  List<ReplayPlayerFrame> framesAt(
    int timeMs, {
    Set<String>? visiblePlayerIds,
  }) {
    return [
      for (final player in players)
        if (visiblePlayerIds == null || visiblePlayerIds.contains(player.id))
          if (player.frameAt(timeMs) case final frame?) frame,
    ];
  }

  List<ReplayUtilityActor> utilityActorsAt(int timeMs) {
    return [
      for (final actor in utilityActors)
        if (actor.isActiveAt(timeMs)) actor,
    ];
  }

  List<ReplayUtilityActor> get abilityEvents {
    final events = [
      for (final actor in utilityActors)
        if (actor.isAbilityUseCandidate && actor.sourceCastId != null) actor,
    ]..sort((a, b) {
        final timeCompare = a.timeMs.compareTo(b.timeMs);
        if (timeCompare != 0) return timeCompare;
        return a.label.compareTo(b.label);
      });
    return events;
  }

  factory ReplayTrack.fromJsonString(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Replay track JSON must be an object.');
    }
    return ReplayTrack.fromJson(decoded);
  }

  factory ReplayTrack.fromJson(Map<String, dynamic> json) {
    final mapId = json['mapId'] as String? ?? json['mapName'] as String?;
    final map = ValorantMapTransforms.mapValueFromAnyId(mapId);
    if (map == null) {
      throw FormatException('Replay track uses an unsupported map: $mapId');
    }
    final playersJson = json['players'];
    if (playersJson is! List) {
      throw const FormatException('Replay track JSON requires players[].');
    }

    final abilityCasts = (json['abilityCasts'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ReplayAbilityCast.fromJson)
            .toList() ??
        <ReplayAbilityCast>[];
    final utilityActors = (json['utilityActors'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ReplayUtilityActor.fromJson)
            .toList() ??
        <ReplayUtilityActor>[];
    final abilityActions = (json['abilityActions'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ReplayAbilityAction.fromJson)
            .toList() ??
        <ReplayAbilityAction>[];
    final abilityStateEvents = (json['abilityStateEvents'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ReplayAbilityStateEvent.fromJson)
            .toList() ??
        <ReplayAbilityStateEvent>[];
    final abilityRpcEvents = (json['abilityRpcEvents'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ReplayAbilityRpcEvent.fromJson)
            .toList() ??
        <ReplayAbilityRpcEvent>[];
    abilityCasts.sort((a, b) {
      final timeCompare = a.timeMs.compareTo(b.timeMs);
      if (timeCompare != 0) return timeCompare;
      return a.id.compareTo(b.id);
    });
    utilityActors.sort((a, b) {
      final timeCompare = a.timeMs.compareTo(b.timeMs);
      if (timeCompare != 0) return timeCompare;
      return a.stableId.compareTo(b.stableId);
    });
    abilityActions.sort((a, b) {
      final timeCompare = (a.startTimeMs ?? 0).compareTo(b.startTimeMs ?? 0);
      if (timeCompare != 0) return timeCompare;
      return a.id.compareTo(b.id);
    });
    abilityStateEvents.sort((a, b) {
      final timeCompare = a.timeMs.compareTo(b.timeMs);
      if (timeCompare != 0) return timeCompare;
      return a.id.compareTo(b.id);
    });
    abilityRpcEvents.sort((a, b) {
      final timeCompare = a.timeMs.compareTo(b.timeMs);
      if (timeCompare != 0) return timeCompare;
      return a.id.compareTo(b.id);
    });

    final decoderJson = json['decoder'];
    final capabilityJson = decoderJson is Map<String, dynamic>
        ? decoderJson['abilityCapabilities']
        : null;

    return ReplayTrack(
      map: map,
      abilitySchemaVersion:
          _nullableIntFromJson(json['abilitySchemaVersion']) ?? 1,
      sourceLabel: json['sourceLabel'] as String?,
      notes: json['notes'] as String?,
      recordedDurationMs: _nullableIntFromJson(
        json['durationMs'] ?? json['recordedDurationMs'],
      ),
      coordinateSpace: _coordinateSpaceFromString(
        json['coordinateSpace'] as String?,
      ),
      abilityCasts: abilityCasts,
      abilityActions: abilityActions,
      utilityActors: utilityActors,
      deathEvents: (json['deathEvents'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayDeathEvent.fromJson)
              .toList() ??
          const <ReplayDeathEvent>[],
      roundStartEvents: (json['roundStartEvents'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayRoundStartEvent.fromJson)
              .toList() ??
          const <ReplayRoundStartEvent>[],
      sideSwitchEvents: (json['sideSwitchEvents'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplaySideSwitchEvent.fromJson)
              .toList() ??
          const <ReplaySideSwitchEvent>[],
      ultimateEvents: (json['ultimateEvents'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayUltimateEvent.fromJson)
              .toList() ??
          const <ReplayUltimateEvent>[],
      inputEvents: (json['inputEvents'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayInputEvent.fromJson)
              .toList() ??
          const <ReplayInputEvent>[],
      abilityStateEvents: abilityStateEvents,
      abilityRpcEvents: abilityRpcEvents,
      abilityCapabilities: capabilityJson is Map<String, dynamic>
          ? capabilityJson.map(
              (key, value) => MapEntry(key, value == true),
            )
          : const <String, bool>{},
      players: playersJson
          .whereType<Map<String, dynamic>>()
          .map(ReplayPlayerTrack.fromJson)
          .where((player) => player.samples.isNotEmpty)
          .toList(),
    );
  }

  List<ReplayAbilityCast> abilityCastsAt(int timeMs) {
    return [
      for (final cast in abilityCasts)
        if (cast.isActiveAt(timeMs)) cast,
    ];
  }

  ReplayPlayerTrack? playerByNetGuid(int? netGuid) {
    if (netGuid == null) return null;
    final id = 'netguid-$netGuid';
    final displaySuffix = 'g$netGuid';
    for (final player in players) {
      if (player.playerNetGuid == netGuid ||
          player.id == id ||
          player.displayName.endsWith(displaySuffix)) {
        return player;
      }
    }
    return null;
  }

  ReplayPlayerTrack? playerBySubject(String? subject) {
    if (subject == null || subject.isEmpty) return null;
    for (final player in players) {
      if (player.subject == subject) return player;
    }
    return null;
  }

  ReplayAbilityCast? abilityCastById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final cast in abilityCasts) {
      if (cast.id == id) return cast;
    }
    return null;
  }
}

class ReplayPlayerTrack {
  ReplayPlayerTrack({
    required this.id,
    required this.displayName,
    required this.samples,
    this.agent,
    this.kind,
    this.sourceTag,
    this.confidence,
    this.notes,
    this.state,
    this.initialSide,
    this.loadoutIndex,
    this.subject,
    this.playerNetGuid,
    List<ReplayPlayerStateSample>? stateSamples,
    List<ReplayPlayerStateInterval>? stateIntervals,
    List<ReplayDeathEvent>? deathEvents,
    List<ReplayRoundStartEvent>? respawnEvents,
    List<ReplayLifeSegment>? lifeSegments,
    Color? teamColor,
  })  : stateSamples =
            List<ReplayPlayerStateSample>.of(stateSamples ?? const []),
        stateIntervals =
            List<ReplayPlayerStateInterval>.of(stateIntervals ?? const []),
        deathEvents = List<ReplayDeathEvent>.of(deathEvents ?? const []),
        respawnEvents =
            List<ReplayRoundStartEvent>.of(respawnEvents ?? const []),
        lifeSegments = List<ReplayLifeSegment>.of(lifeSegments ?? const []),
        teamColor = teamColor ?? const Color(0xFF7C3AED) {
    samples.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    this.stateSamples.sort((a, b) => a.timeMs.compareTo(b.timeMs));
  }

  final String id;
  final String displayName;
  final String? agent;
  final String? kind;
  final String? sourceTag;
  final String? confidence;
  final String? notes;
  final AgentState? state;
  final String? initialSide;
  final int? loadoutIndex;
  final String? subject;
  final int? playerNetGuid;
  final List<ReplayPlayerStateSample> stateSamples;
  final List<ReplayPlayerStateInterval> stateIntervals;
  final List<ReplayDeathEvent> deathEvents;
  final List<ReplayRoundStartEvent> respawnEvents;
  final List<ReplayLifeSegment> lifeSegments;
  final Color teamColor;
  final List<ReplaySample> samples;

  static const int maxInterpolationGapMs = 250;

  int get firstTimeMs => samples.isEmpty ? 0 : samples.first.timeMs;
  int get lastTimeMs => samples.isEmpty ? 0 : samples.last.timeMs;

  List<ReplaySample> samplesBetween(int startMs, int endMs) {
    return [
      for (final sample in samples)
        if (sample.timeMs >= startMs && sample.timeMs <= endMs) sample,
    ];
  }

  ReplayPlayerFrame? frameAt(int timeMs) {
    if (samples.isEmpty) return null;
    if (timeMs <= samples.first.timeMs) {
      return ReplayPlayerFrame(player: this, sample: samples.first);
    }
    if (timeMs >= samples.last.timeMs) {
      return ReplayPlayerFrame(player: this, sample: samples.last);
    }

    var low = 0;
    var high = samples.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final sample = samples[mid];
      if (sample.timeMs == timeMs) {
        return ReplayPlayerFrame(player: this, sample: sample);
      }
      if (sample.timeMs < timeMs) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    final before = samples[high];
    final after = samples[low];
    final span = after.timeMs - before.timeMs;
    if (span > maxInterpolationGapMs) {
      return ReplayPlayerFrame(player: this, sample: before);
    }
    final t = span == 0 ? 0.0 : (timeMs - before.timeMs) / span;
    return ReplayPlayerFrame(
      player: this,
      sample: ReplaySample.lerp(before, after, t),
    );
  }

  AgentState stateAt(ReplaySample sample) {
    final stateSample = stateSampleAt(sample.timeMs);
    if (stateSample != null) return stateSample.state;

    final sampleState = sample.state;
    if (sampleState != null) return sampleState;

    for (final interval in stateIntervals) {
      if (interval.contains(sample.timeMs)) return interval.state;
    }

    return state ?? AgentState.none;
  }

  ReplayPlayerStateSample? stateSampleAt(int timeMs) {
    if (stateSamples.isEmpty) return null;
    var low = 0;
    var high = stateSamples.length - 1;
    ReplayPlayerStateSample? latest;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final sample = stateSamples[mid];
      if (sample.timeMs <= timeMs) {
        latest = sample;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return latest;
  }

  factory ReplayPlayerTrack.fromJson(Map<String, dynamic> json) {
    final samplesJson = json['samples'];
    if (samplesJson is! List) {
      throw const FormatException('Replay player requires samples[].');
    }
    final id = (json['id'] as String?)?.trim();
    final displayName = (json['displayName'] as String?)?.trim();
    return ReplayPlayerTrack(
      id: id == null || id.isEmpty ? displayName ?? 'player' : id,
      displayName: displayName == null || displayName.isEmpty
          ? id ?? 'Player'
          : displayName,
      agent: json['agent'] as String?,
      kind: json['kind'] as String?,
      sourceTag: json['sourceTag'] as String?,
      confidence: json['confidence'] as String?,
      notes: json['notes'] as String?,
      state: _agentStateFromJson(json['state'] ?? json['agentState'] ?? json),
      initialSide: _replaySideFromJson(
        json['initialSide'] ?? json['side'] ?? json['teamSide'],
      ),
      loadoutIndex: _nullableIntFromJson(
        json['loadoutIndex'] ?? json['headerLoadoutIndex'],
      ),
      subject: json['subject'] as String?,
      playerNetGuid: _nullableIntFromJson(
        json['playerNetGuid'] ??
            (json['diagnostic'] is Map<String, dynamic>
                ? (json['diagnostic'] as Map<String, dynamic>)['netGuid']
                : null),
      ),
      stateSamples: _stateSamplesFromJson(json),
      stateIntervals: _stateIntervalsFromJson(json),
      deathEvents: (json['deathEvents'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayDeathEvent.fromJson)
              .toList() ??
          const <ReplayDeathEvent>[],
      respawnEvents: (json['respawnEvents'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayRoundStartEvent.fromJson)
              .toList() ??
          const <ReplayRoundStartEvent>[],
      lifeSegments: (json['lifeSegments'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayLifeSegment.fromJson)
              .toList() ??
          const <ReplayLifeSegment>[],
      teamColor: _colorFromJson(json['teamColor']),
      samples: samplesJson
          .whereType<Map<String, dynamic>>()
          .map(ReplaySample.fromJson)
          .toList(),
    );
  }
}

class ReplayPlayerStateSample {
  const ReplayPlayerStateSample({
    required this.timeMs,
    required this.state,
    this.confidence,
    this.source,
  });

  final int timeMs;
  final AgentState state;
  final String? confidence;
  final String? source;

  bool get isProvenDead =>
      state == AgentState.dead && confidence == 'proven-event-payload';

  factory ReplayPlayerStateSample.fromJson(Map<String, dynamic> json) {
    return ReplayPlayerStateSample(
      timeMs: _intFromJson(json['timeMs']),
      state: _agentStateFromJson(json['state'] ?? json['agentState'] ?? json) ??
          AgentState.none,
      confidence: json['confidence'] as String?,
      source: json['source'] as String?,
    );
  }
}

class ReplayPlayerStateInterval {
  const ReplayPlayerStateInterval({
    required this.startTimeMs,
    required this.endTimeMs,
    required this.state,
  });

  final int startTimeMs;
  final int endTimeMs;
  final AgentState state;

  bool contains(int timeMs) => timeMs >= startTimeMs && timeMs <= endTimeMs;

  factory ReplayPlayerStateInterval.fromJson(Map<String, dynamic> json) {
    return ReplayPlayerStateInterval(
      startTimeMs: _intFromJson(json['startTimeMs'] ?? json['startMs'] ?? 0),
      endTimeMs: _nullableIntFromJson(json['endTimeMs'] ?? json['endMs']) ??
          0x7FFFFFFFFFFFFFFF,
      state: _agentStateFromJson(json['state'] ?? json['agentState'] ?? json) ??
          AgentState.none,
    );
  }

  factory ReplayPlayerStateInterval.deadFromJson(Map<String, dynamic> json) {
    return ReplayPlayerStateInterval(
      startTimeMs: _intFromJson(json['startTimeMs'] ?? json['startMs'] ?? 0),
      endTimeMs: _nullableIntFromJson(json['endTimeMs'] ?? json['endMs']) ??
          0x7FFFFFFFFFFFFFFF,
      state: AgentState.dead,
    );
  }
}

class ReplayLifeSegment {
  const ReplayLifeSegment({
    required this.startTimeMs,
    required this.endTimeMs,
    required this.state,
    this.confidence,
    this.source,
    this.additionalDeathEventCount,
  });

  final int startTimeMs;
  final int endTimeMs;
  final AgentState state;
  final String? confidence;
  final String? source;
  final int? additionalDeathEventCount;

  factory ReplayLifeSegment.fromJson(Map<String, dynamic> json) {
    return ReplayLifeSegment(
      startTimeMs: _intFromJson(json['startTimeMs'] ?? json['startMs'] ?? 0),
      endTimeMs: _nullableIntFromJson(json['endTimeMs'] ?? json['endMs']) ??
          0x7FFFFFFFFFFFFFFF,
      state: _agentStateFromJson(json['state'] ?? json['agentState'] ?? json) ??
          AgentState.none,
      confidence: json['confidence'] as String?,
      source: json['source'] as String?,
      additionalDeathEventCount: _nullableIntFromJson(
        json['additionalDeathEventCount'],
      ),
    );
  }
}

class ReplayAbilityAction {
  const ReplayAbilityAction({
    required this.id,
    required this.phases,
    this.canonicalAbilityId,
    this.agent,
    this.abilitySlot,
    this.abilityIndex,
    this.abilityName,
    this.sourceAbilityAssetPath,
    this.identitySource,
    this.ownerPlayerNetGuid,
    this.ownerSubject,
    this.ownerSource,
    this.sourceCastId,
    this.sourceUtilityActorIds = const <String>[],
    this.sourceUltimateEventIds = const <String>[],
    this.sourceInputEventIds = const <String>[],
    this.sourceStateEventIds = const <String>[],
    this.sourceRpcEventIds = const <String>[],
    this.lifecycleChain,
    this.outcome,
    this.startTimeMs,
    this.endTimeMs,
    this.terminationStatus,
    this.rightCensored = false,
    this.orphanedFromCastLane = false,
  });

  final String id;
  final String? canonicalAbilityId;
  final String? agent;
  final String? abilitySlot;
  final int? abilityIndex;
  final String? abilityName;
  final String? sourceAbilityAssetPath;
  final String? identitySource;
  final int? ownerPlayerNetGuid;
  final String? ownerSubject;
  final String? ownerSource;
  final String? sourceCastId;
  final List<String> sourceUtilityActorIds;
  final List<String> sourceUltimateEventIds;
  final List<String> sourceInputEventIds;
  final List<String> sourceStateEventIds;
  final List<String> sourceRpcEventIds;
  final List<ReplayAbilityLifecycleLink>? lifecycleChain;
  final AbilityOutcome? outcome;
  final List<ReplayAbilityPhase> phases;
  final int? startTimeMs;
  final int? endTimeMs;
  final String? terminationStatus;
  final bool rightCensored;
  final bool orphanedFromCastLane;

  bool get hasObservedTerminalPhase => phases.any(
        (phase) => phase.terminal && phase.evidence == 'observed',
      );

  factory ReplayAbilityAction.fromJson(Map<String, dynamic> json) {
    final phases = (json['phases'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ReplayAbilityPhase.fromJson)
            .toList() ??
        <ReplayAbilityPhase>[];
    phases.sort((a, b) {
      final timeCompare = a.timeMs.compareTo(b.timeMs);
      if (timeCompare != 0) return timeCompare;
      return a.id.compareTo(b.id);
    });
    final id = (json['id'] as String?)?.trim();
    return ReplayAbilityAction(
      id: id == null || id.isEmpty
          ? 'action-${phases.firstOrNull?.timeMs ?? 0}'
          : id,
      canonicalAbilityId: json['canonicalAbilityId'] as String?,
      agent: json['agent'] as String?,
      abilitySlot: json['abilitySlot'] as String?,
      abilityIndex: _nullableIntFromJson(json['abilityIndex']),
      abilityName: json['abilityName'] as String?,
      sourceAbilityAssetPath: json['sourceAbilityAssetPath'] as String?,
      identitySource: json['identitySource'] as String?,
      ownerPlayerNetGuid: _nullableIntFromJson(json['ownerPlayerNetGuid']),
      ownerSubject: json['ownerSubject'] as String?,
      ownerSource: json['ownerSource'] as String?,
      sourceCastId: json['sourceCastId'] as String?,
      sourceUtilityActorIds: (json['sourceUtilityActorIds'] as List?)
              ?.whereType<String>()
              .toList() ??
          const <String>[],
      sourceUltimateEventIds: (json['sourceUltimateEventIds'] as List?)
              ?.whereType<String>()
              .toList() ??
          const <String>[],
      sourceInputEventIds: (json['sourceInputEventIds'] as List?)
              ?.whereType<String>()
              .toList() ??
          const <String>[],
      sourceStateEventIds: (json['sourceStateEventIds'] as List?)
              ?.whereType<String>()
              .toList() ??
          const <String>[],
      sourceRpcEventIds:
          (json['sourceRpcEventIds'] as List?)?.whereType<String>().toList() ??
              const <String>[],
      lifecycleChain: (json['lifecycleChain'] as List?)
          ?.whereType<Map<String, dynamic>>()
          .map(ReplayAbilityLifecycleLink.fromJson)
          .toList(),
      outcome: json['outcome'] is Map<String, dynamic>
          ? AbilityOutcome.fromJson(json['outcome'])
          : null,
      phases: phases,
      startTimeMs: _nullableIntFromJson(json['startTimeMs']),
      endTimeMs: _nullableIntFromJson(json['endTimeMs']),
      terminationStatus: json['terminationStatus'] as String?,
      rightCensored: json['rightCensored'] == true,
      orphanedFromCastLane: json['orphanedFromCastLane'] == true,
    );
  }
}

class AbilityOutcome {
  const AbilityOutcome({
    required this.type,
    required this.confidence,
    required this.evidence,
    this.ruleId,
    this.signatureIds = const <String>[],
  });

  final String type;
  final String confidence;
  final String evidence;
  final String? ruleId;
  final List<String> signatureIds;

  factory AbilityOutcome.fromJson(Map<String, dynamic> json) {
    return AbilityOutcome(
      type: json['type'] as String? ?? 'unknown',
      confidence: json['confidence'] as String? ?? 'low',
      evidence: json['evidence'] as String? ?? 'derived',
      ruleId: json['ruleId'] as String?,
      signatureIds:
          (json['signatureIds'] as List?)?.whereType<String>().toList() ??
              const <String>[],
    );
  }
}

class ReplayAbilityLifecycleLink {
  const ReplayAbilityLifecycleLink({
    required this.utilityActorId,
    this.className,
    this.phaseType,
    this.startMs,
    this.endMs,
    this.handoffGapMs,
  });

  final String utilityActorId;
  final String? className;
  final String? phaseType;
  final int? startMs;
  final int? endMs;
  final int? handoffGapMs;

  factory ReplayAbilityLifecycleLink.fromJson(Map<String, dynamic> json) {
    return ReplayAbilityLifecycleLink(
      utilityActorId: json['utilityActorId'] as String? ?? '',
      className: json['className'] as String?,
      phaseType: json['phaseType'] as String?,
      startMs: _nullableIntFromJson(json['startMs']),
      endMs: _nullableIntFromJson(json['endMs']),
      handoffGapMs: _nullableIntFromJson(json['handoffGapMs']),
    );
  }
}

class ReplayAbilityPhase {
  const ReplayAbilityPhase({
    required this.id,
    required this.type,
    required this.timeMs,
    required this.evidence,
    this.evidenceSource,
    this.semanticEvidence,
    this.timeSource,
    this.roundIndex,
    this.position,
    this.velocity,
    this.yawDegrees,
    this.actorNetGuid,
    this.stateNetGuid,
    this.statePath,
    this.stateName,
    this.stateStartWorldTimeSeconds,
    this.rpcName,
    this.payloadBitCount,
    this.sourceEventId,
    this.ruleId,
    this.signatureIds = const <String>[],
    this.parentUtilityActorId,
    this.sequenceIndex,
    this.actionAssemblyEvidence,
    this.actionAssemblyConfidence,
    this.effectLocations = const <ReplayActorPosition>[],
    this.placementLocations = const <ReplayActorPosition>[],
    this.destroyedCount,
    this.effects = const <ReplayAbilityEffect>[],
    this.closeReason,
    this.dormant,
    this.terminal = false,
  });

  final String id;
  final String type;
  final int timeMs;
  final String evidence;
  final String? evidenceSource;
  final String? semanticEvidence;
  final String? timeSource;
  final int? roundIndex;
  final ReplayActorPosition? position;
  final ReplayActorPosition? velocity;
  final double? yawDegrees;
  final int? actorNetGuid;
  final int? stateNetGuid;
  final String? statePath;
  final String? stateName;
  final double? stateStartWorldTimeSeconds;
  final String? rpcName;
  final int? payloadBitCount;
  final String? sourceEventId;
  final String? ruleId;
  final List<String> signatureIds;
  final String? parentUtilityActorId;
  final int? sequenceIndex;
  final String? actionAssemblyEvidence;
  final String? actionAssemblyConfidence;
  final List<ReplayActorPosition> effectLocations;
  final List<ReplayActorPosition> placementLocations;
  final int? destroyedCount;
  final List<ReplayAbilityEffect> effects;
  final int? closeReason;
  final bool? dormant;
  final bool terminal;

  factory ReplayAbilityPhase.fromJson(Map<String, dynamic> json) {
    final timeMs = _intFromJson(json['timeMs']);
    final id = (json['id'] as String?)?.trim();
    return ReplayAbilityPhase(
      id: id == null || id.isEmpty ? 'phase-$timeMs' : id,
      type: json['type'] as String? ?? 'unknown',
      timeMs: timeMs,
      evidence: json['evidence'] as String? ?? 'absent',
      evidenceSource: json['evidenceSource'] as String?,
      semanticEvidence: json['semanticEvidence'] as String?,
      timeSource: json['timeSource'] as String?,
      roundIndex: _nullableIntFromJson(json['roundIndex']),
      position: json['position'] is Map<String, dynamic>
          ? ReplayActorPosition.fromJson(json['position'])
          : null,
      velocity: json['velocity'] is Map<String, dynamic>
          ? ReplayActorPosition.fromJson(json['velocity'])
          : null,
      yawDegrees: _nullableDoubleFromJson(json['yawDegrees']),
      actorNetGuid: _nullableIntFromJson(json['actorNetGuid']),
      stateNetGuid: _nullableIntFromJson(json['stateNetGuid']),
      statePath: json['statePath'] as String?,
      stateName: json['stateName'] as String?,
      stateStartWorldTimeSeconds:
          _nullableDoubleFromJson(json['stateStartWorldTimeSeconds']),
      rpcName: json['rpcName'] as String?,
      payloadBitCount: _nullableIntFromJson(json['payloadBitCount']),
      sourceEventId: json['sourceEventId'] as String?,
      ruleId: json['ruleId'] as String?,
      signatureIds:
          (json['signatureIds'] as List?)?.whereType<String>().toList() ??
              const <String>[],
      parentUtilityActorId: json['parentUtilityActorId'] as String?,
      sequenceIndex: _nullableIntFromJson(json['sequenceIndex']),
      actionAssemblyEvidence: json['actionAssemblyEvidence'] as String?,
      actionAssemblyConfidence: json['actionAssemblyConfidence'] as String?,
      effectLocations: _positionListFromJson(json['effectLocations']),
      placementLocations: _positionListFromJson(json['placementLocations']),
      destroyedCount: _nullableIntFromJson(json['destroyedCount']),
      effects: (json['effects'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayAbilityEffect.fromJson)
              .toList() ??
          const <ReplayAbilityEffect>[],
      closeReason: _nullableIntFromJson(json['closeReason']),
      dormant: json['dormant'] is bool ? json['dormant'] as bool : null,
      terminal: json['terminal'] == true,
    );
  }
}

class ReplayAbilityEffect {
  const ReplayAbilityEffect({
    this.statisticIndex,
    this.statistic,
    this.localizedStatKey,
    this.localizedStatTable,
    this.value,
    this.timeSeconds,
    this.affectedTargets = const <ReplayAbilityAffectedTarget>[],
    this.sourceStruct,
    this.evidence,
  });

  final int? statisticIndex;
  final String? statistic;
  final String? localizedStatKey;
  final String? localizedStatTable;
  final double? value;
  final double? timeSeconds;
  final List<ReplayAbilityAffectedTarget> affectedTargets;
  final String? sourceStruct;
  final String? evidence;

  factory ReplayAbilityEffect.fromJson(Map<String, dynamic> json) {
    return ReplayAbilityEffect(
      statisticIndex: _nullableIntFromJson(json['statisticIndex']),
      statistic: json['statistic'] as String?,
      localizedStatKey: json['localizedStatKey'] as String?,
      localizedStatTable: json['localizedStatTable'] as String?,
      value: _nullableDoubleFromJson(json['value']),
      timeSeconds: _nullableDoubleFromJson(json['timeSeconds']),
      affectedTargets: (json['affectedTargets'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayAbilityAffectedTarget.fromJson)
              .toList() ??
          const <ReplayAbilityAffectedTarget>[],
      sourceStruct: json['sourceStruct'] as String?,
      evidence: json['evidence'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'statisticIndex': statisticIndex,
        'statistic': statistic,
        'localizedStatKey': localizedStatKey,
        'localizedStatTable': localizedStatTable,
        'value': value,
        'timeSeconds': timeSeconds,
        'affectedTargets':
            affectedTargets.map((target) => target.toJson()).toList(),
        'sourceStruct': sourceStruct,
        'evidence': evidence,
      };
}

class ReplayAbilityAffectedTarget {
  const ReplayAbilityAffectedTarget({
    this.affectedPlayerNetGuid,
    this.value,
  });

  final int? affectedPlayerNetGuid;
  final double? value;

  factory ReplayAbilityAffectedTarget.fromJson(Map<String, dynamic> json) {
    return ReplayAbilityAffectedTarget(
      affectedPlayerNetGuid:
          _nullableIntFromJson(json['affectedPlayerNetGuid']),
      value: _nullableDoubleFromJson(json['value']),
    );
  }

  Map<String, dynamic> toJson() => {
        'affectedPlayerNetGuid': affectedPlayerNetGuid,
        'value': value,
      };
}

class ReplayAbilityCast {
  const ReplayAbilityCast({
    required this.id,
    required this.timeMs,
    this.replicationTimeMs,
    this.playerNetGuid,
    this.playerSubject,
    this.agent,
    this.icarusAgentType,
    this.abilitySlot,
    this.abilityIndex,
    this.abilityName,
    this.slotEnum,
    this.slotEnumValue,
    this.castTimeSeconds,
    this.roundIndex,
    this.roundPhaseValue,
    this.roundPhase,
    this.timeSource,
    this.phaseTimeCandidateMs,
    this.timeAnchorUtilityActorId,
    this.abilityIdentitySource,
    this.sourceAbilityClass,
    this.sourceAbilityAssetPath,
    this.castLocation,
    this.effectLocations = const <ReplayActorPosition>[],
    this.placementLocations = const <ReplayActorPosition>[],
    this.destroyedCount,
    this.displayLifetimeMs,
    this.endTimeMs,
    this.effects = const <ReplayAbilityEffect>[],
    this.linkedUtilityActorIds = const <String>[],
    this.linkedUltimateEventIds = const <String>[],
    this.confidence,
    this.evidenceRoles = const <String>[],
  });

  final String id;
  final int timeMs;
  final int? replicationTimeMs;
  final int? playerNetGuid;
  final String? playerSubject;
  final String? agent;
  final String? icarusAgentType;
  final String? abilitySlot;
  final int? abilityIndex;
  final String? abilityName;
  final String? slotEnum;
  final int? slotEnumValue;
  final double? castTimeSeconds;
  final int? roundIndex;
  final int? roundPhaseValue;
  final String? roundPhase;
  final String? timeSource;
  final int? phaseTimeCandidateMs;
  final String? timeAnchorUtilityActorId;
  final String? abilityIdentitySource;
  final String? sourceAbilityClass;
  final String? sourceAbilityAssetPath;
  final ReplayActorPosition? castLocation;
  final List<ReplayActorPosition> effectLocations;
  final List<ReplayActorPosition> placementLocations;
  final int? destroyedCount;
  final int? displayLifetimeMs;
  final int? endTimeMs;
  final List<ReplayAbilityEffect> effects;
  final List<String> linkedUtilityActorIds;
  final List<String> linkedUltimateEventIds;
  final String? confidence;
  final List<String> evidenceRoles;

  String get label {
    final pieces = <String>[
      if (_hasText(agent)) agent!.trim(),
      if (_hasText(abilityName)) abilityName!.trim(),
      if (!_hasText(abilityName) && _hasText(abilitySlot)) abilitySlot!.trim(),
    ];
    if (pieces.isNotEmpty) return pieces.join(' ');
    if (_hasText(sourceAbilityClass)) {
      return sourceAbilityClass!.split('/').last;
    }
    return 'Ability cast';
  }

  List<ReplayActorPosition> get displayLocations {
    return placementLocations;
  }

  bool isActiveAt(int replayTimeMs) {
    if (displayLocations.isEmpty) return false;
    if (replayTimeMs < timeMs) return false;

    final explicitEndTimeMs = endTimeMs;
    if (explicitEndTimeMs != null) return replayTimeMs <= explicitEndTimeMs;

    final lifetimeMs = displayLifetimeMs;
    // A placement coordinate proves where a cast targeted, not how long its
    // visual effect remained active. Without an explicit replay-backed end or
    // duration, keep the cast as a timeline/navigation row only.
    if (lifetimeMs == null) return false;
    if (lifetimeMs <= 0) return false;
    return replayTimeMs <= timeMs + lifetimeMs;
  }

  factory ReplayAbilityCast.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    return ReplayAbilityCast(
      id: id == null || id.isEmpty
          ? 'cast-${_intFromJson(json['timeMs'])}'
          : id,
      timeMs: _intFromJson(json['timeMs']),
      replicationTimeMs: _nullableIntFromJson(json['replicationTimeMs']),
      playerNetGuid: _nullableIntFromJson(json['playerNetGuid']),
      playerSubject: json['playerSubject'] as String?,
      agent: json['agent'] as String?,
      icarusAgentType: json['icarusAgentType'] as String?,
      abilitySlot: json['abilitySlot'] as String?,
      abilityIndex: _nullableIntFromJson(json['abilityIndex']),
      abilityName: json['abilityName'] as String?,
      slotEnum: json['slotEnum'] as String?,
      slotEnumValue: _nullableIntFromJson(json['slotEnumValue']),
      castTimeSeconds: _nullableDoubleFromJson(json['castTimeSeconds']),
      roundIndex: _nullableIntFromJson(json['roundIndex']),
      roundPhaseValue: _nullableIntFromJson(json['roundPhaseValue']),
      roundPhase: json['roundPhase'] as String?,
      timeSource: json['timeSource'] as String?,
      phaseTimeCandidateMs: _nullableIntFromJson(json['phaseTimeCandidateMs']),
      timeAnchorUtilityActorId: json['timeAnchorUtilityActorId'] as String?,
      abilityIdentitySource: json['abilityIdentitySource'] as String?,
      sourceAbilityClass: json['sourceAbilityClass'] as String?,
      sourceAbilityAssetPath: json['sourceAbilityAssetPath'] as String?,
      castLocation: json['castLocation'] is Map<String, dynamic>
          ? ReplayActorPosition.fromJson(json['castLocation'])
          : null,
      effectLocations: (json['effectLocations'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayActorPosition.fromJson)
              .toList() ??
          const <ReplayActorPosition>[],
      placementLocations: _positionListFromJson(
        json['placementLocations'] ??
            json['displayLocations'] ??
            json['visualLocations'],
      ),
      destroyedCount: _nullableIntFromJson(json['destroyedCount']),
      displayLifetimeMs: _nullableIntFromJson(
        json['displayLifetimeMs'] ?? json['lifetimeMs'] ?? json['durationMs'],
      ),
      endTimeMs: _nullableIntFromJson(json['endTimeMs'] ?? json['endMs']),
      effects: (json['effects'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ReplayAbilityEffect.fromJson)
              .toList() ??
          const <ReplayAbilityEffect>[],
      linkedUtilityActorIds: (json['linkedUtilityActorIds'] as List?)
              ?.whereType<String>()
              .toList() ??
          const <String>[],
      linkedUltimateEventIds: (json['linkedUltimateEventIds'] as List?)
              ?.whereType<String>()
              .toList() ??
          const <String>[],
      confidence: json['confidence'] as String?,
      evidenceRoles:
          (json['evidenceRoles'] as List?)?.whereType<String>().toList() ??
              const <String>[],
    );
  }
}

class ReplayUtilityActor {
  const ReplayUtilityActor({
    required this.timeMs,
    required this.position,
    this.id,
    this.actorNetGuid,
    this.chIndex,
    this.closedAtMs,
    this.lifetimeMs,
    this.observedLifetimeMs,
    this.observedStartMs,
    this.observedEndMs,
    this.fallbackLifetimeMs,
    this.fallbackEndMs,
    this.effectiveEndMs,
    this.closeReason,
    this.dormant,
    this.endReason,
    this.endReasonEvidence,
    this.lifecycleEvidence,
    this.roundTeardownAtMs,
    this.roundTeardownEventId,
    this.censoredAtMs,
    this.lifecyclePolicy,
    this.lifecyclePolicySource,
    this.verifiedAbilityId,
    this.fallbackDurationSource,
    this.archetypePath,
    this.className,
    this.agent,
    this.icarusAgentType,
    this.abilitySlot,
    this.abilityIndex,
    this.abilityName,
    this.utilityKind,
    this.contentKind,
    this.phase,
    this.sourceAbilityClass,
    this.sourceAbilitySlot,
    this.sourceAbilityName,
    this.sourceAbilityAssetPath,
    this.sourceContentKind,
    this.sourceCastId,
    this.sourceCastLinkEvidence,
    this.sourceCastLinkConfidence,
    this.candidateSourceCastId,
    this.candidateSourceCastEvidence,
    this.candidateSourceCastConfidence,
    this.parentActorNetGuid,
    this.parentUtilityActorId,
    this.phaseGroupId,
    this.sequenceIndex,
    this.ownerPlayerNetGuid,
    this.ownerSubject,
    this.ownerSource,
    this.ownerConfidence,
    this.staticAssetPath,
    this.staticAssetKind,
    this.agentUuid,
    this.characterId,
    this.agentDeveloperName,
    this.agentShippingName,
    this.identitySource,
    this.identityConfidence,
    this.evidenceRoles = const <String>[],
    this.samples = const <ReplayUtilitySample>[],
    this.velocity,
    this.yawDegrees,
    this.confidence,
    this.durationSource,
    this.ignoredAsAbility = false,
    this.outcome,
    this.chainGroupId,
    this.chainStageIndex,
    this.predecessorActorId,
    this.successorActorId,
    this.triggerTimeMs,
    this.rawCloseMs,
    this.closeLagMs,
  });

  final int timeMs;
  final String? id;
  final int? actorNetGuid;
  final int? chIndex;
  final int? closedAtMs;
  final int? lifetimeMs;
  final int? observedLifetimeMs;
  final int? observedStartMs;
  final int? observedEndMs;
  final int? fallbackLifetimeMs;
  final int? fallbackEndMs;
  final int? effectiveEndMs;
  final int? closeReason;
  final bool? dormant;
  final String? endReason;
  final String? endReasonEvidence;
  final String? lifecycleEvidence;
  final int? roundTeardownAtMs;
  final String? roundTeardownEventId;
  final int? censoredAtMs;
  final String? lifecyclePolicy;
  final String? lifecyclePolicySource;
  final String? verifiedAbilityId;
  final String? fallbackDurationSource;
  final String? archetypePath;
  final String? className;
  final String? agent;
  final String? icarusAgentType;
  final String? abilitySlot;
  final int? abilityIndex;
  final String? abilityName;
  final String? utilityKind;
  final String? contentKind;
  final String? phase;
  final String? sourceAbilityClass;
  final String? sourceAbilitySlot;
  final String? sourceAbilityName;
  final String? sourceAbilityAssetPath;
  final String? sourceContentKind;
  final String? sourceCastId;
  final String? sourceCastLinkEvidence;
  final String? sourceCastLinkConfidence;
  final String? candidateSourceCastId;
  final String? candidateSourceCastEvidence;
  final String? candidateSourceCastConfidence;
  final int? parentActorNetGuid;
  final String? parentUtilityActorId;
  final String? phaseGroupId;
  final int? sequenceIndex;
  final int? ownerPlayerNetGuid;
  final String? ownerSubject;
  final String? ownerSource;
  final String? ownerConfidence;
  final String? staticAssetPath;
  final String? staticAssetKind;
  final String? agentUuid;
  final String? characterId;
  final String? agentDeveloperName;
  final String? agentShippingName;
  final String? identitySource;
  final String? identityConfidence;
  final List<String> evidenceRoles;
  final ReplayActorPosition position;
  final List<ReplayUtilitySample> samples;
  final ReplayActorPosition? velocity;
  final double? yawDegrees;
  final String? confidence;
  final String? durationSource;
  final bool ignoredAsAbility;
  final AbilityOutcome? outcome;
  final String? chainGroupId;
  final int? chainStageIndex;
  final String? predecessorActorId;
  final String? successorActorId;
  final int? triggerTimeMs;
  final int? rawCloseMs;
  final int? closeLagMs;

  /// The actor-open timestamp used for visibility. Older tracks only expose
  /// [timeMs], which was already sourced from the channel-open observation.
  int get resolvedObservedStartMs => observedStartMs ?? timeMs;

  /// The observed end of this actor phase, independent of any display timer.
  int? get resolvedObservedEndMs {
    final explicitEnd = observedEndMs ?? closedAtMs;
    if (explicitEnd != null) return explicitEnd;
    final observedLifetime = observedLifetimeMs;
    if (observedLifetime == null) return null;
    return resolvedObservedStartMs + observedLifetime;
  }

  /// The predicted end used only when replay evidence does not provide one.
  int? get resolvedFallbackEndMs {
    final explicitEnd = fallbackEndMs;
    if (explicitEnd != null) return explicitEnd;
    final fallbackLifetime = fallbackLifetimeMs ?? _legacyFallbackLifetimeMs;
    if (fallbackLifetime == null) return null;
    return resolvedObservedStartMs + fallbackLifetime;
  }

  /// The end used for playback. Observed evidence always wins, even when an
  /// older fallback would have expired first.
  int? get resolvedEffectiveEndMs =>
      resolvedObservedEndMs ?? effectiveEndMs ?? resolvedFallbackEndMs;

  int? get _legacyFallbackLifetimeMs {
    final legacyLifetime = lifetimeMs;
    if (legacyLifetime == null) return null;
    final normalizedSource = durationSource?.trim().toLowerCase();
    if (normalizedSource != null && normalizedSource.startsWith('observed-')) {
      return null;
    }
    return legacyLifetime;
  }

  String get stableId {
    final explicitId = id?.trim();
    if (explicitId != null && explicitId.isNotEmpty) return explicitId;
    final numericId = actorNetGuid ?? chIndex;
    return numericId == null ? 'actor-$timeMs' : 'actor-$numericId';
  }

  String get label {
    final pieces = <String>[
      if (agent != null && agent!.trim().isNotEmpty) agent!.trim(),
      if (abilityName != null && abilityName!.trim().isNotEmpty)
        abilityName!.trim(),
      if ((abilityName == null || abilityName!.trim().isEmpty) &&
          abilitySlot != null &&
          abilitySlot!.trim().isNotEmpty)
        abilitySlot!.trim(),
    ];
    if (pieces.isNotEmpty) return pieces.join(' ');

    final fallback = className ?? archetypePath;
    if (fallback != null && fallback.trim().isNotEmpty) {
      return fallback.trim();
    }
    final id = actorNetGuid ?? chIndex;
    return id == null ? 'Ability event' : 'Ability event $id';
  }

  bool get hasAbilityMention {
    if (_hasText(agent) ||
        _hasText(icarusAgentType) ||
        _hasText(abilitySlot) ||
        _hasText(abilityName) ||
        abilityIndex != null) {
      return true;
    }
    return _mentionsAbility(archetypePath) ||
        _mentionsAbility(className) ||
        _mentionsAbility(utilityKind) ||
        _mentionsAbility(confidence) ||
        _mentionsAbility(durationSource);
  }

  bool get isIgnoredAbilityNoise {
    if (ignoredAsAbility) return true;
    final normalizedSource = durationSource?.trim().toLowerCase();
    if (normalizedSource != null && normalizedSource.startsWith('ignored-')) {
      return true;
    }

    final name = '${className ?? ''} ${archetypePath ?? ''}';
    return RegExp(r'EquippablePickupProjectile', caseSensitive: false)
            .hasMatch(name) ||
        contentKind == 'pickup-drop' ||
        phase == 'pickup-drop';
  }

  bool get isAbilityUseCandidate {
    final observedEnd = resolvedObservedEndMs;
    final fallbackEnd = resolvedFallbackEndMs;
    final hasObservedLifecycle =
        observedEnd != null && observedEnd >= resolvedObservedStartMs;
    final fallbackDisplayLifetimeMs =
        fallbackEnd == null ? null : fallbackEnd - resolvedObservedStartMs;
    return hasAbilityMention &&
        hasSpatialAbilityPhase &&
        !isIgnoredAbilityNoise &&
        (hasObservedLifecycle ||
            (fallbackDisplayLifetimeMs != null &&
                fallbackDisplayLifetimeMs > 0 &&
                fallbackDisplayLifetimeMs <=
                    _maxReplayUtilityActorDisplayLifetimeMs));
  }

  bool get hasSpatialAbilityPhase {
    final normalizedPhase = phase?.trim().toLowerCase();
    if (normalizedPhase != null) {
      switch (normalizedPhase) {
        case 'placed-object':
        case 'area-patch':
        case 'projectile-flight':
        case 'submunition':
        case 'deployable-pawn':
        case 'reclaimable-object':
          return true;
        case 'cast-identity':
        case 'effect-only':
        case 'generated-child':
        case 'pickup-drop':
          return false;
      }
    }

    final name = className ?? archetypePath ?? '';
    return RegExp(
      r'^(?:GameObject|Projectile|Patch|Pawn|AIPawn)_',
      caseSensitive: false,
    ).hasMatch(name);
  }

  bool get isProjectilePhase {
    if (isIgnoredAbilityNoise) return false;
    final name = className ?? '';
    if (RegExp(r'^Projectile_', caseSensitive: false).hasMatch(name)) {
      return true;
    }
    return utilityKind == 'projectile' &&
        !RegExp(r'^(?:GameObject|Patch)_', caseSensitive: false).hasMatch(name);
  }

  bool isActiveAt(int replayTimeMs) {
    if (isIgnoredAbilityNoise) return false;
    if (!hasSpatialAbilityPhase) return false;
    final startTimeMs = resolvedObservedStartMs;
    if (replayTimeMs < startTimeMs) return false;

    final observedEnd = resolvedObservedEndMs;
    if (observedEnd != null) {
      return observedEnd >= startTimeMs && replayTimeMs <= observedEnd;
    }

    final fallbackEnd = effectiveEndMs ?? resolvedFallbackEndMs;
    if (fallbackEnd == null) {
      return false;
    }
    final fallbackDisplayLifetimeMs = fallbackEnd - startTimeMs;
    if (fallbackDisplayLifetimeMs <= 0 ||
        fallbackDisplayLifetimeMs > _maxReplayUtilityActorDisplayLifetimeMs) {
      return false;
    }
    return replayTimeMs <= fallbackEnd;
  }

  ReplayActorPosition positionAt(int replayTimeMs) {
    if (samples.isEmpty) return position;
    if (replayTimeMs < samples.first.timeMs) return position;
    if (replayTimeMs == samples.first.timeMs) {
      return samples.first.position;
    }
    if (replayTimeMs >= samples.last.timeMs) {
      return samples.last.position;
    }

    var low = 0;
    var high = samples.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final sample = samples[mid];
      if (sample.timeMs == replayTimeMs) return sample.position;
      if (sample.timeMs < replayTimeMs) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    final before = samples[high];
    final after = samples[low];
    final span = after.timeMs - before.timeMs;
    if (span <= 0 || span > _maxReplayUtilitySampleInterpolationGapMs) {
      return before.position;
    }
    final t = (replayTimeMs - before.timeMs) / span;
    return ReplayActorPosition.lerp(before.position, after.position, t);
  }

  double? yawDegreesAt(int replayTimeMs) {
    if (samples.isEmpty) return yawDegrees;
    if (replayTimeMs < samples.first.timeMs) return yawDegrees;
    if (replayTimeMs == samples.first.timeMs) {
      return samples.first.yawDegrees ?? yawDegrees;
    }
    if (replayTimeMs >= samples.last.timeMs) {
      return samples.last.yawDegrees ?? yawDegrees;
    }

    var low = 0;
    var high = samples.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final sample = samples[mid];
      if (sample.timeMs == replayTimeMs) {
        return sample.yawDegrees ?? yawDegrees;
      }
      if (sample.timeMs < replayTimeMs) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    final before = samples[high];
    final after = samples[low];
    final span = after.timeMs - before.timeMs;
    final beforeYaw = before.yawDegrees;
    final afterYaw = after.yawDegrees;
    if (span <= 0 ||
        span > _maxReplayUtilitySampleInterpolationGapMs ||
        beforeYaw == null ||
        afterYaw == null) {
      return beforeYaw ?? yawDegrees;
    }
    final t = (replayTimeMs - before.timeMs) / span;
    return beforeYaw + ((afterYaw - beforeYaw) * t);
  }

  factory ReplayUtilityActor.fromJson(Map<String, dynamic> json) {
    final samples = (json['samples'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ReplayUtilitySample.fromJson)
            .toList() ??
        <ReplayUtilitySample>[];
    samples.sort((a, b) => a.timeMs.compareTo(b.timeMs));

    final timeMs = _intFromJson(json['timeMs']);
    final closedAtMs = _nullableIntFromJson(json['closedAtMs']);
    final observedLifetimeMs = _nullableIntFromJson(json['observedLifetimeMs']);
    final observedStartMs =
        _nullableIntFromJson(json['observedStartMs']) ?? timeMs;
    final observedEndMs = _nullableIntFromJson(json['observedEndMs']) ??
        closedAtMs ??
        (observedLifetimeMs == null
            ? null
            : observedStartMs + observedLifetimeMs);
    final durationSource = json['durationSource'] as String?;
    final legacyLifetimeMs = _nullableIntFromJson(json['lifetimeMs']);
    final hasObservedLegacyDuration =
        durationSource?.trim().toLowerCase().startsWith('observed-') ?? false;
    final fallbackLifetimeMs =
        _nullableIntFromJson(json['fallbackLifetimeMs']) ??
            (hasObservedLegacyDuration ? null : legacyLifetimeMs);
    final fallbackEndMs = _nullableIntFromJson(json['fallbackEndMs']) ??
        (fallbackLifetimeMs == null
            ? null
            : observedStartMs + fallbackLifetimeMs);
    final effectiveEndMs = _nullableIntFromJson(json['effectiveEndMs']) ??
        observedEndMs ??
        fallbackEndMs;
    final dormant = _nullableBoolFromJson(json['dormant']);
    final endReason = json['endReason'] as String? ??
        (observedEndMs == null
            ? null
            : dormant == true
                ? 'channel-dormancy'
                : 'actor-channel-close');
    final lifecycleEvidence = json['lifecycleEvidence'] as String? ??
        json['evidenceClassification'] as String? ??
        (observedEndMs != null
            ? 'observed'
            : fallbackEndMs != null
                ? 'fallback'
                : 'absent');

    return ReplayUtilityActor(
      timeMs: timeMs,
      id: json['id'] as String?,
      actorNetGuid: _nullableIntFromJson(json['actorNetGuid']),
      chIndex: _nullableIntFromJson(json['chIndex']),
      closedAtMs: closedAtMs,
      lifetimeMs: legacyLifetimeMs,
      observedLifetimeMs: observedLifetimeMs,
      observedStartMs: observedStartMs,
      observedEndMs: observedEndMs,
      fallbackLifetimeMs: fallbackLifetimeMs,
      fallbackEndMs: fallbackEndMs,
      effectiveEndMs: effectiveEndMs,
      closeReason: _nullableIntFromJson(
        json['closeReason'] ?? json['closeReasonCode'],
      ),
      dormant: dormant,
      endReason: endReason,
      endReasonEvidence: json['endReasonEvidence'] as String?,
      lifecycleEvidence: lifecycleEvidence,
      roundTeardownAtMs: _nullableIntFromJson(json['roundTeardownAtMs']),
      roundTeardownEventId: json['roundTeardownEventId'] as String?,
      censoredAtMs: _nullableIntFromJson(json['censoredAtMs']),
      lifecyclePolicy: json['lifecyclePolicy'] as String?,
      lifecyclePolicySource: json['lifecyclePolicySource'] as String?,
      verifiedAbilityId: json['verifiedAbilityId'] as String?,
      fallbackDurationSource: json['fallbackDurationSource'] as String? ??
          (fallbackEndMs == null ? null : durationSource),
      archetypePath: json['archetypePath'] as String?,
      className: json['className'] as String?,
      agent: json['agent'] as String?,
      icarusAgentType: json['icarusAgentType'] as String?,
      abilitySlot: json['abilitySlot'] as String?,
      abilityIndex: _nullableIntFromJson(json['abilityIndex']),
      abilityName: json['abilityName'] as String?,
      utilityKind: json['utilityKind'] as String?,
      contentKind: json['contentKind'] as String?,
      phase: json['phase'] as String?,
      sourceAbilityClass: json['sourceAbilityClass'] as String?,
      sourceAbilitySlot: json['sourceAbilitySlot'] as String?,
      sourceAbilityName: json['sourceAbilityName'] as String?,
      sourceAbilityAssetPath: json['sourceAbilityAssetPath'] as String?,
      sourceContentKind: json['sourceContentKind'] as String?,
      sourceCastId: json['sourceCastId'] as String?,
      sourceCastLinkEvidence: json['sourceCastLinkEvidence'] as String?,
      sourceCastLinkConfidence: json['sourceCastLinkConfidence'] as String?,
      candidateSourceCastId: json['candidateSourceCastId'] as String?,
      candidateSourceCastEvidence:
          json['candidateSourceCastEvidence'] as String?,
      candidateSourceCastConfidence:
          json['candidateSourceCastConfidence'] as String?,
      parentActorNetGuid: _nullableIntFromJson(json['parentActorNetGuid']),
      parentUtilityActorId: json['parentUtilityActorId'] as String?,
      phaseGroupId: json['phaseGroupId'] as String?,
      sequenceIndex: _nullableIntFromJson(json['sequenceIndex']),
      ownerPlayerNetGuid: _nullableIntFromJson(json['ownerPlayerNetGuid']),
      ownerSubject: json['ownerSubject'] as String?,
      ownerSource: json['ownerSource'] as String?,
      ownerConfidence: json['ownerConfidence'] as String?,
      staticAssetPath: json['staticAssetPath'] as String?,
      staticAssetKind: json['staticAssetKind'] as String?,
      agentUuid: json['agentUuid'] as String?,
      characterId: json['characterId'] as String?,
      agentDeveloperName: json['agentDeveloperName'] as String?,
      agentShippingName: json['agentShippingName'] as String?,
      identitySource: json['identitySource'] as String?,
      identityConfidence: json['identityConfidence'] as String?,
      evidenceRoles:
          (json['evidenceRoles'] as List?)?.whereType<String>().toList() ??
              const <String>[],
      samples: samples,
      position: ReplayActorPosition.fromJson(json['position']),
      velocity: json['velocity'] is Map<String, dynamic>
          ? ReplayActorPosition.fromJson(json['velocity'])
          : null,
      yawDegrees: _yawDegreesFromJson(json['rotation']) ??
          _nullableDoubleFromJson(json['yawDegrees']),
      confidence: json['confidence'] as String?,
      durationSource: durationSource,
      ignoredAsAbility: _boolFromJson(json['ignoredAsAbility']),
      outcome: json['outcome'] is Map<String, dynamic>
          ? AbilityOutcome.fromJson(json['outcome'])
          : null,
      chainGroupId: json['chainGroupId'] as String?,
      chainStageIndex: _nullableIntFromJson(json['chainStageIndex']),
      predecessorActorId: json['predecessorActorId'] as String?,
      successorActorId: json['successorActorId'] as String?,
      triggerTimeMs: _nullableIntFromJson(json['triggerTimeMs']),
      rawCloseMs: _nullableIntFromJson(json['rawCloseMs']),
      closeLagMs: _nullableIntFromJson(json['closeLagMs']),
    );
  }
}

class ReplayUtilitySample {
  const ReplayUtilitySample({
    required this.timeMs,
    required this.position,
    this.yawDegrees,
  });

  final int timeMs;
  final ReplayActorPosition position;
  final double? yawDegrees;

  factory ReplayUtilitySample.fromJson(Map<String, dynamic> json) {
    final positionJson = json['position'];
    return ReplayUtilitySample(
      timeMs: _intFromJson(json['timeMs'] ?? json['t'] ?? json['ms']),
      position: positionJson is Map<String, dynamic>
          ? ReplayActorPosition.fromJson(positionJson)
          : ReplayActorPosition.fromJson(json),
      yawDegrees: _yawDegreesFromJson(json['rotation']) ??
          _nullableDoubleFromJson(json['yawDegrees']),
    );
  }
}

class ReplayActorPosition {
  const ReplayActorPosition({required this.x, required this.y, this.z});

  final double x;
  final double y;
  final double? z;

  static ReplayActorPosition lerp(
    ReplayActorPosition a,
    ReplayActorPosition b,
    double t,
  ) {
    final zA = a.z;
    final zB = b.z;
    return ReplayActorPosition(
      x: a.x + ((b.x - a.x) * t),
      y: a.y + ((b.y - a.y) * t),
      z: zA == null || zB == null ? zA ?? zB : zA + ((zB - zA) * t),
    );
  }

  factory ReplayActorPosition.fromJson(Object? value) {
    if (value is Map<String, dynamic>) {
      return ReplayActorPosition(
        x: _doubleFromJson(value['x']),
        y: _doubleFromJson(value['y']),
        z: _nullableDoubleFromJson(value['z']),
      );
    }
    throw const FormatException('Replay actor position requires x/y.');
  }
}

class ReplayDeathEvent {
  const ReplayDeathEvent({
    required this.timeMs,
    this.killerNetGuid,
    this.victimNetGuid,
    this.payloadVersion,
    this.eventGroupLabel,
    this.source,
    this.confidence,
  });

  final int timeMs;
  final int? killerNetGuid;
  final int? victimNetGuid;
  final int? payloadVersion;
  final String? eventGroupLabel;
  final String? source;
  final String? confidence;

  factory ReplayDeathEvent.fromJson(Map<String, dynamic> json) {
    return ReplayDeathEvent(
      timeMs: _intFromJson(json['timeMs']),
      killerNetGuid: _nullableIntFromJson(json['killerNetGuid']),
      victimNetGuid: _nullableIntFromJson(json['victimNetGuid']),
      payloadVersion: _nullableIntFromJson(json['payloadVersion']),
      eventGroupLabel: json['eventGroupLabel'] as String?,
      source: json['source'] as String?,
      confidence: json['confidence'] as String?,
    );
  }
}

class ReplayRoundStartEvent {
  const ReplayRoundStartEvent({
    required this.timeMs,
    this.roundIndex,
    this.source,
    this.confidence,
  });

  final int timeMs;
  final int? roundIndex;
  final String? source;
  final String? confidence;

  factory ReplayRoundStartEvent.fromJson(Map<String, dynamic> json) {
    return ReplayRoundStartEvent(
      timeMs: _intFromJson(json['timeMs']),
      roundIndex: _nullableIntFromJson(json['roundIndex']),
      source: json['source'] as String?,
      confidence: json['confidence'] as String?,
    );
  }
}

class ReplaySideSwitchEvent {
  const ReplaySideSwitchEvent({
    required this.timeMs,
    this.source,
    this.confidence,
  });

  final int timeMs;
  final String? source;
  final String? confidence;

  factory ReplaySideSwitchEvent.fromJson(Map<String, dynamic> json) {
    return ReplaySideSwitchEvent(
      timeMs: _intFromJson(json['timeMs']),
      source: json['source'] as String?,
      confidence: json['confidence'] as String?,
    );
  }
}

class ReplayUltimateEvent {
  const ReplayUltimateEvent({
    required this.id,
    required this.timeMs,
    this.endMs,
    this.playerNetGuid,
    this.playerSubject,
    this.agent,
    this.roundIndex,
    this.phase,
    this.payloadVersion,
    this.eventGroupLabel,
    this.eventSeconds,
    this.linkedCastId,
    this.castDeltaMs,
    this.source,
    this.confidence,
    this.evidenceRoles = const <String>[],
  });

  final String id;
  final int timeMs;
  final int? endMs;
  final int? playerNetGuid;
  final String? playerSubject;
  final String? agent;
  final int? roundIndex;
  final String? phase;
  final int? payloadVersion;
  final String? eventGroupLabel;
  final double? eventSeconds;
  final String? linkedCastId;
  final int? castDeltaMs;
  final String? source;
  final String? confidence;
  final List<String> evidenceRoles;

  factory ReplayUltimateEvent.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    final timeMs = _intFromJson(json['timeMs']);
    return ReplayUltimateEvent(
      id: id == null || id.isEmpty ? 'ultimate-$timeMs' : id,
      timeMs: timeMs,
      endMs: _nullableIntFromJson(json['endMs']),
      playerNetGuid: _nullableIntFromJson(json['playerNetGuid']),
      playerSubject: json['playerSubject'] as String?,
      agent: json['agent'] as String?,
      roundIndex: _nullableIntFromJson(json['roundIndex']),
      phase: json['phase'] as String?,
      payloadVersion: _nullableIntFromJson(json['payloadVersion']),
      eventGroupLabel: json['eventGroupLabel'] as String?,
      eventSeconds: _nullableDoubleFromJson(json['eventSeconds']),
      linkedCastId: json['linkedCastId'] as String?,
      castDeltaMs: _nullableIntFromJson(json['castDeltaMs']),
      source: json['source'] as String?,
      confidence: json['confidence'] as String?,
      evidenceRoles:
          (json['evidenceRoles'] as List?)?.whereType<String>().toList() ??
              const <String>[],
    );
  }
}

class ReplayAbilityRpcEvent {
  const ReplayAbilityRpcEvent({
    required this.id,
    required this.timeMs,
    required this.rpcName,
    required this.phaseType,
    required this.evidence,
    this.actorNetGuid,
    this.actorPath,
    this.payloadBitCount,
    this.payloadPrefixHex,
    this.payloadTruncated = false,
    this.agent,
    this.icarusAgentType,
    this.abilitySlot,
    this.abilityIndex,
    this.abilityName,
    this.canonicalAbilityId,
    this.sourceAbilityAssetPath,
    this.identitySource,
    this.identityConfidence,
    this.ownerPlayerNetGuid,
    this.ownerSubject,
    this.ownerSource,
    this.source,
  });

  final String id;
  final int timeMs;
  final int? actorNetGuid;
  final String? actorPath;
  final String rpcName;
  final String phaseType;
  final int? payloadBitCount;
  final String? payloadPrefixHex;
  final bool payloadTruncated;
  final String? agent;
  final String? icarusAgentType;
  final String? abilitySlot;
  final int? abilityIndex;
  final String? abilityName;
  final String? canonicalAbilityId;
  final String? sourceAbilityAssetPath;
  final String? identitySource;
  final String? identityConfidence;
  final int? ownerPlayerNetGuid;
  final String? ownerSubject;
  final String? ownerSource;
  final String? source;
  final String evidence;

  factory ReplayAbilityRpcEvent.fromJson(Map<String, dynamic> json) {
    final timeMs = _intFromJson(json['timeMs']);
    final id = (json['id'] as String?)?.trim();
    return ReplayAbilityRpcEvent(
      id: id == null || id.isEmpty ? 'ability-rpc-$timeMs' : id,
      timeMs: timeMs,
      actorNetGuid: _nullableIntFromJson(json['actorNetGuid']),
      actorPath: json['actorPath'] as String?,
      rpcName: json['rpcName'] as String? ?? 'UnknownRpc',
      phaseType: json['phaseType'] as String? ?? 'unknown',
      payloadBitCount: _nullableIntFromJson(json['payloadBitCount']),
      payloadPrefixHex: json['payloadPrefixHex'] as String?,
      payloadTruncated: json['payloadTruncated'] == true,
      agent: json['agent'] as String?,
      icarusAgentType: json['icarusAgentType'] as String?,
      abilitySlot: json['abilitySlot'] as String?,
      abilityIndex: _nullableIntFromJson(json['abilityIndex']),
      abilityName: json['abilityName'] as String?,
      canonicalAbilityId: json['canonicalAbilityId'] as String?,
      sourceAbilityAssetPath: json['sourceAbilityAssetPath'] as String?,
      identitySource: json['identitySource'] as String?,
      identityConfidence: json['identityConfidence'] as String?,
      ownerPlayerNetGuid: _nullableIntFromJson(json['ownerPlayerNetGuid']),
      ownerSubject: json['ownerSubject'] as String?,
      ownerSource: json['ownerSource'] as String?,
      source: json['source'] as String?,
      evidence: json['evidence'] as String? ?? 'absent',
    );
  }
}

class ReplayAbilityStateEvent {
  const ReplayAbilityStateEvent({
    required this.id,
    required this.timeMs,
    required this.equippableNetGuid,
    required this.stateNetGuid,
    required this.statePath,
    required this.stateName,
    required this.evidence,
    this.roundIndex,
    this.initialReplication = false,
    this.agent,
    this.icarusAgentType,
    this.abilitySlot,
    this.abilityIndex,
    this.abilityName,
    this.canonicalAbilityId,
    this.sourceAbilityAssetPath,
    this.identitySource,
    this.identityConfidence,
    this.ownerPlayerNetGuid,
    this.ownerSubject,
    this.ownerSource,
    this.source,
    this.authStartWorldTimeSeconds,
  });

  final String id;
  final int timeMs;
  final int? roundIndex;
  final int equippableNetGuid;
  final int stateNetGuid;
  final String statePath;
  final String stateName;
  final bool initialReplication;
  final String? agent;
  final String? icarusAgentType;
  final String? abilitySlot;
  final int? abilityIndex;
  final String? abilityName;
  final String? canonicalAbilityId;
  final String? sourceAbilityAssetPath;
  final String? identitySource;
  final String? identityConfidence;
  final int? ownerPlayerNetGuid;
  final String? ownerSubject;
  final String? ownerSource;
  final String? source;
  final double? authStartWorldTimeSeconds;
  final String evidence;

  bool get isActiveTransition =>
      !initialReplication && stateName.toLowerCase() != 'inactivestate';

  factory ReplayAbilityStateEvent.fromJson(Map<String, dynamic> json) {
    final timeMs = _intFromJson(json['timeMs']);
    final id = (json['id'] as String?)?.trim();
    return ReplayAbilityStateEvent(
      id: id == null || id.isEmpty ? 'ability-state-$timeMs' : id,
      timeMs: timeMs,
      roundIndex: _nullableIntFromJson(json['roundIndex']),
      equippableNetGuid: _intFromJson(json['equippableNetGuid']),
      stateNetGuid: _intFromJson(json['stateNetGuid']),
      statePath: json['statePath'] as String? ?? '',
      stateName: json['stateName'] as String? ?? 'UnknownState',
      initialReplication: json['initialReplication'] == true,
      agent: json['agent'] as String?,
      icarusAgentType: json['icarusAgentType'] as String?,
      abilitySlot: json['abilitySlot'] as String?,
      abilityIndex: _nullableIntFromJson(json['abilityIndex']),
      abilityName: json['abilityName'] as String?,
      canonicalAbilityId: json['canonicalAbilityId'] as String?,
      sourceAbilityAssetPath: json['sourceAbilityAssetPath'] as String?,
      identitySource: json['identitySource'] as String?,
      identityConfidence: json['identityConfidence'] as String?,
      ownerPlayerNetGuid: _nullableIntFromJson(json['ownerPlayerNetGuid']),
      ownerSubject: json['ownerSubject'] as String?,
      ownerSource: json['ownerSource'] as String?,
      source: json['source'] as String?,
      authStartWorldTimeSeconds:
          _nullableDoubleFromJson(json['authStartWorldTimeSeconds']),
      evidence: json['evidence'] as String? ?? 'absent',
    );
  }
}

class ReplayInputEvent {
  const ReplayInputEvent({
    required this.id,
    required this.timeMs,
    required this.playerReplayId,
    required this.eventTypeValue,
    required this.eventType,
    required this.serializedBitCount,
    required this.serializedDataHex,
    this.roundIndex,
    this.playerLoadoutIndex,
    this.playerSubject,
    this.agent,
    this.playerIdentitySource,
    this.playerNetGuid,
    this.equippableNetGuid,
    this.equippableActorId,
    this.abilitySlot,
    this.abilityIndex,
    this.abilityName,
    this.canonicalAbilityId,
    this.abilityIdentitySource,
    this.abilityIdentityConfidence,
    this.eventValueNibble,
    this.eventProcessingResult,
    this.rawInputEventDataHex,
    this.evidenceSource,
    this.confidence,
  });

  final String id;
  final int timeMs;
  final int playerReplayId;
  final int? roundIndex;
  final int? playerLoadoutIndex;
  final String? playerSubject;
  final String? agent;
  final String? playerIdentitySource;
  final int? playerNetGuid;
  final int? equippableNetGuid;
  final String? equippableActorId;
  final String? abilitySlot;
  final int? abilityIndex;
  final String? abilityName;
  final String? canonicalAbilityId;
  final String? abilityIdentitySource;
  final String? abilityIdentityConfidence;
  final int eventTypeValue;
  final String eventType;
  final int? eventValueNibble;
  final int serializedBitCount;
  final String serializedDataHex;
  final int? eventProcessingResult;
  final String? rawInputEventDataHex;
  final String? evidenceSource;
  final String? confidence;

  bool get isAbilityLifecycleCandidate =>
      eventType == 'EquippableInput' ||
      eventType == 'ActivationInput' ||
      eventType == 'EquippableChange';

  factory ReplayInputEvent.fromJson(Map<String, dynamic> json) {
    final timeMs = _intFromJson(json['timeMs']);
    final id = (json['id'] as String?)?.trim();
    return ReplayInputEvent(
      id: id == null || id.isEmpty ? 'input-$timeMs' : id,
      timeMs: timeMs,
      playerReplayId: _intFromJson(json['playerReplayId']),
      roundIndex: _nullableIntFromJson(json['roundIndex']),
      playerLoadoutIndex: _nullableIntFromJson(json['playerLoadoutIndex']),
      playerSubject: json['playerSubject'] as String?,
      agent: json['agent'] as String?,
      playerIdentitySource: json['playerIdentitySource'] as String?,
      playerNetGuid: _nullableIntFromJson(json['playerNetGuid']),
      equippableNetGuid: _nullableIntFromJson(json['equippableNetGuid']),
      equippableActorId: json['equippableActorId'] as String?,
      abilitySlot: json['abilitySlot'] as String?,
      abilityIndex: _nullableIntFromJson(json['abilityIndex']),
      abilityName: json['abilityName'] as String?,
      canonicalAbilityId: json['canonicalAbilityId'] as String?,
      abilityIdentitySource: json['abilityIdentitySource'] as String?,
      abilityIdentityConfidence: json['abilityIdentityConfidence'] as String?,
      eventTypeValue: _intFromJson(json['eventTypeValue']),
      eventType: json['eventType'] as String? ?? 'Unknown',
      eventValueNibble: _nullableIntFromJson(json['eventValueNibble']),
      serializedBitCount: _intFromJson(json['serializedBitCount']),
      serializedDataHex: json['serializedDataHex'] as String? ?? '',
      eventProcessingResult:
          _nullableIntFromJson(json['eventProcessingResult']),
      rawInputEventDataHex: json['rawInputEventDataHex'] as String?,
      evidenceSource: json['evidenceSource'] as String?,
      confidence: json['confidence'] as String?,
    );
  }
}

class ReplaySample {
  const ReplaySample({
    required this.timeMs,
    required this.x,
    required this.y,
    required this.yawDegrees,
    this.z,
    this.pitchDegrees,
    this.state,
  });

  final int timeMs;
  final double x;
  final double y;
  final double? z;
  final double yawDegrees;
  final double? pitchDegrees;
  final AgentState? state;

  factory ReplaySample.fromJson(Map<String, dynamic> json) {
    return ReplaySample(
      timeMs: _intFromJson(json['timeMs']),
      x: _doubleFromJson(json['x']),
      y: _doubleFromJson(json['y']),
      z: _nullableDoubleFromJson(json['z']),
      yawDegrees: _doubleFromJson(json['yawDegrees']),
      pitchDegrees: _nullableDoubleFromJson(json['pitchDegrees']),
      state: _agentStateFromJson(json['state'] ?? json['agentState'] ?? json),
    );
  }

  static ReplaySample lerp(ReplaySample a, ReplaySample b, double t) {
    return ReplaySample(
      timeMs: (a.timeMs + (b.timeMs - a.timeMs) * t).round(),
      x: _lerpDouble(a.x, b.x, t),
      y: _lerpDouble(a.y, b.y, t),
      z: a.z == null || b.z == null ? null : _lerpDouble(a.z!, b.z!, t),
      yawDegrees: _lerpYaw(a.yawDegrees, b.yawDegrees, t),
      pitchDegrees: a.pitchDegrees == null || b.pitchDegrees == null
          ? null
          : _lerpDouble(a.pitchDegrees!, b.pitchDegrees!, t),
      state: t < 0.5 ? a.state : b.state,
    );
  }
}

class ReplayPlayerFrame {
  const ReplayPlayerFrame({required this.player, required this.sample});

  final ReplayPlayerTrack player;
  final ReplaySample sample;
}

ReplayCoordinateSpace _coordinateSpaceFromString(String? value) {
  switch (value?.toLowerCase()) {
    case 'icarus':
      return ReplayCoordinateSpace.icarus;
    case 'percent':
      return ReplayCoordinateSpace.percent;
    case 'game':
    default:
      return ReplayCoordinateSpace.game;
  }
}

Color? _colorFromJson(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim().replaceFirst('#', '');
  if (normalized.length == 6) {
    return Color(int.parse('FF$normalized', radix: 16));
  }
  if (normalized.length == 8) {
    return Color(int.parse(normalized, radix: 16));
  }
  return null;
}

AgentState? _agentStateFromJson(Object? value) {
  if (value is bool) return value ? AgentState.dead : AgentState.none;
  if (value is Map<String, dynamic>) {
    if (value['isDead'] == true || value['dead'] == true) {
      return AgentState.dead;
    }
    if (value['isAlive'] == true || value['alive'] == true) {
      return AgentState.none;
    }
    return null;
  }
  if (value is! String) return null;

  switch (value.trim().toLowerCase()) {
    case 'dead':
    case 'death':
    case 'down':
    case 'killed':
      return AgentState.dead;
    case 'alive':
    case 'live':
    case 'none':
      return AgentState.none;
    default:
      return null;
  }
}

List<ReplayPlayerStateInterval> _stateIntervalsFromJson(
  Map<String, dynamic> json,
) {
  final intervals = json['stateIntervals'] ??
      json['lifeStateIntervals'] ??
      json['actorStateIntervals'];
  if (intervals is List) {
    return intervals
        .whereType<Map<String, dynamic>>()
        .map(ReplayPlayerStateInterval.fromJson)
        .toList();
  }

  final deathIntervals = json['deathIntervals'];
  if (deathIntervals is List) {
    return deathIntervals
        .whereType<Map<String, dynamic>>()
        .map(ReplayPlayerStateInterval.deadFromJson)
        .toList();
  }

  return const <ReplayPlayerStateInterval>[];
}

List<ReplayPlayerStateSample> _stateSamplesFromJson(
  Map<String, dynamic> json,
) {
  final samples = json['stateSamples'];
  if (samples is! List) return const <ReplayPlayerStateSample>[];

  return samples
      .whereType<Map<String, dynamic>>()
      .map(ReplayPlayerStateSample.fromJson)
      .toList();
}

List<ReplayActorPosition> _positionListFromJson(Object? value) {
  if (value is Map<String, dynamic>) {
    return [ReplayActorPosition.fromJson(value)];
  }
  if (value is! List) return const <ReplayActorPosition>[];

  return value
      .whereType<Map<String, dynamic>>()
      .map(ReplayActorPosition.fromJson)
      .toList();
}

String? _replaySideFromJson(Object? value) {
  if (value == null) return null;
  final normalized = value.toString().trim().toLowerCase();
  switch (normalized) {
    case 'defender':
    case 'defenders':
    case 'defense':
    case 'defence':
    case 'ally':
    case 'allies':
      return 'defender';
    case 'attacker':
    case 'attackers':
    case 'attack':
    case 'enemy':
    case 'enemies':
      return 'attacker';
  }
  return normalized.isEmpty ? null : normalized;
}

double? _yawDegreesFromJson(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  return _nullableDoubleFromJson(
    value['yawDegrees'] ?? value['yaw'] ?? value['z'],
  );
}

int? _nullableIntFromJson(Object? value) {
  if (value == null) return null;
  return _intFromJson(value);
}

int _intFromJson(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.parse(value);
  throw const FormatException('Expected integer value.');
}

double _doubleFromJson(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.parse(value);
  throw const FormatException('Expected numeric value.');
}

double? _nullableDoubleFromJson(Object? value) {
  if (value == null) return null;
  return _doubleFromJson(value);
}

bool _boolFromJson(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }
  return false;
}

bool? _nullableBoolFromJson(Object? value) {
  if (value == null) return null;
  return _boolFromJson(value);
}

double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

double _lerpYaw(double a, double b, double t) {
  final delta = ((b - a + 540) % 360) - 180;
  return (a + delta * t) % 360;
}

bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

bool _mentionsAbility(String? value) {
  if (value == null) return false;
  final normalized = value.toLowerCase();
  return normalized.contains('ability') ||
      normalized.contains('grenade') ||
      normalized.contains('ultimate') ||
      normalized.contains('projectile') ||
      normalized.contains('gameobject') ||
      normalized.contains('patch_');
}
