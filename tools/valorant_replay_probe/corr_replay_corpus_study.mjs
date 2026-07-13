#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const CORPUS_DIR = path.join(SCRIPT_DIR, 'out', 'corpus');
const SCHEMA_PATH = path.join(
  SCRIPT_DIR,
  'static_decoder_indexes',
  'ability_lifecycle_schema.json',
);
const RESULTS_PATH = path.join(CORPUS_DIR, 'correlation_results.json');
const REPORT_PATH = path.join(CORPUS_DIR, 'correlation_study.md');

const ULT_WINDOW_MS = 2_000;
const SIGNATURE_CLUSTER_TOLERANCE_MS = 200;
const CLEANUP_WINDOWS_MS = [500, 2_000];
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
const NOISE_PATH_RE = /EquippablePickupProjectile|\/Weapons\/WeaponPickups\/|EquippableGroundPickup|Cosmetic|VisualEffect|(?:^|_)VFX(?:_|$)|(?:^|_)FX(?:_|$)/i;

function normalize(value) {
  return String(value ?? '').trim().toLowerCase();
}

function basename(value) {
  const text = String(value ?? 'unknown');
  return text.split(/[./:]/).filter(Boolean).at(-1) ?? text;
}

function fraction(numerator, denominator) {
  return denominator ? Number((numerator / denominator).toFixed(4)) : 0;
}

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
}

function quantile(values, q) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = (sorted.length - 1) * q;
  const lower = Math.floor(index);
  const upper = Math.ceil(index);
  if (lower === upper) return sorted[lower];
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (index - lower);
}

function rounded(value) {
  return Number.isFinite(value) ? Math.round(value) : null;
}

function lowerBound(rows, target, field = 'timeMs') {
  let low = 0;
  let high = rows.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if ((rows[middle]?.[field] ?? Number.POSITIVE_INFINITY) < target) low = middle + 1;
    else high = middle;
  }
  return low;
}

function windowRows(rows, fromMs, toMs, field = 'timeMs') {
  const start = lowerBound(rows, fromMs, field);
  const result = [];
  for (let index = start; index < rows.length; index += 1) {
    const timeMs = rows[index]?.[field];
    if (!Number.isFinite(timeMs) || timeMs > toMs) break;
    result.push(rows[index]);
  }
  return result;
}

function isSuspectedNoise(actor) {
  const initializationNoise =
    Number.isFinite(actor?.timeMs) &&
    actor.timeMs <= 64 &&
    (actor.ignoredAsAbility === true ||
      actor.durationSource === 'ignored-initial-replication');
  return initializationNoise || NOISE_PATH_RE.test(actor?.archetypePath ?? '');
}

function roundForTime(roundStarts, timeMs) {
  let result = null;
  for (let index = 0; index < roundStarts.length; index += 1) {
    if (roundStarts[index].timeMs > timeMs) break;
    // Timeline roundIndex is zero-based; expose the human-facing round number.
    result = (roundStarts[index].roundIndex ?? index) + 1;
  }
  return result;
}

function stateReference(sample) {
  const paths = (sample.netGuidReferences ?? [])
    .map((reference) => basename(reference.pathName))
    .filter(Boolean)
    .sort();
  return paths.length ? paths.join('+') : `payload:${sample.payloadHex ?? 'unknown'}`;
}

function signalToken(sample) {
  const field = sample.fieldName ?? 'unknown';
  if (/^CurrentState$/i.test(field)) {
    return {
      layer: 'equippable-current-state',
      token: `CurrentState:${basename(sample.actorPath)}->${stateReference(sample)}`,
      detail: {
        actorPath: sample.actorPath ?? null,
        repObjectPath: sample.repObjectPath ?? null,
        fieldName: field,
        stateReferences: (sample.netGuidReferences ?? []).map((reference) => ({
          netGuid: reference.netGuid ?? null,
          pathName: reference.pathName ?? null,
        })),
      },
    };
  }
  const layer = sample.source === 'classnet-rpc' ? 'classnet-rpc' : 'rep-layout';
  return {
    layer,
    token: `${field}@${basename(sample.repObjectPath ?? sample.actorGroup ?? sample.actorPath)}`,
    detail: {
      source: sample.source ?? null,
      actorPath: sample.actorPath ?? null,
      actorGroup: sample.actorGroup ?? null,
      repObjectPath: sample.repObjectPath ?? null,
      fieldName: field,
      handle: sample.handle ?? null,
    },
  };
}

function agentPathTokens(agent, schemaByAgent) {
  const record = schemaByAgent.get(normalize(agent))?.[0];
  return [agent, record?.agentCodename]
    .map(normalize)
    .filter((value) => value.length >= 3);
}

function signalRelatedToUlt(sample, event, player, schemaByAgent) {
  if (sample.actorNetGuid === event.playerNetGuid) return true;
  if (/^CurrentState$/i.test(sample.fieldName ?? '')) return true;
  const haystack = normalize([
    sample.actorPath,
    sample.actorGroup,
    sample.repObjectPath,
  ].join(' '));
  return agentPathTokens(player.agent, schemaByAgent).some((token) => haystack.includes(token));
}

function addOccurrence(map, descriptor, offsetMs, absoluteTimeMs) {
  const key = `${descriptor.layer}\u0000${descriptor.token}`;
  if (!map.has(key)) {
    map.set(key, {
      layer: descriptor.layer,
      token: descriptor.token,
      detail: descriptor.detail ?? null,
      occurrences: [],
    });
  }
  map.get(key).occurrences.push({ offsetMs, absoluteTimeMs });
}

