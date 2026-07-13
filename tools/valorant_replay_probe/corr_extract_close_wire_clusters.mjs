#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
export const CORPUS_DIR = path.join(SCRIPT_DIR, 'out', 'corpus');
export const LABELS_PATH = path.join(CORPUS_DIR, 'ability_tagging_results.json');
export const CLUSTERS_PATH = path.join(CORPUS_DIR, 'labeled_close_wire_clusters.json');

export const NOISE_PATH_RE = /EquippablePickupProjectile|\/Weapons\/WeaponPickups\/|EquippableGroundPickup|Cosmetic|VisualEffect|(?:^|_)VFX(?:_|$)|(?:^|_)FX(?:_|$)/i;

export function normalize(value) {
  return String(value ?? '').trim().toLowerCase();
}

export function basename(value) {
  const text = String(value ?? 'unknown');
  return text.split(/[./:]/).filter(Boolean).at(-1) ?? text;
}

export function isSuspectedNoise(actor) {
  const initializationNoise =
    Number.isFinite(actor?.timeMs) &&
    actor.timeMs <= 64 &&
    (actor.ignoredAsAbility === true ||
      actor.durationSource === 'ignored-initial-replication');
  return initializationNoise || NOISE_PATH_RE.test(actor?.archetypePath ?? '');
}

export function lowerBound(rows, target, field = 'timeMs') {
  let low = 0;
  let high = rows.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if ((rows[middle]?.[field] ?? Number.POSITIVE_INFINITY) < target) low = middle + 1;
    else high = middle;
  }
  return low;
}

export function windowRows(rows, fromMs, toMs, field = 'timeMs') {
  const start = lowerBound(rows, fromMs, field);
  const result = [];
  for (let index = start; index < rows.length; index += 1) {
    const timeMs = rows[index]?.[field];
    if (!Number.isFinite(timeMs) || timeMs > toMs) break;
    result.push(rows[index]);
  }
  return result;
}

export function roundAt(roundStarts, timeMs) {
  let round = null;
  let roundStartMs = null;
  let nextRoundStartMs = null;
  for (let index = 0; index < roundStarts.length; index += 1) {
    const start = roundStarts[index];
    if (start.timeMs > timeMs) {
      nextRoundStartMs = start.timeMs;
      break;
    }
    round = (start.roundIndex ?? index) + 1;
    roundStartMs = start.timeMs;
    nextRoundStartMs = roundStarts[index + 1]?.timeMs ?? null;
  }
  return { round, roundStartMs, nextRoundStartMs };
}

export function distance3d(left, right) {
  if (!left || !right) return null;
  if (![left.x, left.y, left.z, right.x, right.y, right.z].every(Number.isFinite)) {
    return null;
  }
  return Math.hypot(left.x - right.x, left.y - right.y, left.z - right.z);
}

export function actorPositionAtEnd(actor) {
  return actor?.samples?.at(-1)?.position ?? actor?.position ?? null;
}

function sortedCopy(rows, field = 'timeMs') {
  return [...(rows ?? [])].sort((left, right) =>
    (left?.[field] ?? Number.POSITIVE_INFINITY) -
    (right?.[field] ?? Number.POSITIVE_INFINITY));
}

function buildOwnerLinkIndex(identityLinks) {
  const index = new Map();
  for (const link of identityLinks) {
    if (link.fieldName !== 'Owner' || !Number.isFinite(link.actorNetGuid)) continue;
    if (!index.has(link.actorNetGuid)) index.set(link.actorNetGuid, []);
    index.get(link.actorNetGuid).push(link);
  }
  for (const rows of index.values()) rows.sort((left, right) => left.timeMs - right.timeMs);
  return index;
}

function latestOwnerLink(ownerLinkIndex, actorNetGuid, timeMs) {
  const rows = ownerLinkIndex.get(actorNetGuid) ?? [];
  let result = null;
  for (const row of rows) {
    if (row.timeMs > timeMs) break;
    result = row;
  }
  return result;
}

