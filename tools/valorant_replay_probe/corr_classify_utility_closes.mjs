#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  CORPUS_DIR,
  LABELS_PATH,
  SCRIPT_DIR,
  basename,
  extractCloseCluster,
  isSuspectedNoise,
  loadReplayEvidence,
  normalize,
  replayDirectories,
} from './corr_extract_close_wire_clusters.mjs';
import { classifyCorpusCloseCluster } from './lib/close_signature_classifier.mjs';

const SCHEMA_PATH = path.join(
  SCRIPT_DIR,
  'static_decoder_indexes',
  'ability_lifecycle_schema.json',
);
const CORRELATION_RESULTS_PATH = path.join(CORPUS_DIR, 'correlation_results.json');
const CLOSE_SIGNATURES_PATH = path.join(CORPUS_DIR, 'close_signatures.json');
const FINDINGS_PATH = path.join(CORPUS_DIR, 'signature_findings.md');
const PROPOSED_REGISTRY_PATH = path.join(CORPUS_DIR, 'proposed_registry_additions.json');

const OUTCOMES = [
  'recalled',
  'destroyed',
  'picked-up',
  'phase-transition',
  'expired',
  'round-ended',
  'unclassifiable',
];

const SLOT_TO_SCHEMA = new Map([
  ['grenade', 'C'],
  ['ability1', 'Q'],
  ['ability2', 'E'],
  ['ultimate', 'X'],
  ['c', 'C'],
  ['q', 'Q'],
  ['e', 'E'],
  ['x', 'X'],
]);

const KNOWN_CHAIN_EDGES = [
  {
    id: 'gekko-mosh-projectile-to-patch',
    agent: 'Gekko',
    ability: 'Mosh Pit',
    from: /^Projectile_Aggrobot_C_ExplodeyPatch$/,
    to: /^Patch_Aggrobot_C_ExplodeyPatch$/,
    gapRangeMs: [-100, 100],
  },
  {
    id: 'gekko-mosh-patch-to-reclaim',
    agent: 'Gekko',
    ability: 'Mosh Pit',
    from: /^Patch_Aggrobot_C_ExplodeyPatch$/,
    to: /^GameObject_Aggrobot_Reclaim_Orb_ExplodeyPatch$/,
    gapRangeMs: [-2_000, -1_800],
  },
  {
    id: 'cypher-cage-projectile-to-zone',
    agent: 'Cypher',
    ability: 'Cyber Cage',
    from: /^Projectile_Gumshoe_4_CageTrap$/,
    to: /^Zone_Gumshoe_4_Cage$/,
    gapRangeMs: [-100, 100],
  },
  {
    id: 'vyse-razorvine-projectile-to-placed',
    agent: 'Vyse',
    ability: 'Razorvine',
    from: /^Projectile_Nox_BarbedWire$/,
    to: /^GameObject_Nox_BarbedWire$/,
    gapRangeMs: [-1_100, -850],
  },
  {
    id: 'vyse-razorvine-placed-to-patch',
    agent: 'Vyse',
    ability: 'Razorvine',
    from: /^GameObject_Nox_BarbedWire$/,
    to: /^Patch_Nox_BarbedWire$/,
    gapRangeMs: [-100, 100],
  },
  {
    id: 'vyse-shear-trap-to-wall',
    agent: 'Vyse',
    ability: 'Shear',
    from: /^GameObject_Nox_WallTrap$/,
    to: /^GameObject_Nox_Wall$/,
    gapRangeMs: [-500, 100],
  },
  {
    id: 'gekko-thrash-pawn-to-reclaim',
    agent: 'Gekko',
    ability: 'Thrash',
    from: /^Pawn_Aggrobot_RollyPolly$/,
    to: /^GameObject_Aggrobot_X_Reclaim_Orb$/,
    gapRangeMs: [-100, 100],
  },
  {
    id: 'gekko-wingman-pawn-to-reclaim',
    agent: 'Gekko',
    ability: 'Wingman',
    from: /^Pawn_Aggrobot_SeekerNade$/,
    to: /^GameObject_Aggrobot_Reclaim_Orb_SeekerNade(?:PlantSuccessful)?$/,
    gapRangeMs: [-100, 100],
  },
  {
    id: 'gekko-dizzy-orbspawner-to-reclaim',
    agent: 'Gekko',
    ability: 'Dizzy',
    from: /^Projectile_E_Aggrobot_OrbSpawner$/,
    to: /^GameObject_Aggrobot_Reclaim_Orb_Turret$/,
    gapRangeMs: [-100, 100],
  },
  {
    id: 'killjoy-nanoswarm-projectile-to-damage',
    agent: 'Killjoy',
    ability: 'Nanoswarm',
    from: /^Projectile_Killjoy_4_RemoteBees_MultiDetonate$/,
    to: /^GameObject_Killjoy_4_BeeSwarm_Damage$/,
    gapRangeMs: [-1_600, -1_200],
  },
];

function rounded(value) {
  return Number.isFinite(value) ? Math.round(value) : null;
}

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
}

function fraction(numerator, denominator) {
  return denominator ? Number((numerator / denominator).toFixed(4)) : 0;
}

function addCount(map, key, amount = 1) {
  map.set(key, (map.get(key) ?? 0) + amount);
}

function countsObject(values) {
  const counts = new Map();
  for (const value of values) addCount(counts, value ?? 'null');
  return Object.fromEntries([...counts.entries()].sort((left, right) =>
    right[1] - left[1] || String(left[0]).localeCompare(String(right[0]))));
}

function canonicalSlot(value) {
  return SLOT_TO_SCHEMA.get(normalize(value)) ?? null;
}

function expectedOutcomeForLabel(label) {
  if (label.tag === 'phase-transition-or-other-early-removal') return 'phase-transition';
  if (label.tag === 'not-found') {
    // These are observation-status tags, not lifecycle outcomes. The comments and
    // wire timing identify two Deadlock fissure lingers and one Nanoswarm linger.
    return 'phase-transition';
  }
  return label.tag;
}

function actorClassFromPath(value) {
  return basename(value)
    .replace(/^Default__/, '')
    .replace(/_C$/, '');
}

function stateNames(signal) {
  return (signal.netGuidReferences ?? [])
    .map((reference) => basename(reference.pathName))
    .filter(Boolean);
}

function signalsMatching(cluster, {
  field = null,
  state = null,
  fromMs = -6_000,
  toMs = 250,
  scopes = null,
  actorPath = null,
} = {}) {
  return cluster.wireSignals.filter((signal) => {
    if (signal.offsetMs < fromMs || signal.offsetMs > toMs) return false;
    if (scopes && !scopes.includes(signal.scope)) return false;
    if (field && !field.test(signal.fieldName ?? '')) return false;
    if (state && !stateNames(signal).some((name) => state.test(name))) return false;
    if (actorPath && !actorPath.test(signal.actorPath ?? '')) return false;
    return true;
  });
}

function ownerInputsMatching(cluster, {
  type = null,
  fromMs = -1_000,
  toMs = 250,
  value = null,
} = {}) {
  return cluster.ownerInputEvents.filter((input) =>
    input.offsetMs >= fromMs && input.offsetMs <= toMs &&
    (!type || type.test(input.eventType ?? '')) &&
    (value == null || input.eventValueNibble === value));
}

function directActorSignals(cluster, options = {}) {
  return signalsMatching(cluster, {
    ...options,
    scopes: ['closing-actor'],
  });
}

function signalEvidence(signal, label = null) {
  return {
    kind: 'wire-signal',
    signal: label ?? signal.fieldName,
    offsetMs: signal.offsetMs,
    scope: signal.scope,
    source: signal.source,
    actorNetGuid: signal.actorNetGuid,
    actorPath: signal.actorPath,
    repObjectPath: signal.repObjectPath,
    stateReferences: stateNames(signal),
    handle: signal.handle,
    numBits: signal.numBits,
    payloadHex: signal.payloadHex,
  };
}

function inputEvidence(input, label = null) {
  return {
    kind: 'owner-input',
    signal: label ?? input.eventType,
    offsetMs: input.offsetMs,
    eventType: input.eventType,
    eventValueNibble: input.eventValueNibble,
    eventProcessingResult: input.eventProcessingResult,
    candidateLoadoutIndex: input.candidateLoadoutIndex,
    serializedDataHex: input.serializedDataHex,
  };
}

function lifetimeEvidence(cluster, expectedMs, label) {
  return {
    kind: 'lifetime',
    signal: label,
    observedLifetimeMs: cluster.actor.observedLifetimeMs,
    expectedLifetimeMs: expectedMs,
    deltaMs: Number.isFinite(expectedMs)
      ? cluster.actor.observedLifetimeMs - expectedMs
      : null,
  };
}

function chainEvidence(chainLink) {
  return {
    kind: 'actor-chain',
    signal: `${chainLink.fromClass}->${chainLink.toClass}`,
    edgeId: chainLink.edgeId,
    gapMs: chainLink.gapMs,
    sameRound: chainLink.sameRound,
    distanceUnits: chainLink.distanceUnits,
    projectedDistance2dUnits: chainLink.projectedDistance2dUnits,
    source: chainLink.source,
  };
}

function candidateSuccessors(cluster) {
  const candidates = [];
  for (const open of cluster.nearbyOpens) {
    if (!open.sameRound) continue;
    candidates.push({
      actorNetGuid: open.actor.actorNetGuid,
      className: open.actor.className,
      timeMs: open.actor.timeMs,
      gapMs: open.offsetMs,
      sameAbility: open.sameAbility,
      sameAgent: open.sameAgent,
      distanceUnits: open.distanceUnits,
      projectedDistance2dUnits: open.projectileProjectionUsed
        ? open.projectedDistance2dUnits
        : null,
      source: 'utility-actor-open',
    });
  }
  for (const signal of cluster.wireSignals) {
    if (signal.offsetMs < -2_000 || signal.offsetMs > 500) continue;
    if (signal.actorNetGuid === cluster.actor.actorNetGuid) continue;
    if (!/^(?:AbilityTrackingComponent|MulticastInitializeTrapAnchors)$/i.test(signal.fieldName ?? '')) {
      continue;
    }
    const className = actorClassFromPath(signal.actorPath);
    if (!/^(?:Projectile|GameObject|Patch|Pawn|Zone)_/.test(className)) continue;
    candidates.push({
      actorNetGuid: signal.actorNetGuid,
      className,
      timeMs: signal.timeMs,
      gapMs: signal.offsetMs,
      sameAbility: null,
      sameAgent: true,
      distanceUnits: null,
      projectedDistance2dUnits: null,
      source: 'same-window-actor-signal',
      openingSignal: signal,
    });
  }
  const deduped = new Map();
  for (const candidate of candidates) {
    const key = `${candidate.actorNetGuid ?? 'none'}\u0000${candidate.className}\u0000${candidate.timeMs}`;
    const existing = deduped.get(key);
    if (!existing || existing.source !== 'utility-actor-open') deduped.set(key, candidate);
  }
  return [...deduped.values()];
}

