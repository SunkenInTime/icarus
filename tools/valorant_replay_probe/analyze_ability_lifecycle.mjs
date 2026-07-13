#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..', '..');

const DEFAULT_TRACK =
  'tools/valorant_replay_probe/tmp/ad64888d_ascent_side_probe.track.json';
const DEFAULT_DIAGNOSTICS =
  'tools/valorant_replay_probe/tmp/ad64888d_ascent_full_capture.diagnostics.json';
const DEFAULT_OUT_JSON =
  'tools/valorant_replay_probe/tmp/ad64888d_ascent_ability_lifecycle.report.json';
const DEFAULT_OUT_MD =
  'tools/valorant_replay_probe/tmp/ad64888d_ascent_ability_lifecycle.report.md';

const ABILITY_CAST_UUID_PATTERN =
  /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

const ARES_ITEM_SLOT_TO_ABILITY_SLOT = new Map([
  [3, 'Grenade'],
  [4, 'Ability1'],
  [5, 'Ability2'],
  [9, 'Ultimate'],
]);

const ABILITY_SLOT_TO_INDEX = new Map([
  ['Grenade', 0],
  ['Ability1', 1],
  ['Ability2', 2],
  ['Ultimate', 3],
]);

const AGENT_TOKENS = new Map([
  ['clay', 'Raze'],
  ['hunter', 'Sova'],
  ['iris', 'Miks'],
  ['killjoy', 'Killjoy'],
  ['pine', 'Pine'],
  ['vampire', 'Reyna'],
  ['wushu', 'Jett'],
]);

const KILLJOY_OBJECTS = [
  {
    pattern: /Killjoy_4_RemoteBees|RemoteBees|Nanoswarm/i,
    slot: 'Grenade',
    abilityName: 'Nanoswarm',
  },
  {
    pattern: /Killjoy_Q_Alarmbot|Alarmbot/i,
    slot: 'Ability1',
    abilityName: 'Alarmbot',
  },
  {
    pattern: /Killjoy_E_Turret|TurretAttack|Pawn_Killjoy_E_Turret/i,
    slot: 'Ability2',
    abilityName: 'Turret',
  },
  {
    pattern: /Killjoy_X_Bomb|Lockdown/i,
    slot: 'Ultimate',
    abilityName: 'Lockdown',
  },
];

const CURRENT_REPLAY_VIDEO_ANCHORS = [];

function parseArgs(argv) {
  const options = {
    track: DEFAULT_TRACK,
    diagnostics: DEFAULT_DIAGNOSTICS,
    outJson: DEFAULT_OUT_JSON,
    outMd: DEFAULT_OUT_MD,
    roundIndex: 0,
    includeAllRoundRows: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--track') options.track = argv[++index];
    else if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out-json') options.outJson = argv[++index];
    else if (arg === '--out-md') options.outMd = argv[++index];
    else if (arg === '--round-index') options.roundIndex = Number(argv[++index]);
    else if (arg === '--include-all-round-rows') options.includeAllRoundRows = true;
    else if (arg === '--help' || arg === '-h') options.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }

  return options;
}

function resolvePath(value) {
  if (!value) return null;
  if (path.isAbsolute(value)) return value;
  const cwdPath = path.resolve(process.cwd(), value);
  if (fs.existsSync(cwdPath)) return cwdPath;
  const repoPath = path.resolve(REPO_ROOT, value);
  if (fs.existsSync(repoPath)) return repoPath;
  if (/^(tools|lib|docs|test|assets)[\\/]/.test(value)) return repoPath;
  return cwdPath;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function writeText(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, value);
}

function round(value, places = 3) {
  if (!Number.isFinite(value)) return value;
  const factor = 10 ** places;
  return Math.round(value * factor) / factor;
}

function archetypeClassName(value) {
  return String(value ?? '')
    .split('/')
    .at(-1)
    .split('.')
    .at(-1)
    .replace(/^Default__/, '')
    .replace(/_C$/, '');
}

function agentFromActorPath(actorPath) {
  const token = archetypeClassName(actorPath).replace(/_PC$/i, '').toLowerCase();
  return AGENT_TOKENS.get(token) ?? null;
}

function killjoyObjectInfo(value) {
  const text = String(value ?? '');
  return KILLJOY_OBJECTS.find((entry) => entry.pattern.test(text)) ?? null;
}

function slotIndex(slot) {
  return ABILITY_SLOT_TO_INDEX.get(slot) ?? null;
}

function playerMap(track) {
  const byGuid = new Map();
  const agentCounts = new Map();
  for (const player of track.players ?? []) {
    const netGuid = player.diagnostic?.netGuid;
    if (!Number.isInteger(netGuid)) continue;
    const agent = normalizeAgent(player.agent);
    const entry = {
      playerNetGuid: netGuid,
      agent,
      actorPath: player.diagnostic?.archetypePath ?? null,
      displayName: player.displayName ?? null,
    };
    byGuid.set(netGuid, entry);
    if (agent) agentCounts.set(agent, (agentCounts.get(agent) ?? 0) + 1);
  }
  return { byGuid, agentCounts };
}

