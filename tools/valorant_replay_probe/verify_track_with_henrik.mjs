#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const HENRIK_MATCH_ENDPOINT = 'https://api.henrikdev.xyz/valorant/v2/match';
const UUID_PATTERN = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
const MOVEMENT_LIMITS = Object.freeze({
  nearestSampleWindowMs: 750,
  minimumComparisons: 20,
  maximumMedianPositionError: 250,
  maximumP90PositionError: 1000,
  maximumMedianYawErrorDegrees: 60,
});

const MAP_ALIASES = new Map([
  ['abyss', 'abyss'],
  ['ascent', 'ascent'],
  ['bind', 'bind'],
  ['bonsai', 'split'],
  ['breeze', 'breeze'],
  ['canyon', 'fracture'],
  ['corrode', 'corrode'],
  ['duality', 'bind'],
  ['foxtrot', 'breeze'],
  ['fracture', 'fracture'],
  ['haven', 'haven'],
  ['icebox', 'icebox'],
  ['infinity', 'abyss'],
  ['jam', 'lotus'],
  ['juliett', 'sunset'],
  ['lotus', 'lotus'],
  ['pearl', 'pearl'],
  ['pitt', 'pearl'],
  ['port', 'icebox'],
  ['rook', 'corrode'],
  ['split', 'split'],
  ['sunset', 'sunset'],
  ['triad', 'haven'],
]);

class CliError extends Error {}

function usage() {
  return [
    'usage: node verify_track_with_henrik.mjs <track.json> [options]',
    '',
    'options:',
    '  --match-id <uuid>       Override the match UUID derived from the track/source label.',
    '  --match-json <path|->   Read a saved Henrik response instead of calling the API.',
    '  --out <path>            Write the JSON report to this path.',
    '  --strict                Fail when a core check cannot be completed.',
    '  --help                  Show this help.',
    '',
    'Live requests read the API key only from HENRIK_API_KEY.',
  ].join('\n');
}

function parseArgs(argv) {
  const options = {
    track: null,
    matchId: null,
    matchJson: null,
    out: null,
    strict: false,
    help: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') options.help = true;
    else if (arg === '--strict') options.strict = true;
    else if (arg === '--match-id') options.matchId = requireArg(argv, ++index, arg);
    else if (arg === '--match-json') options.matchJson = requireArg(argv, ++index, arg);
    else if (arg === '--out') options.out = requireArg(argv, ++index, arg);
    else if (arg.startsWith('-')) throw new CliError(`Unknown option: ${arg}`);
    else if (!options.track) options.track = arg;
    else throw new CliError(`Unexpected positional argument: ${arg}`);
  }

  return options;
}

function requireArg(argv, index, option) {
  const value = argv[index];
  if (!value || value.startsWith('--')) throw new CliError(`${option} requires a value`);
  return value;
}

function resolveUserPath(value) {
  if (!value || value === '-') return value;
  if (path.isAbsolute(value)) return value;
  return path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new CliError(`Could not read JSON from ${filePath}: ${error.message}`);
  }
}

