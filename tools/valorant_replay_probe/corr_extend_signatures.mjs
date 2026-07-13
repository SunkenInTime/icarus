#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

import {
  CORPUS_DIR,
  extractCloseCluster,
  isSuspectedNoise,
  loadReplayEvidence,
  replayDirectories,
} from './corr_extract_close_wire_clusters.mjs';
import { loadCloseSignatureRules } from './lib/close_signature_classifier.mjs';

const V1_PATH = path.join(CORPUS_DIR, 'close_signatures.v1.json');
const CURRENT_PATH = path.join(CORPUS_DIR, 'close_signatures.json');
const CORRELATION_PATH = path.join(CORPUS_DIR, 'correlation_results.json');
const ANALYSIS_PATH = path.join(CORPUS_DIR, 'unclassified_analysis.md');
const WORKLIST_PATH = path.join(CORPUS_DIR, 'unclassified_tagging_worklist.json');

const LEGACY_FIXED_LIFETIME_SIGNATURES = [
  { id: 'reyna-leer-actor-natural-timeout', className: 'GameObject_Vampire_4_NearsightAOE_Source', expectedMs: 2_000, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 1_600, note: 'the replicated source actor retains a consistent ~0.4 s tail after the documented 1.6 s Leer window' },
  { id: 'jett-cloudburst-zone-natural-timeout', className: 'GameObject_Wushu_4_SmokeZone', expectedMs: 3_000, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 2_500, note: 'the zone actor retains a consistent ~0.5 s replication tail after the documented smoke duration' },
  { id: 'jett-cloudburst-projectile-wrapper-timeout', className: 'Projectile_Wushu_4_Smoke', expectedMs: 3_505, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 2_500, note: 'the directly spawned projectile/wrapper persists across the zone and closes on its fixed wrapper timer' },
  { id: 'clove-ruse-smoke-natural-timeout', className: 'GameObject_Smonk_NewSmoke', expectedMs: 15_000, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 14_000, note: 'the smoke actor retains a consistent ~1.0 s replication tail' },
  { id: 'clove-post-death-ruse-smoke-natural-timeout', className: 'GameObject_Smonk_NewSmoke_PDS', expectedMs: 7_000, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 6_000, note: 'the post-death smoke actor retains a consistent ~1.0 s replication tail after the documented six-second cast' },
  { id: 'sage-barrier-segment-natural-timeout', className: 'GameObject_Thorne_E_Wall_Segment_Fortifying', expectedMs: 41_000, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 40_000, note: 'the destroyable segment reaches the documented 40 s maximum plus a consistent ~1.0 s actor tail' },
  { id: 'sage-barrier-parent-natural-timeout', className: 'GameObject_Thorne_E_Wall_Fortifying', expectedMs: 41_000, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 40_000, note: 'the wall parent reaches the documented 40 s maximum plus a consistent ~1.0 s actor tail' },
  { id: 'brimstone-sky-smoke-natural-timeout', className: 'GameObject_Sarge_4_Smoke_ProductionNEW', expectedMs: 20_750, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 19_250, note: 'the actor retains a consistent ~1.5 s tail after the documented smoke duration' },
  { id: 'miks-waveform-smoke-natural-timeout', className: 'GameObject_Iris_E_Smoke', expectedMs: 17_750, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 16_750, note: 'the actor retains a consistent ~1.0 s replication tail' },
  { id: 'omen-dark-cover-natural-timeout', className: 'Zone_Wraith_4_Smoke', expectedMs: 16_000, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 15_000, note: 'the zone retains a consistent ~1.0 s replication tail' },
  { id: 'brimstone-stim-beacon-field-timeout', className: 'GameObject_Sarge_E_SpeedStim', expectedMs: 13_315, toleranceMs: 25, confidence: 'high', status: 'established', schemaMs: 12_000, note: 'all stored field actors close on one narrow timer after the documented 12 s field' },
  { id: 'sova-recon-ping-child-timeout', className: 'GameObject_Hunter_Q_SonarPing', expectedMs: 1_870, toleranceMs: 15, confidence: 'medium', status: 'supported', schemaMs: 3_200, note: 'this is a repeated pulse child, not the destroyable Recon Bolt parent; all 69 children share the timer' },
  { id: 'neon-relay-electric-sphere-timeout', className: 'GameObject_Sprinter_Q_ElectricSphere', expectedMs: 1_000, toleranceMs: 15, confidence: 'medium', status: 'supported', schemaMs: null, note: 'the non-destroyable concuss child has a corpus-wide fixed one-second actor stage' },
  { id: 'killjoy-nanoswarm-damage-child-timeout', className: 'GameObject_Killjoy_4_BeeSwarm_Damage', expectedMs: 5_505, toleranceMs: 20, confidence: 'medium', status: 'supported', schemaMs: 4_000, note: 'the activated damage child has a consistent tail after the documented four-second active swarm' },
  { id: 'clove-meddle-decay-child-timeout', className: 'GameObject_Smonk_Q_DecayExplosion', expectedMs: 10_000, toleranceMs: 15, confidence: 'low', status: 'hypothesis', schemaMs: 5_000, note: 'the actor timer is exact but is longer than the documented debuff, so it may include a non-gameplay tail' },
  { id: 'sova-shock-bolt-explosion-child-timeout', className: 'GameObject_Hunter_4_ExplosiveBolt_Explosion', expectedMs: 4_000, toleranceMs: 15, confidence: 'low', status: 'hypothesis', schemaMs: null, note: 'the explosion child is exact across the corpus but the schema intentionally treats Shock Bolt as transient' },
  { id: 'phoenix-blaze-manager-timeout', className: 'GameObject_Phoenix_Q_FlameWallManager_Production', expectedMs: 10_688, toleranceMs: 20, confidence: 'medium', status: 'supported', schemaMs: 8_000, note: 'the manager closes on one narrow timer after the documented eight-second wall' },
  { id: 'raze-boom-bot-natural-timeout', className: 'Pawn_Clay_E_Boomba', expectedMs: 5_107, toleranceMs: 15, confidence: 'high', status: 'established', schemaMs: 5_000, note: 'the destroyable bot reaches the documented five-second maximum plus one small replay-tick tail' },
  { id: 'tejo-guided-salvo-mortar-child-timeout', className: 'GameObject_Cashew_E_AirStrikeMortar', expectedMs: 2_862, toleranceMs: 15, confidence: 'medium', status: 'supported', schemaMs: 1_600, note: 'the mortar child persists through the strike and a post-strike actor tail; all 18 instances share the timer' },
];

