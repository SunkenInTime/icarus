#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const TOOL_DIR = path.dirname(SCRIPT_PATH);
const DEFAULT_RAW_PACKET_LIMIT = 1_000_000;
const DEFAULT_MAX_SAMPLES = 250_000;
const DEFAULT_TRACK_MIN_SAMPLE_INTERVAL_MS = 50;
const DEFAULT_ABILITY_SIGNAL_SAMPLE_LIMIT = 500_000;
const DEFAULT_NON_MOVEMENT_INPUT_EVENT_SAMPLE_LIMIT = 100_000;
const MIN_TIMELINE_COVERAGE_RATIO = 0.95;
const TIMELINE_EDGE_TOLERANCE_MS = 30_000;
const SUPPORTED_MAP_PATH_TOKENS = [
  ['ascent', 'ascent'],
  ['bonsai', 'split'],
  ['bind', 'bind'],
  ['foxtrot', 'breeze'],
  ['breeze', 'breeze'],
  ['canyon', 'fracture'],
  ['fracture', 'fracture'],
  ['duality', 'bind'],
  ['split', 'split'],
  ['port', 'icebox'],
  ['icebox', 'icebox'],
  ['jam', 'lotus'],
  ['lotus', 'lotus'],
  ['juliett', 'sunset'],
  ['sunset', 'sunset'],
  ['pitt', 'pearl'],
  ['pearl', 'pearl'],
  ['infinity', 'abyss'],
  ['plummet', 'summit'],
  ['abyss', 'abyss'],
  ['rook', 'corrode'],
  ['corrode', 'corrode'],
  ['triad', 'haven'],
  ['haven', 'haven'],
];

function parseArgs(argv) {
  const options = {
    input: null,
    out: null,
    diagnostics: null,
    reportOut: null,
    samplesOut: null,
    rawPacketLimit: DEFAULT_RAW_PACKET_LIMIT,
    rawTimeFromMs: 0,
    rawTimeToMs: null,
    maxSamples: DEFAULT_MAX_SAMPLES,
    trackMinSampleIntervalMs: DEFAULT_TRACK_MIN_SAMPLE_INTERVAL_MS,
    abilitySignalSampleLimit: DEFAULT_ABILITY_SIGNAL_SAMPLE_LIMIT,
    nonMovementInputEventSampleLimit:
      DEFAULT_NON_MOVEMENT_INPUT_EVENT_SAMPLE_LIMIT,
    allowOffMapPosition: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--out') options.out = argv[++index];
    else if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--report-out') options.reportOut = argv[++index];
    else if (arg === '--samples-out') options.samplesOut = argv[++index];
    else if (arg === '--raw-packet-limit') options.rawPacketLimit = Number(argv[++index] ?? 0);
    else if (arg === '--raw-time-from-ms') options.rawTimeFromMs = Number(argv[++index] ?? 0);
    else if (arg === '--raw-time-to-ms') options.rawTimeToMs = Number(argv[++index] ?? 0);
    else if (arg === '--max-samples') options.maxSamples = Number(argv[++index] ?? DEFAULT_MAX_SAMPLES);
    else if (arg === '--track-min-sample-interval-ms') {
      options.trackMinSampleIntervalMs = Number(
        argv[++index] ?? DEFAULT_TRACK_MIN_SAMPLE_INTERVAL_MS,
      );
    }
    else if (arg === '--non-movement-input-event-sample-limit') {
      options.nonMovementInputEventSampleLimit = Number(
        argv[++index] ?? DEFAULT_NON_MOVEMENT_INPUT_EVENT_SAMPLE_LIMIT,
      );
    }
    else if (arg === '--ability-signal-sample-limit') {
      options.abilitySignalSampleLimit = Number(
        argv[++index] ?? DEFAULT_ABILITY_SIGNAL_SAMPLE_LIMIT,
      );
    }
    else if (arg === '--allow-off-map-position') options.allowOffMapPosition = true;
    else if (arg === '--help' || arg === '-h') options.help = true;
    else options.input = arg;
  }

  return options;
}

function usage() {
  return [
    'usage: node extract_native_track.mjs <replay.vrf> --out replay.track.json',
    '',
    'Runs the proven native path:',
    '  extract_track.mjs diagnostics-only raw ReplayController capture',
    '  analyze_component_data_stream_native.mjs track emitter',
    '  strict completeness, player identity, map, timeline, and movement validation',
    '  --non-movement-input-event-sample-limit <n> controls the typed input evidence cap',
    '  --ability-signal-sample-limit <n> controls the lifecycle/property evidence cap',
  ].join('\n');
}