function deriveChainLink(cluster) {
  const fromClass = cluster.actor.className;
  const agent = cluster.actor.agent;
  const ability = cluster.actor.abilityName;
  const candidates = candidateSuccessors(cluster);
  const matches = [];
  for (const edge of KNOWN_CHAIN_EDGES) {
    if (!edge.from.test(fromClass)) continue;
    if (normalize(edge.agent) !== normalize(agent) || normalize(edge.ability) !== normalize(ability)) {
      continue;
    }
    for (const candidate of candidates) {
      if (!edge.to.test(candidate.className)) continue;
      if (edge.gapRangeMs &&
        (candidate.gapMs < edge.gapRangeMs[0] || candidate.gapMs > edge.gapRangeMs[1])) {
        continue;
      }
      const movingPawnWithoutTrack = /^Pawn_Aggrobot_(?:RollyPolly|SeekerNade)$/.test(fromClass);
      const signalOnlySuccessor = candidate.source === 'same-window-actor-signal';
      const movingProjectile = /^Projectile_/.test(fromClass) &&
        Math.hypot(cluster.actor.velocity?.x ?? 0, cluster.actor.velocity?.y ?? 0) >= 100;
      const spatiallyPlausible = movingProjectile
        ? Number.isFinite(candidate.projectedDistance2dUnits) && candidate.projectedDistance2dUnits <= 750
        : Number.isFinite(candidate.distanceUnits) && candidate.distanceUnits <= 1_000;
      if (!movingPawnWithoutTrack && !signalOnlySuccessor && !spatiallyPlausible) continue;
      matches.push({ edge, candidate, explicit: true });
    }
  }
  if (!matches.length) {
    for (const candidate of candidates) {
      if (candidate.className === fromClass || candidate.sameAbility !== true) continue;
      const movingProjectile = /^Projectile_/.test(fromClass) &&
        Math.hypot(cluster.actor.velocity?.x ?? 0, cluster.actor.velocity?.y ?? 0) >= 100;
      const spatiallyPlausible = movingProjectile
        ? Number.isFinite(candidate.projectedDistance2dUnits) && candidate.projectedDistance2dUnits <= 750
        : Number.isFinite(candidate.distanceUnits) && candidate.distanceUnits <= 1_000;
      if (!spatiallyPlausible) continue;
      const genericPhasePair =
        (/^Projectile_/.test(fromClass) && /^(?:GameObject|Patch|Zone|Projectile)_/.test(candidate.className)) ||
        (/^GameObject_/.test(fromClass) && /^Patch_/.test(candidate.className)) ||
        (/^Patch_/.test(fromClass) && /Reclaim_Orb/.test(candidate.className)) ||
        (/^Pawn_/.test(fromClass) && /Reclaim_Orb/.test(candidate.className));
      if (genericPhasePair) matches.push({ edge: null, candidate, explicit: false });
    }
  }
  if (!matches.length) return null;
  matches.sort((left, right) =>
    Number(right.explicit) - Number(left.explicit) ||
    Number(right.candidate.source === 'utility-actor-open') - Number(left.candidate.source === 'utility-actor-open') ||
    Math.abs(left.candidate.gapMs) - Math.abs(right.candidate.gapMs));
  const { edge, candidate, explicit } = matches[0];
  return {
    edgeId: edge?.id ?? 'empirical-same-ability-phase-edge',
    agent,
    abilityName: ability,
    fromClass,
    fromActorNetGuid: cluster.actor.actorNetGuid,
    closeTimeMs: cluster.actor.closedAtMs,
    toClass: candidate.className,
    toActorNetGuid: candidate.actorNetGuid,
    openTimeMs: candidate.timeMs,
    gapMs: candidate.gapMs,
    sameRound: true,
    distanceUnits: candidate.distanceUnits,
    projectedDistance2dUnits: candidate.projectedDistance2dUnits,
    spatialStatus: /^Pawn_Aggrobot_(?:RollyPolly|SeekerNade)$/.test(fromClass)
      ? 'moving-actor-endpoint-unavailable'
      : Number.isFinite(candidate.projectedDistance2dUnits) &&
      Math.hypot(cluster.actor.velocity?.x ?? 0, cluster.actor.velocity?.y ?? 0) >= 100
      ? candidate.projectedDistance2dUnits <= 750 ? 'projected-xy-consistent' : 'projected-xy-mismatch'
      : Number.isFinite(candidate.distanceUnits)
        ? candidate.distanceUnits <= 1_000 ? 'open-position-consistent' : 'moving-actor-endpoint-unavailable'
        : candidate.source === 'same-window-actor-signal'
          ? 'same-tick-wire-handoff-no-position'
          : 'position-unavailable',
    spatialCaveat:
      /^Pawn_Aggrobot_(?:RollyPolly|SeekerNade)$/.test(fromClass)
        ? 'pawn endpoint movement is not decoded; exact-tick typed reclaim successor is the chain evidence'
        : cluster.actor.velocity && Math.hypot(cluster.actor.velocity.x, cluster.actor.velocity.y) >= 100
        ? 'projectile open position is not its landing position; projected XY distance is the useful check'
        : null,
    source: candidate.source,
    explicitKnownPair: explicit,
  };
}

const SIGNATURE_DEFINITIONS = [
  {
    id: 'chamber-rendezvous-recall-rpc-state-input',
    outcome: 'recalled',
    title: 'Rendezvous parent recall RPC/state/input cluster',
    description:
      '`MulticastRecallTeleport` and `EquipState_Recall` occur at the tether close, with owner `InteractInput(14)` at the same tick.',
    predicate: (cluster) =>
      /^GameObject_Deadeye_E_Teleporter_Tether$/.test(cluster.actor.className) &&
      signalsMatching(cluster, { field: /MulticastRecallTeleport/i, fromMs: -20, toMs: 20 }).length > 0 &&
      signalsMatching(cluster, { field: /^CurrentState$/i, state: /EquipState_Recall/i, fromMs: -20, toMs: 20 }).length > 0,
  },
  {
    id: 'vyse-arc-rose-recall-state-sequence',
    outcome: 'recalled',
    title: 'Arc Rose three-state recall sequence',
    description:
      '`EquipState_Recall` -> `TimeState_Recalling` -> `TimedState_RecalledCommitTime` spans about 0.5 s and ends at actor close.',
    predicate: (cluster) =>
      /^GameObject_Nox_StealthingTrap_Flash/.test(cluster.actor.className) &&
      signalsMatching(cluster, { field: /^CurrentState$/i, state: /EquipState_Recall/i, fromMs: -600, toMs: 0 }).length > 0 &&
      signalsMatching(cluster, { field: /^CurrentState$/i, state: /RecalledCommitTime/i, fromMs: -20, toMs: 20 }).length > 0,
  },
  {
    id: 'cypher-trapwire-destruction-one-shot',
    outcome: 'destroyed',
    title: 'Trapwire terminal one-shot effect',
    description:
      'The closing Trapwire actor emits `MulticastPlayOneShotEffect` 15-16 ms before its channel closes.',
    predicate: (cluster) =>
      /^GameObject_Gumshoe_E_TripWire$/.test(cluster.actor.className) &&
      directActorSignals(cluster, { field: /MulticastPlayOneShotEffect/i, fromMs: -25, toMs: 5 }).length > 0,
  },
  {
    id: 'chamber-trademark-parent-destruction-effect',
    outcome: 'destroyed',
    title: 'Trademark parent destruction-effect cluster',
    description:
      'A Chamber character one-shot and parent ability transition fields occur on the trap close tick, without the pickup-only RecallEquipState/TimedState_RecallTrap sequence.',
    predicate: (cluster) =>
      /^GameObject_Deadeye_E_Trap$/.test(cluster.actor.className) &&
      signalsMatching(cluster, {
        field: /MulticastPlayOneShotEffect/i,
        fromMs: -10,
        toMs: 10,
        scopes: ['owner-character', 'owner-character-inferred', 'ability-family'],
        actorPath: /Deadeye_PC/i,
      }).length > 0 &&
      signalsMatching(cluster, { field: /TransitionContext/i, fromMs: -10, toMs: 10 }).length > 0 &&
      signalsMatching(cluster, { field: /^CurrentState$/i, state: /Recall(?:EquipState|Trap)/i, fromMs: -30, toMs: 30 }).length === 0,
  },
  {
    id: 'gekko-reclaim-orb-20s-expiry',
    outcome: 'expired',
    title: 'Gekko reclaim-orb 20 s expiry',
    description:
      'A `GameObject_Aggrobot_Reclaim_Orb_*` actor closes after 20.000 s (observed tolerance +/-50 ms) without a recall/pickup transition.',
    predicate: (cluster) =>
      /^GameObject_Aggrobot_(?:X_)?Reclaim_Orb/.test(cluster.actor.className) &&
      Math.abs(cluster.actor.observedLifetimeMs - 20_000) <= 50,
  },
  {
    id: 'deadlock-fissure-5p5s-linger',
    outcome: 'phase-transition',
    title: 'Deadlock fissure 5.5 s linger close',
    description:
      '`GameObject_SoundSensor_SweetSpotFissure` opens at the trigger and closes 5.50 s later; close is end-of-linger, not trigger.',
    predicate: (cluster) =>
      /^GameObject_SoundSensor_SweetSpotFissure$/.test(cluster.actor.className) &&
      Math.abs(cluster.actor.observedLifetimeMs - 5_500) <= 75,
  },
  {
    id: 'killjoy-nanoswarm-1p8s-detonation-linger',
    outcome: 'phase-transition',
    title: 'Nanoswarm detonation one-shot plus 1.8 s linger',
    description:
      'The projectile actor emits `MulticastPlayOneShotEffect` 1.800-1.805 s before its close; that RPC is the detonation moment.',
    predicate: (cluster) =>
      /^Projectile_Killjoy_4_RemoteBees_MultiDetonate$/.test(cluster.actor.className) &&
      directActorSignals(cluster, { field: /MulticastPlayOneShotEffect/i, fromMs: -1_900, toMs: -1_700 }).length > 0,
  },
  {
    id: 'killjoy-alarmbot-trigger-linger',
    outcome: 'phase-transition',
    title: 'Alarmbot trigger/detonation terminal one-shot',
    description:
      'Triggered Alarmbots emit an actor-side one-shot 656-658 ms before close; destroyed examples lack this terminal timing.',
    predicate: (cluster) =>
      /^Pawn_Killjoy_Q_StealthAlarmbot$/.test(cluster.actor.className) &&
      directActorSignals(cluster, { field: /MulticastPlayOneShotEffect/i, fromMs: -720, toMs: -600 }).length > 0,
  },
  {
    id: 'cypher-cage-zone-handoff',
    outcome: 'phase-transition',
    title: 'Cyber Cage projectile-to-zone handoff',
    description:
      'A `Zone_Gumshoe_4_Cage` actor appears at the projectile close (sometimes by same-channel reuse), so the close is deployment.',
    predicate: (_cluster, chainLink) => chainLink?.edgeId === 'cypher-cage-projectile-to-zone',
  },
  {
    id: 'vyse-razorvine-placed-handoff',
    outcome: 'phase-transition',
    title: 'Razorvine projectile-to-placed handoff',
    description:
      '`GameObject_Nox_BarbedWire` opens about 1 s before the projectile channel closes; the close is the primed/deployed phase boundary.',
    predicate: (_cluster, chainLink) => chainLink?.edgeId === 'vyse-razorvine-projectile-to-placed',
  },
  {
    id: 'vyse-shear-wall-handoff',
    outcome: 'phase-transition',
    title: 'Shear trap-to-wall trigger handoff',
    description:
      '`MulticastTransitionToState` precedes close by 415 ms while `GameObject_Nox_Wall` opens and initializes its anchors.',
    predicate: (_cluster, chainLink) => chainLink?.edgeId === 'vyse-shear-trap-to-wall',
  },
  {
    id: 'gekko-mosh-projectile-patch-handoff',
    outcome: 'phase-transition',
    title: 'Mosh Pit projectile-to-patch handoff',
    description:
      '`MulticastStopProjectile` and `Patch_Aggrobot_C_ExplodeyPatch` open occur on the projectile close tick.',
    predicate: (_cluster, chainLink) => chainLink?.edgeId === 'gekko-mosh-projectile-to-patch',
  },
  {
    id: 'chamber-trademark-recall-pickup-state',
    outcome: 'picked-up',
    title: 'Trademark owner pickup/recall state',
    description:
      '`RecallEquipState` / `TimedState_RecallTrap` plus owner InteractInput distinguishes pickup from the terminal destruction one-shot.',
    predicate: (cluster) =>
      /^GameObject_Deadeye_E_Trap$/.test(cluster.actor.className) &&
      signalsMatching(cluster, { field: /^CurrentState$/i, state: /Recall(?:EquipState|Trap)/i, fromMs: -20, toMs: 20 }).length > 0,
  },
  {
    id: 'vyse-shear-recall-pickup-state',
    outcome: 'picked-up',
    title: 'Shear recall/pickup state sequence',
    description:
      '`RecallEquipState` -> `RecallingTimedState` -> `RecallCommitTimedState` -> `RecallUnequipState` marks owner pickup.',
    predicate: (cluster) =>
      /^GameObject_Nox_WallTrap$/.test(cluster.actor.className) &&
      signalsMatching(cluster, { field: /^CurrentState$/i, state: /RecallUnequipState/i, fromMs: -20, toMs: 20 }).length > 0,
  },
  {
    id: 'synchronized-round-end-close-burst',
    outcome: 'round-ended',
    title: 'Synchronized close burst before next round',
    description:
      'Three or more utility actors close on one tick 8-14.5 s before the next round-start event, with no stronger lifecycle signature.',
    predicate: (cluster, _chainLink, context) =>
      (context?.closeBurst?.total ?? 0) >= 3 &&
      Number.isFinite(cluster.round.closeToNextRoundStartMs) &&
      cluster.round.closeToNextRoundStartMs >= 8_000 &&
      cluster.round.closeToNextRoundStartMs <= 14_500,
  },
];

