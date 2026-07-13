import assert from 'node:assert/strict';
import test from 'node:test';

import {
  annotateUtilityActorEndReasons,
  applyObservedUtilityActorClose,
  classifyUtilityActorArchetype,
  noteUtilityActorOpen,
  verifiedUtilityActorLifecycleRule,
} from './extract_track.mjs';

const ARC_ROSE_CLASS = 'GameObject_Nox_StealthingTrap_Flash_2';
const ARC_ROSE_PATH =
  `/Game/Characters/Nox/S0/Ability_E/${ARC_ROSE_CLASS}.${ARC_ROSE_CLASS}`;

test('verified registry classifies Arc Rose as a persistent placed actor', () => {
  const registryRule = verifiedUtilityActorLifecycleRule(ARC_ROSE_CLASS);
  assert.equal(registryRule?.abilityId, 'vyse.arc_rose');
  assert.equal(registryRule?.timingPolicy, 'observed-actor');

  const classification = classifyUtilityActorArchetype(ARC_ROSE_PATH);
  assert.equal(classification?.abilityName, 'Arc Rose');
  assert.equal(classification?.phase, 'placed');
  assert.equal(classification?.utilityKind, 'deployable');
  assert.equal(classification?.displayLifetimeMs, null);
  assert.equal(classification?.lifecyclePolicy, 'observed-actor');
  assert.equal(
    classification?.lifecyclePolicySource,
    'verified-registry:vyse.arc_rose',
  );
});

test('Arc Rose open has an observed start without a fabricated flash lifetime', () => {
  const packetContext = {
    utilityActorOpenSamples: [],
    utilityActorOpenByNetGuid: new Map(),
  };
  noteUtilityActorOpen(packetContext, {
    timeMs: 127_598,
    chIndex: 186,
    actorNetGuid: 5272,
    archetype: 123,
    archetypePath: ARC_ROSE_PATH,
    location: { x: 100, y: 200, z: 300 },
    rotation: { pitch: 0, yaw: 90, roll: 0 },
    velocity: { x: 0, y: 0, z: 0 },
  });

  const actor = packetContext.utilityActorOpenSamples[0];
  assert.equal(actor.observedStartMs, 127_598);
  assert.equal(actor.observedEndMs, null);
  assert.equal(actor.fallbackLifetimeMs, null);
  assert.equal(actor.fallbackEndMs, null);
  assert.equal(actor.effectiveEndMs, null);
  assert.equal(actor.lifetimeMs, null);
  assert.equal(actor.lifecycleEvidence, 'absent');
});

test('observed close always supersedes but preserves an earlier fallback', () => {
  const actor = {
    observedStartMs: 10_000,
    observedEndMs: null,
    closedAtMs: null,
    fallbackLifetimeMs: 2_000,
    fallbackEndMs: 12_000,
    fallbackDurationSource: 'fallback:flash-or-blind',
    effectiveEndMs: 12_000,
    lifetimeMs: 2_000,
    durationSource: 'fallback:flash-or-blind',
    lifecycleEvidence: 'fallback',
    evidenceRoles: ['actor-channel-open'],
  };

  assert.equal(
    applyObservedUtilityActorClose(actor, {
      timeMs: 34_750,
      closeReason: 0,
      dormant: false,
    }),
    true,
  );
  assert.equal(actor.observedEndMs, 34_750);
  assert.equal(actor.observedLifetimeMs, 24_750);
  assert.equal(actor.effectiveEndMs, 34_750);
  assert.equal(actor.lifetimeMs, 24_750);
  assert.equal(actor.durationSource, 'observed-channel-close');
  assert.equal(actor.lifecycleEvidence, 'observed');
  assert.equal(actor.endReason, 'actor-channel-close');
  assert.equal(actor.closeReason, 0);
  assert.equal(actor.dormant, false);
  assert.equal(actor.fallbackEndMs, 12_000);
  assert.equal(actor.fallbackDurationSource, 'fallback:flash-or-blind');
});

test('dormancy is preserved and is not mislabeled as destruction or teardown', () => {
  const actor = {
    observedStartMs: 5_000,
    ignoredAsAbility: false,
    evidenceRoles: ['actor-channel-open'],
  };
  applyObservedUtilityActorClose(actor, {
    timeMs: 8_000,
    closeReason: 1,
    dormant: true,
  });
  annotateUtilityActorEndReasons([actor], [{ id: 'round-2', timeMs: 8_050 }]);

  assert.equal(actor.closeReason, 1);
  assert.equal(actor.dormant, true);
  assert.equal(actor.endReason, 'channel-dormancy');
  assert.equal(actor.endReasonEvidence, 'observed-channel-close');
});

test('an observed close immediately before a round event is marked as derived teardown', () => {
  const actor = {
    observedStartMs: 127_598,
    observedEndMs: 152_339,
    dormant: false,
    endReason: 'actor-channel-close',
    endReasonEvidence: 'observed-channel-close',
    evidenceRoles: ['actor-channel-open', 'actor-channel-close'],
  };
  annotateUtilityActorEndReasons(
    [actor],
    [{ id: 'round-8', timeMs: 152_416 }],
  );

  assert.equal(actor.endReason, 'round-teardown');
  assert.equal(
    actor.endReasonEvidence,
    'derived:actor-close-before-round-start',
  );
  assert.equal(actor.roundTeardownAtMs, 152_416);
  assert.ok(actor.evidenceRoles.includes('round-start-boundary'));
});

test('complete observation without a close is censored, never observed', () => {
  const actor = {
    observedStartMs: 20_000,
    observedEndMs: null,
    lifecyclePolicy: 'observed-actor',
    lifecycleEvidence: 'absent',
  };
  annotateUtilityActorEndReasons([actor], [], {
    observationEndMs: 50_000,
    observationComplete: true,
  });

  assert.equal(actor.endReason, 'recording-censored');
  assert.equal(actor.censoredAtMs, 50_000);
  assert.equal(actor.observedEndMs, null);
  assert.equal(actor.effectiveEndMs, 50_000);
  assert.equal(actor.lifetimeMs, 30_000);
  assert.equal(actor.lifecycleEvidence, 'derived');
  assert.equal(actor.durationSource, 'derived:recording-censored');
});

test('observed-only actor without a close ends at a known round boundary as derived', () => {
  const actor = {
    observedStartMs: 127_598,
    observedEndMs: null,
    lifecyclePolicy: 'observed-actor',
    lifecycleEvidence: 'absent',
    evidenceRoles: ['actor-channel-open'],
  };
  annotateUtilityActorEndReasons(
    [actor],
    [{ id: 'round-8', timeMs: 152_416 }],
  );

  assert.equal(actor.observedEndMs, null);
  assert.equal(actor.effectiveEndMs, 152_416);
  assert.equal(actor.lifetimeMs, 24_818);
  assert.equal(actor.endReason, 'round-teardown');
  assert.equal(actor.lifecycleEvidence, 'derived');
  assert.equal(actor.durationSource, 'derived:round-start-boundary');
});
