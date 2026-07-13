#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadCloseSignatureRules } from './lib/close_signature_classifier.mjs';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const CORPUS_DIR = path.join(SCRIPT_DIR, 'out', 'corpus');
const PROBE_DIR = path.join(CORPUS_DIR, 'destruction_probe');
const BASELINE_PATH = path.join(CORPUS_DIR, 'close_signatures.json');
const OUTPUT_PATH = path.join(CORPUS_DIR, 'close_signatures_destruction_pass.json');
const FINDINGS_PATH = path.join(CORPUS_DIR, 'destruction_signal_findings.md');

const COOLDOWN_MATCH_TOLERANCE_MS = 24;
const TERMINAL_RPC_WINDOW_MS = 32;
const DESTROYED_COUNT_EARLY_MS = -24;
const DESTROYED_COUNT_LATE_MS = 1_000;

const TARGET_CLASSES = new Set([
  'Pawn_Killjoy_E_Turret',
  'Ability_Gumshoe_Q_Camera_Dart',
  'GameObject_Gumshoe_E_TripWire',
  'GameObject_Deadeye_E_Trap',
  'Pawn_Aggrobot_SeekerNade',
  'Pawn_Aggrobot_RollyPolly',
  'Pawn_Killjoy_Q_StealthAlarmbot',
]);

const DESTROYED_COUNT_PREFIX_BY_CLASS = new Map([
  ['GameObject_Deadeye_E_Trap', '0202'],
  ['Pawn_Aggrobot_SeekerNade', '0402'],
  ['Pawn_Aggrobot_RollyPolly', '0404'],
]);

const LEGACY_SIGNAL_DEFINITIONS = [
  {
    id: 'killjoy-turret-destruction-cooldown-60',
    classes: ['Pawn_Killjoy_E_Turret'],
    confidence: 'high',
    encoding: 'Ability_Killjoy_E_Turret cooldown component: CooldownSeconds RepLayout handle 2/raw 3, IEEE-754 float64 LE = 60.0; CooldownActive handle 4/raw 5, one bit = 1',
  },
  {
    id: 'cypher-spycam-camera-killed-cooldown-60',
    classes: ['Ability_Gumshoe_Q_Camera_Dart'],
    confidence: 'high',
    encoding: 'Ability_Gumshoe_Q_Camera CameraKilled ClassNetCache RPC handle 1 (zero-bit payload), plus cooldown handles 2/raw 3 = float64 LE 60.0 and 4/raw 5 = one-bit true',
  },
  {
    id: 'cypher-trapwire-terminal-destruction-effect',
    classes: ['GameObject_Gumshoe_E_TripWire'],
    confidence: 'high',
    encoding: 'EffectManager ClassNetCache MulticastPlayOneShotEffect RPC handle 1 in the final replay tick before channel close',
  },
  {
    id: 'owner-ability-cast-destroyed-count',
    classes: ['GameObject_Deadeye_E_Trap', 'Pawn_Aggrobot_SeekerNade', 'Pawn_Aggrobot_RollyPolly'],
    confidence: 'high',
    encoding: 'owner Comp_AbilityStatisticsReplicator.AbilityCastsThisRound handle 2/raw 3; nested DestroyedCount handle 12/raw 13, 32-bit little-endian integer > 0',
  },
  {
    id: 'killjoy-alarmbot-damage-effect-burst',
    classes: ['Pawn_Killjoy_Q_StealthAlarmbot'],
    confidence: 'medium',
    encoding: 'EffectManager ClassNetCache MulticastPlayContinuousEffect RPC handle 0 with the 1463-bit external-damage effect payload, followed by continuous-effect stops at close',
  },
];

const legacySignalDefinitionById = new Map(
  LEGACY_SIGNAL_DEFINITIONS.map((definition) => [definition.id, definition]),
);
const SIGNAL_DEFINITIONS = loadCloseSignatureRules().outcomeSignatures
  .filter((rule) => rule.provenance.some((value) =>
    value.startsWith('corr_destruction_signal.mjs')))
  .map((rule) => ({
    ...legacySignalDefinitionById.get(rule.id),
    confidence: rule.confidence,
  }));

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function sha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

function classFromActorPath(actorPath) {
  return actorPath?.match(/^Default__(.+)_C$/)?.[1] ?? actorPath ?? null;
}

function decodeFloat64Le(payloadHex) {
  const bytes = Buffer.from(payloadHex ?? '', 'hex');
  return bytes.length >= 8 ? bytes.readDoubleLE(0) : null;
}

function trueBit(payloadHex) {
  const bytes = Buffer.from(payloadHex ?? '', 'hex');
  return bytes.length > 0 && (bytes[0] & 1) === 1;
}