function matchingSignatureIds(cluster, chainLink, context = {}) {
  return SIGNATURE_DEFINITIONS
    .filter((signature) => signature.predicate(cluster, chainLink, context))
    .map((signature) => signature.id);
}

function foreignWeaponReferences(cluster) {
  const results = [];
  for (const signal of signalsMatching(cluster, {
    field: /AbilityTrackingComponent/i,
    fromMs: -20,
    toMs: 20,
    scopes: ['closing-actor', 'closing-channel'],
  })) {
    for (const reference of signal.netGuidReferences ?? []) {
      if (/Weapon|Gun|Rifle|Sniper|PrimaryAsset/i.test(reference.pathName ?? '')) {
        results.push({ signal, reference });
      }
    }
  }
  return results;
}

function inferredRoundEnd(cluster, closeBurst) {
  const gap = cluster.round.closeToNextRoundStartMs;
  return closeBurst.total >= 3 && Number.isFinite(gap) && gap >= 8_000 && gap <= 14_500;
}

function classifyCluster(cluster, {
  chainLink,
  schemaRecord,
  expiryPrior,
  closeBurst,
}) {
  const className = cluster.actor.className;
  const lifetimeMs = cluster.actor.observedLifetimeMs;
  const signatureIds = matchingSignatureIds(cluster, chainLink, { closeBurst });
  const result = (outcome, confidence, ruleId, evidence, caveats = []) => ({
    outcome,
    confidence,
    ruleId,
    signatureIds,
    evidence: evidence.slice(0, 12),
    caveats,
  });

  if (cluster.actor.endReason === 'round-teardown') {
    return result('round-ended', 'high', 'observed-round-teardown', [{
      kind: 'lifecycle',
      signal: 'endReason=round-teardown',
      endReasonEvidence: cluster.actor.endReasonEvidence,
      closeToNextRoundStartMs: cluster.round.closeToNextRoundStartMs,
    }]);
  }

  const trademarkPickupStates = signalsMatching(cluster, {
    field: /^CurrentState$/i,
    state: /Recall(?:EquipState|Trap)/i,
    fromMs: -30,
    toMs: 30,
  });
  if (/^GameObject_Deadeye_E_Trap$/.test(className) && trademarkPickupStates.length) {
    const interact = ownerInputsMatching(cluster, { type: /InteractInput/i, fromMs: -100, toMs: 180 });
    return result('picked-up', 'high', 'chamber-trademark-pickup-state', [
      ...trademarkPickupStates.map((signal) => signalEvidence(signal)),
      ...interact.slice(0, 1).map((input) => inputEvidence(input)),
    ]);
  }

  const shearPickupStates = signalsMatching(cluster, {
    field: /^CurrentState$/i,
    state: /RecallUnequipState/i,
    fromMs: -30,
    toMs: 30,
  });
  if (/^GameObject_Nox_WallTrap$/.test(className) && shearPickupStates.length) {
    const sequence = signalsMatching(cluster, {
      field: /^CurrentState$/i,
      state: /Recall|Recalling/i,
      fromMs: -1_100,
      toMs: 30,
    });
    return result('picked-up', 'high', 'vyse-shear-pickup-state', sequence.map((signal) => signalEvidence(signal)));
  }

  const recallRpc = signalsMatching(cluster, {
    field: /MulticastRecallTeleport/i,
    fromMs: -30,
    toMs: 30,
  });
  if (/^GameObject_Deadeye_E_Teleporter_Tether$/.test(className) && recallRpc.length) {
    const states = signalsMatching(cluster, {
      field: /^CurrentState$/i,
      state: /Recall/i,
      fromMs: -30,
      toMs: 30,
    });
    const interact = ownerInputsMatching(cluster, { type: /InteractInput/i, fromMs: -30, toMs: 30 });
    return result('recalled', 'high', 'chamber-rendezvous-recall-rpc', [
      ...recallRpc.map((signal) => signalEvidence(signal)),
      ...states.map((signal) => signalEvidence(signal)),
      ...interact.slice(0, 1).map((input) => inputEvidence(input)),
    ]);
  }

  const arcRecallCommit = signalsMatching(cluster, {
    field: /^CurrentState$/i,
    state: /RecalledCommitTime/i,
    fromMs: -30,
    toMs: 30,
  });
  if (/^GameObject_Nox_StealthingTrap_Flash/.test(className) && arcRecallCommit.length) {
    const sequence = signalsMatching(cluster, {
      field: /^CurrentState$/i,
      state: /Recall/i,
      fromMs: -600,
      toMs: 30,
    });
    return result('recalled', 'high', 'vyse-arc-rose-recall-sequence', sequence.map((signal) => signalEvidence(signal)));
  }

  if (/^GameObject_Aggrobot_(?:X_)?Reclaim_Orb/.test(className) && Math.abs(lifetimeMs - 20_000) <= 50) {
    return result('expired', 'high', 'gekko-reclaim-orb-fixed-expiry', [
      lifetimeEvidence(cluster, 20_000, '20-second reclaim window elapsed'),
    ]);
  }

  if (/^GameObject_SoundSensor_SweetSpotFissure$/.test(className) && Math.abs(lifetimeMs - 5_500) <= 75) {
    return result('phase-transition', 'high', 'deadlock-fissure-linger-ended', [
      lifetimeEvidence(cluster, 5_500, 'trigger-spawned fissure linger ended'),
      {
        kind: 'timing-anchor',
        signal: 'actor open is gameplay trigger marker',
        trueGameplayTimeMs: cluster.actor.timeMs,
        closeLagMs: lifetimeMs,
      },
    ]);
  }

  const nanosDetonation = directActorSignals(cluster, {
    field: /MulticastPlayOneShotEffect/i,
    fromMs: -1_900,
    toMs: -1_700,
  });
  if (/^Projectile_Killjoy_4_RemoteBees_MultiDetonate$/.test(className) && nanosDetonation.length) {
    return result('phase-transition', 'high', 'killjoy-nanoswarm-detonation-linger', [
      signalEvidence(nanosDetonation.at(-1), 'detonation one-shot'),
      lifetimeEvidence(cluster, null, 'actor closes after detonation linger'),
    ]);
  }

  const alarmTrigger = directActorSignals(cluster, {
    field: /MulticastPlayOneShotEffect/i,
    fromMs: -720,
    toMs: -600,
  });
  if (/^Pawn_Killjoy_Q_StealthAlarmbot$/.test(className) && alarmTrigger.length) {
    return result('phase-transition', 'high', 'killjoy-alarmbot-triggered', [
      signalEvidence(alarmTrigger.at(-1), 'trigger/detonation one-shot'),
    ]);
  }

  if (/^GameObject_Nox_WallTrap$/.test(className) && chainLink?.edgeId === 'vyse-shear-trap-to-wall') {
    const transition = directActorSignals(cluster, {
      field: /MulticastTransitionToState/i,
      fromMs: -500,
      toMs: -300,
    });
    return result('phase-transition', 'high', 'vyse-shear-trigger-wall-handoff', [
      ...transition.map((signal) => signalEvidence(signal, 'trap trigger transition')),
      chainEvidence(chainLink),
    ]);
  }

  if (/^Projectile_(?:Gumshoe_4_CageTrap|Nox_BarbedWire)$/.test(className)) {
    const stop = directActorSignals(cluster, {
      field: /MulticastStopProjectile/i,
      fromMs: -1_100,
      toMs: 10,
    });
    const evidence = [
      ...stop.slice(-1).map((signal) => signalEvidence(signal, 'projectile landed/stopped')),
      ...(chainLink ? [chainEvidence(chainLink)] : []),
    ];
    return result('phase-transition', chainLink ? 'high' : 'medium',
      /^Projectile_Gumshoe/.test(className) ? 'cypher-cage-deployment' : 'vyse-razorvine-priming',
      evidence,
      chainLink ? [] : ['successor actor was not retained in the filtered utility-open layer']);
  }

  if (/^(?:Projectile_Aggrobot_C_ExplodeyPatch|Patch_Aggrobot_C_ExplodeyPatch)$/.test(className) && chainLink) {
    return result('phase-transition', 'high', 'gekko-mosh-phase-handoff', [chainEvidence(chainLink)]);
  }

  if (/^Pawn_Aggrobot_RollyPolly$/.test(className)) {
    const weaponReferences = foreignWeaponReferences(cluster);
    if (weaponReferences.length) {
      return result('destroyed', 'medium', 'gekko-thrash-foreign-weapon-reference', weaponReferences.map(({ signal, reference }) => ({
        ...signalEvidence(signal, 'foreign weapon reference at handoff'),
        referencedNetGuid: reference.netGuid,
        referencedPath: reference.pathName,
      })), [
        'only one human-labeled destroyed Thrash supports this discriminator; treat as a hypothesis',
      ]);
    }
    if (chainLink) return result('phase-transition', 'medium', 'gekko-thrash-detonation-to-reclaim', [chainEvidence(chainLink)], [
      'the reclaim-orb handoff also occurs after destruction; absence of a foreign weapon reference is the current differentiator',
    ]);
  }

  if (/^Pawn_Aggrobot_SeekerNade$/.test(className)) {
    if (/PlantSuccessful/.test(chainLink?.toClass ?? '')) {
      return result('phase-transition', 'high', 'gekko-wingman-plant-completed', [chainEvidence(chainLink)]);
    }
    if (lifetimeMs <= 2_500 && chainLink) {
      return result('destroyed', 'medium', 'gekko-wingman-short-run-to-reclaim', [
        lifetimeEvidence(cluster, null, 'abnormally short active run'),
        chainEvidence(chainLink),
      ], ['single destroyed Wingman example; duration threshold is provisional']);
    }
    if (chainLink) {
      return result('phase-transition', 'medium', 'gekko-wingman-course-completed', [
        lifetimeEvidence(cluster, null, 'normal active run before reclaim handoff'),
        chainEvidence(chainLink),
      ]);
    }
  }

  const directTerminalOneShot = directActorSignals(cluster, {
    field: /MulticastPlayOneShotEffect/i,
    fromMs: -40,
    toMs: 10,
  });
  if (/^GameObject_(?:Gumshoe_E_TripWire|Deadeye_E_Trap)$/.test(className) && directTerminalOneShot.length) {
    return result('destroyed', 'high', 'deployable-terminal-one-shot-destruction',
      directTerminalOneShot.map((signal) => signalEvidence(signal, 'terminal destruction one-shot')));
  }

  if (/^GameObject_Deadeye_E_Trap$/.test(className)) {
    const parentOneShot = signalsMatching(cluster, {
      field: /MulticastPlayOneShotEffect/i,
      fromMs: -10,
      toMs: 10,
      scopes: ['owner-character', 'owner-character-inferred', 'ability-family'],
      actorPath: /Deadeye_PC/i,
    });
    const transition = signalsMatching(cluster, {
      field: /TransitionContext/i,
      fromMs: -10,
      toMs: 10,
    });
    if (parentOneShot.length && transition.length) {
      return result('destroyed', 'medium', 'chamber-trademark-parent-destruction-effect', [
        signalEvidence(parentOneShot.at(-1), 'parent destruction one-shot'),
        signalEvidence(transition.at(-1), 'parent transition context'),
      ], ['two agreeing labels; the effect RPC payload itself is not semantically named destruction']);
    }
  }

  if (/^Pawn_Killjoy_Q_StealthAlarmbot$/.test(className)) {
    return result('destroyed', 'medium', 'killjoy-alarmbot-no-trigger-signature', [
      lifetimeEvidence(cluster, null, 'closed without the 656-658 ms trigger signature'),
    ], ['destruction is inferred by contrast with two triggered labels']);
  }

  if (inferredRoundEnd(cluster, closeBurst)) {
    return result('round-ended', 'medium', 'synchronized-round-end-close-burst', [{
      kind: 'close-burst',
      signal: `${closeBurst.total} utility actors closed at the same tick`,
      simultaneousCloseCount: closeBurst.total,
      sameAbilityCloseCount: closeBurst.sameAbility,
      closeToNextRoundStartMs: cluster.round.closeToNextRoundStartMs,
    }]);
  }

  if (/^Ability_Gumshoe_Q_Camera_Dart$/.test(className)) {
    return result('destroyed', 'medium', 'cypher-spycam-dart-non-round-close', [{
      kind: 'class-conditioned',
      signal: 'non-round terminal close of camera-dart actor',
      className,
      simultaneousCloseCount: closeBurst.total,
    }], ['two destroyed labels versus one round-end label support this class-conditioned rule']);
  }

  if (/^Pawn_Killjoy_E_Turret$/.test(className)) {
    return result('destroyed', 'medium', 'killjoy-turret-non-recall-close', [{
      kind: 'class-conditioned',
      signal: 'Turret closed without recall state or round teardown',
      className,
    }], ['all three labeled examples are destroyed, but no positive terminal RPC was decoded']);
  }

  if (chainLink) {
    return result('phase-transition', 'high', 'observed-related-actor-handoff', [chainEvidence(chainLink)]);
  }

  if (expiryPrior?.label === 'expiry') {
    return result('expired', 'high', 'schema-lifetime-exact-expiry', [
      lifetimeEvidence(cluster, expiryPrior.expectedLifetimeMs, 'schema maximum reached within two replay ticks'),
    ]);
  }

  if (directTerminalOneShot.length && schemaRecord?.destroyable) {
    return result('destroyed', 'medium', 'generic-destroyable-terminal-one-shot',
      directTerminalOneShot.map((signal) => signalEvidence(signal)));
  }

  const stopProjectile = directActorSignals(cluster, {
    field: /MulticastStopProjectile/i,
    fromMs: -1_500,
    toMs: 20,
  });
  if (stopProjectile.length && /^Projectile_/.test(className)) {
    return result('phase-transition', 'medium', 'generic-projectile-stop',
      stopProjectile.slice(-1).map((signal) => signalEvidence(signal)));
  }

  if (/^Patch_/.test(className) && Number.isFinite(lifetimeMs) && lifetimeMs >= 500) {
    return result('expired', 'low', 'area-patch-natural-duration-ended', [
      lifetimeEvidence(cluster, null, 'area-patch actor reached its natural close'),
    ], ['no successor or explicit expiry RPC was observed']);
  }

  return result('unclassifiable', 'none', 'insufficient-discriminating-evidence', [{
    kind: 'negative-evidence',
    signal: 'no learned recall, pickup, destruction, chain, expiry, or round-teardown signature',
    className,
    schema: schemaRecord ? {
      destroyable: schemaRecord.destroyable,
      recallable: schemaRecord.recallable,
      pickupable: schemaRecord.pickupable,
      maxLifetimeSeconds: schemaRecord.maxLifetimeSeconds,
    } : null,
  }]);
}

