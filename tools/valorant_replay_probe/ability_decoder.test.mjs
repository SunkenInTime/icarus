import assert from 'node:assert/strict';
import test from 'node:test';

import {
  decodeCharacterUltimateUsedPayload,
  decodeInputEventCaptureFields,
  parseCharacterAbilityCastScalarFields,
  parseCharacterAbilityEffects,
} from './extract_track.mjs';
import {
  abilitySignalMetadataFromActorPath,
  abilityRpcEventsFromDiagnostics,
  abilityStateEventsFromDiagnostics,
  buildReplayAbilityActions,
  equippableNetGuidFromInputSample,
  linkUtilityActorsToAbilityCasts,
  replayInputEventsFromDiagnostics,
  resolveAbilityCastTimes,
} from './analyze_component_data_stream_native.mjs';

test('input capture RPC decodes its nested bit count, type, player, and result', () => {
  const decoded = decodeInputEventCaptureFields([
    { name: 'PlayerID', numBits: 32, payloadHex: '04010000' },
    { name: 'InputEventData', numBits: 32, payloadHex: '18040001' },
  ]);

  assert.deepEqual(decoded, {
    playerReplayId: 260,
    candidateLoadoutIndex: 4,
    eventTypeValue: 4,
    eventType: 'EquippableChange',
    eventValueNibble: 0,
    serializedBitCount: 12,
    serializedDataHex: '0400',
    eventProcessingResult: 1,
    rawInputEventDataHex: '18040001',
  });
});

test('typed input events deduplicate raw and compact capture lanes', () => {
  const sample = {
    timeMs: 1234,
    playerReplayId: 260,
    candidateLoadoutIndex: 4,
    eventTypeValue: 1,
    eventType: 'ActivationInput',
    eventValueNibble: 5,
    serializedBitCount: 15,
    serializedDataHex: '5100',
    eventProcessingResult: 0,
    rawInputEventDataHex: '1e510000',
  };
  const events = replayInputEventsFromDiagnostics(
    {
      header: {
        headerPlayerLoadouts: [
          { index: 4, subject: 'player-four', agent: 'Vyse' },
        ],
      },
      frameSummary: {
        nonMovementInputEventSamples: [sample],
        compactNonMovementInputEventSamples: [sample],
      },
    },
    [{ roundIndex: 2, timeMs: 1000 }],
  );

  assert.equal(events.length, 1);
  assert.equal(events[0].playerLoadoutIndex, 4);
  assert.equal(events[0].playerSubject, 'player-four');
  assert.equal(events[0].agent, 'Vyse');
  assert.equal(events[0].roundIndex, 2);
  assert.equal(
    events[0].playerIdentitySource,
    'replay-player-id-0x100-plus-header-loadout-index',
  );
});

test('equippable change joins an exact replay NetGUID to an ability equip phase', () => {
  const sample = {
    timeMs: 14263,
    playerReplayId: 256,
    candidateLoadoutIndex: 0,
    eventTypeValue: 4,
    eventType: 'EquippableChange',
    serializedBitCount: 20,
    serializedDataHex: 'd40e01',
    rawInputEventDataHex: '28d40e0100',
  };
  assert.equal(equippableNetGuidFromInputSample(sample), 1142);

  const [event] = replayInputEventsFromDiagnostics(
    {
      header: {
        headerPlayerLoadouts: [
          { index: 0, subject: 'player-zero', agent: 'Vyse' },
        ],
      },
      frameSummary: { nonMovementInputEventSamples: [sample] },
    },
    [{ roundIndex: 1, timeMs: 1000 }],
    [
      {
        id: 'actor-1142',
        actorNetGuid: 1142,
        agent: 'Vyse',
        sourceAbilitySlot: 'Ability2',
        abilityIndex: 2,
        sourceAbilityName: 'Arc Rose',
        identitySource: 'static-asset-path',
      },
    ],
    [{ subject: 'player-zero', netGuid: 314 }],
  );
  assert.equal(event.equippableNetGuid, 1142);
  assert.equal(event.playerNetGuid, 314);
  assert.equal(event.abilitySlot, 'Ability2');
  assert.equal(event.canonicalAbilityId, 'valorant.vyse.ability2');

  const [action] = buildReplayAbilityActions([], [], [], [event]);
  assert.equal(action.ownerPlayerNetGuid, 314);
  assert.deepEqual(action.sourceInputEventIds, [event.id]);
  assert.equal(action.phases.length, 1);
  assert.equal(action.phases[0].type, 'equip-selected');
  assert.equal(action.phases[0].evidence, 'observed');
});