function buildUltObservation({
  replayUuid,
  event,
  player,
  roundStarts,
  utilityActors,
  abilitySignals,
  inputEvents,
  schemaByAgent,
  inputCoverage,
}) {
  const occurrences = new Map();
  const fromMs = event.timeMs - ULT_WINDOW_MS;
  const toMs = event.timeMs + ULT_WINDOW_MS;

  for (const actor of windowRows(utilityActors, fromMs, toMs)) {
    if (normalize(actor.agent) !== normalize(player.agent)) continue;
    addOccurrence(
      occurrences,
      {
        layer: 'actor-channel-open',
        token: basename(actor.archetypePath ?? actor.className),
        detail: {
          archetypePath: actor.archetypePath ?? null,
          className: actor.className ?? null,
          abilitySlot: actor.abilitySlot ?? null,
          abilityName: actor.abilityName ?? null,
        },
      },
      actor.timeMs - event.timeMs,
      actor.timeMs,
    );
  }

  for (const sample of windowRows(abilitySignals, fromMs, toMs)) {
    if (!signalRelatedToUlt(sample, event, player, schemaByAgent)) continue;
    addOccurrence(
      occurrences,
      signalToken(sample),
      sample.timeMs - event.timeMs,
      sample.timeMs,
    );
  }

  for (const input of windowRows(inputEvents, fromMs, toMs)) {
    if (input.candidateLoadoutIndex !== player.index) continue;
    addOccurrence(
      occurrences,
      {
        layer: 'input-event',
        token: `${input.eventType ?? 'Unknown'}:${input.eventValueNibble ?? 'null'}`,
        detail: {
          eventType: input.eventType ?? null,
          eventTypeValue: input.eventTypeValue ?? null,
          eventValueNibble: input.eventValueNibble ?? null,
          evidenceSource: input.evidenceSource ?? null,
        },
      },
      input.timeMs - event.timeMs,
      input.timeMs,
    );
  }

  return {
    replayUuid,
    eventId: event.id,
    timeMs: event.timeMs,
    round: roundForTime(roundStarts, event.timeMs),
    playerNetGuid: event.playerNetGuid,
    subject: player.subject,
    agent: player.agent,
    inputLayerAvailable:
      !inputCoverage.overflowed || event.timeMs <= inputCoverage.lastRetainedTimeMs,
    occurrences: Object.fromEntries(
      [...occurrences.entries()].map(([key, value]) => [key, value]),
    ),
  };
}

function bestOffsetCluster(observations, key) {
  const centers = observations.flatMap((observation) =>
    (observation.occurrences[key]?.occurrences ?? []).map((item) => item.offsetMs),
  );
  if (!centers.length) return null;
  let best = null;
  for (const center of centers) {
    const matches = [];
    for (let eventIndex = 0; eventIndex < observations.length; eventIndex += 1) {
      const candidates = observationOffsets(observations[eventIndex], key)
        .filter((offset) => Math.abs(offset - center) <= SIGNATURE_CLUSTER_TOLERANCE_MS)
        .sort((a, b) => Math.abs(a - center) - Math.abs(b - center));
      if (candidates.length) matches.push({ eventIndex, offsetMs: candidates[0] });
    }
    const offsets = matches.map((match) => match.offsetMs);
    const spread = offsets.length
      ? quantile(offsets, 0.9) - quantile(offsets, 0.1)
      : Number.POSITIVE_INFINITY;
    if (
      !best ||
      matches.length > best.matches.length ||
      (matches.length === best.matches.length && spread < best.spread)
    ) {
      best = { center, matches, spread };
    }
  }
  const center = median(best.matches.map((match) => match.offsetMs));
  const matches = [];
  for (let eventIndex = 0; eventIndex < observations.length; eventIndex += 1) {
    const candidates = observationOffsets(observations[eventIndex], key)
      .filter((offset) => Math.abs(offset - center) <= SIGNATURE_CLUSTER_TOLERANCE_MS)
      .sort((a, b) => Math.abs(a - center) - Math.abs(b - center));
    if (candidates.length) matches.push({ eventIndex, offsetMs: candidates[0] });
  }
  return { center: median(matches.map((match) => match.offsetMs)), matches };
}

function observationOffsets(observation, key) {
  return (observation.occurrences[key]?.occurrences ?? []).map((item) => item.offsetMs);
}

function eventMatchesSignal(observation, signal) {
  return observationOffsets(observation, signal.key).some(
    (offset) => Math.abs(offset - signal.offsetMedianMs) <= SIGNATURE_CLUSTER_TOLERANCE_MS,
  );
}