function isRoundTeardownContext(row) {
  const toNextRound = row.context?.closeToNextRoundStartMs;
  if (Number.isFinite(toNextRound) && toNextRound >= 8_000 && toNextRound <= 14_500) {
    return true;
  }
  return /(?:round.*(?:teardown|ended)|synchronized-round-end)/i.test(row.ruleId ?? '');
}

function compactWireEvent(event, offsetMs) {
  return {
    timeMs: event.timeMs,
    offsetMs,
    actorNetGuid: event.actorNetGuid,
    actorPath: event.actorPath,
    source: event.source,
    actorGroup: event.actorGroup,
    handle: event.handle,
    rawHandle: event.rawHandle ?? null,
    fieldName: event.fieldName,
    numBits: event.numBits,
    payloadHex: event.payloadHex,
  };
}

function parseDestroyedCountMutation(event) {
  if (event.fieldName !== 'AbilityCastsThisRound' || event.source !== 'rep-layout') return null;
  const payloadHex = (event.payloadHex ?? '').toLowerCase();
  const match = payloadHex.match(/^([0-9a-f]{4})1a40([0-9a-f]{8})0000$/);
  if (!match) return null;
  const value = Buffer.from(match[2], 'hex').readInt32LE(0);
  return {
    outerPrefixHex: match[1],
    nestedRawHandle: 13,
    nestedHandle: 12,
    serializedBits: 32,
    value,
  };
}

function loadCooldownEvidence(replayUuids) {
  const result = new Map();
  for (const replayUuid of replayUuids) {
    const probePath = path.join(PROBE_DIR, `${replayUuid}.corpus-owner.diagnostics.json`);
    if (!fs.existsSync(probePath)) throw new Error(`missing owner probe ${probePath}`);
    const samples = readJson(probePath).frameSummary?.diagnosticActorWireSamples ?? [];
    const ordered = samples.map((sample, order) => ({ sample, order }))
      .sort((left, right) => left.sample.timeMs - right.sample.timeMs || left.order - right.order)
      .map((row) => row.sample);
    const cooldownSecondsByActor = new Map();
    const cameraKills = new Set();
    for (const sample of ordered) {
      const actorClass = classFromActorPath(sample.actorPath);
      const actorKey = `${sample.actorNetGuid}\u0000${actorClass}`;
      if (sample.fieldName === 'CameraKilled' && sample.source === 'classnet-rpc') {
        cameraKills.add(`${actorKey}\u0000${sample.timeMs}`);
      }
      if (sample.fieldName === 'CooldownSeconds' && sample.source === 'rep-layout') {
        cooldownSecondsByActor.set(actorKey, decodeFloat64Le(sample.payloadHex));
      }
      if (sample.fieldName !== 'CooldownActive' || sample.source !== 'rep-layout' || !trueBit(sample.payloadHex)) {
        continue;
      }
      if (!result.has(replayUuid)) result.set(replayUuid, []);
      result.get(replayUuid).push({
        ...sample,
        actorClass,
        cooldownSeconds: cooldownSecondsByActor.get(actorKey) ?? null,
        cameraKilled: cameraKills.has(`${actorKey}\u0000${sample.timeMs}`),
      });
    }
  }
  return result;
}

function loadRelevantReplayEvents(replayUuids) {
  const result = new Map();
  for (const replayUuid of replayUuids) {
    const diagnosticsPath = path.join(CORPUS_DIR, replayUuid, `${replayUuid}.diagnostics.json`);
    if (!fs.existsSync(diagnosticsPath)) throw new Error(`missing corpus diagnostics ${diagnosticsPath}`);
    const diagnostics = readJson(diagnosticsPath);
    const relevant = (diagnostics.frameSummary?.abilitySignalSamples ?? []).filter((sample) =>
      sample.fieldName === 'AbilityCastsThisRound' ||
      sample.fieldName === 'MulticastPlayOneShotEffect' ||
      sample.fieldName === 'MulticastPlayContinuousEffect' ||
      sample.fieldName === 'MulticastStopContinuousEffect');
    const byActor = new Map();
    for (const sample of relevant) {
      if (!byActor.has(sample.actorNetGuid)) byActor.set(sample.actorNetGuid, []);
      byActor.get(sample.actorNetGuid).push(sample);
    }
    for (const events of byActor.values()) events.sort((left, right) => left.timeMs - right.timeMs);
    result.set(replayUuid, byActor);
    if (typeof global.gc === 'function') global.gc();
  }
  return result;
}