test('CurrentState NetGUID paths become observed state-machine phases', () => {
  const inputEvents = [
    {
      id: 'input-0',
      timeMs: 2000,
      roundIndex: 0,
      eventType: 'EquippableChange',
      equippableNetGuid: 742,
      canonicalAbilityId: 'valorant.cypher.grenade',
      agent: 'Cypher',
      abilitySlot: 'Grenade',
      abilityIndex: 0,
      abilityName: 'Trapwire',
      abilityIdentitySource: 'input-equippable-netguid+static-actor-identity',
      playerNetGuid: 726,
      playerSubject: 'cypher-player',
    },
  ];
  const diagnostics = {
    frameSummary: {
      abilitySignalSamples: [
        {
          timeMs: 2000,
          actorNetGuid: 742,
          actorPath: 'Default__Ability_Gumshoe_E_TripWire_C',
          fieldName: 'CurrentState',
          netGuidReferences: [{ netGuid: 2944, pathName: 'EquipDelayState' }],
        },
        {
          timeMs: 2500,
          actorNetGuid: 742,
          actorPath: 'Default__Ability_Gumshoe_E_TripWire_C',
          fieldName: 'CurrentState',
          netGuidReferences: [{ netGuid: 1620, pathName: 'InactiveState' }],
        },
      ],
    },
  };
  const events = abilityStateEventsFromDiagnostics(
    diagnostics,
    [{ roundIndex: 0, timeMs: 1000 }],
    inputEvents,
  );
  assert.equal(events.length, 2);
  assert.equal(events[0].stateName, 'EquipDelayState');
  assert.equal(events[0].ownerPlayerNetGuid, 726);
  assert.equal(events[0].canonicalAbilityId, 'valorant.cypher.grenade');

  const stateActions = buildReplayAbilityActions([], [], [], inputEvents, events);
  assert.equal(stateActions.length, 1);
  assert.deepEqual(
    stateActions[0].phases
      .filter((phase) => phase.stateName)
      .map((phase) => phase.stateName),
    ['EquipDelayState', 'InactiveState'],
  );
  assert.deepEqual(stateActions[0].sourceInputEventIds, ['input-0']);
  assert.equal(stateActions[0].terminationStatus, 'observed');
});

test('ability actor lifecycle RPCs remain observed named phases', () => {
  const events = abilityRpcEventsFromDiagnostics({
    frameSummary: {
      abilitySignalSamples: [
        {
          timeMs: 16677,
          actorNetGuid: 2986,
          actorPath: 'Default__GameObject_Gumshoe_E_TripWire_C',
          fieldName: 'MulticastPlayOneShotEffect',
          numBits: 1196,
          payloadHex: '0440',
        },
      ],
    },
  });
  assert.equal(events.length, 1);
  assert.equal(events[0].canonicalAbilityId, 'valorant.cypher.grenade');
  assert.equal(events[0].phaseType, 'one-shot-effect');
  assert.equal(events[0].evidence, 'observed');

  const [action] = buildReplayAbilityActions(
    [],
    [
      {
        id: 'actor-2986',
        actorNetGuid: 2986,
        timeMs: 16000,
        observedStartMs: 16000,
        observedEndMs: 18000,
        agent: 'Cypher',
        sourceAbilitySlot: 'Grenade',
        abilityIndex: 0,
        abilityName: 'Trapwire',
        phase: 'placed-object',
      },
    ],
    [],
    [],
    [],
    events,
  );
  assert.deepEqual(action.sourceRpcEventIds, [events[0].id]);
  assert.equal(
    action.phases.some((phase) => phase.type === 'rpc-one-shot-effect'),
    true,
  );
});