const LEGACY_CHAIN_SIGNATURES = [
  { id: 'sova-recon-bolt-to-ping', from: 'GameObject_Hunter_Q_SonarBolt', to: /^GameObject_Hunter_Q_SonarPing$/, minGap: -25, maxGap: 25, status: 'established' },
  { id: 'fade-haunt-projectile-to-reveal-source', from: 'Projectile_E_BountyHunter_Divebomb', to: /^GameObject_BountyHunter_E_LoSReveal_Source_Reactivate$/, minGap: -25, maxGap: 25, status: 'established' },
  { id: 'deadlock-sonic-sensor-to-fissure', from: 'GameObject_StealthingTrap_SoundSensor', to: /^GameObject_SoundSensor_SweetSpotFissure$/, minGap: -750, maxGap: -250, status: 'established' },
  { id: 'tejo-guided-salvo-missile-to-mortar', from: 'AIPawn_Cashew_E_SeekingTargetMissile', to: /^GameObject_Cashew_E_AirStrikeMortar$/, minGap: -25, maxGap: 25, status: 'established' },
  { id: 'tejo-guided-salvo-marker-to-mortar', from: 'GameObject_Cashew_E_MapMissileMarker', to: /^GameObject_Cashew_E_AirStrikeMortar$/, minGap: -25, maxGap: 25, status: 'established' },
  { id: 'tejo-guided-salvo-second-marker-to-mortar', from: 'GameObject_Cashew_E_MapMissileMarker_SecondRocket', to: /^GameObject_Cashew_E_AirStrikeMortar$/, minGap: -25, maxGap: 25, status: 'supported' },
  { id: 'raze-paint-shell-primary-to-secondary', from: 'Projectile_Clay_4_Projectile_Primary', to: /^Projectile_Clay_4_Projectile_Secondary(?:Spawner)?$/, minGap: -25, maxGap: 25, status: 'established' },
  { id: 'skye-hawk-to-flash-source', from: 'Projectile_Guide_E_HawkFlash', to: /^GameObject_Guide_E_HawkFlash_FlashSource$/, minGap: -25, maxGap: 25, status: 'established' },
  { id: 'gekko-dizzy-wave-to-orb-spawner', from: 'Projectile_E_Aggrobot_DiscTurret_PowerWave', to: /^Projectile_E_Aggrobot_OrbSpawner$/, minGap: -25, maxGap: 25, status: 'established' },
  { id: 'omen-paranoia-warning-to-projectile', from: 'GameObject_Wraith_Q_NearsightMissile_TrajectoryWarning', to: /^Projectile_Wraith_Q_NearsightMissile$/, minGap: -1_650, maxGap: -1_350, status: 'supported' },
  { id: 'iso-undercut-warning-to-projectile', from: 'GameObject_Sequoia_Q_FragileMissile_TrajectoryWarning', to: /^Projectile_Sequoia_Q_FragileMissile$/, minGap: -1_700, maxGap: -1_350, status: 'supported' },
];

const closeSignatureRules = loadCloseSignatureRules();
const FIXED_LIFETIME_SIGNATURES = closeSignatureRules.fixedTimerExpiry
  .filter((rule) => rule.id !== 'gekko-reclaim-orb-fixed-expiry' &&
    rule.id !== 'deadlock-fissure-linger-ended')
  .map((rule) => ({
    id: rule.id,
    className: rule.classPattern.replace(/^\^/, '').replace(/\$$/, ''),
    expectedMs: rule.timerMs,
    toleranceMs: rule.toleranceMs,
    confidence: rule.confidence,
    status: rule.confidence === 'high'
      ? 'established'
      : rule.confidence === 'medium'
        ? 'supported'
        : 'hypothesis',
    schemaMs: null,
    note: rule.provenance.join('; '),
  }));
const CHAIN_SIGNATURES = closeSignatureRules.chainHandoffs
  .filter((rule) => rule.provenance.some((value) =>
    value.startsWith('unclassified_analysis.md')))
  .map((rule) => ({
    id: rule.id,
    from: rule.fromPattern.replace(/^\^/, '').replace(/\$$/, ''),
    to: new RegExp(rule.toPattern),
    minGap: rule.minGapMs,
    maxGap: rule.maxGapMs,
    status: rule.confidence === 'high' ? 'established' : 'supported',
  }));

function countBy(rows, keyFn) {
  const counts = new Map();
  for (const row of rows) {
    const key = keyFn(row);
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((left, right) => right.count - left.count || left.key.localeCompare(right.key));
}

function quantile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((left, right) => left - right);
  const index = (sorted.length - 1) * fraction;
  const lower = Math.floor(index);
  const upper = Math.ceil(index);
  if (lower === upper) return sorted[lower];
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - lower);
}