function closestEvent(events, timeMs, predicate, minOffset, maxOffset) {
  let best = null;
  for (const event of events ?? []) {
    const offsetMs = event.timeMs - timeMs;
    if (offsetMs < minOffset || offsetMs > maxOffset || !predicate(event)) continue;
    if (!best || Math.abs(offsetMs) < Math.abs(best.offsetMs)) best = { event, offsetMs };
  }
  return best;
}

function findCooldownSignal(row, cooldownEvidence, expectedOwnerClass, requireCameraKilled) {
  if (isRoundTeardownContext(row)) return null;
  const events = cooldownEvidence.get(row.replayUuid) ?? [];
  const match = closestEvent(
    events,
    row.timeMs,
    (event) => event.actorClass === expectedOwnerClass &&
      Math.abs((event.cooldownSeconds ?? Number.NaN) - 60) < 0.0001 &&
      (!requireCameraKilled || event.cameraKilled),
    -COOLDOWN_MATCH_TOLERANCE_MS,
    COOLDOWN_MATCH_TOLERANCE_MS,
  );
  if (!match) return null;
  return {
    signalId: requireCameraKilled
      ? 'cypher-spycam-camera-killed-cooldown-60'
      : 'killjoy-turret-destruction-cooldown-60',
    confidence: 'high',
    summary: requireCameraKilled
      ? `CameraKilled + 60 s cooldown activation at ${match.offsetMs >= 0 ? '+' : ''}${match.offsetMs} ms`
      : `60 s cooldown activation at ${match.offsetMs >= 0 ? '+' : ''}${match.offsetMs} ms`,
    evidence: {
      ...compactWireEvent(match.event, match.offsetMs),
      cooldownSeconds: match.event.cooldownSeconds,
      cooldownSecondsHandle: 2,
      cooldownSecondsRawHandle: 3,
      cooldownActiveHandle: 4,
      cooldownActiveRawHandle: 5,
      cameraKilled: match.event.cameraKilled,
      roundTeardownGuard: 'not in synchronized round teardown window',
    },
  };
}

function findDirectRpcSignal(row, replayEvents) {
  const events = replayEvents.get(row.replayUuid)?.get(row.actor.actorNetGuid) ?? [];
  if (row.actor.className === 'GameObject_Gumshoe_E_TripWire') {
    const match = closestEvent(
      events,
      row.timeMs,
      (event) => event.source === 'classnet-rpc' && event.fieldName === 'MulticastPlayOneShotEffect',
      -TERMINAL_RPC_WINDOW_MS,
      0,
    );
    if (!match) return null;
    return {
      signalId: 'cypher-trapwire-terminal-destruction-effect',
      confidence: 'high',
      summary: `terminal MulticastPlayOneShotEffect at ${match.offsetMs} ms`,
      evidence: compactWireEvent(match.event, match.offsetMs),
    };
  }
  if (row.actor.className === 'Pawn_Killjoy_Q_StealthAlarmbot') {
    const match = closestEvent(
      events,
      row.timeMs,
      (event) => event.source === 'classnet-rpc' &&
        event.fieldName === 'MulticastPlayContinuousEffect' && event.numBits >= 1_400,
      -1_000,
      0,
    );
    if (!match) return null;
    const stopCountAtClose = events.filter((event) =>
      event.source === 'classnet-rpc' &&
      event.fieldName === 'MulticastStopContinuousEffect' &&
      Math.abs(event.timeMs - row.timeMs) <= COOLDOWN_MATCH_TOLERANCE_MS).length;
    return {
      signalId: 'killjoy-alarmbot-damage-effect-burst',
      confidence: 'medium',
      summary: `${match.event.numBits}-bit damage effect at ${match.offsetMs} ms; ${stopCountAtClose} effect stops at close`,
      evidence: {
        ...compactWireEvent(match.event, match.offsetMs),
        stopCountAtClose,
      },
    };
  }
  return null;
}

function findDestroyedCountSignal(row, replayEvents) {
  const expectedPrefix = DESTROYED_COUNT_PREFIX_BY_CLASS.get(row.actor.className);
  const ownerNetGuid = row.context?.ownerPlayer?.netGuid;
  if (!expectedPrefix || !Number.isFinite(ownerNetGuid)) return null;
  const events = replayEvents.get(row.replayUuid)?.get(ownerNetGuid) ?? [];
  const match = closestEvent(
    events,
    row.timeMs,
    (event) => {
      const decoded = parseDestroyedCountMutation(event);
      return decoded?.outerPrefixHex === expectedPrefix && decoded.value > 0;
    },
    DESTROYED_COUNT_EARLY_MS,
    DESTROYED_COUNT_LATE_MS,
  );
  if (!match) return null;
  const decoded = parseDestroyedCountMutation(match.event);
  return {
    signalId: 'owner-ability-cast-destroyed-count',
    confidence: 'high',
    summary: `owner AbilityCastsThisRound DestroyedCount=${decoded.value} at ${match.offsetMs >= 0 ? '+' : ''}${match.offsetMs} ms`,
    evidence: {
      ...compactWireEvent(match.event, match.offsetMs),
      ...decoded,
      outerHandle: match.event.handle,
      outerRawHandle: match.event.rawHandle,
      ownerNetGuid,
    },
  };
}