export function resolveOwnerChain(actor, ownerLinkIndex, playerByNetGuid) {
  const chain = [];
  const visited = new Set();
  let netGuid = actor.actorNetGuid;
  const atMs = actor.timeMs;
  for (let depth = 0; depth < 8 && Number.isFinite(netGuid); depth += 1) {
    if (visited.has(netGuid)) break;
    visited.add(netGuid);
    const link = latestOwnerLink(ownerLinkIndex, netGuid, atMs);
    const ownerNetGuid = link?.decodedNetGuid || null;
    chain.push({
      depth,
      actorNetGuid: netGuid,
      ownerNetGuid,
      link: link ? {
        timeMs: link.timeMs,
        chIndex: link.chIndex,
        actorPath: link.actorPath ?? null,
        actorGroup: link.actorGroup ?? null,
        repObjectPath: link.repObjectPath ?? null,
        fieldName: link.fieldName,
        handle: link.handle ?? null,
        numBits: link.numBits ?? null,
        payloadHex: link.payloadHex ?? null,
      } : null,
      player: playerByNetGuid.get(netGuid) ?? null,
    });
    if (playerByNetGuid.has(netGuid) || !Number.isFinite(ownerNetGuid) || ownerNetGuid === 0) {
      break;
    }
    netGuid = ownerNetGuid;
  }
  return chain;
}

function signalReferenceNames(signal) {
  return [...(signal.netGuidReferences ?? [])]
    .map((reference) => basename(reference.pathName))
    .filter((value) => value && value !== 'unknown');
}

export function signalToken(signal) {
  const field = signal.fieldName ?? signal.functionName ?? 'unknown';
  const references = signalReferenceNames(signal);
  const referenceSuffix = references.length ? `->${references.join('+')}` : '';
  return `${signal.source ?? 'unknown'}:${field}@${basename(signal.repObjectPath ?? signal.actorGroup ?? signal.actorPath)}${referenceSuffix}`;
}

function copySignal(signal, closeMs, scope) {
  return {
    offsetMs: signal.timeMs - closeMs,
    timeMs: signal.timeMs,
    scope,
    token: signalToken(signal),
    source: signal.source ?? null,
    chIndex: signal.chIndex ?? null,
    actorNetGuid: signal.actorNetGuid ?? null,
    actorPath: signal.actorPath ?? null,
    actorGroup: signal.actorGroup ?? null,
    repObject: signal.repObject ?? null,
    repObjectPath: signal.repObjectPath ?? null,
    classNetCache: signal.classNetCache ?? null,
    handle: signal.handle ?? signal.fieldHandle ?? null,
    rawHandle: signal.rawHandle ?? null,
    fieldName: signal.fieldName ?? signal.functionName ?? null,
    numBits: signal.numBits ?? signal.numPayloadBits ?? null,
    payloadHex: signal.payloadHex ?? null,
    payloadHexTruncated: signal.payloadHexTruncated === true,
    netGuidReferences: signal.netGuidReferences ?? [],
    focusProjectileReferences: signal.focusProjectileReferences ?? [],
  };
}

function copyClassNetCall(sample, closeMs, scope) {
  return {
    offsetMs: sample.timeMs - closeMs,
    timeMs: sample.timeMs,
    scope,
    chIndex: sample.chIndex ?? null,
    actorNetGuid: sample.actorNetGuid ?? null,
    actorPath: sample.actorPath ?? null,
    actorGroup: sample.actorGroup ?? null,
    repObject: sample.repObject ?? null,
    repObjectPath: sample.repObjectPath ?? null,
    classNetCache: sample.classNetCache ?? null,
    fieldHandle: sample.fieldHandle ?? null,
    fieldName: sample.fieldName ?? null,
    isTargetFunction: sample.isTargetFunction === true,
    beforePayloadBits: sample.beforePayloadBits ?? null,
    numPayloadBits: sample.numPayloadBits ?? null,
    payloadHex: sample.payloadHex ?? null,
    afterPayloadBits: sample.afterPayloadBits ?? null,
  };
}

function sameAbility(left, right) {
  return normalize(left?.agent) === normalize(right?.agent) &&
    normalize(left?.abilityName ?? left?.sourceAbilityName) ===
      normalize(right?.abilityName ?? right?.sourceAbilityName);
}

function abilityFamilyTokens(actor) {
  const pathTokens = [
    actor?.sourceAbilityClass,
    actor?.sourceAbilityAssetPath,
    actor?.staticAssetPath,
    actor?.archetypePath,
  ]
    .flatMap((value) => String(value ?? '').split(/[/.\\:_-]/))
    .map(normalize)
    .filter((value) => value.length >= 3);
  return new Set([
    normalize(actor?.agentDeveloperName),
    normalize(actor?.icarusAgentType),
    normalize(actor?.agent),
    ...pathTokens.filter((value) =>
      !/^(?:game|characters|ability|default|projectile|gameobject|patch|pawn|zone|production|script|shootergame)$/.test(value)),
  ].filter((value) => value.length >= 3));
}