function roundPhase(cluster) {
  const sinceRoundStartMs = cluster.actor.closedAtMs - cluster.round.roundStartMs;
  const toNextRoundMs = cluster.round.closeToNextRoundStartMs;
  if (Number.isFinite(toNextRoundMs) && toNextRoundMs >= 8_000 && toNextRoundMs <= 14_500) {
    return 'round-end-window';
  }
  if (Number.isFinite(sinceRoundStartMs) && sinceRoundStartMs <= 30_000) return 'buy-phase';
  return 'mid-round';
}

function lifetimeBand(lifetimeMs) {
  if (!Number.isFinite(lifetimeMs)) return 'unknown';
  if (lifetimeMs < 1_000) return '<1s';
  if (lifetimeMs < 3_000) return '1-3s';
  if (lifetimeMs < 8_000) return '3-8s';
  if (lifetimeMs < 16_000) return '8-16s';
  if (lifetimeMs < 30_000) return '16-30s';
  return '>=30s';
}

function layerSummary(cluster, ownerVote) {
  const rpc = cluster.wireSignals.some((signal) => signal.source === 'classnet-rpc');
  const rep = cluster.wireSignals.some((signal) => signal.source === 'rep-layout');
  const chainCandidate = cluster.nearbyOpens.some((open) => open.sameRound && open.sameAbility);
  return {
    rpc,
    rep,
    chainCandidate,
    ownerVote: ownerVote != null,
  };
}

function layerMask(layers) {
  return [
    layers.rpc ? 'rpc+' : 'rpc-',
    layers.rep ? 'rep+' : 'rep-',
    layers.chainCandidate ? 'chain+' : 'chain-',
    layers.ownerVote ? 'vote+' : 'vote-',
  ].join('/');
}

function closeKey(row) {
  return `${row.replayUuid}\u0000${row.actorNetGuid ?? row.actor?.actorNetGuid}\u0000${row.timeMs ?? row.actor?.closedAtMs}`;
}

function actorForClassification(evidence, classification) {
  return evidence.utilityActors.find((actor) =>
    actor.actorNetGuid === classification.actor.actorNetGuid &&
    actor.closedAtMs === classification.timeMs) ?? null;
}

function matchingChain(row, definition) {
  if (row.cluster.actor.className !== definition.from) return null;
  return row.cluster.nearbyOpens.find((open) =>
    open.sameRound && open.sameAbility && definition.to.test(open.actor.className) &&
    open.offsetMs >= definition.minGap && open.offsetMs <= definition.maxGap) ?? null;
}

function extensionFor(row) {
  const className = row.cluster.actor.className;
  if (/^(?:Ability|Equippable)_/.test(className) ||
      /^GameObject_Vampire_Q_Heal_HealPool_(?:High|AutoActivate)$/.test(className)) {
    return {
      outcome: 'filtered-child-actor',
      confidence: 'high',
      ruleId: 'non-world-ability-or-effect-child-filter',
      signatureId: 'non-world-ability-or-effect-child-filter',
      evidence: [{
        kind: 'static-class-role',
        signal: /^Ability_/.test(className)
          ? 'ability state/subobject class, not a spawned world utility lifecycle'
          : /^Equippable_/.test(className)
            ? 'equippable/inventory class, not a spawned world utility lifecycle'
            : 'Reyna Devour effect child; lifecycle schema says spawnsActor=false',
        className,
      }],
      caveats: [],
    };
  }

  for (const definition of CHAIN_SIGNATURES) {
    const successor = matchingChain(row, definition);
    if (!successor) continue;
    const confidence = definition.status === 'established' ? 'high' : 'medium';
    return {
      outcome: 'phase-transition',
      confidence,
      ruleId: definition.id,
      signatureId: definition.id,
      evidence: [{
        kind: 'actor-chain',
        signal: `${className}->${successor.actor.className}`,
        gapMs: successor.offsetMs,
        sameRound: successor.sameRound,
        distanceUnits: successor.distanceUnits,
        source: 'utility-actor-open',
      }],
      chainLink: {
        edgeId: definition.id,
        agent: row.cluster.actor.agent,
        abilityName: row.cluster.actor.abilityName,
        fromClass: className,
        fromActorNetGuid: row.cluster.actor.actorNetGuid,
        closeTimeMs: row.cluster.actor.closedAtMs,
        toClass: successor.actor.className,
        toActorNetGuid: successor.actor.actorNetGuid,
        openTimeMs: successor.actor.timeMs,
        gapMs: successor.offsetMs,
        sameRound: successor.sameRound,
        distanceUnits: successor.distanceUnits,
        projectedDistance2dUnits: successor.projectedDistance2dUnits,
        spatialStatus: 'typed-temporal-handoff',
        source: 'utility-actor-open',
        explicitKnownPair: true,
      },
      caveats: definition.status === 'established' ? [] : [
        'typed temporal pairing is consistent, but this chain stage has no human-labeled example',
      ],
    };
  }

  const lifetimeMs = row.cluster.actor.observedLifetimeMs;
  for (const definition of FIXED_LIFETIME_SIGNATURES) {
    if (className !== definition.className ||
        Math.abs(lifetimeMs - definition.expectedMs) > definition.toleranceMs) continue;
    return {
      outcome: 'expired',
      confidence: definition.confidence,
      ruleId: definition.id,
      signatureId: definition.id,
      evidence: [{
        kind: 'lifetime',
        signal: 'class-specific modal actor timer reached',
        observedLifetimeMs: lifetimeMs,
        expectedActorLifetimeMs: definition.expectedMs,
        toleranceMs: definition.toleranceMs,
        schemaGameplayLifetimeMs: definition.schemaMs,
      }],
      caveats: definition.status === 'established' ? [] : [definition.note],
    };
  }
  return null;
}