function schemaIndex(schema) {
  return new Map(schema.abilities.map((ability) => [
    `${normalize(ability.agentName)}\u0000${ability.slot}`,
    ability,
  ]));
}

function schemaRecordForActor(actor, byKey) {
  const slot = canonicalSlot(actor.abilitySlot ?? actor.sourceAbilitySlot);
  return slot ? byKey.get(`${normalize(actor.agent)}\u0000${slot}`) ?? null : null;
}

function closeKey(replayUuid, actorNetGuid, timeMs) {
  return `${replayUuid}\u0000${actorNetGuid}\u0000${timeMs}`;
}

function publicActor(actor) {
  return {
    actorNetGuid: actor.actorNetGuid,
    chIndex: actor.chIndex,
    className: actor.className,
    archetypePath: actor.archetypePath,
    agent: actor.agent,
    abilitySlot: actor.abilitySlot,
    abilityName: actor.abilityName,
    utilityKind: actor.utilityKind,
    contentKind: actor.contentKind,
    phase: actor.phase,
    timeMs: actor.timeMs,
    closedAtMs: actor.closedAtMs,
    observedLifetimeMs: actor.observedLifetimeMs,
    endReason: actor.endReason,
    endReasonEvidence: actor.endReasonEvidence,
    closeReason: actor.closeReason,
    dormant: actor.dormant,
    position: actor.position,
    endPosition: actor.endPosition,
    velocity: actor.velocity,
  };
}

function buildChainGraphs(classifications) {
  const graphMap = new Map();
  for (const classification of classifications) {
    const link = classification.chainLink;
    if (!link) continue;
    if (!link.sameRound) throw new Error(`cross-round chain escaped filter: ${classification.id}`);
    if (link.gapMs < -2_000 || link.gapMs > 2_000) {
      throw new Error(`chain gap outside sanity window: ${classification.id} ${link.gapMs}`);
    }
    const graphKey = `${link.agent}\u0000${link.abilityName}`;
    if (!graphMap.has(graphKey)) {
      graphMap.set(graphKey, {
        agent: link.agent,
        abilityName: link.abilityName,
        edges: new Map(),
      });
    }
    const graph = graphMap.get(graphKey);
    const edgeKey = `${link.fromClass}\u0000${link.toClass}`;
    if (!graph.edges.has(edgeKey)) {
      graph.edges.set(edgeKey, {
        edgeId: link.edgeId,
        fromClass: link.fromClass,
        toClass: link.toClass,
        observedHandoffs: 0,
        gapsMs: [],
        distancesUnits: [],
        projectedDistances2dUnits: [],
        sources: new Set(),
        instances: [],
      });
    }
    const edge = graph.edges.get(edgeKey);
    edge.observedHandoffs += 1;
    edge.gapsMs.push(link.gapMs);
    if (Number.isFinite(link.distanceUnits)) edge.distancesUnits.push(link.distanceUnits);
    if (Number.isFinite(link.projectedDistance2dUnits)) {
      edge.projectedDistances2dUnits.push(link.projectedDistance2dUnits);
    }
    edge.sources.add(link.source);
    edge.instances.push({
      closeId: classification.id,
      replayUuid: classification.replayUuid,
      round: classification.round,
      closeTimeMs: classification.timeMs,
      fromActorNetGuid: link.fromActorNetGuid,
      toActorNetGuid: link.toActorNetGuid,
      openTimeMs: link.openTimeMs,
      gapMs: link.gapMs,
      distanceUnits: link.distanceUnits,
      projectedDistance2dUnits: link.projectedDistance2dUnits,
      spatialStatus: link.spatialStatus,
      spatialCaveat: link.spatialCaveat,
      sameRound: true,
      source: link.source,
    });
  }
  return [...graphMap.values()]
    .map((graph) => ({
      agent: graph.agent,
      abilityName: graph.abilityName,
      graph: [...graph.edges.values()]
        .sort((left, right) => left.fromClass.localeCompare(right.fromClass) || left.toClass.localeCompare(right.toClass))
        .map((edge) => ({
          edgeId: edge.edgeId,
          fromClass: edge.fromClass,
          toClass: edge.toClass,
          observedHandoffs: edge.observedHandoffs,
          gapMs: {
            min: rounded(Math.min(...edge.gapsMs)),
            median: rounded(median(edge.gapsMs)),
            max: rounded(Math.max(...edge.gapsMs)),
          },
          spatial: {
            directDistanceMedianUnits: rounded(median(edge.distancesUnits)),
            projectileProjected2dMedianUnits: rounded(median(edge.projectedDistances2dUnits)),
            caveat: edge.projectedDistances2dUnits.length
              ? 'projectile actor samples retain launch position; projected XY is used as the landing-location sanity check'
              : null,
          },
          sources: [...edge.sources].sort(),
          instances: edge.instances,
        })),
    }))
    .sort((left, right) => left.agent.localeCompare(right.agent) || left.abilityName.localeCompare(right.abilityName));
}