function signalMatchesAbilityFamily(signal, actor, familyTokens) {
  const haystack = normalize([
    signal.actorPath,
    signal.actorGroup,
    signal.repObjectPath,
  ].join(' '));
  if (!haystack.includes('/game/characters/') && !haystack.includes('default__')) return false;
  const developer = normalize(actor?.agentDeveloperName);
  if (developer.length >= 3 && haystack.includes(developer)) return true;
  return [...familyTokens].some((token) =>
    token.length >= 4 && haystack.includes(token) &&
    (haystack.includes('/ability_') || haystack.includes('gameobject') || haystack.includes('projectile')));
}

function actorSummary(actor) {
  return {
    id: actor.id ?? null,
    timeMs: actor.timeMs ?? null,
    observedStartMs: actor.observedStartMs ?? actor.timeMs ?? null,
    closedAtMs: actor.closedAtMs ?? null,
    observedLifetimeMs: actor.observedLifetimeMs ?? null,
    durationSource: actor.durationSource ?? null,
    lifecycleEvidence: actor.lifecycleEvidence ?? null,
    endReason: actor.endReason ?? null,
    endReasonEvidence: actor.endReasonEvidence ?? null,
    closeReason: actor.closeReason ?? null,
    dormant: actor.dormant === true,
    chIndex: actor.chIndex ?? null,
    actorNetGuid: actor.actorNetGuid ?? null,
    archetypePath: actor.archetypePath ?? null,
    className: actor.className ?? basename(actor.archetypePath),
    agent: actor.agent ?? null,
    icarusAgentType: actor.icarusAgentType ?? null,
    agentDeveloperName: actor.agentDeveloperName ?? null,
    agentShippingName: actor.agentShippingName ?? null,
    abilitySlot: actor.abilitySlot ?? actor.sourceAbilitySlot ?? null,
    abilityName: actor.abilityName ?? actor.sourceAbilityName ?? null,
    utilityKind: actor.utilityKind ?? null,
    contentKind: actor.contentKind ?? null,
    phase: actor.phase ?? null,
    position: actor.position ?? null,
    endPosition: actorPositionAtEnd(actor),
    velocity: actor.velocity ?? null,
    samples: actor.samples ?? [],
  };
}

function nearbyOpenSummary(candidate, actor, closeMs, roundStarts) {
  const sourcePosition = actorPositionAtEnd(actor);
  const candidatePosition = candidate.position ?? candidate.samples?.[0]?.position ?? null;
  const travelSeconds = Number.isFinite(candidate.timeMs) && Number.isFinite(actor.timeMs)
    ? (candidate.timeMs - actor.timeMs) / 1_000
    : null;
  const projectedPosition = Number.isFinite(travelSeconds) && actor.position && actor.velocity
    ? {
        x: actor.position.x + actor.velocity.x * travelSeconds,
        y: actor.position.y + actor.velocity.y * travelSeconds,
        z: actor.position.z + actor.velocity.z * travelSeconds,
      }
    : null;
  const projectedDistance2dUnits = projectedPosition && candidatePosition &&
    [projectedPosition.x, projectedPosition.y, candidatePosition.x, candidatePosition.y].every(Number.isFinite)
    ? Math.hypot(
        projectedPosition.x - candidatePosition.x,
        projectedPosition.y - candidatePosition.y,
      )
    : null;
  const sourceRound = roundAt(roundStarts, closeMs).round;
  const candidateRound = roundAt(roundStarts, candidate.timeMs).round;
  return {
    offsetMs: candidate.timeMs - closeMs,
    sameRound: sourceRound != null && candidateRound === sourceRound,
    sameAbility: sameAbility(actor, candidate),
    sameAgent: normalize(actor.agent) === normalize(candidate.agent),
    distanceUnits: distance3d(sourcePosition, candidatePosition),
    projectedDistance2dUnits,
    projectileProjectionUsed:
      Math.hypot(actor?.velocity?.x ?? 0, actor?.velocity?.y ?? 0) >= 100,
    actor: actorSummary(candidate),
  };
}