function summarizeUltAgent(agent, observations) {
  const keys = new Set(observations.flatMap((observation) => Object.keys(observation.occurrences)));
  const minimumSupport = Math.max(3, Math.ceil(observations.length * 0.4));
  const candidates = [];
  for (const key of keys) {
    const cluster = bestOffsetCluster(observations, key);
    if (!cluster || cluster.matches.length < minimumSupport) continue;
    const descriptor = observations
      .map((observation) => observation.occurrences[key])
      .find(Boolean);
    const offsets = cluster.matches.map((match) => match.offsetMs);
    candidates.push({
      key,
      layer: descriptor.layer,
      token: descriptor.token,
      detail: descriptor.detail,
      supportCount: cluster.matches.length,
      supportFraction: fraction(cluster.matches.length, observations.length),
      offsetMedianMs: rounded(median(offsets)),
      offsetP10Ms: rounded(quantile(offsets, 0.1)),
      offsetP90Ms: rounded(quantile(offsets, 0.9)),
      temporalSpreadMs: rounded(quantile(offsets, 0.9) - quantile(offsets, 0.1)),
    });
  }
  const layerPriority = new Map([
    ['actor-channel-open', 5],
    ['equippable-current-state', 4],
    ['classnet-rpc', 3],
    ['rep-layout', 2],
    ['input-event', 1],
  ]);
  candidates.sort((a, b) =>
    b.supportFraction - a.supportFraction ||
    a.temporalSpreadMs - b.temporalSpreadMs ||
    (layerPriority.get(b.layer) ?? 0) - (layerPriority.get(a.layer) ?? 0) ||
    a.token.localeCompare(b.token),
  );

  const coreSignals = [];
  let matchingIndexes = new Set(observations.map((_, index) => index));
  for (const candidate of candidates) {
    const candidateIndexes = new Set(
      observations
        .map((observation, index) => eventMatchesSignal(observation, candidate) ? index : null)
        .filter((index) => index != null),
    );
    const intersection = new Set([...matchingIndexes].filter((index) => candidateIndexes.has(index)));
    const addsLayer = !coreSignals.some((signal) => signal.layer === candidate.layer);
    const requiredMatches = Math.max(3, Math.ceil(observations.length * 0.5));
    if (
      coreSignals.length === 0 ||
      (intersection.size >= requiredMatches && (addsLayer || coreSignals.length < 2))
    ) {
      coreSignals.push(candidate);
      matchingIndexes = intersection;
    }
    if (coreSignals.length >= 5) break;
  }

  const matchedInstanceCount = coreSignals.length ? matchingIndexes.size : 0;
  const consistencyFraction = fraction(matchedInstanceCount, observations.length);
  const status =
    observations.length >= 4 && consistencyFraction >= 0.75
      ? 'established'
      : matchedInstanceCount >= 3 && consistencyFraction >= 0.5
        ? 'indicative'
        : 'weak-or-absent';
  const orderedCoreSignals = coreSignals
    .map(({ key, ...signal }) => signal)
    .sort((a, b) => a.offsetMedianMs - b.offsetMedianMs);

  return {
    agent,
    instanceCount: observations.length,
    matchedInstanceCount,
    consistencyFraction,
    status,
    clusterToleranceMs: SIGNATURE_CLUSTER_TOLERANCE_MS,
    coreSignals: orderedCoreSignals,
    recurringSignals: candidates.slice(0, 12).map(({ key, ...signal }) => signal),
    instances: observations.map((observation, index) => ({
      replayUuid: observation.replayUuid,
      eventId: observation.eventId,
      round: observation.round,
      timeMs: observation.timeMs,
      playerNetGuid: observation.playerNetGuid,
      subject: observation.subject,
      inputLayerAvailable: observation.inputLayerAvailable,
      matched: matchingIndexes.has(index),
    })),
  };
}

function confidenceLabel(votes, confidence) {
  if (votes >= 3 && confidence >= 0.8) return 'high';
  if (votes >= 2 && confidence >= 0.5) return 'medium';
  return 'low';
}

function schemaRecordForActor(actor, schemaByKey) {
  const slot = SLOT_TO_SCHEMA.get(normalize(
    actor.sourceAbilitySlot ?? actor.staticAbilitySlot ?? actor.abilitySlot,
  ));
  if (!slot || !actor.agent) return null;
  return schemaByKey.get(`${normalize(actor.agent)}\u0000${slot}`) ?? null;
}

function empiricalTickMs(abilitySignals) {
  const uniqueTimes = [];
  let previous = null;
  for (const sample of abilitySignals) {
    if (!Number.isFinite(sample.timeMs) || sample.timeMs === previous) continue;
    uniqueTimes.push(sample.timeMs);
    previous = sample.timeMs;
  }
  const deltaCounts = new Map();
  for (let index = 1; index < uniqueTimes.length; index += 1) {
    const delta = uniqueTimes[index] - uniqueTimes[index - 1];
    // Sparse ability updates skip many frames. The modal short step recovers
    // the underlying recorded tick more faithfully than the median gap.
    if (delta > 0 && delta <= 20) addCount(deltaCounts, delta);
  }
  return [...deltaCounts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0] - b[0])[0]?.[0] ?? null;
}

function addCount(map, key, amount = 1) {
  map.set(key, (map.get(key) ?? 0) + amount);
}

function mdEscape(value) {
  return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ');
}

function percent(value) {
  return `${(value * 100).toFixed(1)}%`;
}

function formatOffset(value) {
  if (!Number.isFinite(value)) return 'n/a';
  return `${value >= 0 ? '+' : ''}${value} ms`;
}