function buildSignatureSupport(classifications) {
  return SIGNATURE_DEFINITIONS.map((definition) => {
    const corpusRows = classifications.filter((row) => row.signatureIds.includes(definition.id));
    const labeledRows = corpusRows.filter((row) => row.humanGroundTruth);
    const supportingRows = labeledRows.filter((row) => row.humanGroundTruth.expectedOutcome === definition.outcome);
    const contradictions = labeledRows.filter((row) => row.humanGroundTruth.expectedOutcome !== definition.outcome);
    const status = supportingRows.length >= 3 && contradictions.length === 0
      ? 'established'
      : supportingRows.length >= 2 && contradictions.length === 0
        ? 'supported'
        : supportingRows.length >= 1 && contradictions.length === 0
          ? 'hypothesis'
          : contradictions.length
            ? 'contradicted'
            : 'unseen-in-labels';
    return {
      id: definition.id,
      outcome: definition.outcome,
      title: definition.title,
      description: definition.description,
      status,
      support: {
        labeledSupportingInstances: supportingRows.length,
        labeledContradictions: contradictions.length,
        corpusMatches: corpusRows.length,
        classes: [...new Set(supportingRows.map((row) => row.actor.className))].sort(),
        labeledIds: supportingRows.map((row) => row.id),
        contradictionIds: contradictions.map((row) => row.id),
      },
    };
  });
}

function classMajorityLeaveOneOut(labeledClassifications) {
  const cases = [];
  for (const heldOut of labeledClassifications) {
    let peers = labeledClassifications.filter((row) =>
      row.id !== heldOut.id && row.actor.className === heldOut.actor.className);
    let basis = 'same-class';
    if (!peers.length) {
      peers = labeledClassifications.filter((row) =>
        row.id !== heldOut.id &&
        normalize(row.actor.agent) === normalize(heldOut.actor.agent) &&
        normalize(row.actor.abilityName) === normalize(heldOut.actor.abilityName));
      basis = 'same-ability';
    }
    const counts = new Map();
    for (const peer of peers) addCount(counts, peer.humanGroundTruth.expectedOutcome);
    const ranked = [...counts.entries()].sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]));
    const uniqueWinner = ranked.length && (ranked.length === 1 || ranked[0][1] > ranked[1][1]);
    const prediction = uniqueWinner ? ranked[0][0] : null;
    cases.push({
      id: heldOut.id,
      expected: heldOut.humanGroundTruth.expectedOutcome,
      predicted: prediction,
      classifiable: prediction != null,
      correct: prediction === heldOut.humanGroundTruth.expectedOutcome,
      basis,
      peerCount: peers.length,
      peerOutcomes: Object.fromEntries(ranked),
    });
  }
  const classifiable = cases.filter((row) => row.classifiable);
  return {
    method: 'leave-one-out class-conditioned majority baseline; falls back to same ability only when the held-out class has no peer',
    purpose: 'small-sample robustness diagnostic, not the wire-rule classifier',
    total: cases.length,
    classifiable: classifiable.length,
    correct: classifiable.filter((row) => row.correct).length,
    accuracyAmongClassifiable: fraction(classifiable.filter((row) => row.correct).length, classifiable.length),
    cases,
  };
}

function lagSummary(className, marker, rows, note) {
  const lags = rows.map((row) => row.lagMs).filter(Number.isFinite);
  return {
    className,
    gameplayMarker: marker,
    instances: rows,
    supportCount: lags.length,
    closeLagMs: {
      min: rounded(Math.min(...lags)),
      median: rounded(median(lags)),
      max: rounded(Math.max(...lags)),
    },
    note,
  };
}

function buildCloseLagFindings(labeledClusters) {
  const byClass = (pattern) => labeledClusters.filter((cluster) => pattern.test(cluster.actor.className));
  const signalLagRows = (pattern, field, fromMs, toMs, humanFilter = () => true) =>
    byClass(pattern).filter(humanFilter).flatMap((cluster) => {
      const signal = directActorSignals(cluster, { field, fromMs, toMs }).at(-1);
      return signal ? [{ id: cluster.id, lagMs: -signal.offsetMs, markerTimeMs: signal.timeMs, closeTimeMs: cluster.actor.closedAtMs }] : [];
    });
  const rows = [
    lagSummary(
      'GameObject_SoundSensor_SweetSpotFissure',
      'actor OPEN / fissure effect spawn (true trigger marker)',
      byClass(/^GameObject_SoundSensor_SweetSpotFissure$/).map((cluster) => ({
        id: cluster.id,
        lagMs: cluster.actor.observedLifetimeMs,
        markerTimeMs: cluster.actor.timeMs,
        closeTimeMs: cluster.actor.closedAtMs,
      })),
      'The close is the end of the replicated fissure effect. Two not-found comments are therefore expected when seeking at close time.',
    ),
    lagSummary(
      'Projectile_Killjoy_4_RemoteBees_MultiDetonate',
      'actor MulticastPlayOneShotEffect (detonation)',
      signalLagRows(
        /^Projectile_Killjoy_4_RemoteBees_MultiDetonate$/,
        /MulticastPlayOneShotEffect/i,
        -1_900,
        -1_700,
      ),
      'The projectile persists for the damaging/visual linger after detonation.',
    ),
    lagSummary(
      'Pawn_Killjoy_Q_StealthAlarmbot',
      'actor MulticastPlayOneShotEffect (trigger/detonation)',
      signalLagRows(
        /^Pawn_Killjoy_Q_StealthAlarmbot$/,
        /MulticastPlayOneShotEffect/i,
        -720,
        -600,
        (cluster) => expectedOutcomeForLabel({ tag: cluster.humanLabel.tag }) === 'phase-transition',
      ),
      'Only the two triggered labels have this ~0.66 s terminal offset; the destroyed label does not.',
    ),
    lagSummary(
      'GameObject_Nox_WallTrap',
      'actor MulticastTransitionToState / wall actor OPEN',
      byClass(/^GameObject_Nox_WallTrap$/)
        .filter((cluster) => expectedOutcomeForLabel({ tag: cluster.humanLabel.tag }) === 'phase-transition')
        .map((cluster) => {
          const signal = directActorSignals(cluster, { field: /MulticastTransitionToState/i, fromMs: -500, toMs: -300 }).at(-1);
          return signal ? { id: cluster.id, lagMs: -signal.offsetMs, markerTimeMs: signal.timeMs, closeTimeMs: cluster.actor.closedAtMs } : null;
        })
        .filter(Boolean),
      'The wall opens at the trigger while the trap channel lingers another 415 ms.',
    ),
    lagSummary(
      'Projectile_Nox_BarbedWire',
      'MulticastStopProjectile + GameObject_Nox_BarbedWire OPEN (landing)',
      byClass(/^Projectile_Nox_BarbedWire$/).map((cluster) => {
        const signal = directActorSignals(cluster, { field: /MulticastStopProjectile/i, fromMs: -1_100, toMs: -900 }).at(-1);
        return signal ? { id: cluster.id, lagMs: -signal.offsetMs, markerTimeMs: signal.timeMs, closeTimeMs: cluster.actor.closedAtMs } : null;
      }).filter(Boolean),
      'Landing creates the placed object; the projectile channel remains for about one second until priming completes.',
    ),
    lagSummary(
      'Patch_Aggrobot_C_ExplodeyPatch',
      'GameObject_Aggrobot_Reclaim_Orb_ExplodeyPatch OPEN',
      byClass(/^Patch_Aggrobot_C_ExplodeyPatch$/).map((cluster) => {
        const open = cluster.nearbyOpens.find((candidate) => /^GameObject_Aggrobot_Reclaim_Orb_ExplodeyPatch$/.test(candidate.actor.className));
        return open ? { id: cluster.id, lagMs: -open.offsetMs, markerTimeMs: open.actor.timeMs, closeTimeMs: cluster.actor.closedAtMs } : null;
      }).filter(Boolean),
      'The reclaim blob overlaps the final two seconds of the patch actor; actor lifetimes are overlapping phases, not a strictly serialized chain.',
    ),
  ];

  const visualCommentMarkers = [
    { id: '1fb53a2c_19134_966265', visualTime: '16:01', visualTimeMs: 961_000 },
    { id: '1fb53a2c_26080_1264178', visualTime: '20:59', visualTimeMs: 1_259_000 },
    { id: '1fb53a2c_27788_1347089', visualTime: '22:27', visualTimeMs: 1_347_000, caveat: 'comment timestamp conflicts with the 5.502 s wire lifetime and appears to identify the close' },
    { id: 'd3c0e7a2_15998_705977', visualTime: '11:46', visualTimeMs: 706_000 },
    { id: 'd3c0e7a2_16020_710977', visualTime: '11:51', visualTimeMs: 711_000 },
    { id: 'd3c0e7a2_12544_535736', visualTime: '8:56', visualTimeMs: 536_000 },
    { id: 'd3c0e7a2_22460_1023409', visualTime: '17:03', visualTimeMs: 1_023_000 },
    { id: 'd3c0e7a2_3134_40598', visualTime: '0:41', visualTimeMs: 41_000 },
    { id: 'd3c0e7a2_4970_115542', visualTime: '1:56', visualTimeMs: 116_000 },
    { id: 'd3c0e7a2_6256_183132', visualTime: '3:03', visualTimeMs: 183_000 },
  ].map((marker) => {
    const cluster = labeledClusters.find((row) => row.id === marker.id);
    return {
      ...marker,
      closeTimeMs: cluster?.actor.closedAtMs ?? null,
      closeMinusRoundedVisualMs: cluster ? cluster.actor.closedAtMs - marker.visualTimeMs : null,
      note: 'viewer comments are rounded to whole seconds; use wire markers for precise lag',
    };
  });
  return { byClass: rows, visualCommentMarkers };
}