async function readJsonInput(value) {
  if (value !== '-') return readJson(resolveUserPath(value));
  let source = '';
  for await (const chunk of process.stdin) source += chunk;
  try {
    return JSON.parse(source);
  } catch (error) {
    throw new CliError(`Could not parse Henrik JSON from stdin: ${error.message}`);
  }
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function normalizeUuid(value) {
  if (typeof value !== 'string') return null;
  const match = value.match(UUID_PATTERN);
  return match ? match[0].toLowerCase() : null;
}

function deriveMatchId(track, trackPath, explicitMatchId) {
  if (explicitMatchId) {
    const normalized = normalizeUuid(explicitMatchId);
    if (!normalized || normalized.length !== explicitMatchId.trim().length) {
      throw new CliError(`--match-id must be a UUID, received: ${explicitMatchId}`);
    }
    return normalized;
  }

  const candidates = [
    track.matchId,
    track.matchID,
    track.replayId,
    track.sourceLabel,
    track.sourcePath,
    track.decoder?.matchId,
    track.decoder?.replayId,
    track.metadata?.matchId,
    track.metadata?.match_id,
    track.metadata?.replayId,
    path.basename(trackPath),
  ];
  for (const candidate of candidates) {
    const matchId = normalizeUuid(candidate);
    if (matchId) return matchId;
  }
  throw new CliError('Could not derive a match UUID from the track; pass --match-id <uuid>.');
}

async function fetchHenrikMatch(matchId, apiKey) {
  if (!apiKey) {
    throw new CliError(
      'HENRIK_API_KEY is not set. Set it for a live lookup or pass --match-json <path>.',
    );
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 20_000);
  try {
    const response = await fetch(`${HENRIK_MATCH_ENDPOINT}/${encodeURIComponent(matchId)}`, {
      headers: {
        Accept: 'application/json',
        Authorization: apiKey,
      },
      signal: controller.signal,
    });
    const body = await response.text();
    let parsed = null;
    try {
      parsed = body ? JSON.parse(body) : null;
    } catch {
      // The status and a bounded text fragment below are more useful than a JSON parse error.
    }
    if (!response.ok) {
      const apiMessage =
        parsed?.errors?.[0]?.message ??
        parsed?.error ??
        parsed?.message ??
        body.slice(0, 240) ??
        'unknown error';
      throw new CliError(`Henrik v2 match request failed (${response.status}): ${apiMessage}`);
    }
    if (!parsed) throw new CliError('Henrik v2 match request returned invalid JSON.');
    return parsed;
  } catch (error) {
    if (error?.name === 'AbortError') throw new CliError('Henrik v2 match request timed out.');
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

function firstFinite(...values) {
  for (const value of values) {
    if (value === null || value === undefined || value === '' || typeof value === 'boolean') continue;
    const number = Number(value);
    if (Number.isFinite(number)) return number;
  }
  return null;
}

function canonicalToken(value) {
  return typeof value === 'string' ? value.toLowerCase().replace(/[^a-z0-9]/g, '') : null;
}

function canonicalAgent(value) {
  return canonicalToken(value);
}

function canonicalMap(value) {
  if (value && typeof value === 'object') value = value.name ?? value.id;
  if (typeof value !== 'string') return null;
  const pieces = value.split(/[\\/]/).filter(Boolean);
  const last = canonicalToken(pieces.at(-1));
  if (!last) return null;
  return MAP_ALIASES.get(last) ?? last;
}

function canonicalSide(value) {
  const token = canonicalToken(value);
  if (token === 'attack' || token === 'attacker' || token === 'offense') return 'attacker';
  if (token === 'defense' || token === 'defender') return 'defender';
  return null;
}

function playerNetGuid(player) {
  const direct = firstFinite(player?.diagnostic?.netGuid, player?.netGuid, player?.actorNetGuid);
  if (direct !== null) return direct;
  const match = typeof player?.id === 'string' ? player.id.match(/^netguid-(\d+)$/i) : null;
  return match ? Number(match[1]) : null;
}

function normalizeApiAbilityCasts(raw) {
  if (!raw || typeof raw !== 'object') return { known: false, total: null, slots: {} };
  const slots = {
    grenade: firstFinite(raw.c_cast, raw.c_casts, raw.grenade),
    ability1: firstFinite(raw.q_cast, raw.q_casts, raw.ability_1),
    ability2: firstFinite(raw.e_cast, raw.e_casts, raw.ability_2),
    ultimate: firstFinite(raw.x_cast, raw.x_casts, raw.ultimate),
  };
  const values = Object.values(slots).filter(Number.isFinite);
  return {
    known: values.length > 0,
    total: values.length ? values.reduce((sum, value) => sum + value, 0) : null,
    slots,
  };
}

function normalizeApiPlayer(player) {
  return {
    puuid: normalizeUuid(player?.puuid ?? player?.id),
    name: [player?.name, player?.tag].filter(Boolean).join('#') || null,
    agent: player?.character ?? player?.agent?.name ?? player?.agent ?? null,
    team: player?.team ?? player?.team_id ?? player?.teamId ?? null,
    abilityCasts: normalizeApiAbilityCasts(player?.ability_casts ?? player?.abilityCasts),
    deaths: firstFinite(player?.stats?.deaths, player?.deaths),
  };
}

function normalizeSnapshot(snapshot) {
  const location = snapshot?.location ?? snapshot?.position;
  const x = firstFinite(location?.x, snapshot?.x);
  const y = firstFinite(location?.y, snapshot?.y);
  if (x === null || y === null) return null;
  const radians = firstFinite(snapshot?.view_radians, snapshot?.viewRadians);
  const degrees = firstFinite(snapshot?.yawDegrees, snapshot?.yaw_degrees);
  return {
    puuid: normalizeUuid(
      snapshot?.player_puuid ?? snapshot?.puuid ?? snapshot?.player?.puuid ?? snapshot?.player?.id,
    ),
    x,
    y,
    yawDegrees: degrees ?? (radians === null ? null : (radians * 180) / Math.PI),
  };
}

function normalizeKill(kill, index) {
  const snapshotsRaw =
    kill?.player_locations_on_kill ??
    kill?.player_locations ??
    kill?.playerLocations ??
    kill?.locations ??
    [];
  return {
    index,
    timeMs: firstFinite(
      kill?.kill_time_in_match,
      kill?.kill_time_in_match_in_ms,
      kill?.time_in_match_in_ms,
      kill?.timeInMatchMs,
    ),
    killerPuuid: normalizeUuid(
      kill?.killer_puuid ?? kill?.killer?.puuid ?? kill?.killer?.id ?? kill?.killerPuuid,
    ),
    victimPuuid: normalizeUuid(
      kill?.victim_puuid ?? kill?.victim?.puuid ?? kill?.victim?.id ?? kill?.victimPuuid,
    ),
    snapshots: Array.isArray(snapshotsRaw)
      ? snapshotsRaw.map(normalizeSnapshot).filter(Boolean)
      : [],
  };
}

function extractRoundKills(rounds) {
  const kills = [];
  for (const round of rounds) {
    const direct = round?.kills ?? round?.kill_events;
    if (Array.isArray(direct)) kills.push(...direct);
    for (const stats of round?.player_stats ?? round?.stats ?? []) {
      const nested = stats?.kill_events ?? stats?.kills;
      if (Array.isArray(nested)) kills.push(...nested);
    }
  }
  const seen = new Set();
  return kills.filter((kill) => {
    const key = [
      kill?.kill_time_in_match ?? kill?.time_in_match_in_ms ?? kill?.timeInMatchMs,
      kill?.killer_puuid ?? kill?.killer?.puuid,
      kill?.victim_puuid ?? kill?.victim?.puuid,
    ].join(':');
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

function normalizeHenrikResponse(response) {
  const match = response?.data ?? response;
  if (!match || typeof match !== 'object') throw new CliError('Henrik response has no match data.');
  const rawPlayers = Array.isArray(match.players)
    ? match.players
    : match.players?.all_players ?? match.all_players ?? [];
  const rounds = Array.isArray(match.rounds) ? match.rounds : [];
  const rawKills = Array.isArray(match.kills) ? match.kills : extractRoundKills(rounds);
  const players = rawPlayers.map(normalizeApiPlayer);
  const kills = rawKills.map(normalizeKill);
  const statsDeathCount = players
    .map((player) => player.deaths)
    .filter(Number.isFinite)
    .reduce((sum, value) => sum + value, 0);
  return {
    schema: Array.isArray(match.players) ? 'v4-compatible' : 'v2',
    matchId: normalizeUuid(match.metadata?.matchid ?? match.metadata?.match_id ?? match.match_id),
    map: match.metadata?.map?.name ?? match.metadata?.map ?? match.map?.name ?? match.map ?? null,
    roundsPlayed: firstFinite(match.metadata?.rounds_played, match.rounds_played) ?? rounds.length,
    players,
    rounds,
    kills,
    deathCount: kills.length || statsDeathCount,
    deathCountSource: kills.length ? 'kills' : statsDeathCount ? 'player-stats' : 'unavailable',
  };
}

function normalizeTrack(track) {
  const players = (Array.isArray(track.players) ? track.players : []).map((player) => ({
    raw: player,
    id: player.id ?? null,
    puuid: normalizeUuid(player.subject ?? player.puuid ?? player.playerSubject),
    agent: player.agent ?? player.character ?? null,
    initialSide: canonicalSide(player.initialSide ?? player.side),
    netGuid: playerNetGuid(player),
    samples: Array.isArray(player.samples) ? player.samples : [],
  }));
  const byNetGuid = new Map(
    players.filter((player) => player.netGuid !== null).map((player) => [player.netGuid, player]),
  );
  const deathEvents = (Array.isArray(track.deathEvents) ? track.deathEvents : []).map(
    (event, index) => ({
      index,
      timeMs: firstFinite(event?.timeMs, event?.endMs, event?.eventSeconds * 1000),
      killerPuuid:
        normalizeUuid(event?.killerSubject ?? event?.killerPuuid) ??
        byNetGuid.get(firstFinite(event?.killerNetGuid))?.puuid ??
        null,
      victimPuuid:
        normalizeUuid(event?.victimSubject ?? event?.victimPuuid) ??
        byNetGuid.get(firstFinite(event?.victimNetGuid))?.puuid ??
        null,
    }),
  );
  return {
    map: track.mapId ?? track.mapPath ?? track.map ?? null,
    players,
    byNetGuid,
    deathEvents,
    roundCount: Array.isArray(track.roundStartEvents)
      ? track.roundStartEvents.length
      : Array.isArray(track.rounds)
        ? track.rounds.length
        : null,
    abilityCasts: Array.isArray(track.abilityCasts) ? track.abilityCasts : [],
  };
}

function sortedObjectCount(values) {
  const counts = new Map();
  for (const value of values) {
    const key = canonicalToken(value) ?? '(unknown)';
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return Object.fromEntries([...counts.entries()].sort(([a], [b]) => a.localeCompare(b)));
}

function sameJsonValue(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function compareRoster(track, api, addFailure, addStrictFailure, addWarning) {
  const trackAgents = sortedObjectCount(track.players.map((player) => player.agent));
  const apiAgents = sortedObjectCount(api.players.map((player) => player.agent));
  const trackKnownAgents = track.players.filter((player) => canonicalAgent(player.agent)).length;
  const apiKnownAgents = api.players.filter((player) => canonicalAgent(player.agent)).length;
  const apiByPuuid = new Map(api.players.filter((player) => player.puuid).map((player) => [player.puuid, player]));
  const trackSubjects = track.players.filter((player) => player.puuid);
  const subjectMissingFromApi = trackSubjects
    .filter((player) => !apiByPuuid.has(player.puuid))
    .map((player) => player.puuid);
  const agentMismatches = trackSubjects
    .map((player) => {
      const apiPlayer = apiByPuuid.get(player.puuid);
      if (!apiPlayer || canonicalAgent(player.agent) === canonicalAgent(apiPlayer.agent)) return null;
      return {
        puuid: player.puuid,
        trackAgent: player.agent,
        apiAgent: apiPlayer.agent,
      };
    })
    .filter(Boolean);

  let status = 'pass';
  if (track.players.length !== api.players.length) {
    status = 'fail';
    addFailure(
      'roster.player-count',
      `Track has ${track.players.length} players; Henrik has ${api.players.length}.`,
    );
  }
  if (!sameJsonValue(trackAgents, apiAgents)) {
    status = 'fail';
    addFailure('roster.agents', 'Track and Henrik agent rosters do not match.');
  }
  if (trackKnownAgents !== track.players.length || apiKnownAgents !== api.players.length) {
    if (status === 'pass') status = 'partial';
    addWarning(
      'roster.agent-coverage',
      `Agent identity coverage is track ${trackKnownAgents}/${track.players.length}, ` +
        `Henrik ${apiKnownAgents}/${api.players.length}.`,
    );
    addStrictFailure('roster.agent-coverage', 'Strict validation requires every roster agent identity.');
  }
  if (trackSubjects.length === track.players.length && subjectMissingFromApi.length) {
    status = 'fail';
    addFailure('roster.subjects', 'One or more track player subjects are absent from Henrik.');
  } else if (trackSubjects.length !== track.players.length) {
    if (status === 'pass') status = 'partial';
    addWarning(
      'roster.subject-coverage',
      `Only ${trackSubjects.length}/${track.players.length} track players have a subject UUID.`,
    );
    addStrictFailure(
      'roster.subject-coverage',
      `Only ${trackSubjects.length}/${track.players.length} track players have a subject UUID.`,
    );
  }
  if (agentMismatches.length) {
    status = 'fail';
    addFailure('roster.subject-agent', 'Subject-matched players have different agents.');
  }

  return {
    status,
    trackPlayerCount: track.players.length,
    apiPlayerCount: api.players.length,
    trackAgents,
    apiAgents,
    agentCoverage: {
      track: `${trackKnownAgents}/${track.players.length}`,
      api: `${apiKnownAgents}/${api.players.length}`,
    },
    subjectCoverage: `${trackSubjects.length}/${track.players.length}`,
    matchedSubjects: trackSubjects.length - subjectMissingFromApi.length,
    subjectMissingFromApi: subjectMissingFromApi.slice(0, 20),
    agentMismatches: agentMismatches.slice(0, 20),
  };
}

function otherTeam(team, teams) {
  const token = canonicalToken(team);
  return teams.find((candidate) => canonicalToken(candidate) !== token) ?? null;
}

function inferInitialAttacker(rounds, apiPlayers) {
  const teams = [...new Set(apiPlayers.map((player) => player.team).filter(Boolean))];
  if (teams.length !== 2) return null;
  const teamByPuuid = new Map(
    apiPlayers
      .filter((player) => player.puuid && player.team)
      .map((player) => [player.puuid, player.team]),
  );
  const actorTeam = (actor) =>
    actor?.team ?? actor?.team_id ?? teamByPuuid.get(actor?.puuid ?? actor?.player_puuid) ?? null;
  const firstHalf = rounds.slice(0, Math.min(12, rounds.length));
  for (let index = 0; index < firstHalf.length; index += 1) {
    const round = firstHalf[index];
    const planter = round?.plant_events?.planted_by ?? round?.plant?.player;
    const planterTeam = actorTeam(planter);
    if (planterTeam) {
      return { team: planterTeam, roundIndex: index, evidence: 'first-half-plant' };
    }
    const defuser = round?.defuse_events?.defused_by ?? round?.defuse?.player;
    const defenderTeam = actorTeam(defuser);
    const attackerTeam = defenderTeam ? otherTeam(defenderTeam, teams) : null;
    if (attackerTeam) {
      return { team: attackerTeam, roundIndex: index, evidence: 'first-half-defuse' };
    }
  }
  return null;
}

function compareInitialSides(track, api, addFailure, addStrictFailure, addWarning) {
  const inference = inferInitialAttacker(api.rounds, api.players);
  const apiByPuuid = new Map(api.players.filter((player) => player.puuid).map((player) => [player.puuid, player]));
  if (!inference) {
    addWarning('sides.unavailable', 'Henrik rounds did not expose a first-half plant/defuse side clue.');
    addStrictFailure('sides.unavailable', 'Initial sides could not be inferred from Henrik rounds.');
    return { status: 'unavailable', inference: null, comparedPlayers: 0, mismatches: [] };
  }

  const comparisons = [];
  for (const player of track.players) {
    const apiPlayer = player.puuid ? apiByPuuid.get(player.puuid) : null;
    if (!apiPlayer || !player.initialSide) continue;
    const apiInitialSide =
      canonicalToken(apiPlayer.team) === canonicalToken(inference.team) ? 'attacker' : 'defender';
    comparisons.push({
      puuid: player.puuid,
      agent: player.agent,
      trackSide: player.initialSide,
      apiInitialSide,
      apiTeam: apiPlayer.team,
    });
  }
  const mismatches = comparisons.filter((entry) => entry.trackSide !== entry.apiInitialSide);
  if (mismatches.length) {
    addFailure('sides.initial', `${mismatches.length} player initial-side assignments disagree with Henrik.`);
  }
  if (comparisons.length !== track.players.length) {
    addWarning(
      'sides.coverage',
      `Initial sides could be compared for only ${comparisons.length}/${track.players.length} players.`,
    );
    addStrictFailure(
      'sides.coverage',
      `Initial sides could be compared for only ${comparisons.length}/${track.players.length} players.`,
    );
  }
  return {
    status: mismatches.length ? 'fail' : comparisons.length ? 'pass' : 'unavailable',
    inference,
    comparedPlayers: comparisons.length,
    mismatches: mismatches.slice(0, 20),
  };
}

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(fraction * sorted.length) - 1));
  return sorted[index];
}

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function rounded(value, digits = 2) {
  if (!Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function summarize(values, digits = 2) {
  if (!values.length) return { count: 0, median: null, p90: null, max: null };
  return {
    count: values.length,
    median: rounded(median(values), digits),
    p90: rounded(percentile(values, 0.9), digits),
    max: rounded(Math.max(...values), digits),
  };
}

function deathIdentityKey(event) {
  if (!event.victimPuuid) return null;
  return `${event.killerPuuid ?? '?'}>${event.victimPuuid}`;
}

function estimateTimeOffset(trackDeaths, apiKills) {
  const replay = trackDeaths.filter((event) => Number.isFinite(event.timeMs));
  const api = apiKills.filter((event) => Number.isFinite(event.timeMs));
  const pairs = new Map();
  const addPair = (trackEvent, apiEvent, mode) => {
    const key = `${trackEvent.index}:${apiEvent.index}`;
    if (!pairs.has(key)) pairs.set(key, { trackEvent, apiEvent, mode });
  };

  if (replay.length === api.length) {
    for (let index = 0; index < replay.length; index += 1) {
      const replayEvent = replay[index];
      const apiEvent = api[index];
      const victimsMatch =
        replayEvent.victimPuuid && replayEvent.victimPuuid === apiEvent.victimPuuid;
      const killersMatch =
        !replayEvent.killerPuuid ||
        !apiEvent.killerPuuid ||
        replayEvent.killerPuuid === apiEvent.killerPuuid;
      if (victimsMatch && killersMatch) addPair(replayEvent, apiEvent, 'identity-sequence');
    }
  }

  const replayGroups = new Map();
  const apiGroups = new Map();
  for (const event of replay) {
    const key = deathIdentityKey(event);
    if (!key) continue;
    if (!replayGroups.has(key)) replayGroups.set(key, []);
    replayGroups.get(key).push(event);
  }
  for (const event of api) {
    const key = deathIdentityKey(event);
    if (!key) continue;
    if (!apiGroups.has(key)) apiGroups.set(key, []);
    apiGroups.get(key).push(event);
  }
  for (const [key, replayGroup] of replayGroups) {
    const apiGroup = apiGroups.get(key);
    if (!apiGroup || replayGroup.length !== apiGroup.length) continue;
    replayGroup.sort((a, b) => a.timeMs - b.timeMs);
    apiGroup.sort((a, b) => a.timeMs - b.timeMs);
    for (let index = 0; index < replayGroup.length; index += 1) {
      addPair(replayGroup[index], apiGroup[index], 'identity-group');
    }
  }

  let mode = 'identity';
  if (!pairs.size && replay.length === api.length) {
    mode = 'sequence-only';
    for (let index = 0; index < replay.length; index += 1) {
      addPair(replay[index], api[index], mode);
    }
  }
  if (!pairs.size) {
    return {
      status: 'unavailable',
      mode: null,
      apiToReplayOffsetMs: null,
      candidatePairs: 0,
      inlierPairs: 0,
      residualMs: summarize([]),
    };
  }

  const pairValues = [...pairs.values()].map((pair) => ({
    ...pair,
    delta: pair.trackEvent.timeMs - pair.apiEvent.timeMs,
  }));
  const initialOffset = median(pairValues.map((pair) => pair.delta));
  const deviations = pairValues.map((pair) => Math.abs(pair.delta - initialOffset));
  const mad = median(deviations) ?? 0;
  const inlierWindow = Math.max(750, mad * 6);
  const inliers = pairValues.filter((pair) => Math.abs(pair.delta - initialOffset) <= inlierWindow);
  const offset = median(inliers.map((pair) => pair.delta));
  const residuals = inliers.map((pair) => Math.abs(pair.delta - offset));
  const minimumPairs = Math.min(10, Math.max(3, Math.floor(Math.min(replay.length, api.length) * 0.2)));
  const residualSummary = summarize(residuals, 1);
  const stable = inliers.length >= minimumPairs && residualSummary.p90 <= 1500;
  return {
    status: stable ? 'pass' : 'fail',
    mode,
    apiToReplayOffsetMs: rounded(offset, 1),
    candidatePairs: pairValues.length,
    inlierPairs: inliers.length,
    minimumPairs,
    inlierWindowMs: rounded(inlierWindow, 1),
    residualMs: residualSummary,
  };
}

function nearestTrackSample(samples, targetTimeMs, windowMs) {
  if (!samples.length) return null;
  let low = 0;
  let high = samples.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const time = firstFinite(samples[middle]?.timeMs) ?? Number.POSITIVE_INFINITY;
    if (time < targetTimeMs) low = middle + 1;
    else high = middle;
  }
  const candidates = [samples[low - 1], samples[low]].filter(Boolean);
  let best = null;
  for (const sample of candidates) {
    const timeMs = firstFinite(sample?.timeMs);
    if (timeMs === null) continue;
    const delta = timeMs - targetTimeMs;
    if (Math.abs(delta) > windowMs) continue;
    if (!best || Math.abs(delta) < Math.abs(best.deltaMs)) best = { sample, deltaMs: delta };
  }
  return best;
}

function circularDegreesDifference(a, b) {
  const difference = Math.abs((((a - b) % 360) + 540) % 360 - 180);
  return Number.isFinite(difference) ? difference : null;
}

function compareMovement(track, api, alignment, addFailure, addStrictFailure, addWarning) {
  if (!Number.isFinite(alignment.apiToReplayOffsetMs) || alignment.status !== 'pass') {
    addWarning('movement.no-time-alignment', 'Movement snapshots could not be aligned to replay time.');
    addStrictFailure('movement.no-time-alignment', 'Movement validation requires a stable death-event offset.');
    return {
      status: 'unavailable',
      limits: MOVEMENT_LIMITS,
      comparedSnapshots: 0,
      positionError: summarize([]),
      yawErrorDegrees: summarize([]),
      sampleTimeDeltaMs: summarize([]),
      perPlayer: [],
    };
  }

  const trackByPuuid = new Map(
    track.players.filter((player) => player.puuid).map((player) => [player.puuid, player]),
  );
  const comparisons = [];
  for (const kill of api.kills) {
    if (!Number.isFinite(kill.timeMs)) continue;
    const replayTimeMs = kill.timeMs + alignment.apiToReplayOffsetMs;
    for (const snapshot of kill.snapshots) {
      const player = snapshot.puuid ? trackByPuuid.get(snapshot.puuid) : null;
      if (!player) continue;
      const nearest = nearestTrackSample(
        player.samples,
        replayTimeMs,
        MOVEMENT_LIMITS.nearestSampleWindowMs,
      );
      if (!nearest) continue;
      const x = firstFinite(nearest.sample?.x);
      const y = firstFinite(nearest.sample?.y);
      if (x === null || y === null) continue;
      const trackYaw = firstFinite(nearest.sample?.yawDegrees, nearest.sample?.yaw);
      const yawError =
        trackYaw === null || snapshot.yawDegrees === null
          ? null
          : circularDegreesDifference(trackYaw, snapshot.yawDegrees);
      comparisons.push({
        puuid: snapshot.puuid,
        agent: player.agent,
        positionError: Math.hypot(x - snapshot.x, y - snapshot.y),
        yawError,
        sampleTimeDeltaMs: Math.abs(nearest.deltaMs),
      });
    }
  }

  const positions = comparisons.map((entry) => entry.positionError);
  const yaws = comparisons.map((entry) => entry.yawError).filter(Number.isFinite);
  const timeDeltas = comparisons.map((entry) => entry.sampleTimeDeltaMs);
  const positionSummary = summarize(positions);
  const yawSummary = summarize(yaws);
  let status = 'pass';
  if (comparisons.length < MOVEMENT_LIMITS.minimumComparisons) {
    status = 'partial';
    addWarning(
      'movement.low-coverage',
      `Only ${comparisons.length} Henrik kill snapshots matched a replay sample.`,
    );
    addStrictFailure(
      'movement.low-coverage',
      `Strict validation requires ${MOVEMENT_LIMITS.minimumComparisons} movement comparisons.`,
    );
  } else {
    if (
      positionSummary.median > MOVEMENT_LIMITS.maximumMedianPositionError ||
      positionSummary.p90 > MOVEMENT_LIMITS.maximumP90PositionError
    ) {
      status = 'fail';
      addFailure(
        'movement.position',
        `Movement position errors are too large (median ${positionSummary.median}, p90 ${positionSummary.p90}).`,
      );
    }
    if (
      yawSummary.count >= MOVEMENT_LIMITS.minimumComparisons &&
      yawSummary.median > MOVEMENT_LIMITS.maximumMedianYawErrorDegrees
    ) {
      status = 'fail';
      addFailure(
        'movement.yaw',
        `Movement yaw errors are too large (median ${yawSummary.median} degrees).`,
      );
    }
  }

  const grouped = new Map();
  for (const comparison of comparisons) {
    if (!grouped.has(comparison.puuid)) grouped.set(comparison.puuid, []);
    grouped.get(comparison.puuid).push(comparison);
  }
  const perPlayer = [...grouped.entries()]
    .map(([puuid, entries]) => ({
      puuid,
      agent: entries[0].agent,
      snapshots: entries.length,
      positionError: summarize(entries.map((entry) => entry.positionError)),
      yawErrorDegrees: summarize(entries.map((entry) => entry.yawError).filter(Number.isFinite)),
    }))
    .sort((a, b) => a.agent.localeCompare(b.agent));

  return {
    status,
    limits: MOVEMENT_LIMITS,
    apiSnapshotCount: api.kills.reduce((sum, kill) => sum + kill.snapshots.length, 0),
    comparedSnapshots: comparisons.length,
    comparedPlayers: perPlayer.length,
    positionError: positionSummary,
    yawErrorDegrees: yawSummary,
    sampleTimeDeltaMs: summarize(timeDeltas, 1),
    perPlayer,
  };
}

function canonicalAbilitySlot(value) {
  if (Number.isInteger(value) && value >= 0 && value <= 3) {
    return ['grenade', 'ability1', 'ability2', 'ultimate'][value];
  }
  const token = canonicalToken(typeof value === 'number' ? String(value) : value);
  if (token === 'grenade' || token === 'c' || token === '0') return 'grenade';
  if (token === 'ability1' || token === 'q' || token === '1') return 'ability1';
  if (token === 'ability2' || token === 'e' || token === '2') return 'ability2';
  if (token === 'ultimate' || token === 'x' || token === '3') return 'ultimate';
  return token ?? 'unknown';
}

function abilityTelemetry(track, api) {
  const trackCounts = new Map();
  const ensure = (puuid) => {
    if (!trackCounts.has(puuid)) {
      trackCounts.set(puuid, { total: 0, slots: { grenade: 0, ability1: 0, ability2: 0, ultimate: 0 } });
    }
    return trackCounts.get(puuid);
  };
  for (const cast of track.abilityCasts) {
    const puuid =
      normalizeUuid(cast?.playerSubject ?? cast?.subject ?? cast?.puuid) ??
      track.byNetGuid.get(firstFinite(cast?.playerNetGuid, cast?.netGuid))?.puuid ??
      null;
    if (!puuid) continue;
    const count = ensure(puuid);
    const slot = canonicalAbilitySlot(cast?.abilitySlot ?? cast?.slot ?? cast?.abilityIndex);
    count.total += 1;
    count.slots[slot] = (count.slots[slot] ?? 0) + 1;
  }

  const rows = [];
  let trackTotal = 0;
  let apiTotal = 0;
  let apiKnownPlayers = 0;
  for (const apiPlayer of api.players) {
    const parsed = apiPlayer.abilityCasts;
    const trackCount = apiPlayer.puuid ? trackCounts.get(apiPlayer.puuid) : null;
    trackTotal += trackCount?.total ?? 0;
    if (parsed.known) {
      apiKnownPlayers += 1;
      apiTotal += parsed.total;
    }
    rows.push({
      puuid: apiPlayer.puuid,
      agent: apiPlayer.agent,
      track: trackCount?.total ?? 0,
      api: parsed.total,
      coverageRatio:
        parsed.total && Number.isFinite(parsed.total)
          ? rounded((trackCount?.total ?? 0) / parsed.total, 3)
          : null,
      trackSlots: trackCount?.slots ?? null,
      apiSlots: parsed.known ? parsed.slots : null,
    });
  }
  const unmappedTrackCasts = track.abilityCasts.length - trackTotal;
  return {
    status: apiKnownPlayers ? 'telemetry' : 'unavailable',
    strict: false,
    note: 'Ability casts are coverage telemetry only and never affect the process exit code.',
    trackTotal: track.abilityCasts.length,
    trackMappedTotal: trackTotal,
    trackUnmappedTotal: unmappedTrackCasts,
    apiTotal: apiKnownPlayers ? apiTotal : null,
    apiKnownPlayers,
    coverageRatio: apiTotal ? rounded(trackTotal / apiTotal, 3) : null,
    players: rows,
  };
}

function compareCount(name, trackCount, apiCount, addFailure, addStrictFailure, addWarning) {
  if (!Number.isFinite(trackCount) || !Number.isFinite(apiCount)) {
    addWarning(`${name}.unavailable`, `${name} count is unavailable on one side.`);
    addStrictFailure(`${name}.unavailable`, `${name} count is unavailable on one side.`);
    return { status: 'unavailable', track: trackCount, api: apiCount, difference: null };
  }
  const difference = trackCount - apiCount;
  if (difference !== 0) {
    addFailure(`${name}.count`, `Track ${name} count ${trackCount} differs from Henrik ${apiCount}.`);
  }
  return { status: difference === 0 ? 'pass' : 'fail', track: trackCount, api: apiCount, difference };
}

function verify(trackRaw, apiRaw, context) {
  const track = normalizeTrack(trackRaw);
  const api = normalizeHenrikResponse(apiRaw);
  const failures = [];
  const warnings = [];
  const addFailure = (code, message) => failures.push({ code, message });
  const addWarning = (code, message) => {
    if (!warnings.some((entry) => entry.code === code)) warnings.push({ code, message });
  };
  const addStrictFailure = (code, message) => {
    if (context.strict) addFailure(code, message);
  };

  const trackMap = canonicalMap(track.map);
  const apiMap = canonicalMap(api.map);
  let mapStatus = 'unavailable';
  if (trackMap && apiMap) {
    mapStatus = trackMap === apiMap ? 'pass' : 'fail';
    if (mapStatus === 'fail') {
      addFailure('map.mismatch', `Track map ${track.map} does not match Henrik map ${api.map}.`);
    }
  } else {
    addWarning('map.unavailable', 'Map identity is unavailable on one side.');
    addStrictFailure('map.unavailable', 'Map identity is unavailable on one side.');
  }

  let matchIdStatus = 'unavailable';
  if (api.matchId) {
    matchIdStatus = api.matchId === context.matchId ? 'pass' : 'fail';
    if (matchIdStatus === 'fail') {
      addFailure(
        'match-id.mismatch',
        `Requested/derived match ${context.matchId} does not match Henrik ${api.matchId}.`,
      );
    }
  } else {
    addWarning('match-id.unavailable', 'Henrik metadata did not include a match UUID.');
    addStrictFailure('match-id.unavailable', 'Henrik metadata did not include a match UUID.');
  }

  const roster = compareRoster(track, api, addFailure, addStrictFailure, addWarning);
  const rounds = compareCount(
    'rounds',
    track.roundCount,
    api.roundsPlayed,
    addFailure,
    addStrictFailure,
    addWarning,
  );
  const deaths = compareCount(
    'deaths',
    track.deathEvents.length,
    api.deathCount,
    addFailure,
    addStrictFailure,
    addWarning,
  );
  deaths.apiSource = api.deathCountSource;
  const initialSides = compareInitialSides(
    track,
    api,
    addFailure,
    addStrictFailure,
    addWarning,
  );
  const alignment = estimateTimeOffset(track.deathEvents, api.kills);
  if (alignment.status === 'fail') {
    addFailure('time-alignment.unstable', 'Matched death events do not produce a stable time offset.');
  } else if (alignment.status === 'unavailable') {
    addWarning('time-alignment.unavailable', 'Death-event time alignment could not be estimated.');
    addStrictFailure('time-alignment.unavailable', 'Strict validation requires a death-event time offset.');
  }
  const movement = compareMovement(
    track,
    api,
    alignment,
    addFailure,
    addStrictFailure,
    addWarning,
  );
  const abilities = abilityTelemetry(track, api);

  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    input: {
      track: context.trackPath,
      matchId: context.matchId,
      matchSource: context.matchSource,
      henrikSchema: api.schema,
      strict: context.strict,
    },
    verdict: {
      status: failures.length ? 'fail' : warnings.length ? 'pass-with-warnings' : 'pass',
      hardFailureCount: failures.length,
      warningCount: warnings.length,
      hardFailures: failures,
      warnings,
    },
    checks: {
      matchId: {
        status: matchIdStatus,
        derivedOrRequested: context.matchId,
        api: api.matchId,
      },
      map: {
        status: mapStatus,
        track: track.map,
        api: api.map,
        canonicalTrack: trackMap,
        canonicalApi: apiMap,
      },
      roster,
      rounds,
      deaths,
      initialSides,
      timeAlignment: alignment,
      movement,
      abilityCasts: abilities,
    },
  };
}

function safeMessage(error, secret) {
  let message = error?.message ?? String(error);
  if (secret) message = message.split(secret).join('[redacted]');
  return message;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(`${usage()}\n`);
    return;
  }
  if (!options.track) throw new CliError(usage());

  const trackPath = resolveUserPath(options.track);
  const trackRaw = readJson(trackPath);
  const matchId = deriveMatchId(trackRaw, trackPath, options.matchId);
  const matchSource = options.matchJson ? `file:${resolveUserPath(options.matchJson)}` : 'henrik-v2-api';
  const apiKey = options.matchJson ? null : process.env.HENRIK_API_KEY?.trim();
  const apiRaw = options.matchJson
    ? await readJsonInput(options.matchJson)
    : await fetchHenrikMatch(matchId, apiKey);
  const report = verify(trackRaw, apiRaw, {
    trackPath,
    matchId,
    matchSource,
    strict: options.strict,
  });

  const outPath = resolveUserPath(options.out);
  if (outPath) {
    writeJson(outPath, report);
    process.stderr.write(
      `Henrik verification ${report.verdict.status}: ${outPath} ` +
        `(${report.verdict.hardFailureCount} hard failures, ${report.verdict.warningCount} warnings)\n`,
    );
  } else {
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  }
  if (report.verdict.hardFailureCount) process.exitCode = 1;
}

const apiKeyForRedaction = process.env.HENRIK_API_KEY;
main().catch((error) => {
  process.stderr.write(`verify_track_with_henrik: ${safeMessage(error, apiKeyForRedaction)}\n`);
  process.exitCode = 2;
});
