#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const TEAM_COLORS = {
  Blue: '#69F0AF',
  Red: '#FF5252',
};

function parseArgs(argv) {
  const options = {
    input: null,
    out: null,
    timeOffsetMs: 0,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--out') options.out = argv[++index];
    else if (arg === '--time-offset-ms') options.timeOffsetMs = Number(argv[++index] ?? 0);
    else options.input = arg;
  }
  return options;
}

function resolveUserPath(value) {
  if (!value) return null;
  if (path.isAbsolute(value)) return value;
  return path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

function playerName(player) {
  if (!player) return 'Unknown';
  const tag = player.tag ? `#${player.tag}` : '';
  return `${player.name ?? 'Unknown'}${tag}`;
}

function loadMatch(filePath) {
  const parsed = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  return parsed.data ?? parsed;
}

function buildPlayerIndex(match) {
  const players = new Map();
  for (const player of match.players ?? []) {
    players.set(player.puuid, {
      id: player.puuid,
      displayName: playerName(player),
      agent: player.agent?.name ?? player.character ?? 'Unknown',
      teamColor: TEAM_COLORS[player.team_id ?? player.team] ?? '#D1D5DB',
      samples: [],
    });
  }
  return players;
}

function emitTrack(match, timeOffsetMs) {
  const players = buildPlayerIndex(match);
  const seen = new Set();
  for (const kill of match.kills ?? []) {
    const timeMs = Math.max(0, Math.round((kill.time_in_match_in_ms ?? 0) + timeOffsetMs));
    for (const snapshot of kill.player_locations ?? []) {
      const puuid = snapshot.player?.puuid;
      if (!puuid || !snapshot.location || !players.has(puuid)) continue;
      const key = `${puuid}:${timeMs}`;
      if (seen.has(key)) continue;
      seen.add(key);
      players.get(puuid).samples.push({
        timeMs,
        x: snapshot.location.x,
        y: snapshot.location.y,
        yawDegrees: ((snapshot.view_radians ?? 0) * 180) / Math.PI,
      });
    }
  }

  return {
    sourceLabel: `Henrik match snapshots: ${match.metadata?.match_id ?? 'unknown match'}`,
    coordinateSpace: 'game',
    mapId: match.metadata?.map?.name ?? match.metadata?.map ?? 'Ascent',
    notes:
      'Sparse, player-labeled match API snapshots from kill events. These are not continuous replay tracks; they are useful ground truth for validating VRF NetGUID and ComponentDataStream decoding.',
    players: [...players.values()].filter((player) => player.samples.length > 0),
  };
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const inputPath = resolveUserPath(options.input);
  if (!inputPath) {
    console.error(
      'usage: node emit_henrik_match_track.mjs match.json --out out.track.json [--time-offset-ms -10016]',
    );
    process.exitCode = 1;
    return;
  }
  const outPath =
    resolveUserPath(options.out) ??
    path.resolve(process.env.INIT_CWD ?? process.cwd(), `${path.basename(inputPath, '.json')}.track.json`);
  const track = emitTrack(loadMatch(inputPath), Number.isFinite(options.timeOffsetMs) ? options.timeOffsetMs : 0);
  writeJson(outPath, track);
  const sampleCount = track.players.reduce((total, player) => total + player.samples.length, 0);
  console.log(`wrote ${outPath} (${track.players.length} players, ${sampleCount} samples)`);
}

main();