function normalizeAgent(agent) {
  if (agent === 'Vampire') return 'Reyna';
  if (agent === 'Iris') return 'Miks';
  if (agent === 'Hunter') return 'Sova';
  if (agent === 'Clay') return 'Raze';
  if (agent === 'Wushu') return 'Jett';
  return agent ?? null;
}

function uniquePlayerForAgent(players, agent) {
  const matches = [...players.byGuid.values()].filter((player) => player.agent === agent);
  return matches.length === 1 ? matches[0] : null;
}

function readByteIntPacked(buffer, offset) {
  let value = 0;
  let shift = 1;
  let cursor = offset;
  for (let index = 0; index < 5; index += 1) {
    if (cursor >= buffer.length) return null;
    const currentByte = buffer[cursor];
    value += (currentByte >> 1) * shift;
    cursor += 1;
    if ((currentByte & 1) === 0) return { value, offset: cursor };
    shift *= 128;
  }
  return null;
}

function readAbilityVectorDouble64(buffer, offset) {
  if (offset + 24 > buffer.length) return null;
  const vector = {
    x: round(buffer.readDoubleLE(offset)),
    y: round(buffer.readDoubleLE(offset + 8)),
    z: round(buffer.readDoubleLE(offset + 16)),
  };
  if (
    Math.abs(vector.x) > 20000 ||
    Math.abs(vector.y) > 20000 ||
    vector.z < -1000 ||
    vector.z > 2000
  ) {
    return null;
  }
  return vector;
}

function parseEffectLocations(buffer, offset) {
  if (buffer[offset] !== 0x14) return [];
  const fieldBits = readByteIntPacked(buffer, offset + 1);
  if (!fieldBits || fieldBits.value <= 0 || fieldBits.value % 8 !== 0) return [];
  const payloadEnd = fieldBits.offset + fieldBits.value / 8;
  const arrayCount = readByteIntPacked(buffer, fieldBits.offset);
  if (!arrayCount || arrayCount.value < 0 || arrayCount.value > 32) return [];

  let cursor = arrayCount.offset;
  const locations = [];
  for (let index = 0; index < arrayCount.value; index += 1) {
    if (buffer[cursor] === 0x02) cursor += 1;
    if (buffer[cursor] !== 0x16) return [];
    const vectorBits = readByteIntPacked(buffer, cursor + 1);
    if (vectorBits?.value !== 192) return [];
    const vector = readAbilityVectorDouble64(buffer, vectorBits.offset);
    if (!vector) return [];
    locations.push(vector);
    cursor = vectorBits.offset + 24;
    while (cursor < payloadEnd && buffer[cursor] === 0x00) cursor += 1;
  }
  return locations;
}

function parseCastTail(buffer, afterNull) {
  const castLocationHeaderOffset = afterNull + 18;
  if (buffer[castLocationHeaderOffset] !== 0x12) return {};
  const vectorBits = readByteIntPacked(buffer, castLocationHeaderOffset + 1);
  if (vectorBits?.value !== 192) return {};
  const castLocation = readAbilityVectorDouble64(buffer, vectorBits.offset);
  const effectLocations = parseEffectLocations(buffer, vectorBits.offset + 24);
  return { castLocation, effectLocations };
}

function decodeAbilityCastSamples(diagnostics) {
  const frameSummary = diagnostics.frameSummary ?? {};
  const samples = [
    ...(frameSummary.abilityCastSignalSamples ?? []),
    ...(frameSummary.compactAbilityCastSignalSamples ?? []),
  ];
  const casts = [];
  const seen = new Set();

  for (const sample of samples) {
    if (sample.fieldName !== 'AbilityCastsThisRound') continue;
    if (!sample.payloadHex || sample.payloadHexTruncated) continue;
    const buffer = Buffer.from(sample.payloadHex, 'hex');
    const ascii = buffer.toString('latin1');
    ABILITY_CAST_UUID_PATTERN.lastIndex = 0;
    let match;
    while ((match = ABILITY_CAST_UUID_PATTERN.exec(ascii))) {
      const uuidEnd = match.index + match[0].length;
      if (buffer[uuidEnd] !== 0) continue;
      const afterNull = uuidEnd + 1;
      const slotEnumValue = buffer[afterNull + 2];
      const abilitySlot = ARES_ITEM_SLOT_TO_ABILITY_SLOT.get(slotEnumValue);
      if (!abilitySlot) continue;
      const castTimeOffset = afterNull + 14;
      const castTimeSeconds =
        castTimeOffset + 4 <= buffer.length ? buffer.readFloatLE(castTimeOffset) : null;
      if (!Number.isFinite(castTimeSeconds) || castTimeSeconds < 0) continue;

      const key = [
        sample.actorNetGuid,
        match[0],
        abilitySlot,
        round(castTimeSeconds),
      ].join('|');
      if (seen.has(key)) continue;
      seen.add(key);
      const tail = parseCastTail(buffer, afterNull);
      casts.push({
        id: `cast-${casts.length}`,
        timeMs: sample.timeMs,
        replicationTimeMs: sample.timeMs,
        playerNetGuid: Number.isInteger(sample.actorNetGuid) ? sample.actorNetGuid : null,
        actorPath: sample.actorPath ?? null,
        agent: normalizeAgent(agentFromActorPath(sample.actorPath)),
        abilitySlot,
        abilityIndex: slotIndex(abilitySlot),
        castTimeSeconds: round(castTimeSeconds),
        castLocation: tail.castLocation ?? null,
        effectLocations: tail.effectLocations ?? [],
        sourceSample: {
          chIndex: sample.chIndex,
          actorNetGuid: sample.actorNetGuid ?? null,
          fieldName: sample.fieldName,
          numBits: sample.numBits ?? null,
        },
      });
    }
  }

  return casts.sort((a, b) => a.timeMs - b.timeMs);
}