function updateClassification(row, extension) {
  if (!extension) return row.classification;
  return {
    ...row.classification,
    outcome: extension.outcome,
    confidence: extension.confidence,
    ruleId: extension.ruleId,
    signatureIds: [...new Set([...(row.classification.signatureIds ?? []), extension.signatureId])],
    evidence: extension.evidence,
    chainLink: extension.chainLink ?? row.classification.chainLink,
    caveats: extension.caveats,
    context: {
      ...row.classification.context,
      extension: {
        source: 'corr_extend_signatures.mjs',
        priorOutcome: row.classification.outcome,
        bucket: `${classNameFor(row)}|${roundPhase(row.cluster)}|${lifetimeBand(row.cluster.actor.observedLifetimeMs)}|${layerMask(row.layers)}`,
      },
    },
  };
}

function classNameFor(row) {
  return row.cluster.actor.className;
}

function countObject(values) {
  return Object.fromEntries(countBy(values, (value) => value).map(({ key, count }) => [key, count]));
}

function coverageFor(classifications, baselineCoverage) {
  const classifiable = classifications.filter((row) => row.outcome !== 'unclassifiable').length;
  return {
    ...baselineCoverage,
    utilityActorCloses: classifications.length,
    classifiable,
    unclassifiable: classifications.length - classifiable,
    classifiableFraction: Number((classifiable / classifications.length).toFixed(4)),
    byConfidence: countObject(classifications.map((row) => row.confidence)),
    byOutcome: countObject(classifications.map((row) => row.outcome)),
    byReplay: countBy(classifications, (row) => row.replayUuid).map(({ key: replayUuid }) => {
      const rows = classifications.filter((row) => row.replayUuid === replayUuid);
      return {
        replayUuid,
        closes: rows.length,
        high: rows.filter((row) => row.confidence === 'high').length,
        medium: rows.filter((row) => row.confidence === 'medium').length,
        low: rows.filter((row) => row.confidence === 'low').length,
        unclassifiable: rows.filter((row) => row.outcome === 'unclassifiable').length,
      };
    }).sort((left, right) => left.replayUuid.localeCompare(right.replayUuid)),
  };
}

function extensionSignatureRows(appliedRows) {
  const definitions = [
    {
      id: 'non-world-ability-or-effect-child-filter',
      outcome: 'filtered-child-actor',
      title: 'Non-world ability/equippable/effect-child exclusion',
      description: '`Ability_*`, `Equippable_*`, and Reyna Devour heal-pool children are replicated implementation objects, not independently meaningful world-utility lifecycle closes.',
      status: 'established',
    },
    ...CHAIN_SIGNATURES.map((row) => ({
      id: row.id,
      outcome: 'phase-transition',
      title: `${row.from} typed handoff`,
      description: `A same-ability ${row.to} successor occurs in the class-specific ${row.minGap}..${row.maxGap} ms handoff window.`,
      status: row.status,
    })),
    ...FIXED_LIFETIME_SIGNATURES.map((row) => ({
      id: row.id,
      outcome: 'expired',
      title: `${row.className} modal actor timeout`,
      description: `Natural close at ${row.expectedMs} +/- ${row.toleranceMs} ms; ${row.note}.`,
      status: row.status,
    })),
  ];
  return definitions.map((definition) => {
    const matches = appliedRows.filter((row) => row.extension?.signatureId === definition.id);
    return {
      ...definition,
      support: {
        labeledSupportingInstances: 0,
        labeledContradictions: 0,
        corpusMatches: matches.length,
        classes: [...new Set(matches.map((row) => row.row.cluster.actor.className))].sort(),
        labeledIds: [],
        contradictionIds: [],
      },
    };
  }).filter((row) => row.support.corpusMatches > 0);
}

function candidateOutcomes(classification) {
  const schema = classification.context?.schema;
  const outcomes = [];
  if (schema?.destroyable) outcomes.push('destroyed');
  if (schema?.recallable) outcomes.push('recalled');
  if (schema?.pickupable) outcomes.push('picked-up');
  if (Number.isFinite(schema?.maxLifetimeSeconds)) outcomes.push('expired');
  outcomes.push('phase-transition-or-other-early-removal', 'round-ended');
  return [...new Set(outcomes)];
}

function buildWorklist(remainingRows) {
  const classCounts = new Map(countBy(remainingRows, (row) => row.cluster.actor.className)
    .map(({ key, count }) => [key, count]));
  const sorted = [...remainingRows].sort((left, right) =>
    (classCounts.get(right.cluster.actor.className) ?? 0) -
      (classCounts.get(left.cluster.actor.className) ?? 0) ||
    left.cluster.actor.className.localeCompare(right.cluster.actor.className) ||
    left.cluster.actor.observedLifetimeMs - right.cluster.actor.observedLifetimeMs);
  const selected = [];
  const perClass = new Map();
  for (const row of sorted) {
    const className = row.cluster.actor.className;
    if ((perClass.get(className) ?? 0) >= 2) continue;
    selected.push(row);
    perClass.set(className, (perClass.get(className) ?? 0) + 1);
    if (selected.length === 20) break;
  }
  return selected.map((row, index) => {
    const classification = row.classification;
    const schema = classification.context?.schema;
    const expectedLifetimeMs = Number.isFinite(schema?.maxLifetimeSeconds)
      ? schema.maxLifetimeSeconds * 1_000
      : null;
    return {
      rank: index + 1,
      replayUuid: classification.replayUuid,
      round: classification.round,
      timeMs: classification.timeMs,
      actorNetGuid: classification.actor.actorNetGuid,
      actorClass: classification.actor.className,
      archetypePath: classification.actor.archetypePath,
      agent: classification.actor.agent,
      slot: schema?.slot ?? classification.actor.abilitySlot,
      abilityName: classification.actor.abilityName,
      closeClassification: 'post-v2-unclassifiable',
      observedLifetimeMs: classification.actor.observedLifetimeMs,
      expectedLifetimeMs,
      earlyByMs: Number.isFinite(expectedLifetimeMs)
        ? expectedLifetimeMs - classification.actor.observedLifetimeMs
        : null,
      candidateOwner: row.ownerVote,
      candidateOutcomes: candidateOutcomes(classification),
      ambiguityScore: Math.min(99, (classCounts.get(classification.actor.className) ?? 0) + 20),
    };
  });
}