function markdownEscape(value) {
  return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ');
}

function classDiffs(labeledClassifications) {
  const groups = new Map();
  for (const row of labeledClassifications) {
    if (!groups.has(row.actor.className)) groups.set(row.actor.className, []);
    groups.get(row.actor.className).push(row);
  }
  return [...groups.entries()].map(([className, rows]) => ({
    className,
    agent: rows[0].humanGroundTruth.agent ?? rows[0].actor.agent,
    abilityName: rows[0].humanGroundTruth.abilityName ?? rows[0].actor.abilityName,
    labeledInstances: rows.length,
    humanOutcomes: countsObject(rows.map((row) => row.humanGroundTruth.expectedOutcome)),
    modelOutcomes: countsObject(rows.map((row) => row.outcome)),
    lifetimeMs: {
      min: rounded(Math.min(...rows.map((row) => row.actor.observedLifetimeMs))),
      median: rounded(median(rows.map((row) => row.actor.observedLifetimeMs))),
      max: rounded(Math.max(...rows.map((row) => row.actor.observedLifetimeMs))),
    },
    rules: countsObject(rows.map((row) => row.ruleId)),
  })).sort((left, right) => left.agent.localeCompare(right.agent) || left.abilityName.localeCompare(right.abilityName) || left.className.localeCompare(right.className));
}

function coverageSummary(classifications, initializationNoiseExcluded, rawUtilityRows, eligibleUtilityRows) {
  const byConfidence = countsObject(classifications.map((row) => row.confidence));
  const byOutcome = countsObject(classifications.map((row) => row.outcome));
  const byReplay = [];
  for (const replayUuid of [...new Set(classifications.map((row) => row.replayUuid))].sort()) {
    const rows = classifications.filter((row) => row.replayUuid === replayUuid);
    byReplay.push({
      replayUuid,
      closes: rows.length,
      high: rows.filter((row) => row.confidence === 'high').length,
      medium: rows.filter((row) => row.confidence === 'medium').length,
      low: rows.filter((row) => row.confidence === 'low').length,
      unclassifiable: rows.filter((row) => row.outcome === 'unclassifiable').length,
    });
  }
  const classifiable = classifications.filter((row) => row.outcome !== 'unclassifiable').length;
  return {
    rawUtilityActorRows: rawUtilityRows,
    initializationNoiseExcluded,
    eligibleUtilityActorRows: eligibleUtilityRows,
    utilityActorCloses: classifications.length,
    classifiable,
    unclassifiable: classifications.length - classifiable,
    classifiableFraction: fraction(classifiable, classifications.length),
    byConfidence,
    byOutcome,
    byReplay,
  };
}