function inputSummary(input, closeMs) {
  return {
    offsetMs: input.timeMs - closeMs,
    timeMs: input.timeMs,
    id: input.id ?? null,
    playerReplayId: input.playerReplayId ?? null,
    candidateLoadoutIndex: input.candidateLoadoutIndex ?? null,
    eventTypeValue: input.eventTypeValue ?? null,
    eventType: input.eventType ?? null,
    eventValueNibble: input.eventValueNibble ?? null,
    serializedBitCount: input.serializedBitCount ?? null,
    serializedDataHex: input.serializedDataHex ?? null,
    eventProcessingResult: input.eventProcessingResult ?? null,
    rawInputEventDataHex: input.rawInputEventDataHex ?? null,
    evidenceSource: input.evidenceSource ?? null,
  };
}

export function loadReplayEvidence(replayUuid) {
  const replayDir = path.join(CORPUS_DIR, replayUuid);
  const diagnosticsPath = path.join(replayDir, `${replayUuid}.diagnostics.json`);
  const summaryPath = path.join(replayDir, 'summary.json');
  if (!fs.existsSync(diagnosticsPath) || !fs.existsSync(summaryPath)) {
    throw new Error(`missing diagnostics or summary for ${replayUuid}`);
  }
  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const summary = JSON.parse(fs.readFileSync(summaryPath, 'utf8'));
  const frame = diagnostics.frameSummary ?? {};
  const playersBySubject = new Map((summary.players ?? []).map((player) => [player.subject, player]));
  const playerByNetGuid = new Map();
  for (const movement of summary.counts?.movementSamplesPerPlayer ?? []) {
    const player = playersBySubject.get(movement.subject);
    if (!player || !Number.isFinite(movement.netGuid)) continue;
    playerByNetGuid.set(movement.netGuid, {
      ...player,
      netGuid: movement.netGuid,
      loadoutIndex: player.index,
      playerReplayId: 0x100 + player.index,
    });
  }
  return {
    replayUuid,
    diagnosticsPath,
    summaryPath,
    diagnostics,
    summary,
    frame,
    roundStarts: sortedCopy(diagnostics.roundStartEvents),
    abilitySignals: sortedCopy(frame.abilitySignalSamples),
    inputEvents: sortedCopy(frame.nonMovementInputEventSamples),
    identityLinks: sortedCopy(frame.identityLinkSamples),
    ownerLinkIndex: buildOwnerLinkIndex(frame.identityLinkSamples ?? []),
    utilityActors: sortedCopy(frame.utilityActorOpenSamples),
    utilityCloses: sortedCopy(frame.utilityActorCloseSamples),
    classNetCacheSamples: sortedCopy(frame.classNetCacheSamples),
    playerByNetGuid,
  };
}

