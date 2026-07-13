#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

function parseArgs(argv) {
  const options = {
    candidateTrack: null,
    henrikTrack: null,
    windowMs: 1500,
    out: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--window-ms') options.windowMs = Number(argv[++index]);
    else if (arg === '--out') options.out = argv[++index];
    else if (!options.candidateTrack) options.candidateTrack = arg;
    else if (!options.henrikTrack) options.henrikTrack = arg;
  }
  return options;
}

function resolveUserPath(value) {
  if (!value) return null;
  if (path.isAbsolute(value)) return value;
  return path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function flattenSamples(track) {
  return track.players
    .flatMap((player) =>
      player.samples.map((sample) => ({
        ...sample,
        playerId: player.id,
        displayName: player.displayName,
        agent: player.agent ?? null,
      })),
    )
    .sort((a, b) => a.timeMs - b.timeMs);
}

function nearestSample(sample, samples, windowMs) {
  let best = null;
  for (const candidate of samples) {
    const dt = candidate.timeMs - sample.timeMs;
    if (dt < -windowMs) continue;
    if (dt > windowMs && candidate.timeMs > sample.timeMs) break;
    const dist = Math.hypot(candidate.x - sample.x, candidate.y - sample.y);
    if (!best || dist < best.dist) best = { ...candidate, dt, dist };
  }
  return best;
}

function percentile(sortedValues, fraction) {
  if (!sortedValues.length) return null;
  const index = Math.min(
    sortedValues.length - 1,
    Math.max(0, Math.floor(sortedValues.length * fraction)),
  );
  return sortedValues[index];
}

function summarizeMatches(candidateTrack, henrikTrack, windowMs) {
  const henrikSamples = flattenSamples(henrikTrack);
  const tracks = [];

  for (const player of candidateTrack.players) {
    const matches = [];
    for (const sample of player.samples) {
      const match = nearestSample(sample, henrikSamples, windowMs);
      if (!match) continue;
      matches.push({ sample, match });
    }
    if (!matches.length) continue;
    const distances = matches.map((entry) => entry.match.dist).sort((a, b) => a - b);
    matches.sort((a, b) => a.match.dist - b.match.dist);
    tracks.push({
      id: player.id,
      displayName: player.displayName,
      kind: player.kind ?? null,
      confidence: player.confidence ?? null,
      sampleCount: player.samples.length,
      matchedSampleCount: matches.length,
      distance: {
        min: Number(distances[0].toFixed(2)),
        median: Number(percentile(distances, 0.5).toFixed(2)),
        p90: Number(percentile(distances, 0.9).toFixed(2)),
      },
      bestMatches: matches.slice(0, 5).map(({ sample, match }) => ({
        timeMs: sample.timeMs,
        x: sample.x,
        y: sample.y,
        nearestPlayer: match.displayName,
        nearestAgent: match.agent,
        nearestTimeMs: match.timeMs,
        dt: match.dt,
        nearestX: match.x,
        nearestY: match.y,
        distance: Number(match.dist.toFixed(2)),
      })),
    });
  }

  tracks.sort((a, b) => a.distance.min - b.distance.min || b.matchedSampleCount - a.matchedSampleCount);
  return tracks;
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const candidatePath = resolveUserPath(options.candidateTrack);
  const henrikPath = resolveUserPath(options.henrikTrack);
  if (!candidatePath || !henrikPath) {
    console.error(
      'usage: node compare_track_to_henrik.mjs candidate.track.json henrik.track.json --window-ms 1500 --out report.json',
    );
    process.exitCode = 1;
    return;
  }

  const candidateTrack = readJson(candidatePath);
  const henrikTrack = readJson(henrikPath);
  const tracks = summarizeMatches(candidateTrack, henrikTrack, options.windowMs);
  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      candidateTrack: candidatePath,
      henrikTrack: henrikPath,
      windowMs: options.windowMs,
    },
    notes:
      'Distances are raw game-coordinate distances from candidate .vrf-derived samples to nearest Henrik sparse player_locations within the time window.',
    comparedTrackCount: candidateTrack.players.length,
    matchedTrackCount: tracks.length,
    bestTracks: tracks.slice(0, 80),
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main();