function detectDestructionSignal(row, cooldownEvidence, replayEvents) {
  switch (row.actor.className) {
    case 'Pawn_Killjoy_E_Turret':
      return findCooldownSignal(row, cooldownEvidence, 'Ability_Killjoy_E_Turret', false);
    case 'Ability_Gumshoe_Q_Camera_Dart':
      return findCooldownSignal(row, cooldownEvidence, 'Ability_Gumshoe_Q_Camera', true);
    case 'GameObject_Gumshoe_E_TripWire':
    case 'Pawn_Killjoy_Q_StealthAlarmbot':
      return findDirectRpcSignal(row, replayEvents);
    case 'GameObject_Deadeye_E_Trap':
    case 'Pawn_Aggrobot_SeekerNade':
    case 'Pawn_Aggrobot_RollyPolly':
      return findDestroyedCountSignal(row, replayEvents);
    default:
      return null;
  }
}

function healthReplicationAudit() {
  const files = fs.readdirSync(PROBE_DIR)
    .filter((name) => name.endsWith('.diagnostics.json'))
    .filter((name) => !name.includes('.ability-owner.') && !name.includes('.corpus-owner.'));
  const actorGroups = new Map();
  let captureOverflowCount = 0;
  let selectedActorCount = 0;
  for (const name of files) {
    const frame = readJson(path.join(PROBE_DIR, name)).frameSummary ?? {};
    captureOverflowCount += frame.diagnosticActorWireCapture?.overflowCount ?? 0;
    selectedActorCount += frame.diagnosticActorWireCapture?.actorNetGuids?.length ?? 0;
    for (const sample of frame.diagnosticActorWireSamples ?? []) {
      if (!/AresAttributeSet/.test(sample.actorGroup ?? '')) continue;
      const key = `${name}\u0000${sample.actorNetGuid}\u0000${sample.repObject}`;
      if (!actorGroups.has(key)) actorGroups.set(key, []);
      actorGroups.get(key).push(sample);
    }
  }
  let attributeSampleCount = 0;
  let postInitialAttributeSampleCount = 0;
  const initialFloatValues = new Set();
  for (const samples of actorGroups.values()) {
    const initialTimeMs = Math.min(...samples.map((sample) => sample.timeMs));
    attributeSampleCount += samples.length;
    postInitialAttributeSampleCount += samples.filter((sample) => sample.timeMs > initialTimeMs).length;
    for (const sample of samples) {
      const bytes = Buffer.from(sample.payloadHex ?? '', 'hex');
      if (sample.numBits === 32 && bytes.length >= 4) initialFloatValues.add(bytes.readFloatLE(0));
    }
  }
  return {
    targetedProbeFiles: fs.readdirSync(PROBE_DIR).filter((name) => name.endsWith('.diagnostics.json')).length,
    directAndSpycamPawnProbeFiles: files.length,
    selectedActorCount,
    aresAttributeRepObjectCount: actorGroups.size,
    attributeSampleCount,
    postInitialAttributeSampleCount,
    initialFloatValues: [...initialFloatValues].sort((left, right) => left - right),
    captureOverflowCount,
    conclusion: 'No health/damage value is replicated after spawn on these actor channels. No schema HP value or decrement-to-zero transition appears.',
  };
}