function castPlacementMergeKey(cast) {
  return [
    cast.playerNetGuid,
    cast.abilitySlot,
    cast.castTimeSeconds,
    cast.actorPath,
  ].join('|');
}

function mergeTrackCastPlacements(decodedCasts, trackCasts) {
  const byKey = new Map();
  for (const cast of trackCasts ?? []) {
    if ((cast.placementLocations ?? []).length === 0) continue;
    byKey.set(castPlacementMergeKey(cast), cast);
  }
  if (byKey.size === 0) return decodedCasts;
  return decodedCasts.map((cast) => {
    const trackCast = byKey.get(castPlacementMergeKey(cast));
    if (!trackCast) return cast;
    return {
      ...cast,
      placementLocations: trackCast.placementLocations ?? [],
      placementTimeMs: trackCast.placementTimeMs ?? null,
      placementSource: trackCast.placementSource ?? null,
      placementActorNetGuid: trackCast.placementActorNetGuid ?? null,
    };
  });
}

function abilitySignals(diagnostics) {
  const frameSummary = diagnostics.frameSummary ?? {};
  return [
    ...(frameSummary.abilitySignalSamples ?? []),
    ...(frameSummary.compactAbilitySignalSamples ?? []),
  ].filter((sample) => sample.timeMs != null);
}

function utilityCloses(diagnostics) {
  const frameSummary = diagnostics.frameSummary ?? {};
  return [
    ...(frameSummary.utilityActorCloseSamples ?? []),
    ...(frameSummary.compactUtilityActorCloseSamples ?? []),
  ];
}

function roundBounds(track, roundIndex) {
  const starts = [...(track.roundStartEvents ?? [])].sort((a, b) => a.timeMs - b.timeMs);
  const start = starts.find((entry) => entry.roundIndex === roundIndex) ?? starts[roundIndex];
  const next = starts.find((entry) => entry.timeMs > (start?.timeMs ?? 0));
  return {
    roundIndex,
    startMs: start?.timeMs ?? 0,
    endMs: next?.timeMs ?? Number.POSITIVE_INFINITY,
  };
}

function timeLabel(timeMs, bounds) {
  return `${round((timeMs - bounds.startMs) / 1000, 3)}s`;
}

function objectLabel(signal) {
  return archetypeClassName(signal.actorPath) || archetypeClassName(signal.archetypePath);
}

function signalShortName(signal) {
  const group = String(signal.actorGroup ?? '').split('.').at(-1) || signal.repObjectPath;
  const field = signal.fieldName ?? signal.closeReason ?? 'open';
  return `${objectLabel(signal)}:${field}${group ? `@${group}` : ''}`;
}

function nearbySignals(signals, timeMs, lane, radiusMs = 750) {
  return signals.filter((signal) => {
    if (Math.abs(signal.timeMs - timeMs) > radiusMs) return false;
    const info = classifySignalLane(signal);
    const playerMatches =
      lane.playerNetGuid != null && signal.actorNetGuid === lane.playerNetGuid;
    const slotMatches =
      lane.agent != null &&
      info.agent === lane.agent &&
      lane.abilitySlot != null &&
      info.abilitySlot === lane.abilitySlot;
    return playerMatches || slotMatches;
  });
}

function classifySignalLane(signal) {
  const playerAgent = agentFromActorPath(signal.actorPath);
  if (playerAgent && Number.isInteger(signal.actorNetGuid)) {
    return {
      playerNetGuid: signal.actorNetGuid,
      agent: normalizeAgent(playerAgent),
      abilitySlot: null,
      abilityIndex: null,
      abilityName: null,
    };
  }

  const info = killjoyObjectInfo(`${signal.actorPath} ${signal.archetypePath}`);
  if (info) {
    return {
      playerNetGuid: null,
      agent: 'Killjoy',
      abilitySlot: info.slot,
      abilityIndex: slotIndex(info.slot),
      abilityName: info.abilityName,
    };
  }

  return {
    playerNetGuid: null,
    agent: null,
    abilitySlot: null,
    abilityIndex: null,
    abilityName: null,
  };
}

function makeLane({ playerNetGuid, agent, abilitySlot, abilityIndex, abilityName }) {
  return {
    playerNetGuid: playerNetGuid ?? null,
    agent: normalizeAgent(agent),
    abilitySlot: abilitySlot ?? null,
    abilityIndex: abilityIndex ?? slotIndex(abilitySlot),
    abilityName: abilityName ?? null,
  };
}

function laneLabel(lane) {
  const slot = lane.abilitySlot ? `${lane.abilitySlot}/${lane.abilityIndex}` : 'unknown';
  return `${lane.playerNetGuid ?? '?'} ${lane.agent ?? '?'} ${slot}`;
}