test('CharacterAbilityCastInfo scalar fields expose replay round, phase, and cast time', () => {
  const payload = Buffer.from(
    '0a10030c40000000000e1003104042f01a42',
    'hex',
  );
  const decoded = parseCharacterAbilityCastScalarFields(payload, 0);
  assert.equal(decoded.roundIndex, 0);
  assert.equal(decoded.roundPhaseValue, 3);
  assert.equal(decoded.roundPhase, 'RoundStarting');
  assert.equal(decoded.castTimeSeconds, 38.735);
});

test('CharacterAbilityEffectInfo decodes statistic, value, time, and affected target', () => {
  const payload = Buffer.from(
    '02021e0e119041070000008005590000002f47616d652f436861726163746572732f476c6f62616c2f537472696e675461626c65732f436861726163746572735f476c6f62616c5f537472696e67732e436861726163746572735f476c6f62616c5f537472696e677300000000000e000000416c6c696573426c696e6465640022400000803f24400043ac4026e00202282075042a4014aa333d00000000',
    'hex',
  );
  const effects = parseCharacterAbilityEffects(payload, 1264);
  assert.equal(effects.length, 1);
  assert.equal(effects[0].statisticIndex, 17);
  assert.equal(effects[0].statistic, 'AlliesBlinded');
  assert.equal(effects[0].value, 1);
  assert.equal(effects[0].affectedTargets.length, 1);
  assert.equal(effects[0].affectedTargets[0].affectedPlayerNetGuid, 314);
});

test('characterUltimateUsed payload has a replay-native player and clock', () => {
  const label = Buffer.from('ultimate\0');
  const payload = Buffer.alloc(12 + label.length + 4);
  payload.writeUInt32LE(11, 0);
  payload.writeUInt32LE(314, 4);
  payload.writeInt32LE(label.length, 8);
  label.copy(payload, 12);
  payload.writeFloatLE(42.25, payload.length - 4);

  assert.deepEqual(decodeCharacterUltimateUsedPayload(payload), {
    status: 'decoded',
    payloadVersion: 11,
    playerNetGuid: 314,
    eventGroupLabel: 'ultimate',
    eventSeconds: 42.25,
  });
});

test('static spawn identity wins for known formerly swapped actor classes', () => {
  const sageWall = abilitySignalMetadataFromActorPath(
    'GameObject_Thorne_E_Wall_Segment_Fortifying',
  );
  const razeSecondary = abilitySignalMetadataFromActorPath(
    'Projectile_Clay_4_Projectile_Secondary',
  );
  const fadeHaunt = abilitySignalMetadataFromActorPath(
    'Ability_E_BountyHunter_ReconDivebomb',
  );

  assert.deepEqual(
    [sageWall.agent, sageWall.abilitySlot, sageWall.abilityName],
    ['Sage', 'Grenade', 'Barrier Orb'],
  );
  assert.deepEqual(
    [razeSecondary.agent, razeSecondary.abilitySlot, razeSecondary.abilityName],
    ['Raze', 'Ability2', 'Paint Shells'],
  );
  assert.deepEqual(
    [fadeHaunt.agent, fadeHaunt.abilitySlot, fadeHaunt.abilityName],
    ['Fade', 'Ability2', 'Haunt'],
  );
});

test('pre-round cast timing anchors only to a matching agent and slot actor', () => {
  const casts = [
    {
      id: 'cast-old',
      timeMs: 212898,
      replicationTimeMs: 212898,
      roundIndex: 7,
      roundPhase: 'RoundStarting',
      castTimeSeconds: 16.81,
      agent: 'Vyse',
      abilitySlot: 'Ability2',
      evidenceRoles: [],
    },
  ];
  const actors = [
    {
      id: 'wrong-slot',
      timeMs: 212898,
      agent: 'Vyse',
      sourceAbilitySlot: 'Ability1',
      contentKind: 'projectile-class',
    },
    {
      id: 'right-slot',
      timeMs: 169227,
      agent: 'Vyse',
      sourceAbilitySlot: 'Ability2',
      contentKind: 'game-object-class',
    },
  ];
  const resolved = resolveAbilityCastTimes(
    casts,
    actors,
    [{ roundIndex: 7, timeMs: 152416 }],
  );
  assert.equal(resolved[0].phaseTimeCandidateMs, 169226);
  assert.equal(resolved[0].timeMs, 169226);
  assert.equal(resolved[0].timeAnchorUtilityActorId, 'right-slot');
  assert.equal(
    resolved[0].timeSource,
    'roundStarted+CharacterAbilityCastInfo-CastTime',
  );
});