function markdownTable(headers, rows) {
  return [
    `| ${headers.join(' | ')} |`,
    `| ${headers.map(() => '---').join(' | ')} |`,
    ...rows.map((row) => `| ${row.map((value) => String(value).replaceAll('|', '\\|')).join(' | ')} |`),
  ].join('\n');
}

function renderAnalysis({ baseline, report, appliedRows, coverage, worklist, regression }) {
  const converted = appliedRows.filter((row) => row.extension);
  const remaining = appliedRows.filter((row) => !row.extension);
  const convertedByClass = new Map(countBy(converted, (row) => row.row.cluster.actor.className)
    .map(({ key, count }) => [key, count]));
  const remainingCompact = remaining.map((row) => ({
    className: row.row.cluster.actor.className,
    phase: roundPhase(row.row.cluster),
    lifetimeBand: lifetimeBand(row.row.cluster.actor.observedLifetimeMs),
    layerMask: layerMask(row.row.layers),
  }));
  const explanation = new Map([
    ['GameObject_Vampire_Q_Heal_HealPool_High', 'Devour heal-pool implementation child; the schema says Devour does not spawn a world actor. Filtered from lifecycle outcomes.'],
    ['GameObject_Vampire_4_NearsightAOE_Source', `${convertedByClass.get('GameObject_Vampire_4_NearsightAOE_Source') ?? 0} exact 2.000 s natural Leer timeouts converted; the early closes remain destruction/cleanup candidates.`],
    ['GameObject_Wushu_4_SmokeZone', 'All are the exact 3.0 s Cloudburst zone timer (2.5 s gameplay duration plus ~0.5 s actor tail).'],
    ['GameObject_Smonk_NewSmoke', '115/116 match the 15.0 s Ruse actor timer (14 s schema duration plus ~1 s tail); one early close remains.'],
    ['GameObject_Thorne_E_Wall_Segment_Fortifying', 'Natural 41.0 s Barrier segments converted; early segments are damage/destruction or cleanup and remain ambiguous.'],
    ['GameObject_Sarge_4_Smoke_ProductionNEW', 'All match the 20.75 s Sky Smoke actor timer (19.25 s schema duration plus ~1.5 s tail).'],
    ['GameObject_Hunter_Q_SonarPing', 'Repeated Recon pulse child with a corpus-wide 1.867-1.874 s timer; converted as a supported child-stage expiry.'],
    ['GameObject_Iris_E_Smoke', 'All match the 17.75 s Waveform actor timer (16.75 s schema duration plus ~1 s tail).'],
    ['Projectile_Wushu_4_Smoke', 'Directly spawned Cloudburst projectile/wrapper; all close on the fixed 3.50 s wrapper timer.'],
  ]);
  const major = report.classes.filter((row) => row.count > 50);
  const formatExample = (entry) => entry
    ? `${entry.row.classification.id} (${entry.row.cluster.actor.observedLifetimeMs} ms; ${roundPhase(entry.row.cluster)}; ${layerMask(entry.row.layers)}${entry.extension ? `; ${entry.extension.ruleId}` : ''})`
    : '-';
  const majorExamples = major.map((bucket) => {
    const bucketRows = appliedRows.filter((entry) => entry.row.cluster.actor.className === bucket.className);
    return [
      bucket.className,
      formatExample(bucketRows.find((entry) => entry.extension)),
      formatExample(bucketRows.find((entry) => !entry.extension)),
    ];
  });
  const roundEndRemaining = remaining.filter((row) => roundPhase(row.row.cluster) === 'round-end-window');
  const weakRoundEnd = roundEndRemaining.filter((row) =>
    (row.row.classification.context?.closeBurst?.total ?? 0) < 3).length;
  const lines = [
    '# Unclassifiable utility-close analysis',
    '',
    '## Result',
    '',
    `The v1 classifier left ${baseline.coverage.unclassifiable.toLocaleString()} of ${baseline.coverage.utilityActorCloses.toLocaleString()} closes unclassifiable. The extension converts ${converted.length.toLocaleString()} and leaves ${remaining.length.toLocaleString()}. The 48 adjudicated labels are unchanged (${regression.identical}/48 exact v1 classification records).`,
    '',
    '## Bucket definitions',
    '',
    '- **Round phase:** buy phase is the first 30,000 ms after the stored round-start event; round-end window is 8,000-14,500 ms before the next stored round start; all other closes are mid-round.',
    '- **Lifetime bands:** `<1s`, `1-3s`, `3-8s`, `8-16s`, `16-30s`, and `>=30s`.',
    '- **RPC / RepLayout:** presence means at least one retained `classnet-rpc` / `rep-layout` signal in the six-second close cluster. This is layer availability, not proof that the signal is discriminating.',
    '- **Chain candidate:** at least one same-round, same-ability actor open within +/-2 s. The extension only promotes class-specific typed temporal pairs, not every candidate.',
    '- **Owner vote:** a compatible candidate owner from the prior death-vote worklist; votes remain attribution hints and are not treated as lifecycle outcomes.',
    '',
    '## Marginal bucket totals (v1 unclassifiable set)',
    '',
    markdownTable(['Dimension', 'Bucket', 'Count'], [
      ...report.phases.map((row) => ['round phase', row.key, row.count]),
      ...report.lifetimeBands.map((row) => ['lifetime', row.key, row.count]),
      ...report.layers.map((row) => ['wire mask', row.key, row.count]),
    ]),
    '',
    'The dominant wire masks have both RPC and RepLayout data. The original failure was therefore mostly missing semantics/signatures, not missing bytes.',
    '',
    '## Top eight composite buckets',
    '',
    markdownTable(['Class / phase / lifetime / layers', 'Count'], report.topCompositeBuckets.slice(0, 8)
      .map((row) => [row.key, row.count])),
    '',
    '## Major actor classes (>50 v1-unclassifiable closes)',
    '',
    markdownTable(['Actor class', 'Count', 'Converted', 'Remaining', 'Explanation'], major.map((row) => [
      row.className,
      row.count,
      convertedByClass.get(row.className) ?? 0,
      row.count - (convertedByClass.get(row.className) ?? 0),
      explanation.get(row.className) ?? 'See class-specific extension evidence.',
    ])),
    '',
    '### Representative examples',
    '',
    markdownTable(['Actor class', 'Converted representative', 'Residual representative'], majorExamples),
    '',
    '### Evidence bar',
    '',
    'A fixed timer is marked established only when the class has a tight corpus-wide modal close, the lifecycle schema independently says the ability has a finite duration, and early closes are excluded rather than forced into expiry. The systematic actor-vs-gameplay offsets are retained explicitly in each signature. Child timers without independent schema timing are `supported` or `hypothesis`, with medium/low confidence. Typed chain stages require a repeated same-ability class pair in a narrow class-specific window.',
    '',
    '## What was converted',
    '',
    markdownTable(['Rule', 'Outcome', 'Confidence', 'Count'], countBy(converted, (row) =>
      `${row.extension.ruleId}\u0000${row.extension.outcome}\u0000${row.extension.confidence}`)
      .map(({ key, count }) => [...key.split('\u0000'), count])),
    '',
    'The non-world filter covers replicated `Ability_*` state/subobjects, `Equippable_*` inventory objects, and Reyna Devour heal-pool effect children. They stay in the 4,963-row accounting but no longer masquerade as unresolved world-utility lifecycle outcomes.',
    '',
    'The new typed chain stages include Sova Recon Bolt -> ping, Fade Haunt -> reveal source, Deadlock Sonic Sensor -> fissure, Tejo Guided Salvo marker/missile -> mortar, Raze Paint Shells primary -> secondary, Skye hawk -> flash source, Gekko Dizzy wave -> orb spawner, and the Omen/Iso trajectory-warning stages.',
    '',
    '## Coverage before -> after',
    '',
    markdownTable(['Metric', 'v1', 'v2'], [
      ['high', baseline.coverage.byConfidence.high ?? 0, coverage.byConfidence.high ?? 0],
      ['medium', baseline.coverage.byConfidence.medium ?? 0, coverage.byConfidence.medium ?? 0],
      ['low', baseline.coverage.byConfidence.low ?? 0, coverage.byConfidence.low ?? 0],
      ['unclassifiable / none', baseline.coverage.unclassifiable, coverage.unclassifiable],
      ['classifiable', baseline.coverage.classifiable, coverage.classifiable],
    ]),
    '',
    '### Outcomes after extension',
    '',
    markdownTable(['Outcome', 'Count'], Object.entries(coverage.byOutcome).map(([key, count]) => [key, count])),
    '',
    '## Remaining unclassifiable set',
    '',
    markdownTable(['Actor class', 'Count'], countBy(remainingCompact, (row) => row.className).slice(0, 20)
      .map((row) => [row.key, row.count])),
    '',
    markdownTable(['Dimension', 'Bucket', 'Count'], [
      ...countBy(remainingCompact, (row) => row.phase).map((row) => ['round phase', row.key, row.count]),
      ...countBy(remainingCompact, (row) => row.lifetimeBand).map((row) => ['lifetime', row.key, row.count]),
      ...countBy(remainingCompact, (row) => row.layerMask).map((row) => ['wire mask', row.key, row.count]),
    ]),
    '',
    `${roundEndRemaining.length} remaining closes lie in the old round-end window; ${weakRoundEnd} of them have fewer than three simultaneous closes. Timing alone cannot distinguish cleanup from a natural/early close, so the round-window rule was not widened. These remain hypotheses rather than being counted as round-ended.`,
    '',
    'The largest genuine ambiguities are early destroyable actors (Sage Barrier segments, early Reyna Leer, Sova Recon/Drone, Skye Trailblazer, Raze Boom Bot, Fade Prowler) and persistent deployables without a decoded terminal HP/damage property. Owner-death votes help attribution but do not distinguish destruction, owner cleanup, recall, or phase completion.',
    '',
    '## Human tagging recommendation',
    '',
    `A focused round would help. \`${path.basename(WORKLIST_PATH)}\` contains ${worklist.length} moments (at most two per large remaining class) aimed at early/destroyable actors. These labels chiefly target Sage Barrier, early Leer, Deadlock Barrier Mesh, Iso shield/orb, Skye Trailblazer, Sova Drone/Recon, Fade Prowler, and Gekko reclaim-orb ambiguity. Fixed-timer smoke and child-stage buckets do not need more tags.`,
    '',
    '## Verification',
    '',
    `- Coverage accounting: ${coverage.classifiable} classifiable + ${coverage.unclassifiable} unclassifiable = ${coverage.utilityActorCloses}.`,
    `- Human-label regression: ${regression.identical}/48 classifications identical to v1; ${regression.errors.length} differences.`,
    '- `close_signatures.json` is parsed after writing.',
    '- `verified_ability_lifecycle_registry.json` and `extract_track.mjs` were not modified.',
    '',
  ];
  return lines.join('\n');
}