function summarizeSignals(items, limit = 8) {
  const labels = [];
  const seen = new Set();
  for (const item of items) {
    const label = signalShortName(item);
    if (seen.has(label)) continue;
    seen.add(label);
    labels.push(label);
    if (labels.length >= limit) break;
  }
  return labels;
}

function inferUtilityLifecycle(actor, timeKind) {
  if (
    /Ability_Killjoy_E_Turret/i.test(actor.className ?? actor.archetypePath) &&
    actor.contentKind === 'component-stationary-track'
  ) {
    if (timeKind === 'open') return 'turret stationary component track opened';
    return 'turret stationary component track ended';
  }
  if (/Pawn_Killjoy_E_Turret/i.test(actor.className ?? actor.archetypePath)) {
    if (timeKind === 'open') return 'turret placed / deployable pawn opened';
    return 'turret deployable ended; recall/retrieve inferred, destroy not proven';
  }
  if (/TurretAttack/i.test(actor.className ?? actor.archetypePath)) {
    if (timeKind === 'open') return 'turret attack helper opened';
    return 'turret attack helper ended with turret pawn';
  }
  if (/Projectile_Killjoy_4_RemoteBees/i.test(actor.className ?? actor.archetypePath)) {
    if (timeKind === 'open') return 'nanoswarm projectile/map phase opened';
    return 'nanoswarm projectile/map phase ended';
  }
  if (/Alarmbot/i.test(actor.className ?? actor.archetypePath)) {
    if (timeKind === 'open') return 'alarmbot ability/deployable actor opened';
    return 'alarmbot actor ended';
  }
  return timeKind === 'open' ? 'utility actor opened' : 'utility actor closed';
}

function inferCastLifecycle(cast) {
  if (cast.agent === 'Killjoy' && cast.abilitySlot === 'Grenade') {
    return 'nanoswarm cast/use; throw/detonate split unresolved';
  }
  if (cast.agent === 'Killjoy' && cast.abilitySlot === 'Ability2') {
    return 'turret canonical cast';
  }
  if (cast.agent === 'Killjoy' && cast.abilitySlot === 'Ability1') {
    return 'alarmbot canonical cast';
  }
  if (cast.agent === 'Reyna' && cast.abilitySlot === 'Ability1') {
    return 'Reyna heal/devour canonical cast';
  }
  return 'canonical ability cast';
}

function confidenceForUtility(actor, timeKind) {
  if (actor.contentKind === 'component-stationary-track') {
    return 'medium-correlated-spatial-component-track';
  }
  if (/Pawn_Killjoy_E_Turret/i.test(actor.className ?? actor.archetypePath)) {
    return timeKind === 'open' ? 'high-proven-open' : 'medium-inferred-recall-close';
  }
  return 'medium-proven-actor-lifecycle';
}

function rowFromUtility(actor, timeMs, timeKind, bounds, players, signals) {
  const info = killjoyObjectInfo(`${actor.className} ${actor.archetypePath}`);
  const uniquePlayer = info ? uniquePlayerForAgent(players, 'Killjoy') : null;
  const lane = makeLane({
    playerNetGuid: actor.ownerPlayerNetGuid ?? uniquePlayer?.playerNetGuid ?? null,
    agent: actor.agent ?? info?.agent ?? uniquePlayer?.agent ?? null,
    abilitySlot: actor.abilitySlot ?? info?.slot ?? null,
    abilityIndex: actor.abilityIndex ?? slotIndex(actor.abilitySlot ?? info?.slot),
    abilityName: info?.abilityName ?? null,
  });
  const adjacent = nearbySignals(signals, timeMs, lane, 800);
  const proof = [
    `${actor.className} ${timeKind} at ${timeLabel(timeMs, bounds)}`,
    actor.actorNetGuid != null ? `actorNetGuid=${actor.actorNetGuid}` : null,
    actor.contentKind === 'component-stationary-track' && actor.position
      ? `position=(${actor.position.x},${actor.position.y},${actor.position.z})`
      : null,
    actor.contentKind === 'component-stationary-track'
      ? `samples=${actor.samples?.length ?? 0}`
      : null,
    actor.raw?.correlatedSignal
      ? `correlated signal ${signalShortName(actor.raw.correlatedSignal)} at ${timeLabel(actor.raw.correlatedSignal.timeMs, bounds)}`
      : null,
    actor.closedAtMs != null && timeKind === 'open'
      ? `closes ${timeLabel(actor.closedAtMs, bounds)}`
      : null,
    uniquePlayer && !actor.ownerPlayerNetGuid ? 'owner inferred because Killjoy is unique in match' : null,
  ].filter(Boolean);

  return {
    timeMs,
    time: timeLabel(timeMs, bounds),
    lane,
    laneKey: laneLabel(lane),
    objects: [
      `${actor.className}:actor-${actor.actorNetGuid}`,
      ...summarizeSignals(adjacent, 7),
    ],
    inferredLifecycleAction: inferUtilityLifecycle(actor, timeKind),
    confidence: confidenceForUtility(actor, timeKind),
    proofNotes: proof,
  };
}