test('utility actor linking refuses a different ability slot', () => {
  const casts = [
    {
      id: 'cast-0',
      timeMs: 1000,
      agent: 'Vyse',
      abilitySlot: 'Ability1',
      linkedUtilityActorIds: [],
    },
  ];
  const [actor] = linkUtilityActorsToAbilityCasts(
    [
      {
        id: 'actor-0',
        timeMs: 1100,
        agent: 'Vyse',
        sourceAbilitySlot: 'Ability2',
        contentKind: 'game-object-class',
      },
    ],
    casts,
  );
  assert.equal(actor.sourceCastId, undefined);
  assert.deepEqual(casts[0].linkedUtilityActorIds, []);
});

test('same-slot time proximity remains a candidate link, never causal ownership', () => {
  const casts = [
    {
      id: 'cast-0',
      timeMs: 1000,
      playerNetGuid: 42,
      playerSubject: 'subject-42',
      agent: 'Vyse',
      abilitySlot: 'Ability2',
      linkedUtilityActorIds: [],
    },
  ];
  const [actor] = linkUtilityActorsToAbilityCasts(
    [
      {
        id: 'actor-0',
        timeMs: 1100,
        agent: 'Vyse',
        sourceAbilitySlot: 'Ability2',
        contentKind: 'game-object-class',
      },
    ],
    casts,
  );
  assert.equal(actor.sourceCastId, undefined);
  assert.equal(actor.ownerPlayerNetGuid, undefined);
  assert.equal(actor.candidateSourceCastId, 'cast-0');
  assert.equal(
    actor.candidateSourceCastConfidence,
    'derived-replay-agent-slot-time-window',
  );
  assert.deepEqual(casts[0].linkedUtilityActorIds, []);
});

test('canonical actions preserve observed and derived lifecycle phases without a timer', () => {
  const actions = buildReplayAbilityActions(
    [
      {
        id: 'cast-0',
        timeMs: 1000,
        roundIndex: 1,
        timeSource: 'CharacterAbilityCastInfo-CastTime+actor-channel-open',
        playerNetGuid: 42,
        playerSubject: 'subject-42',
        agent: 'Gekko',
        abilitySlot: 'Ability2',
        abilityIndex: 2,
        abilityName: 'Dizzy',
        sourceAbilityAssetPath: '/Game/Characters/AggroBot/S0/Ability_E/Dizzy',
        abilityIdentitySource: 'static-source-ability',
        effects: [],
      },
    ],
    [
      {
        id: 'actor-0',
        sourceCastId: 'cast-0',
        observedStartMs: 1050,
        observedEndMs: null,
        effectiveEndMs: 5000,
        durationSource: 'derived:round-start-boundary',
        endReason: 'round-teardown',
        endReasonEvidence: 'derived:actor-close-before-round-start',
        agent: 'Gekko',
        sourceAbilitySlot: 'Ability2',
        abilityIndex: 2,
        abilityName: 'Dizzy',
        phase: 'reclaimable-object',
        actorNetGuid: 99,
        position: { x: 1, y: 2, z: 3 },
      },
    ],
    [],
  );

  assert.equal(actions.length, 1);
  assert.equal(actions[0].canonicalAbilityId, 'valorant.gekko.ability2');
  assert.equal(actions[0].ownerPlayerNetGuid, 42);
  assert.deepEqual(
    actions[0].phases.map((phase) => [phase.type, phase.evidence]),
    [
      ['cast', 'observed'],
      ['reclaimable-object', 'observed'],
      ['round-teardown', 'derived'],
    ],
  );
  assert.equal(actions[0].terminationStatus, 'derived');
  assert.equal(actions[0].endTimeMs, 5000);
});