function resolveUserPath(value) {
  if (value == null) return null;
  if (path.isAbsolute(value)) return value;
  return path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

function defaultOutPath(inputPath) {
  return path.join(
    process.env.INIT_CWD ?? process.cwd(),
    `${path.basename(inputPath, path.extname(inputPath))}.native_component.track.json`,
  );
}

function replaceJsonSuffix(filePath, suffix) {
  return /\.json$/i.test(filePath) ? filePath.replace(/\.json$/i, suffix) : `${filePath}${suffix}`;
}

function runNode(scriptName, args) {
  const result = spawnSync(process.execPath, [path.join(TOOL_DIR, scriptName), ...args], {
    cwd: TOOL_DIR,
    encoding: 'utf8',
    env: {
      ...process.env,
      INIT_CWD: process.env.INIT_CWD ?? process.cwd(),
    },
  });

  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);

  if (result.status !== 0) {
    throw new Error(`${scriptName} exited with code ${result.status ?? 'unknown'}`);
  }
}

function reportStage(message) {
  console.error(`[icarus-replay] ${message}`);
}

function readJsonArtifact(filePath, label) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`Could not read the native ${label} artifact at ${filePath}: ${error.message}`);
  }
}

function normalizedIdentityValue(value) {
  return String(value ?? '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
}

function supportedMapKey(mapPath) {
  const lowered = String(mapPath ?? '').toLowerCase();
  return SUPPORTED_MAP_PATH_TOKENS.find(([token]) => lowered.includes(token))?.[1] ?? null;
}

function lowerBound(sorted, target) {
  let low = 0;
  let high = sorted.length;
  while (low < high) {
    const middle = low + ((high - low) >> 1);
    if (sorted[middle] < target) low = middle + 1;
    else high = middle;
  }
  return low;
}

function rangeCoverageRatio(targetStart, targetEnd, observedStart, observedEnd) {
  const targetSpan = targetEnd - targetStart;
  if (!(targetSpan > 0)) return 0;
  const overlap = Math.max(
    0,
    Math.min(targetEnd, observedEnd) - Math.max(targetStart, observedStart),
  );
  return overlap / targetSpan;
}

function expectedSideForLoadout(loadout, expectedPlayerCount) {
  if (loadout?.initialSide === 'defender' || loadout?.initialSide === 'attacker') {
    return loadout.initialSide;
  }
  return loadout.index < expectedPlayerCount / 2 ? 'defender' : 'attacker';
}

function addIdentityIssues(issues, players, loadouts, expectedPlayerCount) {
  const loadoutByIndex = new Map();
  const headerSubjects = new Set();
  for (let fallbackIndex = 0; fallbackIndex < loadouts.length; fallbackIndex += 1) {
    const loadout = loadouts[fallbackIndex];
    const loadoutIndex = Number.isInteger(loadout?.index) ? loadout.index : fallbackIndex;
    const label = `header loadout ${loadoutIndex}`;
    if (loadoutByIndex.has(loadoutIndex)) {
      issues.push(
        `${label} duplicates another header loadout index. Regenerate diagnostics before trusting player identity joins.`,
      );
      continue;
    }
    loadoutByIndex.set(loadoutIndex, { ...loadout, index: loadoutIndex });

    const subject = String(loadout?.subject ?? '').trim();
    if (!subject) {
      issues.push(`${label} has no subject UUID, so emitted player identity cannot be proven.`);
    } else if (headerSubjects.has(subject)) {
      issues.push(`${label} reuses subject ${subject}; header player identities must be unique.`);
    } else {
      headerSubjects.add(subject);
    }
    if (!normalizedIdentityValue(loadout?.agent) || /^unknown$/i.test(loadout?.agent ?? '')) {
      issues.push(`${label} has no resolved agent identity.`);
    }
  }

  const seenIds = new Set();
  const seenNetGuids = new Set();
  const seenLoadoutIndexes = new Set();
  const seenSubjects = new Set();
  const invalidPlayers = [];
  for (let playerIndex = 0; playerIndex < players.length; playerIndex += 1) {
    const player = players[playerIndex] ?? {};
    const label = player.id ?? `players[${playerIndex}]`;
    const reasons = [];
    if (!player.id || seenIds.has(player.id)) reasons.push('missing or duplicate track id');
    else seenIds.add(player.id);

    const netGuid = player.diagnostic?.netGuid;
    if (!Number.isInteger(netGuid) || seenNetGuids.has(netGuid)) {
      reasons.push('missing or duplicate native NetGUID');
    } else {
      seenNetGuids.add(netGuid);
    }

    const loadoutIndex = player.loadoutIndex;
    const loadout = Number.isInteger(loadoutIndex) ? loadoutByIndex.get(loadoutIndex) : null;
    if (!loadout || seenLoadoutIndexes.has(loadoutIndex)) {
      reasons.push('missing, unknown, or duplicate loadoutIndex');
    } else {
      seenLoadoutIndexes.add(loadoutIndex);
      if (player.subject !== loadout.subject) reasons.push('subject does not match header loadout');
      if (
        normalizedIdentityValue(player.agent) !== normalizedIdentityValue(loadout.agent)
      ) {
        reasons.push(`agent does not match header ${loadout.agent}`);
      }
      const expectedSide = expectedSideForLoadout(loadout, expectedPlayerCount);
      if (player.initialSide !== expectedSide) {
        reasons.push(`initialSide is not the header-derived ${expectedSide} side`);
      }
    }

    const subject = String(player.subject ?? '').trim();
    if (!subject || seenSubjects.has(subject)) reasons.push('missing or duplicate subject');
    else seenSubjects.add(subject);
    if (!player.sideSource) reasons.push('missing identity/side provenance');
    if (reasons.length > 0) invalidPlayers.push(`${label}: ${reasons.join(', ')}`);
  }

  if (invalidPlayers.length > 0) {
    issues.push(
      `Emitted player identities are incomplete or inconsistent (${invalidPlayers.join('; ')}). ` +
        'The analyzer must join every native NetGUID to one unique header loadout/subject before this track is import-safe.',
    );
  }
  if (seenLoadoutIndexes.size !== expectedPlayerCount) {
    issues.push(
      `Only ${seenLoadoutIndexes.size}/${expectedPlayerCount} header loadout identities are represented by emitted players.`,
    );
  }
}

export function validateNativeExtractionQuality({
  track,
  diagnostics,
  report,
  trackPath = 'native track',
  diagnosticsPath = 'native diagnostics',
  reportPath = 'native report',
}) {
  const issues = [];
  const frameSummary = diagnostics?.frameSummary ?? {};
  const rawPacketsScanned = frameSummary.rawPacketsScanned;
  const rawPacketScanLimit = frameSummary.rawPacketScanLimit;

  if (frameSummary.rawPacketScanSkipped !== false) {
    issues.push(
      'The raw ReplayController packet scan was skipped or its completion was not recorded. Rerun with a positive --raw-packet-limit.',
    );
  }
  if (!Number.isInteger(rawPacketsScanned) || rawPacketsScanned <= 0) {
    issues.push(
      `rawPacketsScanned is ${rawPacketsScanned ?? 'missing'}; no completed native packet scan can be verified.`,
    );
  }
  if (!Number.isInteger(rawPacketScanLimit) || rawPacketScanLimit <= 0) {
    issues.push(
      `rawPacketScanLimit is ${rawPacketScanLimit ?? 'missing'}; rerun with --raw-packet-limit ${DEFAULT_RAW_PACKET_LIMIT} or higher.`,
    );
  }
  if (
    frameSummary.rawPacketScanLimitReached !== false ||
    (Number.isInteger(rawPacketsScanned) &&
      Number.isInteger(rawPacketScanLimit) &&
      rawPacketsScanned >= rawPacketScanLimit)
  ) {
    const suggestedLimit = Math.max(
      DEFAULT_RAW_PACKET_LIMIT,
      Number.isInteger(rawPacketsScanned) ? rawPacketsScanned + 250_000 : 0,
      Number.isInteger(rawPacketScanLimit) ? rawPacketScanLimit * 2 : 0,
    );
    issues.push(
      `The raw packet scan reached or may have reached its cap (${rawPacketsScanned ?? '?'} scanned, limit ${rawPacketScanLimit ?? '?'}). ` +
        `Rerun with --raw-packet-limit ${suggestedLimit}; capped output can look plausible while ending mid-match.`,
    );
  }

  const replayChunks = Array.isArray(diagnostics?.replayDataChunks)
    ? diagnostics.replayDataChunks
    : [];
  const chunkStarts = replayChunks.map((chunk) => chunk?.startMs).filter(Number.isFinite);
  const chunkEnds = replayChunks.map((chunk) => chunk?.endMs).filter(Number.isFinite);
  const replayStartMs = chunkStarts.length > 0 ? Math.min(...chunkStarts) : null;
  const replayEndMs = chunkEnds.length > 0 ? Math.max(...chunkEnds) : null;
  if (!(Number.isFinite(replayStartMs) && Number.isFinite(replayEndMs) && replayEndMs > replayStartMs)) {
    issues.push('Replay chunk timing is missing or invalid, so full-timeline coverage cannot be verified.');
  } else {
    const rawTimeFromMs = frameSummary.rawPacketTimeFromMs;
    const rawTimeToMs = frameSummary.rawPacketTimeToMs;
    if (!Number.isFinite(rawTimeFromMs) || rawTimeFromMs > replayStartMs) {
      issues.push(
        `The raw scan starts at ${rawTimeFromMs ?? 'an unknown time'}ms, after the replay starts at ${replayStartMs}ms. Rerun with --raw-time-from-ms ${replayStartMs}.`,
      );
    }
    if (rawTimeToMs != null && (!Number.isFinite(rawTimeToMs) || rawTimeToMs < replayEndMs)) {
      issues.push(
        `The raw scan stops at ${rawTimeToMs}ms, before the replay ends at ${replayEndMs}ms. Omit --raw-time-to-ms or set it to at least ${replayEndMs}.`,
      );
    }
  }

  const mapPath = diagnostics?.header?.mapPath;
  const mapKey = supportedMapKey(mapPath);
  if (!mapKey) {
    const supportedMaps = [...new Set(SUPPORTED_MAP_PATH_TOKENS.map(([, key]) => key))].join(', ');
    issues.push(
      `Unsupported replay map ${JSON.stringify(mapPath ?? null)}. Add verified map bounds before extraction; currently supported maps: ${supportedMaps}.`,
    );
  }
  if (track?.mapId !== mapPath) {
    issues.push(
      `Track mapId ${JSON.stringify(track?.mapId ?? null)} does not match the replay header map ${JSON.stringify(mapPath ?? null)}.`,
    );
  }
  if (report?.input?.requireMapPlausiblePosition !== true) {
    issues.push(
      'The analyzer did not enforce map-plausible positions. Rerun without --allow-off-map-position before importing this track.',
    );
  }

  const abilityCapabilities = track?.decoder?.abilityCapabilities ?? {};
  if (track?.abilitySchemaVersion !== 3) {
    issues.push(
      `Track abilitySchemaVersion is ${track?.abilitySchemaVersion ?? 'missing'}; schema version 3 is required.`,
    );
  }
  for (const capability of [
    'characterAbilityCastInfo',
    'actorChannelOpenClose',
    'equippableStateTransitions',
    'abilityLifecycleRpcEvents',
    'canonicalAbilityActions',
  ]) {
    if (abilityCapabilities[capability] !== true) {
      issues.push(`Required ability decoder capability ${capability} is missing.`);
    }
  }
  const abilityCasts = Array.isArray(track?.abilityCasts)
    ? track.abilityCasts
    : [];
  const utilityActors = Array.isArray(track?.utilityActors)
    ? track.utilityActors
    : [];
  const abilityActions = Array.isArray(track?.abilityActions)
    ? track.abilityActions
    : [];
  const abilityStateEvents = Array.isArray(track?.abilityStateEvents)
    ? track.abilityStateEvents
    : [];
  const abilityRpcEvents = Array.isArray(track?.abilityRpcEvents)
    ? track.abilityRpcEvents
    : [];
  if (abilityCasts.length === 0) {
    issues.push('No CharacterAbilityCastInfo rows were emitted for the match.');
  }
  if (
    abilityActions.length === 0 &&
    (abilityCasts.length > 0 || utilityActors.length > 0)
  ) {
    issues.push('Ability source rows exist, but no canonical ability actions were emitted.');
  }
  const resolvedStateSignalCount = (
    diagnostics?.frameSummary?.abilitySignalSamples ?? []
  ).filter(
    (sample) =>
      sample?.fieldName === 'CurrentState' &&
      (sample?.netGuidReferences ?? []).some((reference) => reference?.pathName),
  ).length;
  if (resolvedStateSignalCount > 0 && abilityStateEvents.length === 0) {
    issues.push(
      `${resolvedStateSignalCount} resolved EquippableStateMachine CurrentState rows were captured, but no typed abilityStateEvents were emitted.`,
    );
  }
  const invalidAbilityRpcEvents = abilityRpcEvents.filter(
    (event) =>
      !event?.canonicalAbilityId ||
      !event?.rpcName ||
      !event?.phaseType ||
      event?.evidence !== 'observed',
  );
  if (invalidAbilityRpcEvents.length > 0) {
    issues.push(
      `${invalidAbilityRpcEvents.length}/${abilityRpcEvents.length} typed ability RPC events lack canonical identity or observed RPC provenance.`,
    );
  }
  const invalidUtilityActors = utilityActors.filter(
    (actor) =>
      !actor?.ignoredAsAbility &&
      (!actor?.agent ||
        !(actor?.sourceAbilitySlot ?? actor?.abilitySlot) ||
        actor?.observedStartMs == null),
  );
  if (invalidUtilityActors.length > 0) {
    issues.push(
      `${invalidUtilityActors.length}/${utilityActors.length} app-facing utility actors lack proven identity or observed channel-open timing.`,
    );
  }
  const fallbackUtilityActors = utilityActors.filter(
    (actor) =>
      actor?.observedEndMs == null &&
      (/fallback|wiki|default|kind-duration/i.test(actor?.durationSource ?? '') ||
        (actor?.fallbackEndMs != null &&
          actor?.effectiveEndMs === actor?.fallbackEndMs)),
  );
  if (fallbackUtilityActors.length > 0) {
    issues.push(
      `${fallbackUtilityActors.length}/${utilityActors.length} utility actors still use an app-facing fallback end.`,
    );
  }
  const weakPromotedCastLinks = utilityActors.filter(
    (actor) =>
      actor?.sourceCastId != null &&
      actor?.sourceCastLinkConfidence !== 'derived-replay-netguid-and-time',
  );
  if (weakPromotedCastLinks.length > 0) {
    issues.push(
      `${weakPromotedCastLinks.length}/${utilityActors.length} utility actors promote a proximity-only cast link into sourceCastId.`,
    );
  }
  const invalidActions = abilityActions.filter(
    (action) =>
      !action?.canonicalAbilityId ||
      !action?.agent ||
      !action?.abilitySlot ||
      !Array.isArray(action?.phases) ||
      action.phases.length === 0 ||
      action.phases.some(
        (phase) =>
          !['observed', 'derived', 'absent'].includes(phase?.evidence),
      ),
  );
  if (invalidActions.length > 0) {
    issues.push(
      `${invalidActions.length}/${abilityActions.length} canonical ability actions have missing identity, phases, or evidence provenance.`,
    );
  }
  const inputOverflowCount =
    track?.decoder?.inputEventSummary?.overflowCount ?? 0;
  if (inputOverflowCount > 0) {
    issues.push(
      `The typed non-movement input lane overflowed by ${inputOverflowCount} unique events; raise --non-movement-input-event-sample-limit.`,
    );
  }
  const abilitySignalCount =
    diagnostics?.frameSummary?.abilitySignalSamples?.length ?? 0;
  const abilitySignalLimit =
    diagnostics?.frameSummary?.abilitySignalSampleLimit ?? null;
  const abilitySignalOverflowCount =
    diagnostics?.frameSummary?.abilitySignalOverflowCount ?? null;
  if (
    (abilitySignalOverflowCount ?? 0) > 0 ||
    (abilitySignalOverflowCount == null &&
      Number.isFinite(abilitySignalLimit) &&
      abilitySignalCount >= abilitySignalLimit)
  ) {
    issues.push(
      `The generic ability/property signal lane reached its ${abilitySignalLimit ?? 'unknown'}-row cap${abilitySignalOverflowCount == null ? '' : ` and overflowed by ${abilitySignalOverflowCount} rows`}; raise --ability-signal-sample-limit before auditing lifecycle absence.`,
    );
  }
  if (mapKey && report?.input?.mapKey !== mapKey) {
    issues.push(
      `The native report used map key ${JSON.stringify(report?.input?.mapKey ?? null)} instead of the supported header map key ${JSON.stringify(mapKey)}.`,
    );
  }

  const expectedPlayerCount = diagnostics?.header?.playerCount;
  const loadouts = Array.isArray(diagnostics?.header?.headerPlayerLoadouts)
    ? diagnostics.header.headerPlayerLoadouts
    : [];
  const players = Array.isArray(track.players) ? track.players : [];
  if (!Number.isInteger(expectedPlayerCount) || expectedPlayerCount <= 0) {
    issues.push(
      `Replay header playerCount is ${expectedPlayerCount ?? 'missing'}; expected player coverage cannot be verified.`,
    );
  } else {
    if (loadouts.length !== expectedPlayerCount) {
      issues.push(
        `Replay header declares ${expectedPlayerCount} players but contains ${loadouts.length} player loadouts. Regenerate diagnostics; do not infer identities from a malformed header.`,
      );
    }
    if (players.length !== expectedPlayerCount) {
      issues.push(
        `Native decoding emitted ${players.length}/${expectedPlayerCount} expected players. Inspect actor-open/NetGUID parsing and rerun before importing this track.`,
      );
    }
    addIdentityIssues(issues, players, loadouts, expectedPlayerCount);
  }

  if (!(Number.isFinite(report?.movementSampleCount) && report.movementSampleCount > 0)) {
    issues.push(
      `The native report contains no accepted movement samples (movementSampleCount=${report?.movementSampleCount ?? 'missing'}).`,
    );
  }
  if (
    !(Number.isFinite(report?.emittedMovementSampleCount) && report.emittedMovementSampleCount > 0)
  ) {
    issues.push(
      `The native report emitted no app-track movement samples (emittedMovementSampleCount=${report?.emittedMovementSampleCount ?? 'missing'}).`,
    );
  }

  let totalSamples = 0;
  let invalidSampleCount = 0;
  let movementStartMs = Infinity;
  let movementEndMs = -Infinity;
  let minX = Infinity;
  let maxX = -Infinity;
  let minY = Infinity;
  let maxY = -Infinity;
  let minZ = Infinity;
  let maxZ = -Infinity;
  const movementTimes = [];
  const playersWithoutSamples = [];
  const playersWithUnsortedSamples = [];
  const playerMovementRanges = [];
  for (const player of players) {
    const samples = Array.isArray(player?.samples) ? player.samples : [];
    if (samples.length === 0) playersWithoutSamples.push(player?.id ?? 'unknown player');
    let previousTimeMs = -Infinity;
    let playerStartMs = Infinity;
    let playerEndMs = -Infinity;
    for (const sample of samples) {
      totalSamples += 1;
      const timeMs = sample?.timeMs;
      const x = sample?.x;
      const y = sample?.y;
      const z = sample?.z;
      if (
        !Number.isFinite(timeMs) ||
        !Number.isFinite(x) ||
        !Number.isFinite(y) ||
        !Number.isFinite(z)
      ) {
        invalidSampleCount += 1;
        continue;
      }
      if (timeMs < previousTimeMs && !playersWithUnsortedSamples.includes(player?.id)) {
        playersWithUnsortedSamples.push(player?.id ?? 'unknown player');
      }
      previousTimeMs = timeMs;
      movementTimes.push(timeMs);
      playerStartMs = Math.min(playerStartMs, timeMs);
      playerEndMs = Math.max(playerEndMs, timeMs);
      movementStartMs = Math.min(movementStartMs, timeMs);
      movementEndMs = Math.max(movementEndMs, timeMs);
      minX = Math.min(minX, x);
      maxX = Math.max(maxX, x);
      minY = Math.min(minY, y);
      maxY = Math.max(maxY, y);
      minZ = Math.min(minZ, z);
      maxZ = Math.max(maxZ, z);
    }
    if (Number.isFinite(playerStartMs) && Number.isFinite(playerEndMs)) {
      playerMovementRanges.push({
        id: player?.id ?? 'unknown player',
        netGuid: player?.diagnostic?.netGuid,
        startMs: playerStartMs,
        endMs: playerEndMs,
      });
    }
  }

  if (players.length === 0 || totalSamples === 0) {
    issues.push(
      `No native player movement was emitted for ${mapPath ?? 'the replay'} (${diagnostics?.header?.branch ?? 'unknown branch'}). Keep ${diagnosticsPath} and add support for this packet shape before importing.`,
    );
  }
  if (playersWithoutSamples.length > 0) {
    issues.push(
      `Players without movement samples: ${playersWithoutSamples.join(', ')}. Every expected player must have a decoded native lane.`,
    );
  }
  if (invalidSampleCount > 0) {
    issues.push(
      `${invalidSampleCount}/${totalSamples} emitted movement samples have a missing/non-finite time or position.`,
    );
  }
  if (playersWithUnsortedSamples.length > 0) {
    issues.push(
      `Movement time goes backwards for ${playersWithUnsortedSamples.join(', ')}; timeline interpolation would be unsafe.`,
    );
  }
  if (
    movementTimes.length > 0 &&
    Math.max(maxX - minX, maxY - minY, maxZ - minZ) < 1
  ) {
    issues.push(
      'Movement samples are nonempty but spatially constant. The native decoder did not recover actual player movement.',
    );
  }

  const diagnosticsRoundStarts = Array.isArray(diagnostics?.roundStartEvents)
    ? diagnostics.roundStartEvents
    : [];
  const diagnosticsDeaths = Array.isArray(diagnostics?.deathEvents) ? diagnostics.deathEvents : [];
  const trackRoundStarts = Array.isArray(track?.roundStartEvents) ? track.roundStartEvents : [];
  const trackDeaths = Array.isArray(track?.deathEvents) ? track.deathEvents : [];
  if (diagnosticsRoundStarts.length === 0) {
    issues.push('No roundStarted timeline events were decoded, so match timeline coverage is unproven.');
  }
  if (trackRoundStarts.length !== diagnosticsRoundStarts.length) {
    issues.push(
      `Track timeline contains ${trackRoundStarts.length}/${diagnosticsRoundStarts.length} decoded round starts.`,
    );
  }
  if (trackDeaths.length !== diagnosticsDeaths.length) {
    issues.push(
      `Track timeline contains ${trackDeaths.length}/${diagnosticsDeaths.length} decoded death events.`,
    );
  }

  movementTimes.sort((left, right) => left - right);
  const timelineTimes = [...diagnosticsRoundStarts, ...diagnosticsDeaths]
    .map((event) => event?.timeMs)
    .filter(Number.isFinite)
    .sort((left, right) => left - right);
  const timelineStartMs = timelineTimes[0] ?? null;
  const timelineEndMs = timelineTimes.at(-1) ?? null;
  if (timelineTimes.length === 0) {
    issues.push('Replay timeline events have no valid timestamps.');
  } else if (movementTimes.length > 0) {
    const timelineCoverage = rangeCoverageRatio(
      timelineStartMs,
      timelineEndMs,
      movementStartMs,
      movementEndMs,
    );
    if (timelineCoverage < MIN_TIMELINE_COVERAGE_RATIO) {
      issues.push(
        `Movement covers only ${(timelineCoverage * 100).toFixed(1)}% of the decoded event timeline (${movementStartMs}-${movementEndMs}ms vs ${timelineStartMs}-${timelineEndMs}ms). Check the raw packet cap/time range and decoder branch.`,
      );
    }
    if (movementStartMs > timelineStartMs + TIMELINE_EDGE_TOLERANCE_MS) {
      issues.push(
        `Movement begins ${(movementStartMs - timelineStartMs) / 1000}s after the decoded timeline starts.`,
      );
    }
    if (movementEndMs < timelineEndMs - TIMELINE_EDGE_TOLERANCE_MS) {
      issues.push(
        `Movement ends ${((timelineEndMs - movementEndMs) / 1000).toFixed(1)}s before the last decoded timeline event. Increase --raw-packet-limit or remove the raw time cutoff.`,
      );
    }

    const sortedRoundStarts = diagnosticsRoundStarts
      .map((event) => event?.timeMs)
      .filter(Number.isFinite)
      .sort((left, right) => left - right);
    const roundsWithoutMovement = [];
    for (let index = 0; index < sortedRoundStarts.length; index += 1) {
      const roundStartMs = sortedRoundStarts[index];
      const nextRoundStartMs = sortedRoundStarts[index + 1] ?? replayEndMs ?? Infinity;
      const sampleIndex = lowerBound(movementTimes, roundStartMs - 5_000);
      const firstNearbySample = movementTimes[sampleIndex];
      const windowEndMs = Math.min(nextRoundStartMs, roundStartMs + TIMELINE_EDGE_TOLERANCE_MS);
      if (!Number.isFinite(firstNearbySample) || firstNearbySample > windowEndMs) {
        roundsWithoutMovement.push(roundStartMs);
      }
    }
    if (roundsWithoutMovement.length > 0) {
      issues.push(
        `No native movement was found near round starts at ${roundsWithoutMovement.join(', ')}ms. The track has an internal timeline gap.`,
      );
    }

    const finalRoundStartMs = sortedRoundStarts.at(-1) ?? timelineStartMs;
    const incompletePlayerRanges = [];
    for (const range of playerMovementRanges) {
      const finalRoundDeathMs = diagnosticsDeaths
        .map((event) => ({
          timeMs: event?.timeMs,
          victimNetGuid: event?.victimNetGuid,
        }))
        .filter(
          (event) =>
            Number.isFinite(event.timeMs) &&
            event.victimNetGuid === range.netGuid &&
            event.timeMs >= finalRoundStartMs,
        )
        .sort((left, right) => left.timeMs - right.timeMs)[0]?.timeMs;
      const expectedEndMs = finalRoundDeathMs ?? timelineEndMs;
      const playerCoverage = rangeCoverageRatio(
        timelineStartMs,
        expectedEndMs,
        range.startMs,
        range.endMs,
      );
      const reasons = [];
      if (range.startMs > timelineStartMs + TIMELINE_EDGE_TOLERANCE_MS) {
        reasons.push(`starts ${((range.startMs - timelineStartMs) / 1000).toFixed(1)}s late`);
      }
      if (range.endMs < expectedEndMs - TIMELINE_EDGE_TOLERANCE_MS) {
        reasons.push(`ends ${((expectedEndMs - range.endMs) / 1000).toFixed(1)}s early`);
      }
      if (playerCoverage < MIN_TIMELINE_COVERAGE_RATIO) {
        reasons.push(`covers ${(playerCoverage * 100).toFixed(1)}%`);
      }
      if (reasons.length > 0) {
        incompletePlayerRanges.push(`${range.id} (${reasons.join(', ')})`);
      }
    }
    if (incompletePlayerRanges.length > 0) {
      issues.push(
        `Player movement lanes do not cover their full playable timelines: ${incompletePlayerRanges.join('; ')}. A final-round death is accepted as that player's endpoint.`,
      );
    }
  }

  let replayCoverage = null;
  if (
    Number.isFinite(replayStartMs) &&
    Number.isFinite(replayEndMs) &&
    movementTimes.length > 0
  ) {
    replayCoverage = rangeCoverageRatio(
      replayStartMs,
      replayEndMs,
      movementStartMs,
      movementEndMs,
    );
    if (replayCoverage < MIN_TIMELINE_COVERAGE_RATIO) {
      issues.push(
        `Movement spans only ${(replayCoverage * 100).toFixed(1)}% of replay chunk time. A complete native track must span at least ${MIN_TIMELINE_COVERAGE_RATIO * 100}%.`,
      );
    }
  }

  if (issues.length > 0) {
    throw new Error(
      [
        `Native extraction quality validation failed with ${issues.length} issue${issues.length === 1 ? '' : 's'}:`,
        ...issues.map((issue) => `- ${issue}`),
        'The artifacts were kept for decoder diagnosis:',
        `- track: ${trackPath}`,
        `- diagnostics: ${diagnosticsPath}`,
        `- report: ${reportPath}`,
      ].join('\n'),
    );
  }

  return {
    mapKey,
    players: players.length,
    totalSamples,
    rawPacketsScanned,
    movementStartMs,
    movementEndMs,
    replayStartMs,
    replayEndMs,
    replayCoverage,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log(usage());
    return;
  }

  const inputPath = resolveUserPath(options.input);
  if (!inputPath) {
    console.error(usage());
    process.exitCode = 1;
    return;
  }
  if (!fs.existsSync(inputPath)) {
    throw new Error(`Replay file not found: ${inputPath}`);
  }
  if (!Number.isSafeInteger(options.rawPacketLimit) || options.rawPacketLimit <= 0) {
    throw new Error(
      `--raw-packet-limit must be a positive integer; received ${options.rawPacketLimit}. A full native scan cannot be optional.`,
    );
  }
  if (!Number.isFinite(options.rawTimeFromMs) || options.rawTimeFromMs < 0) {
    throw new Error(`--raw-time-from-ms must be a non-negative number; received ${options.rawTimeFromMs}.`);
  }
  if (
    !Number.isSafeInteger(options.abilitySignalSampleLimit) ||
    options.abilitySignalSampleLimit <= 0
  ) {
    throw new Error(
      `--ability-signal-sample-limit must be a positive integer; received ${options.abilitySignalSampleLimit}.`,
    );
  }
  if (
    !Number.isSafeInteger(options.nonMovementInputEventSampleLimit) ||
    options.nonMovementInputEventSampleLimit <= 0
  ) {
    throw new Error(
      `--non-movement-input-event-sample-limit must be a positive integer; received ${options.nonMovementInputEventSampleLimit}.`,
    );
  }
  if (
    options.rawTimeToMs != null &&
    (!Number.isFinite(options.rawTimeToMs) || options.rawTimeToMs <= options.rawTimeFromMs)
  ) {
    throw new Error(
      `--raw-time-to-ms must be greater than --raw-time-from-ms; received ${options.rawTimeToMs}.`,
    );
  }

  const outPath = resolveUserPath(options.out) ?? defaultOutPath(inputPath);
  const diagnosticsPath =
    resolveUserPath(options.diagnostics) ?? replaceJsonSuffix(outPath, '.diagnostics.json');
  const reportPath =
    resolveUserPath(options.reportOut) ?? replaceJsonSuffix(outPath, '.native_report.json');
  const samplesPath = resolveUserPath(options.samplesOut);

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.mkdirSync(path.dirname(diagnosticsPath), { recursive: true });
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  if (samplesPath) fs.mkdirSync(path.dirname(samplesPath), { recursive: true });

  const extractArgs = [
    inputPath,
    '--out',
    replaceJsonSuffix(outPath, '.legacy_extract.track.json'),
    '--diagnostics',
    diagnosticsPath,
    '--raw-packet-limit',
    String(options.rawPacketLimit),
    '--diagnostics-only',
    '--skip-compact-diagnostics',
    '--ability-signal-sample-limit',
    String(options.abilitySignalSampleLimit),
    '--non-movement-input-event-sample-limit',
    String(options.nonMovementInputEventSampleLimit),
  ];
  if (options.rawTimeFromMs != null) {
    extractArgs.push('--raw-time-from-ms', String(options.rawTimeFromMs));
  }
  if (options.rawTimeToMs != null) {
    extractArgs.push('--raw-time-to-ms', String(options.rawTimeToMs));
  }

  reportStage('Scanning replay packets...');
  runNode('extract_track.mjs', extractArgs);

  const analyzerArgs = [
    '--diagnostics',
    diagnosticsPath,
    '--out',
    reportPath,
    '--track-out',
    outPath,
    '--max-samples',
    String(options.maxSamples),
    '--track-min-sample-interval-ms',
    String(options.trackMinSampleIntervalMs),
    '--omit-samples-in-report',
  ];
  if (samplesPath) analyzerArgs.push('--samples-out', samplesPath);
  if (options.allowOffMapPosition) analyzerArgs.push('--allow-off-map-position');

  reportStage('Decoding player movement and abilities...');
  runNode('analyze_component_data_stream_native.mjs', analyzerArgs);

  reportStage('Validating match completeness...');
  const summary = validateNativeExtractionQuality({
    track: readJsonArtifact(outPath, 'track'),
    diagnostics: readJsonArtifact(diagnosticsPath, 'diagnostics'),
    report: readJsonArtifact(reportPath, 'report'),
    trackPath: outPath,
    diagnosticsPath,
    reportPath,
  });
  console.log(
    `native replay track: map=${summary.mapKey} players=${summary.players} samples=${summary.totalSamples} coverage=${(summary.replayCoverage * 100).toFixed(1)}% rawPackets=${summary.rawPacketsScanned} out=${outPath}`,
  );
  reportStage('Replay ready.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(SCRIPT_PATH)) {
  try {
    main();
  } catch (error) {
    console.error(error.message || error);
    process.exitCode = 1;
  }
}