export function extractCloseCluster(evidence, actor, label = null, {
  signalBeforeMs = 6_000,
  signalAfterMs = 250,
  inputBeforeMs = 3_000,
  inputAfterMs = 250,
  nearbyBeforeMs = 2_000,
  nearbyAfterMs = 2_000,
} = {}) {
  const closeMs = actor.closedAtMs;
  if (!Number.isFinite(closeMs)) throw new Error(`actor ${actor.actorNetGuid} has no close`);
  const ownerChain = resolveOwnerChain(actor, evidence.ownerLinkIndex, evidence.playerByNetGuid);
  const chainGuids = new Set(ownerChain.map((row) => row.actorNetGuid));
  const linkedOwnerPlayer = ownerChain.find((row) => row.player)?.player ?? null;
  const agentPlayers = [...evidence.playerByNetGuid.values()]
    .filter((player) => normalize(player.agent) === normalize(actor.agent));
  const ownerPlayer = linkedOwnerPlayer ?? (agentPlayers.length === 1 ? agentPlayers[0] : null);
  const ownerResolution = linkedOwnerPlayer
    ? 'replicated-owner-chain'
    : ownerPlayer
      ? 'unique-agent-fallback'
      : 'unresolved';
  const familyTokens = abilityFamilyTokens(actor);
  const signalWindow = windowRows(
    evidence.abilitySignals,
    closeMs - signalBeforeMs,
    closeMs + signalAfterMs,
  );
  const wireSignals = [];
  for (const signal of signalWindow) {
    const onActorChannel =
      signal.chIndex === actor.chIndex &&
      signal.timeMs >= actor.timeMs &&
      signal.timeMs <= closeMs + signalAfterMs;
    const onOwnerChain = chainGuids.has(signal.actorNetGuid);
    const onResolvedOwner = signal.actorNetGuid === ownerPlayer?.netGuid;
    const onAbilityFamily = signalMatchesAbilityFamily(signal, actor, familyTokens);
    if (!onActorChannel && !onOwnerChain && !onResolvedOwner && !onAbilityFamily) continue;
    const scope = onActorChannel
      ? signal.actorNetGuid === actor.actorNetGuid ? 'closing-actor' : 'closing-channel'
      : onOwnerChain
        ? signal.actorNetGuid === ownerPlayer?.netGuid ? 'owner-character' : 'owner-chain'
        : onResolvedOwner
          ? 'owner-character-inferred'
          : 'ability-family';
    wireSignals.push(copySignal(signal, closeMs, scope));
  }
  const rawClassNetCacheCalls = [];
  for (const sample of windowRows(
    evidence.classNetCacheSamples,
    closeMs - signalBeforeMs,
    closeMs + signalAfterMs,
  )) {
    const onActorChannel = sample.chIndex === actor.chIndex;
    const onOwnerChain = chainGuids.has(sample.actorNetGuid);
    if (!onActorChannel && !onOwnerChain) continue;
    rawClassNetCacheCalls.push(copyClassNetCall(
      sample,
      closeMs,
      onActorChannel ? 'closing-actor-channel' : 'owner-chain',
    ));
  }
  const ownerInputEvents = Number.isInteger(ownerPlayer?.loadoutIndex)
    ? windowRows(
        evidence.inputEvents,
        closeMs - inputBeforeMs,
        closeMs + inputAfterMs,
      )
        .filter((input) => input.candidateLoadoutIndex === ownerPlayer.loadoutIndex)
        .map((input) => inputSummary(input, closeMs))
    : [];
  const nearbyOpens = windowRows(
    evidence.utilityActors,
    closeMs - nearbyBeforeMs,
    closeMs + nearbyAfterMs,
  )
    .filter((candidate) => candidate.actorNetGuid !== actor.actorNetGuid)
    .map((candidate) => nearbyOpenSummary(candidate, actor, closeMs, evidence.roundStarts))
    .filter((candidate) =>
      candidate.sameAbility ||
      (candidate.sameAgent && Number.isFinite(candidate.distanceUnits) && candidate.distanceUnits <= 1_000));
  const closeSample = evidence.utilityCloses.find((sample) =>
    sample.actorNetGuid === actor.actorNetGuid && sample.timeMs === closeMs) ?? null;
  const round = roundAt(evidence.roundStarts, closeMs);
  return {
    id: label?.id ?? `${evidence.replayUuid.slice(0, 8)}_${actor.actorNetGuid}_${closeMs}`,
    replayUuid: evidence.replayUuid,
    humanLabel: label ? {
      tag: label.tag,
      comment: label.comment ?? '',
      round: label.round ?? null,
      agent: label.agent ?? null,
      slot: label.slot ?? null,
      abilityName: label.abilityName ?? null,
      actorClass: label.actorClass ?? null,
    } : null,
    round: {
      ...round,
      closeToNextRoundStartMs: Number.isFinite(round.nextRoundStartMs)
        ? round.nextRoundStartMs - closeMs
        : null,
    },
    actor: actorSummary(actor),
    actorClose: closeSample,
    ownerChain,
    ownerPlayer,
    ownerResolution,
    wireWindow: {
      beforeMs: signalBeforeMs,
      afterMs: signalAfterMs,
      rawClassNetCacheStoredRange: {
        firstTimeMs: evidence.classNetCacheSamples[0]?.timeMs ?? null,
        lastTimeMs: evidence.classNetCacheSamples.at(-1)?.timeMs ?? null,
        sampleCount: evidence.classNetCacheSamples.length,
        cappedAt: 20_000,
      },
      abilitySignalCoverage: {
        sampleCount: evidence.abilitySignals.length,
        overflowCount: evidence.frame.abilitySignalOverflowCount ?? 0,
      },
    },
    wireSignals,
    rawClassNetCacheCalls,
    ownerInputEvents,
    nearbyOpens,
  };
}

export function replayDirectories() {
  return fs.readdirSync(CORPUS_DIR, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^[0-9a-f-]{36}$/i.test(entry.name))
    .map((entry) => entry.name)
    .sort();
}

export function findActorForLabel(evidence, label) {
  return evidence.utilityActors.find((actor) =>
    actor.actorNetGuid === label.actorNetGuid && actor.closedAtMs === label.timeMs) ??
    evidence.utilityActors.find((actor) => actor.actorNetGuid === label.actorNetGuid) ?? null;
}