function renderReport(results) {
  const lines = [];
  lines.push('# Valorant replay ability-wire correlation study', '');
  lines.push(
    `Generated ${results.meta.generatedAt} from ${results.meta.replayCount} release-13.00 replays. ` +
      'All labels come from replay timeline events or the supplied lifecycle schema; no human labels were used.',
    '',
  );
  lines.push('## Corpus-level results', '');
  lines.push(
    `- Ultimate signatures: **${results.totals.ultimateSignatureMatches}/${results.totals.ultimateEvents}** ` +
      'ultimate events matched their agent\'s inferred composite signature.',
    `- Owner-death cleanup: **${results.totals.deathsWithCleanupCandidate2000Ms}/${results.totals.deaths}** deaths ` +
      `had at least one filtered utility close within 2,000 ms; **${results.totals.deathsWithCleanupCandidate500Ms}/${results.totals.deaths}** did within 500 ms.`,
    `- Expiry labels: **${results.totals.expiryLabeledCloses}** observed closes matched a non-null schema maximum within the empirical ${results.expiryLabels.tickToleranceMs} ms tolerance.`,
    `- Initialization filter: **${results.totals.initializationNoiseExcluded}** rows excluded (expected corpus flag count: 188).`,
    '',
  );

  lines.push('## Method', '');
  lines.push(
    `Ultimate windows span ±${ULT_WINDOW_MS} ms. Signals are grouped by layer and exact wire token, then clustered by relative offset within ±${SIGNATURE_CLUSTER_TOLERANCE_MS} ms. ` +
      'A composite signature adds recurring signals only while at least half the agent instances retain the full intersection; “established” requires at least four instances and ≥75% composite consistency.',
    '',
    'Owner-death votes pair every filtered utility close with each preceding death in the requested 500 ms and 2,000 ms windows. Round-teardown, dormant, and agent-incompatible coincidences remain in collision diagnostics but are excluded from the ownership matrix. Matrix confidence is a candidate subject’s share of compatible votes for that utility class within that replay; low sample counts remain low confidence even at 100%.',
    '',
    `Expiry uses observed, non-dormant, non-round-teardown closes. The tolerance is two empirical replay ticks (${results.expiryLabels.empiricalModalTickMs} ms/tick, ${results.expiryLabels.tickToleranceMs} ms total). Early and late closes are kept separate; late closes often indicate that the classified channel represents a parent/phase object rather than the schema's spawned effect.`,
    '',
  );

  lines.push('## Ultimate cast signatures', '');
  lines.push('| Agent | Instances | Composite matches | Status | Ordered recurring wire signature |', '|---|---:|---:|---|---|');
  for (const signature of results.ultSignatures) {
    const description = signature.coreSignals.length
      ? signature.coreSignals
          .map((signal) =>
            `${signal.layer}: ${mdEscape(signal.token)} (${signal.supportCount}/${signature.instanceCount}, median ${formatOffset(signal.offsetMedianMs)}, p10–p90 ${formatOffset(signal.offsetP10Ms)} to ${formatOffset(signal.offsetP90Ms)})`,
          )
          .join(' → ')
      : 'No signal reached the minimum recurring-support threshold';
    lines.push(
      `| ${mdEscape(signature.agent)} | ${signature.instanceCount} | ${signature.matchedInstanceCount}/${signature.instanceCount} (${percent(signature.consistencyFraction)}) | ${signature.status} | ${description} |`,
    );
  }
  lines.push('', `Total composite matches: ${results.totals.ultimateSignatureMatches}/${results.totals.ultimateEvents}.`, '');

  lines.push('### Signal-layer coverage caveat', '');
  for (const coverage of results.signalCoverage) {
    const input = coverage.nonMovementInputOverflowCount > 0
      ? `secondary non-movement input cap overflowed by ${coverage.nonMovementInputOverflowCount}; retained through ${coverage.nonMovementInputLastTimeMs} ms`
      : 'secondary non-movement input stream complete';
    lines.push(
      `- ${coverage.replayUuid}: ${coverage.abilitySignalCount} ability signals (${coverage.abilitySignalOverflowCount} overflow), ${coverage.utilityActorCount} filtered utility actors; ${input}. Raw input capture was capped at ${coverage.rawInputCaptured}/${coverage.rawInputSampleLimit}.`,
    );
  }
  lines.push('');

  lines.push('## Owner-death cleanup and ownership votes', '');
  lines.push('| Window | Deaths with ≥1 candidate | Candidate pairs | Strict compatible votes | Rejected incompatible | Round teardown/dormant excluded |', '|---|---:|---:|---:|---:|---:|');
  for (const window of results.ownershipVotes.windowAnalysis) {
    lines.push(
      `| 0–${window.windowMs} ms | ${window.deathsWithCandidates}/${results.totals.deaths} | ${window.candidatePairs} | ${window.strictCompatibleVotes} | ${window.rejectedAgentIncompatible} | ${window.rejectedRoundTeardownOrDormant} |`,
    );
  }
  lines.push('', 'The attribution matrix below shows the strongest schema-compatible 2,000 ms rows. The JSON contains every row.', '');
  lines.push('| Replay | Utility class | Ability agent | Candidate owner | Owner agent | Votes 500/2000 | Confidence |', '|---|---|---|---|---|---:|---:|');
  for (const row of results.ownershipVotes.attributionMatrix.slice(0, 40)) {
    lines.push(
      `| ${row.replayUuid.slice(0, 8)} | ${mdEscape(row.utilityClass)} | ${mdEscape(row.utilityAgent)} | ${row.candidateOwnerNetGuid} / ${mdEscape(row.candidateOwnerSubject)} | ${mdEscape(row.candidateOwnerAgent)} | ${row.votes500Ms}/${row.votes2000Ms} | ${percent(row.confidence)} (${row.confidenceLabel}) |`,
    );
  }
  lines.push('');

  lines.push('## Expiry auto-labels', '');
  lines.push('| Ability | Schema max | Evaluated closes | Expiry-labeled | Early | Late | Teardown/dormant excluded |', '|---|---:|---:|---:|---:|---:|---:|');
  for (const row of results.expiryLabels.byAbility) {
    lines.push(
      `| ${mdEscape(row.agent)} — ${mdEscape(row.abilityName)} (${row.slot}) | ${row.maxLifetimeSeconds}s | ${row.evaluatedCloses} | ${row.expiryLabeled} | ${row.earlyCloses} | ${row.lateCloses} | ${row.excludedRoundTeardownOrDormant} |`,
    );
  }
  lines.push('', `Total expiry-labeled closes: ${results.totals.expiryLabeledCloses}.`, '');

  lines.push('## Ranked human-tagging worklist', '');
  lines.push(
    'These are finite-lifetime early closes plus indefinite-lifetime deployable closes where schema semantics leave destruction, recall, pickup, owner-death cleanup, or a phase transition unresolved. Times are replay-relative.',
    '',
  );
  lines.push('| Rank | Replay | Round | Time | Actor / ability | Candidate owner | Observed vs max | Candidate outcomes |', '|---:|---|---:|---:|---|---|---:|---|');
  for (const item of results.ambiguousCloseWorklist.slice(0, 30)) {
    lines.push(
      `| ${item.rank} | ${item.replayUuid.slice(0, 8)} | ${item.round ?? 'n/a'} | ${item.timeMs} ms | ${mdEscape(item.actorClass)} / ${mdEscape(item.agent)} ${mdEscape(item.abilityName)} | ${item.candidateOwner ? `${item.candidateOwner.netGuid} / ${mdEscape(item.candidateOwner.subject)} (${percent(item.candidateOwner.confidence)})` : 'unresolved'} | ${item.observedLifetimeMs}/${item.expectedLifetimeMs == null ? 'indefinite' : item.expectedLifetimeMs} ms | ${item.candidateOutcomes.join(', ')} |`,
    );
  }
  lines.push('');

  lines.push('## Interpretation limits', '');
  lines.push(
    '- Timeline ultimate events are ground truth for “an ultimate was used,” but the inferred wire signatures are correlations. A generic input or state transition inside a four-second window is not automatically causal.',
    '- Actor classification identifies an ability family, not necessarily the exact spawned-effect phase. Late lifetimes are therefore reported rather than coerced into expiry or early-removal labels.',
    '- Owner-death coincidence is a vote, not proof. Agent compatibility removes impossible owners, and confidence fractions expose splits between same-agent candidates.',
    '- The initialization-noise predicate is applied before every analysis. Initial replicated ability objects and pickup/cosmetic paths contribute no signatures, votes, expiry labels, or worklist entries.',
    '',
  );
  return `${lines.join('\n')}\n`;
}