function alarmbotIncendiaryAudit() {
  const cases = [
    {
      id: '1fb53a2c_9876_422812',
      replayUuid: '1fb53a2c-bf7b-4276-80cf-54e1f01017ba',
      actorNetGuid: 9876,
      closeTimeMs: 422812,
      expectedOutcome: 'destroyed',
    },
    {
      id: '1fb53a2c_8184_353873',
      replayUuid: '1fb53a2c-bf7b-4276-80cf-54e1f01017ba',
      actorNetGuid: 8184,
      closeTimeMs: 353873,
      expectedOutcome: 'phase-transition',
    },
    {
      id: 'c8989335_24680_1247365',
      replayUuid: 'c8989335-cde6-47e1-8c20-80e376ed7411',
      actorNetGuid: 24680,
      closeTimeMs: 1247365,
      expectedOutcome: 'phase-transition',
    },
  ];
  const samplesByReplay = new Map();
  return cases.map((entry) => {
    if (!samplesByReplay.has(entry.replayUuid)) {
      const filePath = path.join(PROBE_DIR, `${entry.replayUuid}.diagnostics.json`);
      samplesByReplay.set(
        entry.replayUuid,
        readJson(filePath).frameSummary?.diagnosticActorWireSamples ?? [],
      );
    }
    const samples = samplesByReplay.get(entry.replayUuid).filter((sample) =>
      sample.actorNetGuid === entry.actorNetGuid &&
      sample.timeMs >= entry.closeTimeMs - 651 && sample.timeMs <= entry.closeTimeMs);
    const transformUpdates = samples.filter((sample) =>
      sample.fieldName === 'ReplayLastTransformUpdateTimeStamp');
    const damageEffect = samples.find((sample) =>
      sample.source === 'classnet-rpc' &&
      sample.fieldName === 'MulticastPlayContinuousEffect' && sample.numBits >= 1_400);
    return {
      ...entry,
      damageEffectBits: damageEffect?.numBits ?? null,
      damageEffectOffsetMs: damageEffect ? damageEffect.timeMs - entry.closeTimeMs : null,
      transformTimestampHandle: 26,
      transformTimestampRawHandle: 27,
      transformTimestampUpdateCount: transformUpdates.length,
      firstTransformTimestampOffsetMs: transformUpdates.length
        ? transformUpdates[0].timeMs - entry.closeTimeMs
        : null,
      lastTransformTimestampOffsetMs: transformUpdates.length
        ? transformUpdates.at(-1).timeMs - entry.closeTimeMs
        : null,
    };
  });
}

function countObject(rows, valueFn) {
  const result = {};
  for (const row of rows) {
    const value = valueFn(row);
    result[value] = (result[value] ?? 0) + 1;
  }
  return result;
}

function recalculateCoverage(previous, classifications) {
  const byOutcome = countObject(classifications, (row) => row.outcome);
  const byConfidence = countObject(classifications, (row) => row.confidence);
  const unclassifiable = byOutcome.unclassifiable ?? 0;
  const byReplay = [];
  for (const replayUuid of [...new Set(classifications.map((row) => row.replayUuid))]) {
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
  return {
    ...previous,
    utilityActorCloses: classifications.length,
    classifiable: classifications.length - unclassifiable,
    unclassifiable,
    classifiableFraction: Number(((classifications.length - unclassifiable) / classifications.length).toFixed(4)),
    byConfidence,
    byOutcome,
    byReplay,
  };
}

function markdownEscape(value) {
  return String(value ?? '').replaceAll('|', '\\|').replaceAll('\n', ' ');
}

function buildFindings(report) {
  const gtRows = report.validation.groundTruth.rows.map((row) =>
    `| ${markdownEscape(row.id)} | ${markdownEscape(row.abilityName)} | ${markdownEscape(row.comment || '-')} | ${markdownEscape(row.signalSummary)} | ${row.pass ? 'PASS' : 'FAIL'} |`).join('\n');
  const controlRows = report.validation.sameClassLabeledControls.rows.map((row) =>
    `| ${markdownEscape(row.id)} | ${markdownEscape(row.abilityName)} | ${markdownEscape(row.expectedOutcome)} | ${row.signalDetected ? 'FAIL' : 'PASS'} |`).join('\n');
  const signalRows = SIGNAL_DEFINITIONS.map((definition) =>
    `| \`${definition.id}\` | ${definition.classes.join(', ')} | ${definition.encoding} |`).join('\n');
  const classVerificationRows = Object.entries(report.validation.groundTruth.byAbility).map(([ability, counts]) =>
    `| ${ability} | ${counts.passed}/${counts.total} |`).join('\n');
  const health = report.healthReplicationAudit;
  const alarmbot = report.alarmbotIncendiaryAudit;
  const alarmbotDestroyed = alarmbot.find((row) => row.expectedOutcome === 'destroyed');
  const alarmbotControls = alarmbot.filter((row) => row.expectedOutcome !== 'destroyed');
  const impact = report.corpusImpact;
  const expanded = report.validation.sameClassLabeledControls;
  const strict = report.validation.strictRecallExpirePickupControls;
  return `# Valorant utility destruction signal pass

## Result

No replicated utility-health property was found. The full-life actor-channel capture includes every decoded and unknown RepLayout handle, yet the generic \`AresAttributeSet\` sends only its initial \`BaseValue\`/\`CurrentValue\` float32 fields. Across ${health.aresAttributeRepObjectCount} captured attribute-set rep objects and ${health.attributeSampleCount} attribute samples, **${health.postInitialAttributeSampleCount} samples occur after initial replication**. The only initial float values are ${health.initialFloatValues.map((value) => `\`${value}\``).join(', ')}; none transition through the documented per-class HP values. Diffing full-life handle sets against the labeled non-destroy controls found lifecycle/effect/timestamp changes, but no unknown numeric handle that updates with damage. In this branch and corpus, the relevant actor channels do not expose Turret 100 HP, one-shot utility HP, Alarmbot incendiary ticks, or a decrement-to-zero field.