function renderProbeSummary(clusters) {
  const byClass = new Map();
  for (const cluster of clusters) {
    const key = cluster.actor.className;
    if (!byClass.has(key)) byClass.set(key, []);
    byClass.get(key).push(cluster);
  }
  const lines = [];
  for (const [className, rows] of [...byClass.entries()].sort()) {
    lines.push(`\n${className} (${rows.length})`);
    for (const row of rows) {
      const finalSignals = row.wireSignals
        .filter((signal) => signal.offsetMs >= -6_000)
        .map((signal) => `${signal.offsetMs}:${signal.token}`);
      const inputs = row.ownerInputEvents
        .filter((input) => input.offsetMs >= -1_500)
        .map((input) => `${input.offsetMs}:${input.eventType}(${input.eventValueNibble})`);
      const opens = row.nearbyOpens
        .filter((open) => open.sameRound)
        .map((open) => `${open.offsetMs}:${open.actor.className}@${Math.round(open.distanceUnits ?? -1)}`);
      lines.push([
        `  ${row.id} ${row.humanLabel.tag}`,
        `life=${row.actor.observedLifetimeMs}`,
        `end=${row.actor.endReason}`,
        `signals=[${finalSignals.join(', ')}]`,
        `inputs=[${inputs.join(', ')}]`,
        `opens=[${opens.join(', ')}]`,
      ].join(' | '));
    }
  }
  return `${lines.join('\n').trim()}\n`;
}

async function main() {
  const labelsDocument = JSON.parse(fs.readFileSync(LABELS_PATH, 'utf8'));
  const labelsByReplay = new Map();
  for (const label of labelsDocument.tags ?? []) {
    if (!labelsByReplay.has(label.replayUuid)) labelsByReplay.set(label.replayUuid, []);
    labelsByReplay.get(label.replayUuid).push(label);
  }
  const clusters = [];
  const missing = [];
  const replayCoverage = [];
  for (const replayUuid of replayDirectories()) {
    const labels = labelsByReplay.get(replayUuid) ?? [];
    if (!labels.length) continue;
    const evidence = loadReplayEvidence(replayUuid);
    replayCoverage.push({
      replayUuid,
      labels: labels.length,
      abilitySignals: evidence.abilitySignals.length,
      abilitySignalOverflowCount: evidence.frame.abilitySignalOverflowCount ?? 0,
      rawClassNetCacheSamples: evidence.classNetCacheSamples.length,
      rawClassNetCacheFirstMs: evidence.classNetCacheSamples[0]?.timeMs ?? null,
      rawClassNetCacheLastMs: evidence.classNetCacheSamples.at(-1)?.timeMs ?? null,
    });
    for (const label of labels) {
      const actor = findActorForLabel(evidence, label);
      if (!actor) {
        missing.push({ id: label.id, reason: 'utility actor not found' });
        continue;
      }
      clusters.push(extractCloseCluster(evidence, actor, label));
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
  const output = {
    meta: {
      schema: 'icarus-labeled-close-wire-clusters-v1',
      generatedAt: new Date().toISOString(),
      sourceLabels: LABELS_PATH,
      signalWindowMs: { before: 6_000, after: 250 },
      nearbyOpenWindowMs: { before: 2_000, after: 2_000 },
      note: 'abilitySignalSamples are the complete filtered RepLayout/ClassNetCache layer for this corpus; every replay reports zero overflow. Stored generic classNetCacheSamples are capped and are retained separately where available.',
    },
    replayCoverage,
    expectedLabelCount: labelsDocument.tags?.length ?? 0,
    extractedLabelCount: clusters.length,
    missing,
    clusters,
  };
  fs.writeFileSync(CLUSTERS_PATH, `${JSON.stringify(output, null, 2)}\n`);
  console.log(renderProbeSummary(clusters));
  console.error(JSON.stringify({
    clustersPath: CLUSTERS_PATH,
    expected: output.expectedLabelCount,
    extracted: output.extractedLabelCount,
    missing: missing.length,
  }, null, 2));
}

const invokedPath = process.argv[1] == null ? null : path.resolve(process.argv[1]);
if (invokedPath && invokedPath.toLowerCase() === fileURLToPath(import.meta.url).toLowerCase()) {
  main().catch((error) => {
    console.error(error.stack ?? error);
    process.exitCode = 1;
  });
}