function rowFromCast(cast, bounds, signals) {
  const lane = makeLane(cast);
  const eventTimeMs = cast.timeMs;
  const adjacent = nearbySignals(signals, eventTimeMs, lane, 850);
  const proof = [
    `AbilityCastsThisRound replication ${timeLabel(cast.replicationTimeMs, bounds)}`,
    Number.isFinite(cast.castTimeSeconds) ? `castTimeSeconds=${cast.castTimeSeconds}` : null,
    `diagnostic actorNetGuid=${cast.playerNetGuid}`,
    cast.castLocation
      ? `castLocation=(${cast.castLocation.x},${cast.castLocation.y},${cast.castLocation.z})`
      : null,
    cast.effectLocations?.length ? `effectLocations=${cast.effectLocations.length}` : null,
  ].filter(Boolean);
  return {
    timeMs: eventTimeMs,
    time: timeLabel(eventTimeMs, bounds),
    lane,
    laneKey: laneLabel(lane),
    objects: [
      `AbilityCastsThisRound:${cast.id}`,
      ...summarizeSignals(adjacent, 8),
    ],
    inferredLifecycleAction: inferCastLifecycle(cast),
    confidence:
      adjacent.length > 0
        ? 'high-proven-cast-with-component-pulses'
        : 'high-proven-canonical-cast',
    proofNotes: proof,
  };
}

function manualBlockerRows(bounds) {
  return [];
}

function textForEvidence(value) {
  return JSON.stringify(value ?? {});
}

function matchesAnchorPattern(value, anchor) {
  anchor.pattern.lastIndex = 0;
  return anchor.pattern.test(textForEvidence(value));
}

function matchesContextPattern(value, anchor) {
  if (!anchor.contextPattern) return false;
  anchor.contextPattern.lastIndex = 0;
  return anchor.contextPattern.test(textForEvidence(value));
}

function castMatchesAnchor(cast, anchor, bounds) {
  const radiusMs = anchor.radiusMs ?? 1200;
  if (Math.abs(cast.timeMs - (bounds.startMs + anchor.timeMs)) > radiusMs) return false;
  if (anchor.agent && cast.agent !== anchor.agent) return false;
  if (anchor.abilitySlot && cast.abilitySlot !== anchor.abilitySlot) return false;
  return true;
}

function utilityMatchesAnchor(actor, anchor, bounds, timeKey = 'timeMs', linkedCastIds = null) {
  const timeMs = actor[timeKey];
  if (!Number.isFinite(timeMs)) return false;
  const radiusMs = anchor.radiusMs ?? 1200;
  if (Math.abs(timeMs - (bounds.startMs + anchor.timeMs)) > radiusMs) return false;
  if (anchor.agent && actor.agent && normalizeAgent(actor.agent) !== anchor.agent) return false;
  const linkedToAnchorCast = actor.sourceCastId && linkedCastIds?.has(actor.sourceCastId);
  if (
    anchor.abilitySlot &&
    actor.abilitySlot &&
    actor.abilitySlot !== anchor.abilitySlot &&
    !linkedToAnchorCast
  ) {
    return false;
  }
  return matchesAnchorPattern(actor, anchor);
}

function signalMatchesAnchor(signal, anchor, bounds) {
  const radiusMs = anchor.radiusMs ?? 1200;
  if (Math.abs(signal.timeMs - (bounds.startMs + anchor.timeMs)) > radiusMs) return false;
  return matchesAnchorPattern(signal, anchor);
}

function signalMatchesAnchorContext(signal, anchor, bounds) {
  const radiusMs = anchor.radiusMs ?? 1200;
  if (Math.abs(signal.timeMs - (bounds.startMs + anchor.timeMs)) > radiusMs) return false;
  return matchesContextPattern(signal, anchor);
}