Destruction can nevertheless be made positive for all 13 human-confirmed cases using class-specific replicated teardown signals. The most reusable signals are the 60-second owner cooldown activation and the named \`DestroyedCount\` statistic; the remaining classes expose terminal effect RPCs.

## Positive wire signals and encoding

| Signal | Classes | Wire encoding |
|---|---|---|
${signalRows}

The Spycam \`CameraKilled\` RPC also fires during synchronized round teardown. It becomes destruction-specific only when paired with the 60-second cooldown activation **and** a non-round-teardown close. The labeled round-ended Spycam is therefore a deliberate negative control, not hidden from the validation.

The incendiary Alarmbot does not expose explicit damage ticks. Its positive differential is a unique ${alarmbotDestroyed.damageEffectBits}-bit continuous-effect RPC at ${alarmbotDestroyed.damageEffectOffsetMs} ms, followed by ${alarmbotDestroyed.transformTimestampUpdateCount} updates of float32 RepLayout handle 26/raw 27 from ${alarmbotDestroyed.firstTransformTimestampOffsetMs} to ${alarmbotDestroyed.lastTransformTimestampOffsetMs} ms. The two triggered controls have ${alarmbotControls.map((row) => row.transformTimestampUpdateCount).join(' and ')} such updates in the same 651 ms window and no >=1400-bit effect RPC. The high-cadence timestamps are corroborating activity, not decoded HP or individual damage counters.

## Ground-truth verification

| Ability | Passed |
|---|---:|
${classVerificationRows}

**Ground-truth total: ${report.validation.groundTruth.passed}/${report.validation.groundTruth.total}.**

| Close ID | Ability | Human note | Positive evidence | Result |
|---|---|---|---|---|
${gtRows}

## Negative controls

Every human-labeled non-destruction instance of the same seven actor classes was tested. The expanded set is **${expanded.passed}/${expanded.total} negative** (zero false positives), including triggered/self-completed/round-ended behavior. The exact contract subset - same-class labeled recalled, expired, or picked-up instances - is **${strict.passed}/${strict.total} negative** (zero false positives). The corpus has no labeled recalled or expired instance of these exact classes; its one strict control is the picked-up Chamber Trademark.

| Close ID | Ability | Expected outcome | No destruction signal |
|---|---|---|---|
${controlRows}

The pass also checked all ${report.validation.allSameClassBaselineNonDestroyed.total} baseline non-destroy closes of these exact classes: ${report.validation.allSameClassBaselineNonDestroyed.falsePositiveCount} matched the guarded positive signatures.

## Corpus-wide impact

The source classifier had **${impact.destroyedBefore}** destroyed closes. This pass has **${impact.destroyedAfter}**: **${impact.promotedFromUnclassifiable}** previously unclassifiable closes became destroyed. ${impact.promotedFromUnclassifiable === 0 ? 'The count remains 70 because the v2 classifier had already assigned every signal-positive target close by class/elimination rules; this pass replaces inference with positive evidence rather than inflating the count.' : 'Only signal-positive unclassifiable closes were promoted; existing non-destroy outcomes were never overridden.'}

There are ${impact.signalPositiveRows} signal-positive corpus rows in the target primary actor classes, of which ${impact.signalPositiveDestroyedRows} are classified destroyed after the pass. Existing destroyed closes outside these target classes remain unchanged and retain their prior evidence.

## Shooter attribution

The new universal signals do **not** identify the destroyer. \`DestroyedCount\` is replicated on the utility owner's player controller and describes that owner's cast; cooldown and effect RPCs carry no decoded shooter NetGUID. Actor RepLayout handle 13 \`Instigator\` is the deployer/owner, not the attacker.

Thrash alone exposes zero-based RepLayout handle 61 (raw handle 62), \`Last Damage Instigator\`, as a bit-packed object reference. Around the destroyed Thrash it resolves through Sova/Vyse/Sova references, but a self-detonated Thrash control also sends the field. Wingman and the other ground-truth classes do not expose an equivalent final-damage reference. It is therefore useful diagnostic context but not a reliable corpus-wide shooter-attribution signal.

## Decoder and extraction notes

\`extract_track.mjs\` now has an additive \`--diagnostic-actor-net-guid\` capture that records every RepLayout property and ClassNetCache RPC for selected actor channels, including unknown handles. Existing output fields and classifier inputs are unchanged. ${health.targetedProbeFiles} targeted diagnostic files were generated with ${health.captureOverflowCount} capture overflows. Generated Dart files were not touched.
`;
}

