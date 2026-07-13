import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/replay/replay_track.dart';

void main() {
  Map<String, Object?> baseTrackJson({
    required List<Map<String, Object?>> abilityCasts,
    required List<Map<String, Object?>> utilityActors,
  }) {
    return {
      'mapId': '/Game/Maps/Juliett/Juliett',
      'coordinateSpace': 'game',
      'abilityCasts': abilityCasts,
      'utilityActors': utilityActors,
      'players': [
        {
          'id': 'netguid-776',
          'displayName': 'Raze g776',
          'agent': 'Raze',
          'samples': [
            {
              'timeMs': 0,
              'x': 0,
              'y': 0,
              'z': 0,
              'yawDegrees': 0,
            },
          ],
        },
      ],
    };
  }

  test('ability casts sort by time without treating cast positions as overlays',
      () {
    final track = ReplayTrack.fromJson(
      baseTrackJson(
        abilityCasts: [
          {
            'id': 'late',
            'timeMs': 5000,
            'agent': 'Miks',
            'abilityIndex': 2,
            'effectLocations': [
              {'x': 20, 'y': 30, 'z': 40},
            ],
          },
          {
            'id': 'early',
            'timeMs': 1000,
            'agent': 'Raze',
            'abilityIndex': 0,
            'castLocation': {'x': 1, 'y': 2, 'z': 3},
            'displayLifetimeMs': 1000,
          },
        ],
        utilityActors: const [],
      ),
    );

    expect(track.abilityCasts.map((cast) => cast.id), ['early', 'late']);
    expect(track.abilityCastsAt(1500), isEmpty);
    expect(track.abilityCasts.last.effectLocations.single.x, 20);
    expect(track.abilityCasts.last.displayLocations, isEmpty);
  });

  test('ability casts require explicit placement locations for overlays', () {
    final track = ReplayTrack.fromJson(
      baseTrackJson(
        abilityCasts: [
          {
            'id': 'metadata-only',
            'timeMs': 1000,
            'agent': 'Raze',
            'abilityIndex': 0,
            'castLocation': {'x': 1, 'y': 2, 'z': 3},
            'effectLocations': [
              {'x': 4, 'y': 5, 'z': 6},
            ],
            'placementLocations': [
              {'x': 10, 'y': 20, 'z': 30},
            ],
            'displayLifetimeMs': 1000,
          },
        ],
        utilityActors: const [],
      ),
    );

    final activeCast = track.abilityCastsAt(1500).single;
    expect(activeCast.id, 'metadata-only');
    expect(activeCast.displayLocations.single.x, 10);
    expect(track.abilityCastsAt(2501), isEmpty);
  });

  test('placement casts require a replay-backed end before rendering', () {
    final track = ReplayTrack.fromJson(
      baseTrackJson(
        abilityCasts: [
          {
            'id': 'placement-with-unknown-end',
            'timeMs': 1000,
            'agent': 'Brimstone',
            'abilitySlot': 'Ability2',
            'placementLocations': [
              {'x': 10, 'y': 20, 'z': 30},
            ],
          },
        ],
        utilityActors: const [],
      ),
    );

    expect(track.abilityCastsAt(1000), isEmpty);
    expect(track.abilityCasts.single.displayLocations, isNotEmpty);
  });

  test('ability names are preserved for casts and utility actors', () {
    final track = ReplayTrack.fromJson(
      baseTrackJson(
        abilityCasts: [
          {
            'id': 'sova-recon',
            'timeMs': 1000,
            'agent': 'Sova',
            'abilitySlot': 'Ability2',
            'abilityIndex': 2,
            'abilityName': 'Recon Bolt',
          },
        ],
        utilityActors: [
          {
            'id': 'raze-boombot',
            'timeMs': 1000,
            'lifetimeMs': 5000,
            'agent': 'Raze',
            'abilitySlot': 'Grenade',
            'abilityIndex': 0,
            'abilityName': 'Boom Bot',
            'sourceAbilityName': 'Boom Bot',
            'position': {'x': 0, 'y': 0, 'z': 0},
          },
        ],
      ),
    );

    expect(track.abilityCasts.single.label, 'Sova Recon Bolt');
    expect(track.utilityActors.single.label, 'Raze Boom Bot');
    expect(track.utilityActors.single.sourceAbilityName, 'Boom Bot');
  });

  test('utility actors interpolate position samples over replay time', () {
    final track = ReplayTrack.fromJson(
      baseTrackJson(
        abilityCasts: const [],
        utilityActors: [
          {
            'id': 'actor-boombot',
            'timeMs': 1000,
            'lifetimeMs': 5000,
            'agent': 'Raze',
            'abilityIndex': 2,
            'position': {'x': 0, 'y': 0, 'z': 0},
            'samples': [
              {
                'timeMs': 1000,
                'position': {'x': 0, 'y': 0, 'z': 0},
                'yawDegrees': 0,
              },
              {
                'timeMs': 1200,
                'position': {'x': 10, 'y': 20, 'z': 30},
                'yawDegrees': 90,
              },
            ],
          },
        ],
      ),
    );

    final actor = track.utilityActors.single;
    final position = actor.positionAt(1100);
    expect(position.x, 5);
    expect(position.y, 10);
    expect(position.z, 15);
    expect(actor.yawDegreesAt(1100), 45);
  });

  test('utility actors ignore cast identity rows as spatial overlays', () {
    final track = ReplayTrack.fromJson(
      baseTrackJson(
        abilityCasts: const [],
        utilityActors: [
          {
            'id': 'actor-ability-class',
            'timeMs': 1000,
            'lifetimeMs': 5000,
            'agent': 'Miks',
            'abilitySlot': 'Ability2',
            'className': 'Ability_Iris_E_MT_Smoke_Production',
            'phase': 'cast-identity',
            'position': {'x': 200, 'y': 300, 'z': 400},
          },
          {
            'id': 'actor-real-smoke',
            'timeMs': 1000,
            'lifetimeMs': 5000,
            'agent': 'Miks',
            'abilitySlot': 'Ability2',
            'className': 'GameObject_Iris_E_Smoke',
            'phase': 'placed-object',
            'position': {'x': 500, 'y': 600, 'z': 700},
          },
        ],
      ),
    );

    final activeActors = track.utilityActorsAt(1500);
    expect(activeActors.map((actor) => actor.stableId), ['actor-real-smoke']);
    expect(track.utilityActors.first.isAbilityUseCandidate, isFalse);
    expect(track.utilityActors.last.isAbilityUseCandidate, isTrue);
  });

  test('persistent utility actors stay visible until an observed close', () {
    final track = ReplayTrack.fromJson(
      baseTrackJson(
        abilityCasts: const [],
        utilityActors: [
          {
            'id': 'rendezvous-anchor',
            'timeMs': 16000,
            'closedAtMs': 42000,
            'lifetimeMs': 180000,
            'agent': 'Chamber',
            'abilityName': 'Rendezvous',
            'className': 'GameObject_Deadeye_E_Teleporter',
            'phase': 'placed-object',
            'position': {'x': 0, 'y': 0, 'z': 0},
          },
        ],
      ),
    );

    expect(track.utilityActorsAt(17500).single.stableId, 'rendezvous-anchor');
    expect(track.utilityActorsAt(41000).single.stableId, 'rendezvous-anchor');
    expect(track.utilityActorsAt(42001), isEmpty);
  });

  test('observed Arc Rose lifecycle overrides its shorter fallback', () {
    final track = ReplayTrack.fromJson(
      baseTrackJson(
        abilityCasts: const [],
        utilityActors: [
          {
            'id': 'actor-5272',
            'timeMs': 127598,
            'observedStartMs': 127598,
            'observedEndMs': 152339,
            'fallbackLifetimeMs': 2000,
            'fallbackEndMs': 129598,
            'effectiveEndMs': 152339,
            'closeReason': 0,
            'dormant': false,
            'endReason': 'round-teardown',
            'endReasonEvidence': 'derived:actor-close-before-round-start',
            'lifecycleEvidence': 'observed',
            'roundTeardownAtMs': 152416,
            'lifecyclePolicy': 'observed-actor',
            'lifecyclePolicySource': 'verified-registry:vyse.arc_rose',
            'verifiedAbilityId': 'vyse.arc_rose',
            'fallbackDurationSource': 'fallback:flash-or-blind',
            'agent': 'Vyse',
            'abilityName': 'Arc Rose',
            'className': 'GameObject_Nox_StealthingTrap_Flash_2',
            'phase': 'placed-object',
            'position': {'x': 0, 'y': 0, 'z': 0},
          },
        ],
      ),
    );

    final actor = track.utilityActors.single;
    expect(actor.observedStartMs, 127598);
    expect(actor.observedEndMs, 152339);
    expect(actor.fallbackLifetimeMs, 2000);
    expect(actor.fallbackEndMs, 129598);
    expect(actor.effectiveEndMs, 152339);
    expect(actor.closeReason, 0);
    expect(actor.dormant, isFalse);
    expect(actor.endReason, 'round-teardown');
    expect(
      actor.endReasonEvidence,
      'derived:actor-close-before-round-start',
    );
    expect(actor.lifecycleEvidence, 'observed');
    expect(actor.roundTeardownAtMs, 152416);
    expect(actor.lifecyclePolicy, 'observed-actor');
    expect(actor.lifecyclePolicySource, 'verified-registry:vyse.arc_rose');
    expect(actor.verifiedAbilityId, 'vyse.arc_rose');
    expect(actor.fallbackDurationSource, 'fallback:flash-or-blind');
    expect(actor.isActiveAt(130000), isTrue);
    expect(actor.isActiveAt(152339), isTrue);
    expect(actor.isActiveAt(152340), isFalse);
  });

  test('legacy close and lifetime fields retain separate provenance', () {
    final track = ReplayTrack.fromJson(
      baseTrackJson(
        abilityCasts: const [],
        utilityActors: [
          {
            'id': 'legacy-placed-object',
            'timeMs': 1000,
            'closedAtMs': 6000,
            'observedLifetimeMs': 5000,
            'lifetimeMs': 2000,
            'durationSource': 'wiki:legacy-timer',
            'className': 'GameObject_Legacy_Trap',
            'phase': 'placed-object',
            'position': {'x': 0, 'y': 0, 'z': 0},
          },
        ],
      ),
    );

    final actor = track.utilityActors.single;
    expect(actor.observedStartMs, 1000);
    expect(actor.observedEndMs, 6000);
    expect(actor.fallbackLifetimeMs, 2000);
    expect(actor.fallbackEndMs, 3000);
    expect(actor.effectiveEndMs, 6000);
    expect(actor.lifecycleEvidence, 'observed');
    expect(actor.isActiveAt(4000), isTrue);
    expect(actor.isActiveAt(6001), isFalse);
  });

  test('legacy lifetime remains an explicit fallback without an observed end',
      () {
    final track = ReplayTrack.fromJson(
      baseTrackJson(
        abilityCasts: const [],
        utilityActors: [
          {
            'id': 'legacy-fallback-object',
            'timeMs': 1000,
            'lifetimeMs': 2000,
            'durationSource': 'fallback:placed-utility',
            'className': 'GameObject_Legacy_Trap',
            'phase': 'placed-object',
            'position': {'x': 0, 'y': 0, 'z': 0},
          },
        ],
      ),
    );

    final actor = track.utilityActors.single;
    expect(actor.observedEndMs, isNull);
    expect(actor.fallbackEndMs, 3000);
    expect(actor.effectiveEndMs, 3000);
    expect(actor.lifecycleEvidence, 'fallback');
    expect(actor.isActiveAt(3000), isTrue);
    expect(actor.isActiveAt(3001), isFalse);
  });

  test('track preserves recorded duration and side-switch timeline events', () {
    final json = baseTrackJson(
      abilityCasts: const [],
      utilityActors: const [
        {
          'id': 'round-state-actor',
          'timeMs': 110000,
          'lifetimeMs': 180000,
          'agent': 'Chamber',
          'abilityName': 'Trademark',
          'className': 'GameObject_Deadeye_E_Trap',
          'phase': 'placed-object',
          'position': {'x': 0, 'y': 0, 'z': 0},
        },
      ],
    );
    json['durationMs'] = 120000;
    json['sideSwitchEvents'] = [
      {
        'id': 'halftime',
        'timeMs': 60000,
        'source': 'vrf-timeline-switchTeams',
      },
    ];

    final track = ReplayTrack.fromJson(json);

    expect(track.durationMs, 120000);
    expect(track.sideSwitchEvents.single.timeMs, 60000);
  });

  test('unknown replay maps fail instead of silently using Ascent', () {
    final json = baseTrackJson(
      abilityCasts: const [],
      utilityActors: const [],
    );
    json['mapId'] = '/Game/Maps/Unknown/Unknown';

    expect(
      () => ReplayTrack.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });

  test('internal Bonsai and Duality map codenames resolve correctly', () {
    final splitJson = baseTrackJson(
      abilityCasts: const [],
      utilityActors: const [],
    );
    splitJson['mapId'] = '/Game/Maps/Bonsai/Bonsai';
    final bindJson = baseTrackJson(
      abilityCasts: const [],
      utilityActors: const [],
    );
    bindJson['mapId'] = '/Game/Maps/Duality/Duality';

    expect(ReplayTrack.fromJson(splitJson).map, MapValue.split);
    expect(ReplayTrack.fromJson(bindJson).map, MapValue.bind);
  });

  test(
      'native ability schema preserves canonical actions, typed effects, and input evidence',
      () {
    final json = baseTrackJson(
      abilityCasts: [
        {
          'id': 'cast-0',
          'timeMs': 1000,
          'agent': 'Vyse',
          'abilitySlot': 'Ability2',
          'effects': [
            {
              'statisticIndex': 17,
              'statistic': 'AlliesBlinded',
              'value': 1,
              'affectedTargets': [
                {'affectedPlayerNetGuid': 314, 'value': 1},
              ],
            },
          ],
        },
      ],
      utilityActors: const [],
    );
    json['abilitySchemaVersion'] = 2;
    json['decoder'] = {
      'abilityCapabilities': {
        'characterAbilityCastInfo': true,
        'actorChannelOpenClose': true,
        'canonicalAbilityActions': true,
        'inputAbilitySlot': true,
        'equippableStateTransitions': true,
        'abilityLifecycleRpcEvents': true,
      },
    };
    json['abilityActions'] = [
      {
        'id': 'action-cast-0',
        'canonicalAbilityId': 'valorant.vyse.ability2',
        'agent': 'Vyse',
        'abilitySlot': 'Ability2',
        'ownerPlayerNetGuid': 314,
        'sourceCastId': 'cast-0',
        'sourceInputEventIds': ['input-0'],
        'sourceStateEventIds': ['ability-state-0'],
        'sourceRpcEventIds': ['ability-rpc-0'],
        'startTimeMs': 1000,
        'endTimeMs': 5000,
        'terminationStatus': 'derived',
        'phases': [
          {
            'id': 'phase-cast',
            'type': 'cast',
            'timeMs': 1000,
            'evidence': 'observed',
            'effects': [
              {
                'statisticIndex': 17,
                'statistic': 'AlliesBlinded',
                'affectedTargets': [
                  {'affectedPlayerNetGuid': 314, 'value': 1},
                ],
              },
            ],
          },
          {
            'id': 'phase-state',
            'type': 'state-map-targeting-state',
            'timeMs': 1100,
            'evidence': 'observed',
            'actorNetGuid': 1142,
            'stateNetGuid': 2048,
            'statePath': 'MapTargetingState',
            'stateName': 'MapTargetingState',
            'stateStartWorldTimeSeconds': 124.5,
          },
          {
            'id': 'phase-rpc',
            'type': 'rpc-one-shot-effect',
            'timeMs': 1200,
            'evidence': 'observed',
            'actorNetGuid': 1142,
            'rpcName': 'MulticastPlayOneShotEffect',
            'payloadBitCount': 1196,
          },
          {
            'id': 'phase-end',
            'type': 'round-teardown',
            'timeMs': 5000,
            'evidence': 'derived',
            'terminal': true,
          },
        ],
      },
    ];
    json['inputEvents'] = [
      {
        'id': 'input-0',
        'timeMs': 900,
        'playerReplayId': 260,
        'playerLoadoutIndex': 4,
        'playerSubject': 'subject-4',
        'agent': 'Vyse',
        'playerNetGuid': 314,
        'eventTypeValue': 4,
        'eventType': 'EquippableChange',
        'serializedBitCount': 20,
        'serializedDataHex': 'd40e01',
        'equippableNetGuid': 1142,
        'equippableActorId': 'actor-1142',
        'abilitySlot': 'Ability2',
        'abilityIndex': 2,
        'abilityName': 'Arc Rose',
        'canonicalAbilityId': 'valorant.vyse.ability2',
        'abilityIdentitySource':
            'input-equippable-netguid+static-actor-identity',
        'abilityIdentityConfidence': 'replay-exact-netguid-static-identity',
      },
    ];
    json['abilityStateEvents'] = [
      {
        'id': 'ability-state-0',
        'timeMs': 1100,
        'roundIndex': 0,
        'equippableNetGuid': 1142,
        'stateNetGuid': 2048,
        'statePath': 'MapTargetingState',
        'stateName': 'MapTargetingState',
        'authStartWorldTimeSeconds': 124.5,
        'agent': 'Vyse',
        'abilitySlot': 'Ability2',
        'abilityIndex': 2,
        'abilityName': 'Arc Rose',
        'canonicalAbilityId': 'valorant.vyse.ability2',
        'ownerPlayerNetGuid': 314,
        'ownerSubject': 'subject-4',
        'evidence': 'observed',
      },
    ];
    json['abilityRpcEvents'] = [
      {
        'id': 'ability-rpc-0',
        'timeMs': 1200,
        'actorNetGuid': 1142,
        'actorPath': 'Default__GameObject_Nox_E_Flash_C',
        'rpcName': 'MulticastPlayOneShotEffect',
        'phaseType': 'one-shot-effect',
        'payloadBitCount': 1196,
        'payloadPrefixHex': '0440',
        'agent': 'Vyse',
        'abilitySlot': 'Ability2',
        'canonicalAbilityId': 'valorant.vyse.ability2',
        'evidence': 'observed',
      },
    ];
    final player = (json['players']! as List).single as Map<String, Object?>;
    player['subject'] = 'subject-4';
    player['diagnostic'] = {'netGuid': 314};

    final track = ReplayTrack.fromJson(json);

    expect(track.abilitySchemaVersion, 2);
    expect(track.abilityCapabilities['canonicalAbilityActions'], isTrue);
    expect(track.abilityCapabilities['inputAbilitySlot'], isTrue);
    expect(track.abilityCasts.single.effects.single.statistic, 'AlliesBlinded');
    expect(
      track.abilityCasts.single.effects.single.affectedTargets.single
          .affectedPlayerNetGuid,
      314,
    );
    expect(track.abilityActions.single.canonicalAbilityId,
        'valorant.vyse.ability2');
    expect(track.abilityActions.single.terminationStatus, 'derived');
    expect(track.abilityActions.single.phases.last.terminal, isTrue);
    expect(track.abilityActions.single.sourceInputEventIds, ['input-0']);
    expect(
        track.abilityActions.single.sourceStateEventIds, ['ability-state-0']);
    expect(track.abilityActions.single.sourceRpcEventIds, ['ability-rpc-0']);
    expect(
        track.abilityActions.single.phases[1].stateName, 'MapTargetingState');
    expect(track.inputEvents.single.eventType, 'EquippableChange');
    expect(track.inputEvents.single.equippableNetGuid, 1142);
    expect(
        track.inputEvents.single.canonicalAbilityId, 'valorant.vyse.ability2');
    expect(track.abilityStateEvents.single.stateName, 'MapTargetingState');
    expect(track.abilityStateEvents.single.authStartWorldTimeSeconds, 124.5);
    expect(track.abilityStateEvents.single.isActiveTransition, isTrue);
    expect(track.abilityRpcEvents.single.phaseType, 'one-shot-effect');
    expect(track.inputEvents.single.isAbilityLifecycleCandidate, isTrue);
    expect(track.playerByNetGuid(314)?.subject, 'subject-4');
    expect(track.playerBySubject('subject-4')?.playerNetGuid, 314);
    expect(track.abilityCastById('cast-0')?.agent, 'Vyse');
  });

  test('ability schema v3 parses outcomes, close lag, and lifecycle chains',
      () {
    final json = baseTrackJson(
      abilityCasts: const [],
      utilityActors: const [
        {
          'id': 'actor-projectile',
          'timeMs': 1000,
          'closedAtMs': 2000,
          'className': 'Projectile_Gumshoe_4_CageTrap',
          'phase': 'projectile-flight',
          'position': {'x': 0, 'y': 0, 'z': 0},
          'outcome': {
            'type': 'phase-transition',
            'confidence': 'high',
            'evidence': 'observed',
            'ruleId': 'cypher-cage-deployment',
            'signatureIds': ['cypher-cage-projectile-to-zone'],
          },
          'chainGroupId': 'chain-actor-projectile',
          'chainStageIndex': 0,
          'predecessorActorId': null,
          'successorActorId': 'actor-zone',
          'triggerTimeMs': 1992,
          'rawCloseMs': 2000,
          'closeLagMs': 8,
        },
      ],
    );
    json['abilitySchemaVersion'] = 3;
    json['abilityActions'] = [
      {
        'id': 'action-cage',
        'phases': [
          {
            'id': 'phase-handoff',
            'type': 'lifecycle-chain-handoff',
            'timeMs': 1992,
            'evidence': 'observed',
            'ruleId': 'cypher-cage-deployment',
            'signatureIds': ['cypher-cage-projectile-to-zone'],
          },
        ],
        'lifecycleChain': [
          {
            'utilityActorId': 'actor-projectile',
            'className': 'Projectile_Gumshoe_4_CageTrap',
            'phaseType': 'projectile-flight',
            'startMs': 1000,
            'endMs': 1992,
            'handoffGapMs': 0,
          },
          {
            'utilityActorId': 'actor-zone',
            'className': 'Zone_Gumshoe_4_Cage',
            'phaseType': 'area-patch',
            'startMs': 1992,
            'endMs': 9250,
            'handoffGapMs': null,
          },
        ],
        'outcome': {
          'type': 'expired',
          'confidence': 'high',
          'evidence': 'derived',
          'ruleId': 'cage-expiry',
          'signatureIds': [],
        },
      },
    ];

    final track = ReplayTrack.fromJson(json);
    final actor = track.utilityActors.single;
    final action = track.abilityActions.single;

    expect(track.abilitySchemaVersion, 3);
    expect(actor.outcome?.type, 'phase-transition');
    expect(actor.outcome?.evidence, 'observed');
    expect(actor.chainStageIndex, 0);
    expect(actor.successorActorId, 'actor-zone');
    expect(actor.triggerTimeMs, 1992);
    expect(actor.rawCloseMs, 2000);
    expect(actor.closeLagMs, 8);
    expect(action.lifecycleChain, hasLength(2));
    expect(action.lifecycleChain?.first.handoffGapMs, 0);
    expect(action.outcome?.type, 'expired');
    expect(action.phases.single.ruleId, 'cypher-cage-deployment');
  });

  test('ability schema v2 keeps all v3 additions nullable', () {
    final json = baseTrackJson(
      abilityCasts: const [],
      utilityActors: const [
        {
          'id': 'actor-v2',
          'timeMs': 1000,
          'className': 'GameObject_Legacy',
          'phase': 'placed-object',
          'position': {'x': 0, 'y': 0, 'z': 0},
        },
      ],
    );
    json['abilitySchemaVersion'] = 2;
    json['abilityActions'] = [
      {
        'id': 'action-v2',
        'phases': const [],
      },
    ];

    final track = ReplayTrack.fromJson(json);

    expect(track.utilityActors.single.outcome, isNull);
    expect(track.utilityActors.single.chainGroupId, isNull);
    expect(track.utilityActors.single.triggerTimeMs, isNull);
    expect(track.abilityActions.single.lifecycleChain, isNull);
    expect(track.abilityActions.single.outcome, isNull);
  });

  test('release 13 Plummet codename is not mislabeled as Abyss', () {
    final json = baseTrackJson(
      abilityCasts: const [],
      utilityActors: const [],
    );
    json['mapId'] = '/Game/Maps/Plummet/Plummet';

    expect(
      () => ReplayTrack.fromJson(json),
      throwsA(isA<FormatException>()),
    );
  });
}