async function sha256File(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return null;
  return await new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

function slug(value) {
  return normalize(value)
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
}

function buildProposedRegistry(labeledClassifications, clusterById, replayHashes) {
  const groups = new Map();
  for (const classification of labeledClassifications) {
    const registryAgent = classification.humanGroundTruth.agent ?? classification.actor.agent;
    const registryAbility = classification.humanGroundTruth.abilityName ?? classification.actor.abilityName;
    const key = `${registryAgent}\u0000${registryAbility}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(classification);
  }
  return {
    version: 1,
    status: 'proposal-only',
    generatedAt: new Date().toISOString(),
    source: {
      humanLabels: LABELS_PATH,
      signatureStudy: FINDINGS_PATH,
      classifications: CLOSE_SIGNATURES_PATH,
      warning: 'Do not merge automatically; this file intentionally does not modify verified_ability_lifecycle_registry.json.',
    },
    evidenceClasses: ['observed', 'derived', 'fallback', 'absent'],
    abilities: [...groups.values()].map((rows) => {
      const first = rows[0];
      const registryAgent = first.humanGroundTruth.agent ?? first.actor.agent;
      const registryAbility = first.humanGroundTruth.abilityName ?? first.actor.abilityName;
      const observedOutcomes = [...new Set(rows.map((row) => row.humanGroundTruth.expectedOutcome))].sort();
      const actorRules = [...new Map(rows.map((row) => [row.actor.className, {
        classPattern: `^${row.actor.className.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`,
        phase: row.actor.phase,
        utilityKind: row.actor.utilityKind,
        timingPolicy:
          /^GameObject_SoundSensor_SweetSpotFissure$/.test(row.actor.className)
            ? 'observed-actor-open-plus-fixed-linger'
            : row.chainLink
              ? 'observed-actor-chain'
              : 'observed-parent-or-actor-signal',
        fallbackLifetimeMs:
          /^GameObject_SoundSensor_SweetSpotFissure$/.test(row.actor.className)
            ? 5_500
            : /^GameObject_Aggrobot_(?:X_)?Reclaim_Orb/.test(row.actor.className)
              ? 20_000
              : null,
        source: `proposed-signature-study:${slug(registryAgent)}.${slug(registryAbility)}`,
      }])).values()];
      const verifiedCases = rows
        .sort((left, right) => left.timeMs - right.timeMs)
        .map((row) => {
          const cluster = clusterById.get(row.id);
          return {
            caseId: `${row.outcome}-${row.replayUuid.slice(0, 8)}-${row.actor.actorNetGuid}-${row.timeMs}`,
            eventType: row.outcome,
            replayId: row.replayUuid,
            replaySha256: replayHashes.get(row.replayUuid) ?? null,
            actorNetGuid: row.actor.actorNetGuid,
            channelIndex: row.actor.chIndex,
            className: row.actor.className,
            observedStartMs: row.actor.timeMs,
            observedEndMs: row.timeMs,
            nextRoundStartMs: cluster?.round.nextRoundStartMs ?? null,
            activationEvidence: row.evidence[0]?.signal ?? 'observed actor close',
            expectedPhase: row.actor.phase,
            expectedEndReason: row.outcome,
            signal: {
              ruleId: row.ruleId,
              signatureIds: row.signatureIds,
              confidence: row.confidence,
              evidence: row.evidence,
              chainLink: row.chainLink,
            },
            humanGroundTruth: row.humanGroundTruth,
            verifiedBy: row.humanGroundTruth.rawTag === 'not-found'
              ? 'official-replay-viewer-comment-adjudication+wire-timing'
              : 'official-replay-viewer-human-tag+wire-signature-study',
          };
        });
      return {
        abilityId: `${slug(registryAgent)}.${slug(registryAbility)}`,
        agent: registryAgent,
        abilityName: registryAbility,
        status: 'proposed',
        actorRules,
        verifiedCases,
        unknownCases: OUTCOMES
          .filter((outcome) => outcome !== 'unclassifiable' && !observedOutcomes.includes(outcome)),
      };
    }).sort((left, right) => left.agent.localeCompare(right.agent) || left.abilityName.localeCompare(right.abilityName)),
  };
}

function chainGraphLine(graph) {
  return graph.graph.map((edge) =>
    `${edge.fromClass} --${edge.observedHandoffs}x, gap ${edge.gapMs.min}..${edge.gapMs.max} ms--> ${edge.toClass}`,
  ).join('; ');
}

function renderFindings(results) {
  const lines = [
    '# Utility-close wire signature findings',
    '',
    `Generated ${results.meta.generatedAt} from ${results.meta.replayCount} replays and ${results.validation.humanLabelCount} human-tagged closes.`,
    '',
    '## Result',
    '',
    `The wire-rule model classifies **${results.validation.trainingAgreement.correct}/${results.validation.trainingAgreement.classifiable}** adjudicated human labels correctly. The three raw \`not-found\` tags are observation-status labels; their comments and wire timing resolve them to phase transitions. Literal agreement on the other tags is **${results.validation.literalTagAgreement.correct}/${results.validation.literalTagAgreement.classifiable}**.`,
    '',
    `Corpus-wide, ${results.coverage.classifiable}/${results.coverage.utilityActorCloses} non-initialization utility closes are classifiable (${(results.coverage.classifiableFraction * 100).toFixed(1)}%): ${results.coverage.byConfidence.high ?? 0} high, ${results.coverage.byConfidence.medium ?? 0} medium, ${results.coverage.byConfidence.low ?? 0} low, and ${results.coverage.unclassifiable} unclassifiable.`,
    '',
    '> Data note: the JSON label manifest contains 13 `destroyed` tags, although the task summary says 12. This study uses the 48 rows on disk.',
    '',
    '## Signature support by outcome',
    '',
  ];
  for (const outcome of OUTCOMES.filter((value) => value !== 'unclassifiable')) {
    const signatures = results.signatures.filter((signature) => signature.outcome === outcome);
    lines.push(`### ${outcome}`, '');
    if (!signatures.length) {
      lines.push('No reusable positive signature was established.', '');
      continue;
    }
    lines.push('| Signature | Status | Human support | Contradictions | Corpus matches | Signal |', '|---|---|---:|---:|---:|---|');
    for (const signature of signatures) {
      lines.push(`| ${markdownEscape(signature.title)} | ${signature.status} | ${signature.support.labeledSupportingInstances} | ${signature.support.labeledContradictions} | ${signature.support.corpusMatches} | ${markdownEscape(signature.description)} |`);
    }
    lines.push('');
  }
  lines.push(
    'Support language is deliberate: **established** means at least three agreeing human instances and no contradiction; **supported** means two; **hypothesis** means one. A semantic-looking RPC with one label is not promoted beyond hypothesis.',
    '',
    '## Class-by-class labeled diffs',
    '',
    '| Agent / ability | Actor class | n | Human outcomes | Lifetime ms (min/median/max) | Applied discriminators |',
    '|---|---|---:|---|---:|---|',
  );
  for (const row of results.classDiffs) {
    const human = Object.entries(row.humanOutcomes).map(([key, value]) => `${key}:${value}`).join(', ');
    const rules = Object.entries(row.rules).map(([key, value]) => `${key}:${value}`).join(', ');
    lines.push(`| ${markdownEscape(`${row.agent} / ${row.abilityName}`)} | ${markdownEscape(row.className)} | ${row.labeledInstances} | ${markdownEscape(human)} | ${row.lifetimeMs.min}/${row.lifetimeMs.median}/${row.lifetimeMs.max} | ${markdownEscape(rules)} |`);
  }
  lines.push('', '## Actor chain graphs', '');
  for (const graph of results.chainGraphs) {
    lines.push(`- **${graph.agent} / ${graph.abilityName}:** ${markdownEscape(chainGraphLine(graph))}`);
  }
  lines.push(
    '',
    `All emitted chain instances remain within one round and have gaps from -2,000 to +2,000 ms; spatial mismatches: ${results.validation.chainSanity.spatialMismatches}. Negative gaps are real phase overlap. Projectile spatial checks use launch velocity projected in XY because utility actor samples retain launch position. ${results.validation.chainSanity.movingActorEndpointUnavailable} moving Gekko-pawn handoffs have typed exact-tick successors but no decoded endpoint, and ${results.validation.chainSanity.sameTickWireHandoffsWithoutPosition} same-tick channel handoffs expose no successor transform.`,
    '',
    '## Close-lag / true gameplay markers',
    '',
    '| Actor class | True gameplay marker | n | Close lag min / median / max | Interpretation |',
    '|---|---|---:|---:|---|',
  );
  for (const row of results.closeLag.byClass) {
    lines.push(`| ${markdownEscape(row.className)} | ${markdownEscape(row.gameplayMarker)} | ${row.supportCount} | ${row.closeLagMs.min}/${row.closeLagMs.median}/${row.closeLagMs.max} ms | ${markdownEscape(row.note)} |`);
  }
  lines.push(
    '',
    'Viewer-comment timestamps are whole-second approximations. The exact per-label comparisons, including the one Deadlock comment that conflicts with the replicated 5.502 s actor lifetime, are in `close_signatures.json`.',
    '',
    '## Validation',
    '',
    `- Adjudicated training-set agreement: **${results.validation.trainingAgreement.correct}/${results.validation.trainingAgreement.classifiable}** (${results.validation.trainingAgreement.incorrect} errors). No label-ID override is used; rules key on class, state/RPC, timing, chain, and round context.`,
    `- Literal comparable-tag agreement: **${results.validation.literalTagAgreement.correct}/${results.validation.literalTagAgreement.classifiable}**. The three \`not-found\` rows are excluded from this literal metric and retained separately.`,
    `- Leave-one-out class-majority baseline: **${results.validation.leaveOneOut.correct}/${results.validation.leaveOneOut.classifiable}** among classifiable holds. This intentionally weak baseline shows how much the wire signals add beyond memorizing class outcomes.`,
    `- Label coverage: **${results.validation.labelIdsPresent}/${results.validation.humanLabelCount}** IDs present exactly once in the classification file.`,
    '',
    '## Corpus-wide coverage',
    '',
    `The scope starts with ${results.coverage.rawUtilityActorRows} classified utility-actor rows, removes the same ${results.coverage.initializationNoiseExcluded} initialization/noise rows as the correlation study, and evaluates all ${results.coverage.utilityActorCloses} remaining observed closes.`,
    '',
    '| Confidence / status | Count |',
    '|---|---:|',
    `| high | ${results.coverage.byConfidence.high ?? 0} |`,
    `| medium | ${results.coverage.byConfidence.medium ?? 0} |`,
    `| low | ${results.coverage.byConfidence.low ?? 0} |`,
    `| unclassifiable | ${results.coverage.unclassifiable} |`,
    '',
    '| Outcome | Count |',
    '|---|---:|',
  );
  for (const [outcome, count] of Object.entries(results.coverage.byOutcome)) {
    lines.push(`| ${outcome} | ${count} |`);
  }
  lines.push(
    '',
    '## Stored signal-layer coverage',
    '',
    '| Replay | Ability signals | Overflow | Owner inputs | Input overflow | Identity links (last ms) | Generic ClassNetCache preview (last ms) |',
    '|---|---:|---:|---:|---:|---:|---:|',
  );
  for (const row of results.signalLayerCoverage) {
    lines.push(`| ${row.replayUuid.slice(0, 8)} | ${row.abilitySignalSampleCount} | ${row.abilitySignalOverflowCount} | ${row.nonMovementInputSampleCount} | ${row.nonMovementInputOverflowCount} | ${row.identityLinkSampleCount} (${row.identityLinkLastTimeMs}) | ${row.genericClassNetCacheSampleCount} (${row.genericClassNetCacheLastTimeMs}) |`);
  }
  lines.push(
    '',
    'The ability-signal and non-movement-input layers have zero overflow in all seven replays. The generic ClassNetCache preview and some identity-link arrays are capped; parent/actor ability signals remain complete, so targeted replay extraction would duplicate the discriminating layer rather than add it.',
    '',
    '## Open questions',
    '',
    '1. **Destroyed versus self-completed Gekko pawns.** Thrash and Wingman open reclaim-orb successors in both cases. A foreign weapon NetGUID reference distinguishes the single destroyed Thrash, and short lifetime distinguishes the single destroyed Wingman, but both remain medium-confidence hypotheses until more labeled examples expose a damage-source field or RPC.',
    '2. **Silent destruction of Turret and some Spycam actors.** Their channels can close without a decoded terminal HP/damage property. Current medium-confidence rules use class contrast plus the absence of recall/round signatures; targeted damage-component decoding would make these positive signatures.',
    '3. **Projectile endpoint and late owner-link fidelity.** Launch-position projection validates the observed phase pairs in XY, but a decoded terminal transform would make same-location chaining direct. Some late identity-link samples are capped, so unique-agent owner inference is used where the complete ability-signal layer still identifies the parent state.',
    '',
    '## Reproduction',
    '',
    'From `tools/valorant_replay_probe/`:',
    '',
    '```powershell',
    'node --expose-gc --max-old-space-size=6144 .\\corr_extract_close_wire_clusters.mjs',
    'node --expose-gc --max-old-space-size=6144 .\\corr_classify_utility_closes.mjs',
    '```',
    '',
    'No targeted replay re-extraction was required: all seven stored `abilitySignalSamples` layers report zero overflow and contain the relevant actor/parent RepLayout and ClassNetCache RPC signals. The generic `classNetCacheSamples` preview is capped, so it is treated only as a supplemental copy; the complete filtered ability-signal layer is the authoritative wire source.',
    '',
  );
  return lines.join('\n');
}

async function main() {
  const generatedAt = new Date().toISOString();
  const labelsDocument = JSON.parse(fs.readFileSync(LABELS_PATH, 'utf8'));
  const schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, 'utf8'));
  const correlation = JSON.parse(fs.readFileSync(CORRELATION_RESULTS_PATH, 'utf8'));
  const schemaByKey = schemaIndex(schema);
  const labelsByClose = new Map((labelsDocument.tags ?? []).map((label) => [
    closeKey(label.replayUuid, label.actorNetGuid, label.timeMs),
    label,
  ]));
  const expiryPriorByClose = new Map((correlation.expiryLabels?.instances ?? []).map((instance) => [
    closeKey(instance.replayUuid, instance.actorNetGuid, instance.timeMs),
    instance,
  ]));

  const classifications = [];
  const labeledClusters = [];
  const replayInputPaths = new Map();
  const signalLayerCoverage = [];
  let rawUtilityActorRows = 0;
  let eligibleUtilityActorRows = 0;
  let initializationNoiseExcluded = 0;

  for (const replayUuid of replayDirectories()) {
    const evidence = loadReplayEvidence(replayUuid);
    replayInputPaths.set(replayUuid, evidence.diagnostics.inputPath ?? null);
    signalLayerCoverage.push({
      replayUuid,
      abilitySignalSampleCount: evidence.abilitySignals.length,
      abilitySignalOverflowCount: evidence.frame.abilitySignalOverflowCount ?? 0,
      nonMovementInputSampleCount: evidence.inputEvents.length,
      nonMovementInputOverflowCount:
        evidence.frame.nonMovementInputEventSummary?.overflowCount ??
        evidence.frame.nonMovementInputEventOverflowCount ?? 0,
      identityLinkSampleCount: evidence.identityLinks.length,
      identityLinkLastTimeMs: evidence.identityLinks.at(-1)?.timeMs ?? null,
      genericClassNetCacheSampleCount: evidence.classNetCacheSamples.length,
      genericClassNetCacheLastTimeMs: evidence.classNetCacheSamples.at(-1)?.timeMs ?? null,
    });
    const rawActors = evidence.utilityActors;
    const actors = rawActors.filter((actor) => !isSuspectedNoise(actor));
    const closes = actors.filter((actor) => Number.isFinite(actor.closedAtMs));
    rawUtilityActorRows += rawActors.length;
    eligibleUtilityActorRows += actors.length;
    initializationNoiseExcluded += rawActors.length - actors.length;

    const closeGroups = new Map();
    for (const actor of closes) {
      if (!closeGroups.has(actor.closedAtMs)) closeGroups.set(actor.closedAtMs, []);
      closeGroups.get(actor.closedAtMs).push(actor);
    }

    for (const actor of closes) {
      const label = labelsByClose.get(closeKey(replayUuid, actor.actorNetGuid, actor.closedAtMs)) ?? null;
      const cluster = extractCloseCluster(evidence, actor, label, {
        signalBeforeMs: 6_000,
        signalAfterMs: 250,
        inputBeforeMs: 3_000,
        inputAfterMs: 250,
        nearbyBeforeMs: 2_000,
        nearbyAfterMs: 2_000,
      });
      const chainLink = deriveChainLink(cluster);
      const simultaneous = closeGroups.get(actor.closedAtMs) ?? [];
      const closeBurst = {
        total: simultaneous.length,
        sameAbility: simultaneous.filter((candidate) =>
          normalize(candidate.agent) === normalize(actor.agent) &&
          normalize(candidate.abilityName) === normalize(actor.abilityName)).length,
      };
      const schemaRecord = schemaRecordForActor(actor, schemaByKey);
      const expiryPrior = expiryPriorByClose.get(closeKey(replayUuid, actor.actorNetGuid, actor.closedAtMs)) ?? null;
      const classificationContext = {
        chainLink,
        schemaRecord,
        expiryPrior,
        closeBurst,
      };
      const model = classifyCorpusCloseCluster(
        cluster,
        classificationContext,
        classifyCluster,
      );
      const id = label?.id ?? `${replayUuid.slice(0, 8)}_${actor.actorNetGuid}_${actor.closedAtMs}`;
      const humanGroundTruth = label ? {
        rawTag: label.tag,
        comment: label.comment ?? '',
        agent: label.agent ?? null,
        slot: label.slot ?? null,
        abilityName: label.abilityName ?? null,
        actorClass: label.actorClass ?? null,
        expectedOutcome: expectedOutcomeForLabel(label),
        normalization:
          label.tag === 'not-found'
            ? 'comment-adjudicated observation-status -> phase-transition'
            : label.tag === 'phase-transition-or-other-early-removal'
              ? 'tag alias -> phase-transition'
              : 'identity',
        modelMatches: model.outcome === expectedOutcomeForLabel(label),
      } : null;
      const classification = {
        id,
        replayUuid,
        round: cluster.round.round,
        timeMs: actor.closedAtMs,
        actor: publicActor(cluster.actor),
        outcome: model.outcome,
        confidence: model.confidence,
        ruleId: model.ruleId,
        signatureIds: model.signatureIds,
        evidence: model.evidence,
        chainLink,
        caveats: model.caveats,
        context: {
          ownerResolution: cluster.ownerResolution,
          ownerPlayer: cluster.ownerPlayer,
          closeBurst,
          closeToNextRoundStartMs: cluster.round.closeToNextRoundStartMs,
          abilitySignalCountInCluster: cluster.wireSignals.length,
          rawClassNetCacheCallsInCluster: cluster.rawClassNetCacheCalls.length,
          expiryPrior: expiryPrior ? {
            label: expiryPrior.label,
            expectedLifetimeMs: expiryPrior.expectedLifetimeMs,
            deltaMs: expiryPrior.deltaMs,
          } : null,
          schema: schemaRecord ? {
            agentName: schemaRecord.agentName,
            slot: schemaRecord.slot,
            abilityName: schemaRecord.abilityName,
            maxLifetimeSeconds: schemaRecord.maxLifetimeSeconds,
            destroyable: schemaRecord.destroyable,
            recallable: schemaRecord.recallable,
            pickupable: schemaRecord.pickupable,
          } : null,
        },
        humanGroundTruth,
      };
      classifications.push(classification);
      if (label) {
        labeledClusters.push({
          ...cluster,
          modelClassification: {
            outcome: model.outcome,
            confidence: model.confidence,
            ruleId: model.ruleId,
            signatureIds: model.signatureIds,
            evidence: model.evidence,
            chainLink,
            matchesAdjudicatedHumanOutcome: humanGroundTruth.modelMatches,
          },
        });
      }
    }

    evidence.diagnostics = null;
    evidence.frame = null;
    evidence.abilitySignals.length = 0;
    evidence.inputEvents.length = 0;
    evidence.identityLinks.length = 0;
    evidence.utilityActors.length = 0;
    evidence.utilityCloses.length = 0;
    evidence.classNetCacheSamples.length = 0;
    if (global.gc) global.gc();
  }

  classifications.sort((left, right) =>
    left.replayUuid.localeCompare(right.replayUuid) || left.timeMs - right.timeMs ||
    left.actor.actorNetGuid - right.actor.actorNetGuid);
  labeledClusters.sort((left, right) =>
    left.replayUuid.localeCompare(right.replayUuid) || left.actor.closedAtMs - right.actor.closedAtMs);
  const labeledClassifications = classifications.filter((row) => row.humanGroundTruth);
  const trainingCorrect = labeledClassifications.filter((row) => row.humanGroundTruth.modelMatches).length;
  const literalComparable = labeledClassifications.filter((row) => row.humanGroundTruth.rawTag !== 'not-found');
  const literalExpected = (rawTag) => rawTag === 'phase-transition-or-other-early-removal'
    ? 'phase-transition'
    : rawTag;
  const literalCorrect = literalComparable.filter((row) =>
    row.outcome === literalExpected(row.humanGroundTruth.rawTag)).length;
  const labelMultiplicity = new Map();
  for (const row of labeledClassifications) addCount(labelMultiplicity, row.id);
  const expectedLabelIds = new Set((labelsDocument.tags ?? []).map((label) => label.id));
  const labelIdsPresent = [...expectedLabelIds].filter((id) => labelMultiplicity.get(id) === 1).length;

  const chainGraphs = buildChainGraphs(classifications);
  const signatures = buildSignatureSupport(classifications);
  const closeLag = buildCloseLagFindings(labeledClusters);
  const coverage = coverageSummary(
    classifications,
    initializationNoiseExcluded,
    rawUtilityActorRows,
    eligibleUtilityActorRows,
  );
  const leaveOneOut = classMajorityLeaveOneOut(labeledClassifications);
  const validation = {
    humanLabelCount: labelsDocument.tags?.length ?? 0,
    manifestTagCounts: countsObject((labelsDocument.tags ?? []).map((label) => label.tag)),
    taskSummaryCountMismatch: {
      taskSaysDestroyed: 12,
      manifestDestroyed: (labelsDocument.tags ?? []).filter((label) => label.tag === 'destroyed').length,
      resolution: 'manifest rows are authoritative; all 48 IDs are retained',
    },
    labelIdsPresent,
    duplicateOrMissingLabelIds: [...expectedLabelIds]
      .filter((id) => labelMultiplicity.get(id) !== 1)
      .map((id) => ({ id, occurrences: labelMultiplicity.get(id) ?? 0 })),
    trainingAgreement: {
      classifiable: labeledClassifications.length,
      correct: trainingCorrect,
      incorrect: labeledClassifications.length - trainingCorrect,
      accuracy: fraction(trainingCorrect, labeledClassifications.length),
      errors: labeledClassifications
        .filter((row) => !row.humanGroundTruth.modelMatches)
        .map((row) => ({ id: row.id, expected: row.humanGroundTruth.expectedOutcome, actual: row.outcome, ruleId: row.ruleId })),
    },
    literalTagAgreement: {
      classifiable: literalComparable.length,
      correct: literalCorrect,
      incorrect: literalComparable.length - literalCorrect,
      excludedNotFound: labeledClassifications.length - literalComparable.length,
      accuracy: fraction(literalCorrect, literalComparable.length),
    },
    leaveOneOut,
    chainSanity: {
      crossRoundLinks: classifications.filter((row) => row.chainLink && !row.chainLink.sameRound).length,
      linksOutsideTwoSecondWindow: classifications.filter((row) =>
        row.chainLink && (row.chainLink.gapMs < -2_000 || row.chainLink.gapMs > 2_000)).length,
      spatialMismatches: classifications.filter((row) =>
        row.chainLink?.spatialStatus === 'projected-xy-mismatch').length,
      movingActorEndpointUnavailable: classifications.filter((row) =>
        row.chainLink?.spatialStatus === 'moving-actor-endpoint-unavailable').length,
      sameTickWireHandoffsWithoutPosition: classifications.filter((row) =>
        row.chainLink?.spatialStatus === 'same-tick-wire-handoff-no-position').length,
      passed: classifications.every((row) =>
        !row.chainLink || (
          row.chainLink.sameRound &&
          row.chainLink.gapMs >= -2_000 &&
          row.chainLink.gapMs <= 2_000 &&
          row.chainLink.spatialStatus !== 'projected-xy-mismatch'
        )),
    },
  };

  const results = {
    meta: {
      schema: 'icarus-utility-close-signatures-v1',
      generatedAt,
      branch: '++Ares-Core+release-13.00',
      replayCount: replayDirectories().length,
      sourceCorpus: CORPUS_DIR,
      sourceLabels: LABELS_PATH,
      sourceLifecycleSchema: SCHEMA_PATH,
      sourcePriorCorrelation: CORRELATION_RESULTS_PATH,
      initializationNoiseFilter:
        '(timeMs <= 64 && ignoredAsAbility/ignored-initial-replication) OR pickup/cosmetic/VFX/FX path filter; matches prior study total of 188',
      targetedReextractions: 0,
      signalLayerDecision:
        'No re-extraction needed: all abilitySignalSamples layers have zero overflow and include relevant ability-path RepLayout and ClassNetCache calls. The capped generic classNetCacheSamples preview is supplemental only.',
    },
    outcomeDefinitions: {
      recalled: 'owner recall removes a persistent deployable',
      destroyed: 'enemy/environment damage or other hostile early removal',
      'picked-up': 'owner retrieves a pickupable deployable',
      'phase-transition': 'the actor closes as an ability phase hands off or a trigger/detonation linger ends',
      expired: 'a fixed natural lifetime elapses',
      'round-ended': 'round teardown removes the actor',
      unclassifiable: 'available wire evidence does not discriminate the lifecycle outcome',
    },
    validation,
    coverage,
    signalLayerCoverage,
    signatures,
    classDiffs: classDiffs(labeledClassifications),
    chainGraphs,
    closeLag,
    classifications,
    labeledWireClusters: labeledClusters,
  };

  const replayHashes = new Map();
  for (const [replayUuid, inputPath] of replayInputPaths) {
    replayHashes.set(replayUuid, await sha256File(inputPath));
  }
  const clusterById = new Map(labeledClusters.map((cluster) => [cluster.id, cluster]));
  const proposedRegistry = buildProposedRegistry(labeledClassifications, clusterById, replayHashes);

  fs.writeFileSync(CLOSE_SIGNATURES_PATH, `${JSON.stringify(results, null, 2)}\n`);
  fs.writeFileSync(PROPOSED_REGISTRY_PATH, `${JSON.stringify(proposedRegistry, null, 2)}\n`);
  fs.writeFileSync(FINDINGS_PATH, renderFindings(results));

  // Parse what was actually written so the reproducibility run fails immediately
  // on malformed or truncated output rather than relying on an in-memory object.
  const reparsed = JSON.parse(fs.readFileSync(CLOSE_SIGNATURES_PATH, 'utf8'));
  const registryReparsed = JSON.parse(fs.readFileSync(PROPOSED_REGISTRY_PATH, 'utf8'));
  if (reparsed.validation.labelIdsPresent !== (labelsDocument.tags?.length ?? 0)) {
    throw new Error(`label coverage verification failed: ${reparsed.validation.labelIdsPresent}/${labelsDocument.tags?.length ?? 0}`);
  }
  if (!reparsed.validation.chainSanity.passed) throw new Error('chain sanity verification failed');
  if (!registryReparsed.abilities?.length) throw new Error('proposed registry is empty');

  console.log(JSON.stringify({
    closeSignaturesPath: CLOSE_SIGNATURES_PATH,
    findingsPath: FINDINGS_PATH,
    proposedRegistryPath: PROPOSED_REGISTRY_PATH,
    agreement: `${trainingCorrect}/${labeledClassifications.length}`,
    literalAgreement: `${literalCorrect}/${literalComparable.length}`,
    coverage,
    establishedSignatures: signatures.filter((signature) => signature.status === 'established').length,
    chainGraphs: chainGraphs.length,
    verification: {
      jsonParsed: true,
      labelIdsPresent,
      chainSanity: validation.chainSanity,
    },
  }, null, 2));
}

const invokedPath = process.argv[1] == null ? null : path.resolve(process.argv[1]);
if (invokedPath && invokedPath.toLowerCase() === fileURLToPath(import.meta.url).toLowerCase()) {
  main().catch((error) => {
    console.error(error.stack ?? error);
    process.exitCode = 1;
  });
}