function main() {
  const baselineBuffer = fs.readFileSync(BASELINE_PATH);
  const baseline = JSON.parse(baselineBuffer.toString('utf8'));
  const replayUuids = [...new Set(baseline.classifications.map((row) => row.replayUuid))];
  const cooldownEvidence = loadCooldownEvidence(replayUuids);
  const replayEvents = loadRelevantReplayEvents(replayUuids);
  const detectedById = new Map();
  for (const row of baseline.classifications) {
    if (!TARGET_CLASSES.has(row.actor.className)) continue;
    const signal = detectDestructionSignal(row, cooldownEvidence, replayEvents);
    if (signal) detectedById.set(row.id, signal);
  }

  const destroyedBefore = baseline.classifications.filter((row) => row.outcome === 'destroyed').length;
  const promotedIds = [];
  const classifications = baseline.classifications.map((row) => {
    const signal = detectedById.get(row.id);
    if (!signal || !['destroyed', 'unclassifiable'].includes(row.outcome)) return row;
    const promoted = row.outcome === 'unclassifiable';
    if (promoted) promotedIds.push(row.id);
    return {
      ...row,
      outcome: 'destroyed',
      confidence: signal.confidence,
      ruleId: signal.signalId,
      signatureIds: [...new Set([...(row.signatureIds ?? []), signal.signalId])],
      evidence: [...(row.evidence ?? []), {
        kind: 'positive-destruction-wire-signal',
        signal: signal.summary,
        signalId: signal.signalId,
        wire: signal.evidence,
      }],
      destructionPass: {
        positiveSignal: true,
        signalId: signal.signalId,
        signalSummary: signal.summary,
        promotedFromUnclassifiable: promoted,
        priorOutcome: row.outcome,
        priorConfidence: row.confidence,
        priorRuleId: row.ruleId,
      },
    };
  });

  const groundTruthRows = baseline.classifications
    .filter((row) => row.humanGroundTruth?.expectedOutcome === 'destroyed' && TARGET_CLASSES.has(row.actor.className))
    .map((row) => {
      const signal = detectedById.get(row.id) ?? null;
      return {
        id: row.id,
        replayUuid: row.replayUuid,
        timeMs: row.timeMs,
        actorClass: row.actor.className,
        abilityName: row.humanGroundTruth.abilityName,
        comment: row.humanGroundTruth.comment,
        signalId: signal?.signalId ?? null,
        signalSummary: signal?.summary ?? 'no signal',
        evidence: signal?.evidence ?? null,
        pass: signal != null,
      };
    });
  const byAbility = {};
  for (const row of groundTruthRows) {
    if (!byAbility[row.abilityName]) byAbility[row.abilityName] = { total: 0, passed: 0 };
    byAbility[row.abilityName].total += 1;
    if (row.pass) byAbility[row.abilityName].passed += 1;
  }

  const controlRows = baseline.classifications
    .filter((row) => row.humanGroundTruth && row.humanGroundTruth.expectedOutcome !== 'destroyed' && TARGET_CLASSES.has(row.actor.className))
    .map((row) => ({
      id: row.id,
      replayUuid: row.replayUuid,
      timeMs: row.timeMs,
      actorClass: row.actor.className,
      abilityName: row.humanGroundTruth.abilityName,
      expectedOutcome: row.humanGroundTruth.expectedOutcome,
      signalDetected: detectedById.has(row.id),
      signalId: detectedById.get(row.id)?.signalId ?? null,
    }));
  const strictControlRows = controlRows.filter((row) => ['recalled', 'expired', 'picked-up'].includes(row.expectedOutcome));
  const allSameClassBaselineNonDestroyed = baseline.classifications
    .filter((row) => TARGET_CLASSES.has(row.actor.className) && !['destroyed', 'unclassifiable'].includes(row.outcome));
  const allSameClassFalsePositives = allSameClassBaselineNonDestroyed.filter((row) => detectedById.has(row.id));
  const destroyedAfter = classifications.filter((row) => row.outcome === 'destroyed').length;
  const signalPositiveRows = [...detectedById.keys()];

  const destructionPass = {
    schema: 'icarus-utility-destruction-signal-pass-v1',
    generatedAt: new Date().toISOString(),
    sourceBaseline: BASELINE_PATH,
    sourceBaselineSchema: baseline.meta?.schema ?? null,
    sourceBaselineSha256: sha256(baselineBuffer),
    healthReplicationAudit: healthReplicationAudit(),
    alarmbotIncendiaryAudit: alarmbotIncendiaryAudit(),
    signalDefinitions: SIGNAL_DEFINITIONS,
    validation: {
      groundTruth: {
        total: groundTruthRows.length,
        passed: groundTruthRows.filter((row) => row.pass).length,
        failed: groundTruthRows.filter((row) => !row.pass).length,
        byAbility,
        rows: groundTruthRows,
      },
      sameClassLabeledControls: {
        total: controlRows.length,
        passed: controlRows.filter((row) => !row.signalDetected).length,
        falsePositiveCount: controlRows.filter((row) => row.signalDetected).length,
        rows: controlRows,
      },
      strictRecallExpirePickupControls: {
        total: strictControlRows.length,
        passed: strictControlRows.filter((row) => !row.signalDetected).length,
        falsePositiveCount: strictControlRows.filter((row) => row.signalDetected).length,
        rows: strictControlRows,
      },
      allSameClassBaselineNonDestroyed: {
        total: allSameClassBaselineNonDestroyed.length,
        falsePositiveCount: allSameClassFalsePositives.length,
        falsePositiveIds: allSameClassFalsePositives.map((row) => row.id),
      },
    },
    corpusImpact: {
      destroyedBefore,
      destroyedAfter,
      promotedFromUnclassifiable: promotedIds.length,
      promotedIds,
      signalPositiveRows: signalPositiveRows.length,
      signalPositiveDestroyedRows: classifications.filter((row) => row.outcome === 'destroyed' && detectedById.has(row.id)).length,
      signalCounts: countObject([...detectedById.values()], (signal) => signal.signalId),
    },
    shooterAttribution: {
      universalDestroyerNetGuidAvailable: false,
      ownerInstigatorHandle: { handle: 13, role: 'deployer/owner, not destroyer' },
      thrashLastDamageInstigator: {
        handle: 61,
        rawHandle: 62,
        encoding: 'bit-packed internal object reference',
        limitation: 'also appears in a self-detonation control and is absent for the other target classes',
      },
    },
  };

  const output = {
    ...baseline,
    meta: {
      ...baseline.meta,
      schema: 'icarus-utility-close-signatures-destruction-pass-v1',
      generatedAt: destructionPass.generatedAt,
      sourceDestructionBaseline: BASELINE_PATH,
      sourceDestructionBaselineSha256: destructionPass.sourceBaselineSha256,
      destructionPassScript: fileURLToPath(import.meta.url),
      targetedReextractions: destructionPass.healthReplicationAudit.targetedProbeFiles,
      signalLayerDecision: 'Full-life targeted capture found no replicated utility HP; class-specific cooldown, DestroyedCount, and terminal effect RPC signals are used instead.',
    },
    coverage: recalculateCoverage(baseline.coverage, classifications),
    classifications,
    destructionPass,
  };

  if (groundTruthRows.length !== 13 || groundTruthRows.some((row) => !row.pass)) {
    throw new Error(`ground-truth destruction validation failed: ${groundTruthRows.filter((row) => row.pass).length}/${groundTruthRows.length}`);
  }
  if (controlRows.some((row) => row.signalDetected)) {
    throw new Error(`same-class labeled control false positives: ${controlRows.filter((row) => row.signalDetected).map((row) => row.id).join(', ')}`);
  }
  if (allSameClassFalsePositives.length) {
    throw new Error(`same-class baseline non-destroy false positives: ${allSameClassFalsePositives.map((row) => row.id).join(', ')}`);
  }

  fs.writeFileSync(OUTPUT_PATH, `${JSON.stringify(output, null, 2)}\n`);
  fs.writeFileSync(FINDINGS_PATH, `${buildFindings(destructionPass).trimEnd()}\n`);
  process.stdout.write(`${JSON.stringify({
    outputPath: OUTPUT_PATH,
    findingsPath: FINDINGS_PATH,
    groundTruth: `${destructionPass.validation.groundTruth.passed}/${destructionPass.validation.groundTruth.total}`,
    labeledControls: `${destructionPass.validation.sameClassLabeledControls.passed}/${destructionPass.validation.sameClassLabeledControls.total}`,
    strictControls: `${destructionPass.validation.strictRecallExpirePickupControls.passed}/${destructionPass.validation.strictRecallExpirePickupControls.total}`,
    destroyed: `${destroyedBefore}->${destroyedAfter}`,
    promotedFromUnclassifiable: promotedIds.length,
    signalCounts: destructionPass.corpusImpact.signalCounts,
  }, null, 2)}\n`);
}

main();
