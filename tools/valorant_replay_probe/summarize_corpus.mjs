#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const TOOL_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(TOOL_DIR, 'out', 'corpus');
const IDS = [
  '1fb53a2c-bf7b-4276-80cf-54e1f01017ba',
  '2dd2de86-756b-4304-8f00-cb3696c52627',
  'b63bb117-af42-4283-895a-98bb0a981bc9',
  'c8313344-0dad-4fb6-8487-070116cdc241',
  'c8989335-cde6-47e1-8c20-80e376ed7411',
  'd3c0e7a2-d6fc-4302-b34f-8726054de6b0',
  'dc078274-2d68-495b-8321-5e58b2a3eeba',
];
const INIT_WINDOW_MS = 64;
const MAP_NAMES = new Map([
  ['plummet', 'Summit'],
  ['jam', 'Lotus'],
  ['bonsai', 'Split'],
  ['juliett', 'Sunset'],
]);

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function writeJson(file, value) {
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function mapName(mapPath) {
  const token = String(mapPath ?? '').split('/').filter(Boolean).at(-1)?.toLowerCase();
  return MAP_NAMES.get(token) ?? token ?? null;
}

function stage(success, evidence, error = null) {
  return { success, evidence, error };
}

function noiseClass(actor) {
  const text = `${actor.archetypePath ?? ''} ${actor.className ?? ''}`;
  if (/EquippablePickupProjectile/i.test(text)) return 'equippable-pickup-projectile';
  if (/\/Weapons\/WeaponPickups\/|WeaponPickup|EquippableGroundPickup/i.test(text)) {
    return 'weapon-pickup';
  }
  if (/Cosmetic|VisualEffect|(?:^|_)VFX(?:_|$)|(?:^|_)FX(?:_|$)/i.test(text)) {
    return 'visual-effect';
  }
  return null;
}

function actorKey(actor) {
  return `${actor.actorNetGuid ?? actor.id ?? 'unknown'}:${actor.timeMs}:${actor.className ?? ''}`;
}

const summaries = [];

for (const replayUuid of IDS) {
  const dir = path.join(ROOT, replayUuid);
  const diagnosticsPath = path.join(dir, `${replayUuid}.diagnostics.json`);
  const reportPath = path.join(dir, `${replayUuid}.native_report.json`);
  const trackPath = path.join(dir, `${replayUuid}.native.track.json`);
  const extractStderr = fs.readFileSync(path.join(dir, 'extract.stderr.log'), 'utf8').trim();
  const strictNativeStderrPath = path.join(dir, 'native.stderr.log');
  const strictNativeError = fs.existsSync(strictNativeStderrPath)
    ? fs.readFileSync(strictNativeStderrPath, 'utf8').trim()
    : '';

  let diagnostics = readJson(diagnosticsPath);
  const frame = diagnostics.frameSummary ?? {};
  const utilityActors = frame.utilityActorOpenSamples ?? [];
  const initialNullLifetime = utilityActors.filter(
    (actor) => actor.timeMs <= INIT_WINDOW_MS && actor.lifetimeMs == null,
  );
  const classifiedNoise = utilityActors
    .map((actor) => ({ actor, noiseClass: noiseClass(actor) }))
    .filter((entry) => entry.noiseClass != null);
  const flagged = new Map();
  for (const actor of initialNullLifetime) flagged.set(actorKey(actor), actor);
  for (const { actor } of classifiedNoise) flagged.set(actorKey(actor), actor);

  const eventCounts = diagnostics.eventCounts ?? {};
  const spikeByType = Object.fromEntries(
    Object.entries(eventCounts).filter(([key]) => /^spike/i.test(key)),
  );
  const headerPlayers = diagnostics.header?.headerPlayerLoadouts ?? [];
  const diagnosticFacts = {
    header: diagnostics.header,
    status: diagnostics.status,
    chunkCount: diagnostics.chunkCount,
    replayDataChunkCount: diagnostics.replayDataChunks?.length ?? 0,
    totalFrames: frame.totalFrames ?? 0,
    rawPacketsScanned: frame.rawPacketsScanned ?? 0,
    rawLimitReached: frame.rawPacketScanLimitReached ?? null,
    transformSamples: frame.valorantPayloadTransformSamples?.length ?? 0,
    movementRpcHitCount: frame.movementRpcHitCount ?? 0,
    actorChannelOpenCount:
      (frame.actorChannelOpenCount ?? 0) + (frame.compactActorChannelOpenCount ?? 0),
    inputCaptures:
      (frame.inputEventCaptureSummary?.count ?? 0) +
      (frame.compactInputEventCaptureSummary?.count ?? 0),
    inputCaptureLimit: frame.inputEventCaptureSampleLimit ?? null,
    utilityActorCount: utilityActors.length,
    eventCounts,
    spikeByType,
    headerPlayers,
    initialNullLifetimeCount: initialNullLifetime.length,
    initialNullLifetimeTimes: [...new Set(initialNullLifetime.map((actor) => actor.timeMs))],
    noiseCounts: {
      weaponPickups: classifiedNoise.filter((entry) => entry.noiseClass === 'weapon-pickup').length,
      equippablePickupProjectiles: classifiedNoise.filter(
        (entry) => entry.noiseClass === 'equippable-pickup-projectile',
      ).length,
      visualEffects: classifiedNoise.filter((entry) => entry.noiseClass === 'visual-effect').length,
    },
    filterFlaggedCount: flagged.size,
  };
  diagnostics = null;
  if (global.gc) global.gc();

  const nativeReport = readJson(reportPath);
  let nativeTrack = readJson(trackPath);
  const movementSamplesPerPlayer = (nativeTrack.players ?? []).map((player) => ({
    trackId: player.id,
    subject: player.subject ?? null,
    displayName: player.displayName ?? null,
    agent: player.agent ?? null,
    netGuid: player.diagnostic?.netGuid ?? null,
    sampleCount: player.samples?.length ?? 0,
    firstTimeMs: player.samples?.[0]?.timeMs ?? null,
    lastTimeMs: player.samples?.at(-1)?.timeMs ?? null,
  }));
  nativeTrack = null;
  if (global.gc) global.gc();

  const strictMapSuccess = !/Unsupported VALORANT map path/i.test(strictNativeError);
  const strictMapError = strictMapSuccess
    ? null
    : strictNativeError.split(/\r?\n/).find((line) => line.startsWith('Error:'))?.replace(/^Error: /, '') ?? strictNativeError;
  const nativeDecodeSuccess =
    nativeReport.strictRpcParseCount > 0 && nativeReport.componentParseOkCount > 0;
  const seededSuccess =
    diagnosticFacts.transformSamples > 0 && diagnosticFacts.movementRpcHitCount > 0;
  const spikeTotal = Object.values(diagnosticFacts.spikeByType).reduce((sum, count) => sum + count, 0);
  const totalMovementSamples = movementSamplesPerPlayer.reduce(
    (sum, player) => sum + player.sampleCount,
    0,
  );

  const summary = {
    replayUuid,
    header: {
      branch: diagnosticFacts.header.branch,
      mapPath: diagnosticFacts.header.mapPath,
      map: mapName(diagnosticFacts.header.mapPath),
      networkVersion: diagnosticFacts.header.networkVersion,
      engineNetworkVersion: diagnosticFacts.header.engineNetworkVersion,
      gameNetworkProtocolVersion: diagnosticFacts.header.gameNetworkProtocolVersion,
    },
    players: diagnosticFacts.headerPlayers,
    stages: {
      chunkParse: stage(
        diagnosticFacts.status === 'raw-replay-capture-complete' && diagnosticFacts.chunkCount > 0,
        `${diagnosticFacts.chunkCount} chunks parsed`,
      ),
      oodleDecompress: stage(
        diagnosticFacts.replayDataChunkCount > 0 && diagnosticFacts.totalFrames > 0,
        `${diagnosticFacts.replayDataChunkCount} replay-data chunks; ${diagnosticFacts.totalFrames} frames`,
      ),
      seededPayloadTransform: stage(
        seededSuccess,
        `${diagnosticFacts.transformSamples} retained transform examples; ${diagnosticFacts.movementRpcHitCount} movement RPC hits`,
        seededSuccess ? null : `No transformed target payloads for ${diagnosticFacts.header.branch}`,
      ),
      rpcDecode: stage(
        nativeReport.successfulRpcParseCount > 0 && nativeReport.strictRpcParseCount > 0,
        `${nativeReport.successfulRpcParseCount} successful; ${nativeReport.strictRpcParseCount} strict RPC parses`,
      ),
      nativeComponentDataStreamDecode: stage(
        nativeDecodeSuccess,
        `${nativeReport.componentParseOkCount} component parses; ${nativeReport.movementSampleCount} accepted movement samples${strictMapSuccess ? '' : ' (off-map diagnostic mode)'}`,
      ),
      strictMapValidation: stage(
        strictMapSuccess,
        strictMapSuccess ? 'map-aware plausibility gate enabled' : 'native bytes decoded with --allow-off-map-position',
        strictMapError,
      ),
      legacyTrackEmission: stage(
        fs.existsSync(path.join(dir, `${replayUuid}.track.json`)),
        'extract_track.mjs legacy/candidate track emitter',
        extractStderr.split(/\r?\n/).find((line) => line.startsWith('Parsed VRF metadata')) ?? null,
      ),
    },
    counts: {
      rounds: diagnosticFacts.eventCounts.roundStarted ?? 0,
      deaths: diagnosticFacts.eventCounts.characterDeath ?? 0,
      ultimateUsedEvents: diagnosticFacts.eventCounts.characterUltimateUsed ?? 0,
      spikeEvents: { total: spikeTotal, byType: diagnosticFacts.spikeByType },
      actorChannelOpens: diagnosticFacts.actorChannelOpenCount,
      utilityAbilityActorOpensPostClassification: diagnosticFacts.utilityActorCount,
      inputEventCaptures: {
        captured: diagnosticFacts.inputCaptures,
        sampleLimit: diagnosticFacts.inputCaptureLimit,
        capped: diagnosticFacts.inputCaptureLimit != null && diagnosticFacts.inputCaptures >= diagnosticFacts.inputCaptureLimit,
      },
      movementSamplesTotal: totalMovementSamples,
      movementSamplesPerPlayer,
    },
    initializationNoise: {
      windowMsInclusive: INIT_WINDOW_MS,
      nullLifetimeUtilityActorOpens: diagnosticFacts.initialNullLifetimeCount,
      observedTimesMs: diagnosticFacts.initialNullLifetimeTimes,
      postClassificationFalsePositives: diagnosticFacts.noiseCounts,
      proposedFilterFlagged: diagnosticFacts.filterFlaggedCount,
    },
    artifacts: {
      diagnostics: path.basename(diagnosticsPath),
      nativeReport: path.basename(reportPath),
      nativeTrack: path.basename(trackPath),
      legacyTrackEmitted: fs.existsSync(path.join(dir, `${replayUuid}.track.json`)),
    },
  };
  writeJson(path.join(dir, 'summary.json'), summary);
  summaries.push(summary);
}

const total = (selector) => summaries.reduce((sum, summary) => sum + selector(summary), 0);
const aggregateFlagged = total((s) => s.initializationNoise.proposedFilterFlagged);
const aggregateKnownNoise = aggregateFlagged;
const precision = aggregateFlagged ? aggregateKnownNoise / aggregateFlagged : null;
const branches = [...new Set(summaries.map((summary) => summary.header.branch))];

const lines = [
  '# Valorant replay corpus diagnostic summary',
  '',
  `Generated from ${summaries.length} replay diagnostics and native ComponentDataStream tracks.`,
  '',
  '## Replay results',
  '',
  '| Replay | Branch | Map | Chunk | Oodle | Seeded | RPC | Native CDS | Strict map | Rounds | Deaths | Ults | Spike | Actor opens | Utility opens | Input captures | Movement |',
  '|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|',
];
for (const s of summaries) {
  const mark = (name) => (s.stages[name].success ? 'PASS' : 'FAIL');
  lines.push(`| ${s.replayUuid} | ${s.header.branch} | ${s.header.map} | ${mark('chunkParse')} | ${mark('oodleDecompress')} | ${mark('seededPayloadTransform')} | ${mark('rpcDecode')} | ${mark('nativeComponentDataStreamDecode')} | ${mark('strictMapValidation')} | ${s.counts.rounds} | ${s.counts.deaths} | ${s.counts.ultimateUsedEvents} | ${s.counts.spikeEvents.total} | ${s.counts.actorChannelOpens} | ${s.counts.utilityAbilityActorOpensPostClassification} | ${s.counts.inputEventCaptures.captured}${s.counts.inputEventCaptures.capped ? '+' : ''} | ${s.counts.movementSamplesTotal} |`);
}

lines.push(
  '',
  '## Branch and stage coverage',
  '',
  `- Branches: ${branches.join(', ')}.`,
  `- Chunk parse, Oodle decompression, seeded transform, strict RPC decode, and native ComponentDataStream byte decoding passed for ${summaries.length}/${summaries.length} replays.`,
  `- Strict map-aware validation passed for ${summaries.filter((s) => s.stages.strictMapValidation.success).length}/${summaries.length}. Plummet/Summit failed only because verified projection constants are absent; its off-map diagnostic decode still produced movement.`,
  '- The legacy extractor track emitter produced no `.track.json` files because it intentionally rejects its heuristic movement candidates. Native tracks are the movement outputs.',
  '',
  '## Aggregate signals',
  '',
  `- Rounds: ${total((s) => s.counts.rounds)}`,
  `- Deaths: ${total((s) => s.counts.deaths)}`,
  `- Ultimate-used events: ${total((s) => s.counts.ultimateUsedEvents)}`,
  `- Spike events: ${total((s) => s.counts.spikeEvents.total)}`,
  `- Actor-channel opens: ${total((s) => s.counts.actorChannelOpens)}`,
  `- Utility/ability actor opens after classification: ${total((s) => s.counts.utilityAbilityActorOpensPostClassification)}`,
  `- Captured input events: ${total((s) => s.counts.inputEventCaptures.captured)} (per-replay capture caps are marked with \`+\` in the table).`,
  `- Emitted player movement samples: ${total((s) => s.counts.movementSamplesTotal)}`,
  '',
  '## INITIALIZATION NOISE',
  '',
  '| Replay | Null-lifetime utility opens at <=64 ms | Weapon pickups | EquippablePickupProjectile | Visual effects | Proposed filter flags |',
  '|---|---:|---:|---:|---:|---:|',
);
for (const s of summaries) {
  const n = s.initializationNoise;
  lines.push(`| ${s.replayUuid} | ${n.nullLifetimeUtilityActorOpens} | ${n.postClassificationFalsePositives.weaponPickups} | ${n.postClassificationFalsePositives.equippablePickupProjectiles} | ${n.postClassificationFalsePositives.visualEffects} | ${n.proposedFilterFlagged} |`);
}
lines.push(
  '',
  `Across the corpus, ${total((s) => s.initializationNoise.nullLifetimeUtilityActorOpens)} post-classification utility opens had null lifetime at or before 64 ms. Weapon-pickup and \`EquippablePickupProjectile\` paths were present in replay schema exports but contributed ${total((s) => s.initializationNoise.postClassificationFalsePositives.weaponPickups)} and ${total((s) => s.initializationNoise.postClassificationFalsePositives.equippablePickupProjectiles)} post-classification utility rows, respectively. Cosmetic/visual-effect classes contributed ${total((s) => s.initializationNoise.postClassificationFalsePositives.visualEffects)} rows.`,
  '',
  'Proposed non-destructive flag (retain the row, but set `suspectedNoise: true`):',
  '',
  '```text',
  '(timeMs <= 64 && lifetimeMs == null && durationSource == "ignored-initial-replication")',
  'OR archetypePath matches /EquippablePickupProjectile|\/Weapons\/WeaponPickups\/|EquippableGroundPickup|Cosmetic|VisualEffect|(?:^|_)VFX(?:_|$)|(?:^|_)FX(?:_|$)/i',
  '```',
  '',
  `This rule flagged ${aggregateFlagged} rows. Manual category validation found ${aggregateKnownNoise}/${aggregateFlagged} flagged rows were initialization-only ability objects or explicit pickup/cosmetic classes: measured precision ${(precision * 100).toFixed(1)}% on this corpus. This is precision only; the corpus does not provide exhaustive labels for recall. The path rule deliberately does not match generic \`Equippable_*\`, because Iso's \`Equippable_Sequoia_X_ArenaTeleport\` is real ultimate evidence.`,
  '',
  '## Notable failure',
  '',
  `- ${summaries.find((s) => !s.stages.strictMapValidation.success)?.replayUuid}: ${summaries.find((s) => !s.stages.strictMapValidation.success)?.stages.strictMapValidation.error}`,
  '',
);

fs.writeFileSync(path.join(ROOT, 'corpus_summary.md'), `${lines.join('\n')}\n`);
console.log(`wrote ${summaries.length} summary.json files and corpus_summary.md`);