function main() {
  const schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, 'utf8'));
  const schemaByKey = new Map();
  const schemaByAgent = new Map();
  for (const ability of schema.abilities) {
    schemaByKey.set(`${normalize(ability.agentName)}\u0000${ability.slot}`, ability);
    const key = normalize(ability.agentName);
    if (!schemaByAgent.has(key)) schemaByAgent.set(key, []);
    schemaByAgent.get(key).push(ability);
  }

  const replayDirs = fs
    .readdirSync(CORPUS_DIR, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^[0-9a-f-]{36}$/i.test(entry.name))
    .map((entry) => entry.name)
    .sort();

  const totals = {
    replays: replayDirs.length,
    rounds: 0,
    deaths: 0,
    ultimateEvents: 0,
    initializationNoiseExcluded: 0,
  };
  const ultObservationsByAgent = new Map();
  const signalCoverage = [];
  const cleanupByWindow = new Map(CLEANUP_WINDOWS_MS.map((windowMs) => [windowMs, {
    windowMs,
    deathsWithCandidates: 0,
    candidatePairs: 0,
    strictCompatibleVotes: 0,
    rejectedAgentIncompatible: 0,
    rejectedRoundTeardownOrDormant: 0,
  }]));
  const ownershipAggregates = new Map();
  const directCleanupByActor = new Map();
  const expiryInstances = [];
  const expiryGroups = new Map();
  const earlyCloseCandidates = [];
  const unboundedCloseCandidates = [];
  const empiricalTicks = [];
  const missingLayers = [];

  for (const replayUuid of replayDirs) {
    const replayDir = path.join(CORPUS_DIR, replayUuid);
    const diagnosticsPath = path.join(replayDir, `${replayUuid}.diagnostics.json`);
    const summaryPath = path.join(replayDir, 'summary.json');
    if (!fs.existsSync(diagnosticsPath) || !fs.existsSync(summaryPath)) {
      missingLayers.push({ replayUuid, layer: 'replay', reason: 'missing diagnostics or summary' });
      continue;
    }
    const summary = JSON.parse(fs.readFileSync(summaryPath, 'utf8'));
    let diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
    const frame = diagnostics.frameSummary ?? {};
    const roundStarts = [...(diagnostics.roundStartEvents ?? [])].sort((a, b) => a.timeMs - b.timeMs);
    const deaths = [...(diagnostics.deathEvents ?? [])].sort((a, b) => a.timeMs - b.timeMs);
    const ults = [...(diagnostics.ultimateEvents ?? [])].sort((a, b) => a.timeMs - b.timeMs);
    const allUtilityActors = [...(frame.utilityActorOpenSamples ?? [])].sort((a, b) => a.timeMs - b.timeMs);
    const utilityActors = allUtilityActors.filter((actor) => !isSuspectedNoise(actor));
    const abilitySignals = [...(frame.abilitySignalSamples ?? [])].sort((a, b) => a.timeMs - b.timeMs);
    const inputEvents = [...(frame.nonMovementInputEventSamples ?? [])].sort((a, b) => a.timeMs - b.timeMs);
    const inputSummary = frame.nonMovementInputEventSummary ?? {};
    const inputOverflow = inputSummary.overflowCount ?? frame.nonMovementInputEventOverflowCount ?? 0;
    const inputCoverage = {
      overflowed: inputOverflow > 0,
      lastRetainedTimeMs: inputEvents.at(-1)?.timeMs ?? null,
    };

    totals.rounds += roundStarts.length;
    totals.deaths += deaths.length;
    totals.ultimateEvents += ults.length;
    totals.initializationNoiseExcluded += allUtilityActors.length - utilityActors.length;
    const tick = empiricalTickMs(abilitySignals);
    if (Number.isFinite(tick)) empiricalTicks.push(tick);

    const playerByNetGuid = new Map();
    const playersBySubject = new Map((summary.players ?? []).map((player) => [player.subject, player]));
    for (const movement of summary.counts?.movementSamplesPerPlayer ?? []) {
      const player = playersBySubject.get(movement.subject);
      if (player && Number.isFinite(movement.netGuid)) {
        playerByNetGuid.set(movement.netGuid, { ...player, netGuid: movement.netGuid });
      }
    }
    for (const ult of ults) {
      const player = playerByNetGuid.get(ult.playerNetGuid);
      if (!player) {
        missingLayers.push({
          replayUuid,
          layer: 'ultimate-player-join',
          eventId: ult.id,
          reason: `no player mapping for NetGUID ${ult.playerNetGuid}`,
        });
        continue;
      }
      const observation = buildUltObservation({
        replayUuid,
        event: ult,
        player,
        roundStarts,
        utilityActors,
        abilitySignals,
        inputEvents,
        schemaByAgent,
        inputCoverage,
      });
      if (!ultObservationsByAgent.has(player.agent)) ultObservationsByAgent.set(player.agent, []);
      ultObservationsByAgent.get(player.agent).push(observation);
    }

    const closes = utilityActors
      .filter((actor) => Number.isFinite(actor.closedAtMs))
      .sort((a, b) => a.closedAtMs - b.closedAtMs);
    for (const windowMs of CLEANUP_WINDOWS_MS) {
      const windowStats = cleanupByWindow.get(windowMs);
      for (const death of deaths) {
        const player = playerByNetGuid.get(death.victimNetGuid);
        const candidates = windowRows(closes, death.timeMs, death.timeMs + windowMs, 'closedAtMs');
        if (candidates.length) windowStats.deathsWithCandidates += 1;
        windowStats.candidatePairs += candidates.length;
        for (const actor of candidates) {
          const teardownOrDormant = actor.endReason === 'round-teardown' || actor.dormant === true;
          const compatible = player && normalize(player.agent) === normalize(actor.agent);
          if (teardownOrDormant) {
            windowStats.rejectedRoundTeardownOrDormant += 1;
            continue;
          }
          if (!compatible) {
            windowStats.rejectedAgentIncompatible += 1;
            continue;
          }
          windowStats.strictCompatibleVotes += 1;
          const utilityClass = actor.className ?? basename(actor.archetypePath);
          const key = [replayUuid, utilityClass, death.victimNetGuid, player.subject].join('\u0000');
          if (!ownershipAggregates.has(key)) {
            ownershipAggregates.set(key, {
              replayUuid,
              utilityClass,
              archetypePath: actor.archetypePath ?? null,
              utilityAgent: actor.agent,
              abilityName: actor.sourceAbilityName ?? actor.abilityName ?? null,
              candidateOwnerNetGuid: death.victimNetGuid,
              candidateOwnerSubject: player.subject,
              candidateOwnerAgent: player.agent,
              votes500Ms: 0,
              votes2000Ms: 0,
            });
          }
          const aggregate = ownershipAggregates.get(key);
          if (windowMs === 500) aggregate.votes500Ms += 1;
          if (windowMs === 2_000) {
            aggregate.votes2000Ms += 1;
            const actorKey = [
              replayUuid,
              actor.actorNetGuid ?? 'null',
              actor.closedAtMs,
              utilityClass,
            ].join('\u0000');
            const existing = directCleanupByActor.get(actorKey);
            const deltaMs = actor.closedAtMs - death.timeMs;
            if (!existing || deltaMs < existing.deltaMs) {
              directCleanupByActor.set(actorKey, {
                netGuid: death.victimNetGuid,
                subject: player.subject,
                agent: player.agent,
                deathEventId: death.id,
                deathTimeMs: death.timeMs,
                deltaMs,
                source: 'direct-close-after-death-vote',
              });
            }
          }
        }
      }
    }

    for (const actor of utilityActors) {
      const ability = schemaRecordForActor(actor, schemaByKey);
      if (!ability || !ability.spawnsActor) continue;
      const hasObservedLifecycleClose =
        Number.isFinite(actor.closedAtMs) &&
        Number.isFinite(actor.observedLifetimeMs) &&
        actor.endReason !== 'round-teardown' &&
        actor.dormant !== true;
      if (
        hasObservedLifecycleClose &&
        !Number.isFinite(ability.maxLifetimeSeconds) &&
        (ability.destroyable || ability.recallable || ability.pickupable)
      ) {
        unboundedCloseCandidates.push({
          replayUuid,
          round: roundForTime(roundStarts, actor.closedAtMs),
          timeMs: actor.closedAtMs,
          actorNetGuid: actor.actorNetGuid ?? null,
          actorClass: actor.className ?? basename(actor.archetypePath),
          archetypePath: actor.archetypePath ?? null,
          agent: ability.agentName,
          slot: ability.slot,
          abilityName: ability.abilityName,
          observedLifetimeMs: actor.observedLifetimeMs,
          expectedLifetimeMs: null,
          deltaMs: null,
          label: 'indefinite-lifetime-close',
          schema: {
            destroyable: ability.destroyable,
            hp: ability.hp,
            recallable: ability.recallable,
            pickupable: ability.pickupable,
            suppressionInteraction: ability.suppressionInteraction,
          },
        });
      }
      if (!Number.isFinite(ability.maxLifetimeSeconds)) continue;
      const groupKey = `${ability.agentName}\u0000${ability.slot}`;
      if (!expiryGroups.has(groupKey)) {
        expiryGroups.set(groupKey, {
          agent: ability.agentName,
          slot: ability.slot,
          abilityName: ability.abilityName,
          maxLifetimeSeconds: ability.maxLifetimeSeconds,
          evaluatedCloses: 0,
          expiryLabeled: 0,
          earlyCloses: 0,
          lateCloses: 0,
          excludedRoundTeardownOrDormant: 0,
          noObservedClose: 0,
        });
      }
      const group = expiryGroups.get(groupKey);
      if (!Number.isFinite(actor.closedAtMs) || !Number.isFinite(actor.observedLifetimeMs)) {
        group.noObservedClose += 1;
        continue;
      }
      if (actor.endReason === 'round-teardown' || actor.dormant === true) {
        group.excludedRoundTeardownOrDormant += 1;
        continue;
      }
      // Classification waits until the empirical tolerance is known below.
      expiryInstances.push({
        replayUuid,
        round: roundForTime(roundStarts, actor.closedAtMs),
        timeMs: actor.closedAtMs,
        actorNetGuid: actor.actorNetGuid ?? null,
        actorClass: actor.className ?? basename(actor.archetypePath),
        archetypePath: actor.archetypePath ?? null,
        agent: ability.agentName,
        slot: ability.slot,
        abilityName: ability.abilityName,
        observedLifetimeMs: actor.observedLifetimeMs,
        expectedLifetimeMs: ability.maxLifetimeSeconds * 1_000,
        deltaMs: actor.observedLifetimeMs - ability.maxLifetimeSeconds * 1_000,
        schema: {
          destroyable: ability.destroyable,
          hp: ability.hp,
          recallable: ability.recallable,
          pickupable: ability.pickupable,
          suppressionInteraction: ability.suppressionInteraction,
        },
        groupKey,
      });
      group.evaluatedCloses += 1;
    }

    signalCoverage.push({
      replayUuid,
      abilitySignalCount: abilitySignals.length,
      abilitySignalOverflowCount: frame.abilitySignalOverflowCount ?? 0,
      utilityActorCount: utilityActors.length,
      utilityActorRawCount: allUtilityActors.length,
      initializationNoiseExcluded: allUtilityActors.length - utilityActors.length,
      rawInputCaptured: frame.inputEventCaptureSamples?.length ?? 0,
      rawInputSampleLimit: frame.inputEventCaptureSummary?.sampleLimit ?? 10_000,
      nonMovementInputCount: inputEvents.length,
      nonMovementInputOverflowCount: inputOverflow,
      nonMovementInputLastTimeMs: inputEvents.at(-1)?.timeMs ?? null,
    });

    diagnostics = null;
    if (global.gc) global.gc();
  }

  const empiricalModalTickMs = median(empiricalTicks) ?? 8;
  const tickToleranceMs = Math.max(1, Math.ceil(empiricalModalTickMs * 2));
  for (const instance of expiryInstances) {
    const group = expiryGroups.get(instance.groupKey);
    if (Math.abs(instance.deltaMs) <= tickToleranceMs) {
      instance.label = 'expiry';
      group.expiryLabeled += 1;
    } else if (instance.deltaMs < -tickToleranceMs) {
      instance.label = 'early-close';
      group.earlyCloses += 1;
      earlyCloseCandidates.push(instance);
    } else {
      instance.label = 'late-close';
      group.lateCloses += 1;
    }
    delete instance.groupKey;
  }

  const ownershipRows = [...ownershipAggregates.values()];
  const denominatorByClassReplay = new Map();
  for (const row of ownershipRows) {
    addCount(denominatorByClassReplay, `${row.replayUuid}\u0000${row.utilityClass}`, row.votes2000Ms);
  }
  for (const row of ownershipRows) {
    const denominator = denominatorByClassReplay.get(`${row.replayUuid}\u0000${row.utilityClass}`) ?? 0;
    row.confidence = fraction(row.votes2000Ms, denominator);
    row.confidenceLabel = confidenceLabel(row.votes2000Ms, row.confidence);
    row.schemaCompatible = normalize(row.utilityAgent) === normalize(row.candidateOwnerAgent);
  }
  ownershipRows.sort((a, b) =>
    b.votes2000Ms - a.votes2000Ms || b.confidence - a.confidence ||
    a.utilityClass.localeCompare(b.utilityClass),
  );
  const invalidAttributions = ownershipRows.filter((row) => !row.schemaCompatible);
  if (invalidAttributions.length) {
    throw new Error(`ownership sanity check failed: ${invalidAttributions.length} incompatible rows`);
  }

  const bestOwnerByClassReplay = new Map();
  for (const row of ownershipRows) {
    const key = `${row.replayUuid}\u0000${row.utilityClass}`;
    if (!bestOwnerByClassReplay.has(key)) bestOwnerByClassReplay.set(key, row);
  }
  const rankedAmbiguousCandidates = [...earlyCloseCandidates, ...unboundedCloseCandidates]
    .map((instance) => {
      const lifecycleOutcomes = [];
      if (instance.schema.destroyable) lifecycleOutcomes.push('destroyed');
      if (instance.schema.recallable) lifecycleOutcomes.push('recalled');
      if (instance.schema.pickupable) lifecycleOutcomes.push('picked-up');
      lifecycleOutcomes.push('phase-transition-or-other-early-removal');
      const owner = bestOwnerByClassReplay.get(`${instance.replayUuid}\u0000${instance.actorClass}`);
      const directCleanup = directCleanupByActor.get([
        instance.replayUuid,
        instance.actorNetGuid ?? 'null',
        instance.timeMs,
        instance.actorClass,
      ].join('\u0000'));
      if (directCleanup) lifecycleOutcomes.push('owner-death-cleanup');
      return {
        replayUuid: instance.replayUuid,
        round: instance.round,
        timeMs: instance.timeMs,
        actorNetGuid: instance.actorNetGuid,
        actorClass: instance.actorClass,
        archetypePath: instance.archetypePath,
        agent: instance.agent,
        slot: instance.slot,
        abilityName: instance.abilityName,
        closeClassification: instance.label,
        observedLifetimeMs: instance.observedLifetimeMs,
        expectedLifetimeMs: instance.expectedLifetimeMs,
        earlyByMs: Number.isFinite(instance.deltaMs) ? -instance.deltaMs : null,
        candidateOwner: directCleanup ? {
          ...directCleanup,
          confidence: 1,
          votes2000Ms: 1,
        } : owner ? {
          netGuid: owner.candidateOwnerNetGuid,
          subject: owner.candidateOwnerSubject,
          agent: owner.candidateOwnerAgent,
          confidence: owner.confidence,
          votes2000Ms: owner.votes2000Ms,
          source: 'class-level-owner-death-vote',
        } : null,
        candidateOutcomes: lifecycleOutcomes,
        ambiguityScore:
          lifecycleOutcomes.filter((outcome) => ['destroyed', 'recalled', 'picked-up'].includes(outcome)).length * 10 +
          (directCleanup ? 5 : owner ? 2 : 0) +
          (Number.isFinite(instance.expectedLifetimeMs)
            ? Math.min(5, Math.round((instance.expectedLifetimeMs - instance.observedLifetimeMs) / 1_000))
            : 3),
      };
    })
    .filter((item) => item.candidateOutcomes.some((outcome) => ['destroyed', 'recalled', 'picked-up'].includes(outcome)))
    .sort((a, b) => b.ambiguityScore - a.ambiguityScore || a.timeMs - b.timeMs);
  // Put a diverse set of abilities first so the human queue is not monopolized
  // by dozens of phases from one frequently used ability. Preserve every row.
  const promoted = [];
  const deferred = [];
  const promotedByAbility = new Map();
  for (const item of rankedAmbiguousCandidates) {
    const key = `${item.agent}\u0000${item.abilityName}`;
    const count = promotedByAbility.get(key) ?? 0;
    if (count < 3) {
      promoted.push(item);
      promotedByAbility.set(key, count + 1);
    } else {
      deferred.push(item);
    }
  }
  const ambiguousCloseWorklist = [...promoted, ...deferred]
    .map((item, index) => ({ rank: index + 1, ...item }));

  const ultSignatures = [...ultObservationsByAgent.entries()]
    .map(([agent, observations]) => summarizeUltAgent(agent, observations))
    .sort((a, b) => b.instanceCount - a.instanceCount || a.agent.localeCompare(b.agent));
  totals.ultimateSignatureMatches = ultSignatures.reduce((sum, row) => sum + row.matchedInstanceCount, 0);
  totals.deathsWithCleanupCandidate500Ms = cleanupByWindow.get(500).deathsWithCandidates;
  totals.deathsWithCleanupCandidate2000Ms = cleanupByWindow.get(2_000).deathsWithCandidates;
  totals.expiryLabeledCloses = expiryInstances.filter((instance) => instance.label === 'expiry').length;

  const results = {
    meta: {
      schemaVersion: 1,
      generatedAt: new Date().toISOString(),
      replayCount: replayDirs.length,
      branch: '++Ares-Core+release-13.00',
      corpusDirectory: CORPUS_DIR,
      initializationNoiseFilter:
        '(timeMs <= 64 && ignoredAsAbility/ignored-initial-replication) OR archetypePath matches pickup/cosmetic/VFX/FX regex',
      noHumanLabels: true,
    },
    totals,
    signalCoverage,
    missingLayers,
    ultSignatures,
    ownershipVotes: {
      windowAnalysis: CLEANUP_WINDOWS_MS.map((windowMs) => cleanupByWindow.get(windowMs)),
      attributionMatrix: ownershipRows,
      confidenceDefinition:
        'candidate 2000ms votes / all strict schema-compatible 2000ms votes for the utility class in that replay',
      sanityCheck: {
        incompatibleAttributionRows: invalidAttributions.length,
        passed: invalidAttributions.length === 0,
      },
    },
    expiryLabels: {
      empiricalModalTickMs,
      tickToleranceMs,
      toleranceDefinition: 'two modal short positive replay signal ticks',
      totals: {
        evaluatedCloses: expiryInstances.length,
        expiryLabeled: expiryInstances.filter((instance) => instance.label === 'expiry').length,
        earlyCloses: expiryInstances.filter((instance) => instance.label === 'early-close').length,
        lateCloses: expiryInstances.filter((instance) => instance.label === 'late-close').length,
      },
      byAbility: [...expiryGroups.values()].sort((a, b) =>
        b.expiryLabeled - a.expiryLabeled || b.earlyCloses - a.earlyCloses ||
        a.agent.localeCompare(b.agent) || a.slot.localeCompare(b.slot),
      ),
      instances: expiryInstances,
    },
    ambiguousCloseWorklist,
  };

  fs.writeFileSync(RESULTS_PATH, `${JSON.stringify(results, null, 2)}\n`);
  fs.writeFileSync(REPORT_PATH, renderReport(results));
  console.log(JSON.stringify({
    resultsPath: RESULTS_PATH,
    reportPath: REPORT_PATH,
    totals,
    ownershipRows: ownershipRows.length,
    ambiguousCloses: ambiguousCloseWorklist.length,
  }, null, 2));
}

main();