function videoAnchorEvidenceSummary(anchor, bounds, casts, utilityActors, signals, closes) {
  const matchingCasts = casts.filter((cast) => castMatchesAnchor(cast, anchor, bounds));
  const matchingCastIds = new Set(matchingCasts.map((cast) => cast.id));
  const matchingPlacementCasts = matchingCasts.filter(
    (cast) => (cast.placementLocations ?? []).length > 0,
  );
  const matchingSpatialActors = utilityActors.filter((actor) =>
    utilityMatchesAnchor(actor, anchor, bounds, 'timeMs', matchingCastIds),
  );
  const matchingActorCloses = [
    ...closes.filter((close) => utilityMatchesAnchor(close, anchor, bounds, 'timeMs', matchingCastIds)),
    ...utilityActors.filter((actor) => utilityMatchesAnchor(actor, anchor, bounds, 'closedAtMs', matchingCastIds)),
  ];
  const matchingSignals = signals.filter((signal) => signalMatchesAnchor(signal, anchor, bounds));
  const matchingContextSignals = signals.filter((signal) =>
    signalMatchesAnchorContext(signal, anchor, bounds),
  );
  const evidenceLabels = [
    ...matchingCasts.slice(0, 5).map(
      (cast) => `cast ${cast.id} ${timeLabel(cast.timeMs, bounds)} ${cast.agent ?? ''} ${cast.abilitySlot ?? ''}`.trim(),
    ),
    ...matchingPlacementCasts.slice(0, 5).map((cast) => {
      const position = cast.placementLocations?.[0];
      const label =
        position == null
          ? 'unknown'
          : `(${round(position.x, 1)}, ${round(position.y, 1)}, ${round(position.z, 1)})`;
      return `placement ${cast.id} ${label}`;
    }),
    ...matchingSpatialActors.slice(0, 5).map(
      (actor) =>
        `actor ${actor.className ?? actor.archetypePath} ${timeLabel(actor.timeMs, bounds)}`,
    ),
    ...matchingActorCloses.slice(0, 5).map(
      (close) =>
        `close ${close.className ?? close.archetypePath} ${timeLabel(close.timeMs, bounds)}`,
    ),
    ...summarizeSignals(matchingSignals, 8).map((label) => `signal ${label}`),
    ...summarizeSignals(matchingContextSignals, 5).map((label) => `context signal ${label}`),
  ];

  let evidenceLevel = 'missing-current-diagnostics';
  if (matchingSpatialActors.length > 0) evidenceLevel = 'spatial-actor';
  else if (matchingActorCloses.length > 0) evidenceLevel = 'actor-close';
  else if (matchingPlacementCasts.length > 0 && matchingSignals.length > 0) {
    evidenceLevel = 'cast-placement-and-component';
  } else if (matchingPlacementCasts.length > 0) evidenceLevel = 'cast-placement';
  else if (matchingCasts.length > 0 && matchingSignals.length > 0) {
    evidenceLevel = 'cast-and-component';
  } else if (matchingCasts.length > 0) evidenceLevel = 'cast-only';
  else if (matchingSignals.length > 0) evidenceLevel = 'component-only';
  else if (matchingContextSignals.length > 0) evidenceLevel = 'nearby-context-only';

  return {
    source: 'user-video-ground-truth',
    expectedTime: timeLabel(bounds.startMs + anchor.timeMs, bounds),
    expectedTimeMs: bounds.startMs + anchor.timeMs,
    label: anchor.label,
    agent: anchor.agent,
    abilitySlot: anchor.abilitySlot,
    abilityName: anchor.abilityName ?? null,
    evidenceLevel,
    castCount: matchingCasts.length,
    placementCastCount: matchingPlacementCasts.length,
    spatialActorCount: matchingSpatialActors.length,
    actorCloseCount: matchingActorCloses.length,
    componentSignalCount: matchingSignals.length,
    contextSignalCount: matchingContextSignals.length,
    evidence: evidenceLabels,
  };
}

function videoAnchorAudit(bounds, casts, utilityActors, signals, closes) {
  return CURRENT_REPLAY_VIDEO_ANCHORS.map((anchor) =>
    videoAnchorEvidenceSummary(anchor, bounds, casts, utilityActors, signals, closes),
  );
}

function buildReport(track, diagnostics, options) {
  const bounds = roundBounds(track, options.roundIndex);
  const players = playerMap(track);
  const casts = mergeTrackCastPlacements(decodeAbilityCastSamples(diagnostics), track.abilityCasts);
  const signals = abilitySignals(diagnostics);
  const closes = utilityCloses(diagnostics);
  const utilityActors = track.utilityActors ?? [];
  const closeByActorAndTime = new Set(
    closes.map((close) => `${close.actorNetGuid}|${close.timeMs}`),
  );

  const utilityRows = [];
  for (const actor of utilityActors) {
    if (actor.ignoredAsAbility || actor.timeMs < bounds.startMs || actor.timeMs >= bounds.endMs) {
      continue;
    }
    if (!/Killjoy/i.test(`${actor.agent} ${actor.className} ${actor.archetypePath}`)) {
      if (!options.includeAllRoundRows) continue;
    }
    utilityRows.push(rowFromUtility(actor, actor.timeMs, 'open', bounds, players, signals));
    if (Number.isFinite(actor.closedAtMs) && actor.closedAtMs < bounds.endMs) {
      utilityRows.push(rowFromUtility(actor, actor.closedAtMs, 'close', bounds, players, signals));
    }
  }

  const castRows = casts
    .filter((cast) => cast.timeMs >= bounds.startMs && cast.timeMs < bounds.endMs)
    .map((cast) => rowFromCast(cast, bounds, signals));

  const componentOnlyRows = [
    ...buildKilljoyGrenadeSignalRows(signals, casts, bounds, players),
    ...buildKilljoyTurretEquipRows(signals, bounds, players, utilityActors),
  ];

  const rows = [
    ...utilityRows,
    ...castRows,
    ...componentOnlyRows,
    ...manualBlockerRows(bounds),
  ]
    .sort((a, b) => a.timeMs - b.timeMs || a.laneKey.localeCompare(b.laneKey))
    .map((row, index) => ({ id: `lifecycle-${index}`, ...row }));

  return {
    input: {
      track: options.track,
      diagnostics: options.diagnostics,
      map: track.mapId ?? diagnostics.header?.mapPath ?? null,
      roundIndex: options.roundIndex,
      roundStartMs: bounds.startMs,
      roundEndMs: Number.isFinite(bounds.endMs) ? bounds.endMs : null,
      abilitySignalSampleCount: diagnostics.frameSummary?.abilitySignalSamples?.length ?? 0,
      abilitySignalSampleLimit: diagnostics.frameSummary?.abilitySignalSampleLimit ?? null,
    },
    identityNotes: [
      'Ability cast ownership is decoded from diagnostics sample.actorNetGuid, not collapsed actor class path.',
      ...[...players.byGuid.values()].map(
        (player) => `${player.playerNetGuid}: ${player.agent} (${player.actorPath})`,
      ),
    ],
    duplicateAgentChecks: duplicateAgentChecks(casts, bounds, players),
    videoAnchors: videoAnchorAudit(bounds, casts, utilityActors, signals, closes),
    rows,
  };
}