async function main() {
  const signatures = JSON.parse(fs.readFileSync(fs.existsSync(V1_PATH) ? V1_PATH : CURRENT_PATH, 'utf8'));
  const correlation = JSON.parse(fs.readFileSync(CORRELATION_PATH, 'utf8'));
  const unclassified = signatures.classifications.filter((row) => row.outcome === 'unclassifiable');
  const byReplay = new Map();
  for (const row of unclassified) {
    if (!byReplay.has(row.replayUuid)) byReplay.set(row.replayUuid, []);
    byReplay.get(row.replayUuid).push(row);
  }
  const ownerVotes = new Map(
    (correlation.ambiguousCloseWorklist ?? [])
      .filter((row) => row.candidateOwner)
      .map((row) => [closeKey(row), row.candidateOwner]),
  );
  const rows = [];
  for (const replayUuid of replayDirectories()) {
    const targets = byReplay.get(replayUuid) ?? [];
    if (!targets.length) continue;
    const evidence = loadReplayEvidence(replayUuid);
    for (const classification of targets) {
      const actor = actorForClassification(evidence, classification);
      if (!actor || isSuspectedNoise(actor)) continue;
      const cluster = extractCloseCluster(evidence, actor);
      const ownerVote = ownerVotes.get(closeKey(classification)) ?? null;
      const layers = layerSummary(cluster, ownerVote);
      rows.push({ classification, cluster, ownerVote, layers });
    }
  }
  const compact = rows.map((row) => ({
    id: row.classification.id,
    className: row.cluster.actor.className,
    agent: row.cluster.actor.agent,
    abilityName: row.cluster.actor.abilityName,
    phase: roundPhase(row.cluster),
    lifetimeBand: lifetimeBand(row.cluster.actor.observedLifetimeMs),
    lifetimeMs: row.cluster.actor.observedLifetimeMs,
    layerMask: layerMask(row.layers),
    closeToNextRoundStartMs: row.cluster.round.closeToNextRoundStartMs,
    wireCount: row.cluster.wireSignals.length,
    rpcFields: row.cluster.wireSignals
      .filter((signal) => signal.source === 'classnet-rpc')
      .map((signal) => `${signal.offsetMs}:${signal.fieldName}`),
    repFields: row.cluster.wireSignals
      .filter((signal) => signal.source === 'rep-layout')
      .map((signal) => `${signal.offsetMs}:${signal.fieldName}`),
    nearby: row.cluster.nearbyOpens.map((open) => `${open.offsetMs}:${open.actor.className}:${open.sameAbility}`),
  }));
  const byClass = countBy(compact, (row) => row.className);
  const details = byClass.slice(0, 30).map(({ key, count }) => {
    const classRows = compact.filter((row) => row.className === key);
    const lifetimes = classRows.map((row) => row.lifetimeMs).filter(Number.isFinite);
    return {
      className: key,
      count,
      agentAbility: countBy(classRows, (row) => `${row.agent}/${row.abilityName}`).slice(0, 4),
      phases: countBy(classRows, (row) => row.phase),
      lifetimeBands: countBy(classRows, (row) => row.lifetimeBand),
      lifetimeQuantilesMs: {
        min: Math.min(...lifetimes),
        p25: Math.round(quantile(lifetimes, 0.25)),
        median: Math.round(quantile(lifetimes, 0.5)),
        p75: Math.round(quantile(lifetimes, 0.75)),
        max: Math.max(...lifetimes),
      },
      lifetimeModesMs: countBy(classRows, (row) => String(Math.round(row.lifetimeMs / 10) * 10)).slice(0, 8),
      layers: countBy(classRows, (row) => row.layerMask),
      rpcFields: countBy(classRows.flatMap((row) => row.rpcFields), (value) => value.replace(/^-?\d+:/, '')).slice(0, 10),
      repFields: countBy(classRows.flatMap((row) => row.repFields), (value) => value.replace(/^-?\d+:/, '')).slice(0, 10),
      examples: classRows.slice(0, 3),
    };
  });
  const report = {
    expected: unclassified.length,
    extracted: rows.length,
    phases: countBy(compact, (row) => row.phase),
    lifetimeBands: countBy(compact, (row) => row.lifetimeBand),
    layers: countBy(compact, (row) => row.layerMask),
    chainPairs: countBy(rows.flatMap((row) => row.cluster.nearbyOpens
      .filter((open) => open.sameRound && open.sameAbility)
      .map((open) => `${row.cluster.actor.className}->${open.actor.className}@${Math.round(open.offsetMs / 50) * 50}`)),
    (value) => value).slice(0, 80),
    topCompositeBuckets: countBy(compact, (row) =>
      `${row.className}|${row.phase}|${row.lifetimeBand}|${row.layerMask}`).slice(0, 30),
    classes: details,
  };
  if (process.argv.includes('--summary') && !process.argv.includes('--write')) {
    report.classes = report.classes.map(({ examples, rpcFields, repFields, ...row }) => row);
  }
  if (process.argv.includes('--pairs') && !process.argv.includes('--write')) {
    console.log(JSON.stringify({ chainPairs: report.chainPairs }, null, 2));
    return;
  }
  if ((process.argv.includes('--summary') || process.argv.includes('--pairs')) &&
      !process.argv.includes('--write')) {
    console.log(JSON.stringify(report, null, 2));
    return;
  }

  const appliedRows = rows.map((row) => {
    const extension = extensionFor(row);
    return { row, extension };
  });
  const updatedById = new Map(appliedRows
    .filter((row) => row.extension)
    .map((row) => [row.row.classification.id, updateClassification(row.row, row.extension)]));
  const classifications = signatures.classifications.map((classification) =>
    updatedById.get(classification.id) ?? classification);
  const coverage = coverageFor(classifications, signatures.coverage);
  const converted = appliedRows.filter((row) => row.extension);
  const remaining = appliedRows.filter((row) => !row.extension).map((row) => row.row);
  const worklist = buildWorklist(remaining);
  const labeledV1 = signatures.classifications.filter((row) => row.humanGroundTruth);
  const updatedClassificationById = new Map(classifications.map((row) => [row.id, row]));
  const regressionErrors = [];
  for (const before of labeledV1) {
    const after = updatedClassificationById.get(before.id);
    const beforeComparable = {
      outcome: before.outcome,
      confidence: before.confidence,
      ruleId: before.ruleId,
      signatureIds: before.signatureIds,
    };
    const afterComparable = after ? {
      outcome: after.outcome,
      confidence: after.confidence,
      ruleId: after.ruleId,
      signatureIds: after.signatureIds,
    } : null;
    if (JSON.stringify(beforeComparable) !== JSON.stringify(afterComparable)) {
      regressionErrors.push({ id: before.id, before: beforeComparable, after: afterComparable });
    }
  }
  const regression = { identical: labeledV1.length - regressionErrors.length, errors: regressionErrors };
  const extensionSignatures = extensionSignatureRows(converted);
  const extensionChainGraphs = CHAIN_SIGNATURES.map((definition) => {
    const instances = converted.filter((row) => row.extension.ruleId === definition.id);
    return {
      edgeId: definition.id,
      fromClass: definition.from,
      toClassPattern: String(definition.to),
      gapRangeMs: [definition.minGap, definition.maxGap],
      status: definition.status,
      instances: instances.length,
      replayCount: new Set(instances.map((row) => row.row.classification.replayUuid)).size,
    };
  }).filter((row) => row.instances > 0);
  const result = {
    ...signatures,
    meta: {
      ...signatures.meta,
      schema: 'icarus-utility-close-signatures-v2',
      generatedAt: new Date().toISOString(),
      sourceV1: V1_PATH,
      extensionScript: path.join(path.dirname(CURRENT_PATH), '..', '..', 'corr_extend_signatures.mjs'),
      extensionPolicy: 'v1 classifications are retained; only v1-unclassifiable rows may be converted by typed chains, class-specific fixed actor timers, or static non-world child filtering',
    },
    outcomeDefinitions: {
      ...signatures.outcomeDefinitions,
      'filtered-child-actor': 'replicated ability/equippable/effect implementation object excluded from world-utility lifecycle interpretation',
    },
    validation: {
      ...signatures.validation,
      extensionRegression: {
        v1HumanLabelCount: labeledV1.length,
        identicalClassificationRecords: regression.identical,
        errors: regression.errors,
        passed: regression.errors.length === 0 && labeledV1.length === 48,
      },
      extensionCoverageAccounting: {
        utilityActorCloses: coverage.utilityActorCloses,
        classifiable: coverage.classifiable,
        unclassifiable: coverage.unclassifiable,
        sum: coverage.classifiable + coverage.unclassifiable,
        passed: coverage.classifiable + coverage.unclassifiable === 4_963,
      },
    },
    coverage,
    signatures: [...signatures.signatures, ...extensionSignatures],
    extensionChainGraphs,
    extensionSummary: {
      sourceUnclassifiable: unclassified.length,
      converted: converted.length,
      remainingUnclassifiable: remaining.length,
      convertedByRule: countObject(converted.map((row) => row.extension.ruleId)),
      remainingByClass: countObject(remaining.map((row) => row.cluster.actor.className)),
      taggingWorklist: WORKLIST_PATH,
    },
    classifications,
  };

  const analysis = renderAnalysis({
    baseline: signatures,
    report,
    appliedRows,
    coverage,
    worklist,
    regression,
  });
  if (!process.argv.includes('--write')) {
    console.log(JSON.stringify({
      mode: 'dry-run',
      sourceUnclassifiable: unclassified.length,
      converted: converted.length,
      remaining: remaining.length,
      coverage,
      convertedByRule: result.extensionSummary.convertedByRule,
      remainingByClass: Object.entries(result.extensionSummary.remainingByClass).slice(0, 30),
      regression,
      worklistCount: worklist.length,
    }, null, 2));
    return;
  }

  if (!fs.existsSync(V1_PATH)) {
    throw new Error(`missing preserved v1 signatures: ${V1_PATH}`);
  }
  if (!result.validation.extensionRegression.passed) {
    throw new Error(`human-label regression failed: ${JSON.stringify(regression.errors)}`);
  }
  if (!result.validation.extensionCoverageAccounting.passed) {
    throw new Error(`coverage accounting failed: ${JSON.stringify(result.validation.extensionCoverageAccounting)}`);
  }
  fs.writeFileSync(CURRENT_PATH, `${JSON.stringify(result, null, 2)}\n`);
  fs.writeFileSync(ANALYSIS_PATH, `${analysis}\n`);
  fs.writeFileSync(WORKLIST_PATH, `${JSON.stringify(worklist, null, 2)}\n`);
  const reparsed = JSON.parse(fs.readFileSync(CURRENT_PATH, 'utf8'));
  if (reparsed.meta.schema !== 'icarus-utility-close-signatures-v2') {
    throw new Error('written close_signatures.json did not parse as v2');
  }
  console.log(JSON.stringify({
    mode: 'write',
    closeSignaturesPath: CURRENT_PATH,
    analysisPath: ANALYSIS_PATH,
    worklistPath: WORKLIST_PATH,
    sourceUnclassifiable: unclassified.length,
    converted: converted.length,
    remaining: remaining.length,
    coverage,
    humanLabelRegression: `${regression.identical}/${labeledV1.length}`,
    jsonParsed: true,
  }, null, 2));
}

main().catch((error) => {
  console.error(error.stack ?? error);
  process.exitCode = 1;
});
