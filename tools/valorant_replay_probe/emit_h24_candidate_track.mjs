#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const TRACK_COLORS = [
  '#69F0AF',
  '#FF5252',
  '#7C3AED',
  '#F97316',
  '#38BDF8',
  '#F43F5E',
  '#A3E635',
  '#FACC15',
  '#C084FC',
  '#2DD4BF',
];

function parseArgs(argv) {
  const options = {
    report: null,
    out: null,
    mapId: '/Game/Maps/Ascent/Ascent',
    maxClusters: 8,
    minSamples: 2,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--out') options.out = argv[++index];
    else if (arg === '--map-id') options.mapId = argv[++index];
    else if (arg === '--max-clusters') options.maxClusters = Number(argv[++index]);
    else if (arg === '--min-samples') options.minSamples = Number(argv[++index]);
    else if (!options.report) options.report = arg;
  }
  return options;
}

function resolveUserPath(value) {
  if (!value) return null;
  if (path.isAbsolute(value)) return value;
  return path.resolve(process.env.INIT_CWD ?? process.cwd(), value);
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function rounded(value, digits = 2) {
  return Number(value.toFixed(digits));
}

function addYawFromNeighboringSamples(samples) {
  samples.sort(
    (a, b) =>
      a.timeMs - b.timeMs ||
      a.x - b.x ||
      a.y - b.y ||
      (a.z ?? 0) - (b.z ?? 0),
  );
  for (let index = 0; index < samples.length; index += 1) {
    const previous = samples[index - 1];
    const next = samples[index + 1];
    const reference = next ?? previous;
    if (!reference) {
      samples[index].yawDegrees = 0;
      continue;
    }
    const dx = reference.x - samples[index].x;
    const dy = reference.y - samples[index].y;
    samples[index].yawDegrees =
      dx === 0 && dy === 0 ? 0 : rounded((Math.atan2(dy, dx) * 180) / Math.PI);
  }
}

function sampleTrackKey(sample) {
  const source = sample.source ?? {};
  return [
    sample.netGuid,
    source.clusterRank ?? 'rank',
    source.guidOffset ?? 'go',
    source.vectorOffset ?? 'vo',
    source.relativeOffset ?? 'rel',
  ].join('|');
}

function buildTrack(report, options) {
  const rows =
    report.h24SubrecordNeighborhoods?.candidateMovementLikeSamples?.filter(
      (sample) => (sample.source?.clusterRank ?? Infinity) < options.maxClusters,
    ) ?? [];
  const grouped = new Map();

  for (const row of rows) {
    if (!row.position || !Number.isFinite(row.position.x) || !Number.isFinite(row.position.y)) {
      continue;
    }
    const key = sampleTrackKey(row);
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(row);
  }

  const players = [...grouped.entries()]
    .map(([key, groupRows], index) => {
      const first = groupRows[0];
      const source = first.source ?? {};
      const anchorIdentityConfidence = source.anchorIdentityConfidence ?? 'unknown-anchor-confidence';
      const samples = groupRows.map((row) => ({
        timeMs: row.timeMs,
        x: rounded(row.position.x),
        y: rounded(row.position.y),
        z: row.position.z == null ? null : rounded(row.position.z),
      }));
      addYawFromNeighboringSamples(samples);
      return {
        id: `h24-${key.replaceAll('|', '-')}`,
        displayName: `h24 g${first.netGuid} r${source.clusterRank} v${source.vectorOffset}`,
        agent: `NetGUID ${first.netGuid}`,
        teamColor: TRACK_COLORS[index % TRACK_COLORS.length],
        kind: 'candidate-h24-guid-adjacent-vector',
        sourceTag: `h24 rank ${source.clusterRank}, guid@${source.guidOffset}, vector@${source.vectorOffset}, anchor=${anchorIdentityConfidence}`,
        confidence: first.confidence ?? 'candidate-h24-guid-adjacent-vector',
        anchorIdentityConfidence,
        notes:
          `Diagnostic h24 ReplayController candidate. Anchor identity confidence: ${anchorIdentityConfidence}. GUID-adjacent vector only; not confirmed world-space player movement.`,
        samples,
      };
    })
    .filter((player) => player.samples.length >= options.minSamples)
    .sort((a, b) => b.samples.length - a.samples.length || a.id.localeCompare(b.id));

  return {
    sourceLabel: 'VRF h24 ReplayController candidates',
    coordinateSpace: 'game',
    mapId: options.mapId,
    notes:
      'Generated from analyze_replay_controller_streams h24 candidateMovementLikeSamples. These are diagnostic GUID-adjacent vectors, not confirmed continuous player tracks.',
    sourceReport: report.input?.diagnostics ?? null,
    players,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const reportPath = resolveUserPath(options.report);
  if (!reportPath) {
    console.error(
      'usage: node emit_h24_candidate_track.mjs replay_controller_streams.report.json --out h24_candidates.track.json [--max-clusters 8] [--min-samples 2]',
    );
    process.exitCode = 1;
    return;
  }
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  const track = buildTrack(report, options);
  const outPath =
    resolveUserPath(options.out) ??
    path.resolve(process.env.INIT_CWD ?? process.cwd(), `${path.basename(reportPath, '.json')}.h24.track.json`);
  writeJson(outPath, track);
  const sampleCount = track.players.reduce((sum, player) => sum + player.samples.length, 0);
  console.log(`wrote ${outPath} (${track.players.length} tracks, ${sampleCount} samples)`);
}

main();