function buildKilljoyGrenadeSignalRows(signals, casts, bounds, players) {
  const grenadeSignals = signals.filter((signal) => {
    if (signal.timeMs < bounds.startMs || signal.timeMs >= bounds.endMs) return false;
    return (
      /Ability_Killjoy_4_RemoteBees_MultiDetonate/i.test(signal.actorPath ?? '') &&
      signal.timeMs >= bounds.startMs + 37000 &&
      signal.timeMs <= bounds.startMs + 40000
    );
  });
  if (grenadeSignals.length === 0) return [];

  const owner = uniquePlayerForAgent(players, 'Killjoy');
  const matchingCast = casts.find(
    (cast) =>
      cast.agent === 'Killjoy' &&
      cast.abilitySlot === 'Grenade' &&
      Number.isFinite(cast.castTimeSeconds) &&
      Math.abs(bounds.startMs + cast.castTimeSeconds * 1000 - grenadeSignals[0].timeMs) < 250,
  );
  const lane = makeLane({
    playerNetGuid: owner?.playerNetGuid ?? matchingCast?.playerNetGuid ?? null,
    agent: 'Killjoy',
    abilitySlot: 'Grenade',
    abilityName: 'Nanoswarm',
  });
  return [
    {
      timeMs: grenadeSignals[0].timeMs,
      time: timeLabel(grenadeSignals[0].timeMs, bounds),
      lane,
      laneKey: laneLabel(lane),
      objects: summarizeSignals(grenadeSignals, 8),
      inferredLifecycleAction: 'nanoswarm component throw/use pulse; detonate split unresolved',
      confidence: matchingCast
        ? 'high-component-pulse-matches-canonical-cast-time'
        : 'medium-component-only',
      proofNotes: [
        'Ability_Killjoy_4_RemoteBees_MultiDetonate component rows include MulticastOnThrow, state, and charge changes.',
        matchingCast
          ? `matching AbilityCastsThisRound has castTimeSeconds=${matchingCast.castTimeSeconds} and replication ${timeLabel(matchingCast.replicationTimeMs, bounds)}`
          : null,
      ].filter(Boolean),
    },
  ];
}

function buildKilljoyTurretEquipRows(signals, bounds, players, utilityActors = []) {
  const turretSignals = signals.filter((signal) => {
    if (signal.timeMs < bounds.startMs || signal.timeMs >= bounds.endMs) return false;
    return (
      /Ability_Killjoy_E_Turret/i.test(signal.actorPath ?? '') &&
      /EquippableStateMachine|EquipmentCharge/i.test(
        `${signal.actorGroup} ${signal.repObjectPath}`,
      ) &&
      signal.timeMs >= bounds.startMs + 48000 &&
      signal.timeMs <= bounds.startMs + 51000
    );
  });
  if (turretSignals.length === 0) return [];

  const groups = [];
  for (const signal of turretSignals) {
    const group = groups.find((entry) => Math.abs(entry.timeMs - signal.timeMs) <= 120);
    if (group) group.signals.push(signal);
    else groups.push({ timeMs: signal.timeMs, signals: [signal] });
  }

  const owner = uniquePlayerForAgent(players, 'Killjoy');
  return groups.map((group) => {
    const spatialActor = utilityActors.find((actor) => {
      if (Math.abs((actor.timeMs ?? 0) - group.timeMs) > 1000) return false;
      return (
        actor.agent === 'Killjoy' &&
        actor.abilitySlot === 'Ability2' &&
        /Turret/i.test(`${actor.className} ${actor.archetypePath}`) &&
        /component-stationary-track|pawn-deployable/i.test(`${actor.contentKind} ${actor.phase}`)
      );
    });
    const lane = makeLane({
      playerNetGuid: owner?.playerNetGuid ?? null,
      agent: 'Killjoy',
      abilitySlot: 'Ability2',
      abilityName: 'Turret',
    });
    return {
      timeMs: group.timeMs,
      time: timeLabel(group.timeMs, bounds),
      lane,
      laneKey: laneLabel(lane),
      objects: summarizeSignals(group.signals, 8),
      inferredLifecycleAction: spatialActor
        ? 'turret equip/state-machine pulse paired with spatial component track'
        : 'turret equip/state-machine pulse; no pawn open in artifact',
      confidence: spatialActor
        ? 'medium-component-pulse-paired-with-spatial-track'
        : 'medium-component-only',
      proofNotes: [
        'EquippableStateMachine/EquipmentCharge rows exist for Ability_Killjoy_E_Turret.',
        spatialActor
          ? `paired spatial track actorNetGuid=${spatialActor.actorNetGuid} at ${timeLabel(spatialActor.timeMs, bounds)} position=(${spatialActor.position?.x},${spatialActor.position?.y},${spatialActor.position?.z})`
          : 'No Pawn_Killjoy_E_Turret actor open found near this anchor, so placement is not proven.',
      ],
    };
  });
}

function duplicateAgentChecks(casts, bounds, players) {
  const roundCasts = casts.filter((cast) => cast.timeMs >= bounds.startMs && cast.timeMs < bounds.endMs);
  return ['Killjoy', 'Omen'].map((agent) => ({
    agent,
    playerNetGuids: [...players.byGuid.values()]
      .filter((player) => player.agent === agent)
      .map((player) => player.playerNetGuid),
    rows: roundCasts
      .filter((cast) => cast.agent === agent)
      .map((cast) => ({
        time: timeLabel(cast.timeMs, bounds),
        playerNetGuid: cast.playerNetGuid,
        slot: cast.abilitySlot,
      })),
  }));
}

function markdownReport(report) {
  const lines = [];
  lines.push('# Ascent Ability Lifecycle Report');
  lines.push('');
  lines.push(`Round ${report.input.roundIndex}, start ${report.input.roundStartMs}ms`);
  lines.push('');
  lines.push('## Duplicate-agent identity checks');
  for (const check of report.duplicateAgentChecks) {
    const rows = check.rows
      .map((row) => `${row.time} -> ${row.playerNetGuid} ${row.slot}`)
      .join('; ');
    lines.push(
      `- ${check.agent}: players ${check.playerNetGuids.join(', ')}; casts ${rows || 'no round rows'}`,
    );
  }
  lines.push('');
  lines.push('## Video ground-truth anchor audit');
  lines.push(
    '| video time | source action | agent | ability | decoded evidence level | counts | evidence seen |',
  );
  lines.push('|---:|---|---|---|---|---|---|');
  for (const anchor of report.videoAnchors ?? []) {
    lines.push(
      [
        anchor.expectedTime,
        anchor.label,
        anchor.agent ?? '',
        [
          anchor.abilityName,
          `${anchor.abilitySlot ?? ''}/${slotIndex(anchor.abilitySlot) ?? ''}`,
        ].filter(Boolean).join(' '),
        anchor.evidenceLevel,
        `casts=${anchor.castCount}; placements=${anchor.placementCastCount}; actors=${anchor.spatialActorCount}; closes=${anchor.actorCloseCount}; signals=${anchor.componentSignalCount}`,
        anchor.evidence.join('<br>'),
      ]
        .map(markdownCell)
        .join('|')
        .replace(/^/, '|')
        .replace(/$/, '|'),
    );
  }
  lines.push('');
  lines.push('## Lifecycle rows');
  lines.push(
    '| time | playerNetGuid | agent | slot/index | objects/signals seen | inferred lifecycle action | confidence | proof notes |',
  );
  lines.push('|---:|---:|---|---|---|---|---|---|');
  for (const row of report.rows) {
    lines.push(
      [
        row.time,
        row.lane.playerNetGuid ?? '',
        row.lane.agent ?? '',
        `${row.lane.abilitySlot ?? ''}/${row.lane.abilityIndex ?? ''}`,
        row.objects.join('<br>'),
        row.inferredLifecycleAction,
        row.confidence,
        row.proofNotes.join('<br>'),
      ]
        .map(markdownCell)
        .join('|')
        .replace(/^/, '|')
        .replace(/$/, '|'),
    );
  }
  lines.push('');
  lines.push('## Proof boundary');
  lines.push(
    '- Proven rows are tied to AbilityCastsThisRound, actor open/close rows, or retained component samples.',
  );
  lines.push(
    '- Recall/retrieve and throw-vs-detonate labels remain explicit inferences unless a dedicated opcode/field is decoded.',
  );
  if (
    report.input.abilitySignalSampleLimit != null &&
    report.input.abilitySignalSampleCount >= report.input.abilitySignalSampleLimit
  ) {
    lines.push(
      `- The diagnostics hit the generic abilitySignalSamples cap (${report.input.abilitySignalSampleCount}/${report.input.abilitySignalSampleLimit}); rerun extraction with a higher --ability-signal-sample-limit before treating missing component-only anchors as absent.`,
    );
  } else if (report.input.abilitySignalSampleLimit != null) {
    lines.push(
      `- The diagnostics did not hit the generic abilitySignalSamples cap (${report.input.abilitySignalSampleCount}/${report.input.abilitySignalSampleLimit}).`,
    );
  }
  lines.push('');
  return `${lines.join('\n')}\n`;
}

function markdownCell(value) {
  return String(value ?? '').replace(/\|/g, '\\|').replace(/\r?\n/g, '<br>');
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log(
      'usage: node analyze_ability_lifecycle.mjs [--track track.json] [--diagnostics diagnostics.json] [--out-json report.json] [--out-md report.md] [--round-index 0] [--include-all-round-rows]',
    );
    return;
  }

  options.track = resolvePath(options.track);
  options.diagnostics = resolvePath(options.diagnostics);
  options.outJson = resolvePath(options.outJson);
  options.outMd = resolvePath(options.outMd);

  const track = readJson(options.track);
  const diagnostics = readJson(options.diagnostics);
  const report = buildReport(track, diagnostics, options);
  writeJson(options.outJson, report);
  writeText(options.outMd, markdownReport(report));
  console.error(`ability lifecycle rows: ${report.rows.length}`);
  console.error(`wrote ${options.outJson}`);
  console.error(`wrote ${options.outMd}`);
}

main();
