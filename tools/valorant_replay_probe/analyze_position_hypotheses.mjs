#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const ASCENT_TRANSFORM = {
  xMultiplier: 0.00007,
  yMultiplier: -0.00007,
  xScalarToAdd: 0.813895,
  yScalarToAdd: 0.573242,
  minPercent: -0.08,
  maxPercent: 1.08,
};

const DEFAULT_EARLY_TO_MS = 5000;
const DEFAULT_PREFIX_BITS = 32;
const DEFAULT_MAX_SCAN_BITS = 512;
const DEFAULT_MIN_EARLY_MATCHES = 2;
const DEFAULT_SPAWN_TOLERANCE = 45;
const DEFAULT_TOP_LIMIT = 80;
const DEFAULT_MAX_AXIS_MATCHES_PER_SAMPLE = 16;
const DEFAULT_MAX_CANDIDATES_TO_EVALUATE = 12000;

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    out: null,
    earlyToMs: DEFAULT_EARLY_TO_MS,
    prefixBits: DEFAULT_PREFIX_BITS,
    maxScanBits: DEFAULT_MAX_SCAN_BITS,
    minEarlyMatches: DEFAULT_MIN_EARLY_MATCHES,
    spawnTolerance: DEFAULT_SPAWN_TOLERANCE,
    topLimit: DEFAULT_TOP_LIMIT,
    maxAxisMatchesPerSample: DEFAULT_MAX_AXIS_MATCHES_PER_SAMPLE,
    maxCandidatesToEvaluate: DEFAULT_MAX_CANDIDATES_TO_EVALUATE,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--early-to-ms') options.earlyToMs = Number(argv[++index]);
    else if (arg === '--prefix-bits') options.prefixBits = Number(argv[++index]);
    else if (arg === '--max-scan-bits') options.maxScanBits = Number(argv[++index]);
    else if (arg === '--min-early-matches') options.minEarlyMatches = Number(argv[++index]);
    else if (arg === '--spawn-tolerance') options.spawnTolerance = Number(argv[++index]);
    else if (arg === '--top-limit') options.topLimit = Number(argv[++index]);
    else if (arg === '--max-axis-matches-per-sample') {
      options.maxAxisMatchesPerSample = Number(argv[++index]);
    } else if (arg === '--max-candidates-to-evaluate') {
      options.maxCandidatesToEvaluate = Number(argv[++index]);
    }
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

function normalizeHexToFullBytes(hex) {
  if (typeof hex !== 'string') return '';
  return hex.length % 2 === 0 ? hex : `${hex}0`;
}

function readBit(buffer, bitOffset) {
  return (buffer[bitOffset >> 3] >> (bitOffset & 7)) & 1;
}

function readBitsUnsigned(buffer, bitOffset, bitCount) {
  let value = 0;
  let bitValue = 1;
  for (let bit = 0; bit < bitCount; bit += 1) {
    if (readBit(buffer, bitOffset + bit)) value += bitValue;
    bitValue *= 2;
  }
  return value;
}

function readBitsSigned(buffer, bitOffset, bitCount) {
  const value = readBitsUnsigned(buffer, bitOffset, bitCount);
  const signBit = 2 ** (bitCount - 1);
  return (value ^ signBit) - signBit;
}

function copyBits(buffer, sourceBitOffset, bitCount) {
  const result = Buffer.alloc(Math.ceil(bitCount / 8));
  for (let bit = 0; bit < bitCount; bit += 1) {
    if (readBit(buffer, sourceBitOffset + bit)) result[bit >> 3] |= 1 << (bit & 7);
  }
  return result;
}

function bitsToHex(buffer, bitOffset, bitCount) {
  if (bitCount <= 0) return '';
  return copyBits(buffer, bitOffset, bitCount).toString('hex');
}

function roundMetric(value, digits = 3) {
  if (!Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * fraction)));
  return sorted[index];
}

function distance2d(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function projectAscent(x, y) {
  return {
    u: y * ASCENT_TRANSFORM.xMultiplier + ASCENT_TRANSFORM.xScalarToAdd,
    v: x * ASCENT_TRANSFORM.yMultiplier + ASCENT_TRANSFORM.yScalarToAdd,
  };
}

function isPlausibleAscentXY(x, y) {
  const percent = projectAscent(x, y);
  return (
    percent.u >= ASCENT_TRANSFORM.minPercent &&
    percent.u <= ASCENT_TRANSFORM.maxPercent &&
    percent.v >= ASCENT_TRANSFORM.minPercent &&
    percent.v <= ASCENT_TRANSFORM.maxPercent
  );
}

function parseCandidateFieldSamples(diagnostics, options) {
  return (diagnostics.frameSummary?.replayControllerCandidateFieldSamples ?? [])
    .filter((sample) => sample.payloadHex != null && Number.isInteger(sample.numPayloadBits))
    .map((sample, sampleIndex) => {
      const bitCount = sample.numPayloadBits;
      const payloadHex = normalizeHexToFullBytes(sample.payloadHex);
      const buffer = Buffer.from(payloadHex, 'hex');
      return {
        ...sample,
        sampleIndex,
        bitCount,
        payloadHex,
        buffer,
        hasFullPayload: !sample.payloadHexTruncated && buffer.length * 8 >= bitCount,
        prefixHex: bitsToHex(buffer, 0, Math.min(options.prefixBits, bitCount)),
      };
    })
    .filter((sample) => sample.hasFullPayload && sample.bitCount > 0)
    .sort(
      (a, b) =>
        a.timeMs - b.timeMs ||
        a.sampleIndex - b.sampleIndex ||
        a.fieldHandle - b.fieldHandle,
    );
}

function knownPlayerOpenSamplesFromDiagnostics(diagnostics) {
  return (diagnostics.frameSummary?.channelOpenSamples ?? [])
    .filter((sample) => /Default__[^/]+_PC_C$/i.test(sample.archetypePath ?? ''))
    .filter((sample) => !/Ability|PostDeath/i.test(sample.archetypePath ?? ''))
    .map((sample) => ({
      timeMs: sample.timeMs,
      chIndex: sample.chIndex,
      netGuid: sample.actorNetGuid,
      archetypePath: sample.archetypePath ?? null,
      location: sample.location ?? null,
      yaw: sample.rotation?.yaw ?? null,
    }))
    .filter(
      (sample) =>
        Number.isInteger(sample.netGuid) &&
        Number.isFinite(sample.location?.x) &&
        Number.isFinite(sample.location?.y),
    )
    .sort((a, b) => a.netGuid - b.netGuid);
}

function familyKeyFor(sample) {
  return [sample.fieldHandle, sample.fieldName ?? '', sample.bitCount, sample.prefixHex].join('|');
}

function specKey(spec) {
  return `${spec.bitOffset}:${spec.bitCount}:${spec.divisor}`;
}

function dedupeAndLimitAxisMatches(matches, axis, limit) {
  const bySpec = new Map();
  for (const match of matches) {
    if (match.axis !== axis) continue;
    const key = specKey(match);
    const existing = bySpec.get(key);
    if (!existing || match.delta < existing.delta) bySpec.set(key, match);
  }
  return [...bySpec.values()]
    .sort(
      (a, b) =>
        a.delta - b.delta ||
        a.bitCount - b.bitCount ||
        a.bitOffset - b.bitOffset ||
        a.divisor - b.divisor,
    )
    .slice(0, limit);
}

function decodeSpec(sample, spec) {
  if (spec.bitOffset + spec.bitCount > sample.bitCount) return null;
  return readBitsSigned(sample.buffer, spec.bitOffset, spec.bitCount) / spec.divisor;
}

function findSpawnScalarMatches(sample, players, options) {
  const matchesByPlayer = new Map();
  const maxBitCount = Math.min(sample.bitCount, options.maxScanBits);
  const divisors = [1, 10, 100];

  for (let bitCount = 10; bitCount <= 24; bitCount += 1) {
    if (bitCount > maxBitCount) break;
    for (let bitOffset = 0; bitOffset + bitCount <= maxBitCount; bitOffset += 1) {
      const signed = readBitsSigned(sample.buffer, bitOffset, bitCount);
      for (const divisor of divisors) {
        const value = signed / divisor;
        for (const player of players) {
          const location = player.location;
          for (const axis of ['x', 'y']) {
            const delta = Math.abs(value - location[axis]);
            if (delta > options.spawnTolerance) continue;
            const key = player.netGuid;
            if (!matchesByPlayer.has(key)) matchesByPlayer.set(key, []);
            matchesByPlayer.get(key).push({
              axis,
              value,
              delta,
              bitOffset,
              bitCount,
              divisor,
            });
          }
        }
      }
    }
  }
  return matchesByPlayer;
}

function addCandidate(candidates, sample, player, xMatch, yMatch) {
  const familyKey = familyKeyFor(sample);
  const key = [
    familyKey,
    player.netGuid,
    specKey(xMatch),
    specKey(yMatch),
  ].join('|');
  let candidate = candidates.get(key);
  if (!candidate) {
    candidate = {
      key,
      familyKey,
      fieldHandle: sample.fieldHandle,
      fieldName: sample.fieldName ?? null,
      bitCount: sample.bitCount,
      prefixHex: sample.prefixHex,
      netGuid: player.netGuid,
      archetypePath: player.archetypePath,
      spawn: player.location,
      xSpec: {
        bitOffset: xMatch.bitOffset,
        bitCount: xMatch.bitCount,
        divisor: xMatch.divisor,
      },
      ySpec: {
        bitOffset: yMatch.bitOffset,
        bitCount: yMatch.bitCount,
        divisor: yMatch.divisor,
      },
      earlyMatchCount: 0,
      firstEarlyTimeMs: sample.timeMs,
      lastEarlyTimeMs: sample.timeMs,
      minSpawnDistance: Infinity,
      sampleMatches: [],
    };
    candidates.set(key, candidate);
  }
  const x = xMatch.value;
  const y = yMatch.value;
  const spawnDistance = distance2d({ x, y }, player.location);
  candidate.earlyMatchCount += 1;
  candidate.firstEarlyTimeMs = Math.min(candidate.firstEarlyTimeMs, sample.timeMs);
  candidate.lastEarlyTimeMs = Math.max(candidate.lastEarlyTimeMs, sample.timeMs);
  candidate.minSpawnDistance = Math.min(candidate.minSpawnDistance, spawnDistance);
  if (candidate.sampleMatches.length < 6) {
    candidate.sampleMatches.push({
      timeMs: sample.timeMs,
      x: roundMetric(x, 2),
      y: roundMetric(y, 2),
      spawnDistance: roundMetric(spawnDistance, 2),
      payloadHex: sample.payloadHex.slice(0, 160),
    });
  }
}

function collectSpawnMatchedCandidates(samples, players, options) {
  const candidates = new Map();
  const earlySamples = samples.filter(
    (sample) => sample.timeMs <= options.earlyToMs && sample.bitCount <= options.maxScanBits,
  );
  const playersByGuid = new Map(players.map((player) => [player.netGuid, player]));

  for (const sample of earlySamples) {
    const matchesByPlayer = findSpawnScalarMatches(sample, players, options);
    for (const [netGuid, matches] of matchesByPlayer.entries()) {
      const player = playersByGuid.get(netGuid);
      if (!player) continue;
      const xMatches = dedupeAndLimitAxisMatches(
        matches,
        'x',
        options.maxAxisMatchesPerSample,
      );
      const yMatches = dedupeAndLimitAxisMatches(
        matches,
        'y',
        options.maxAxisMatchesPerSample,
      );
      for (const xMatch of xMatches) {
        for (const yMatch of yMatches) {
          if (xMatch.bitOffset === yMatch.bitOffset && xMatch.bitCount === yMatch.bitCount) {
            continue;
          }
          addCandidate(candidates, sample, player, xMatch, yMatch);
        }
      }
    }
  }

  return [...candidates.values()]
    .filter((candidate) => candidate.earlyMatchCount >= options.minEarlyMatches)
    .sort(
      (a, b) =>
        b.earlyMatchCount - a.earlyMatchCount ||
        a.minSpawnDistance - b.minSpawnDistance ||
        a.fieldHandle - b.fieldHandle,
    )
    .slice(0, options.maxCandidatesToEvaluate);
}

function sampleStatsForCandidate(candidate, entries) {
  const decoded = [];
  const payloads = new Set();
  for (const sample of entries) {
    const x = decodeSpec(sample, candidate.xSpec);
    const y = decodeSpec(sample, candidate.ySpec);
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
    payloads.add(sample.payloadHex);
    decoded.push({
      timeMs: sample.timeMs,
      x,
      y,
      mapPlausible: isPlausibleAscentXY(x, y),
      payloadHex: sample.payloadHex,
    });
  }
  const mapPlausible = decoded.filter((sample) => sample.mapPlausible);
  const sorted = [...mapPlausible].sort((a, b) => a.timeMs - b.timeMs);
  const uniquePositions = new Set(
    sorted.map((sample) => `${sample.x.toFixed(1)},${sample.y.toFixed(1)}`),
  );
  const uniqueTimes = new Set(sorted.map((sample) => sample.timeMs));
  const speeds = [];
  const adjacentSteps = [];
  let maxStepDistance = 0;
  for (let index = 1; index < sorted.length; index += 1) {
    const previous = sorted[index - 1];
    const current = sorted[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0 || dtMs > 2000) continue;
    const stepDistance = distance2d(previous, current);
    maxStepDistance = Math.max(maxStepDistance, stepDistance);
    const speed = stepDistance / (dtMs / 1000);
    speeds.push(speed);
    adjacentSteps.push({ dtMs, stepDistance, speed });
  }
  const xs = sorted.map((sample) => sample.x);
  const ys = sorted.map((sample) => sample.y);
  const bounds =
    sorted.length > 0
      ? {
          minX: roundMetric(Math.min(...xs), 2),
          maxX: roundMetric(Math.max(...xs), 2),
          minY: roundMetric(Math.min(...ys), 2),
          maxY: roundMetric(Math.max(...ys), 2),
        }
      : null;
  const xySpan = bounds
    ? Math.hypot(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY)
    : 0;
  const xSpan = bounds ? bounds.maxX - bounds.minX : 0;
  const ySpan = bounds ? bounds.maxY - bounds.minY : 0;
  const first = sorted[0] ?? null;
  const firstSpawnDistance = first ? distance2d(first, candidate.spawn) : null;
  const p90Speed = percentile(speeds, 0.9);
  const p99Speed = percentile(speeds, 0.99);
  const medianSpeed = percentile(speeds, 0.5);
  const isKnownYawLane = candidate.fieldHandle === 122 && candidate.bitCount === 92;
  const passesMovementContinuity =
    !isKnownYawLane &&
    sorted.length >= 12 &&
    uniquePositions.size >= 8 &&
    uniqueTimes.size >= 8 &&
    xSpan >= 40 &&
    ySpan >= 40 &&
    xySpan >= 80 &&
    (p90Speed == null || p90Speed <= 2200) &&
    (p99Speed == null || p99Speed <= 6000) &&
    (firstSpawnDistance == null || firstSpawnDistance <= 250);
  const rejectionReasons = [];
  if (isKnownYawLane) rejectionReasons.push('known-handle122-yaw-lane');
  if (sorted.length < 12) rejectionReasons.push('too-few-map-plausible-samples');
  if (uniquePositions.size < 8) rejectionReasons.push('mostly-static-or-low-cardinality');
  if (uniqueTimes.size < 8) rejectionReasons.push('too-few-unique-times');
  if (xSpan < 40) rejectionReasons.push('x-span-too-small');
  if (ySpan < 40) rejectionReasons.push('y-span-too-small');
  if (xySpan < 80) rejectionReasons.push('xy-span-too-small');
  if (p90Speed != null && p90Speed > 2200) rejectionReasons.push('p90-speed-too-high');
  if (p99Speed != null && p99Speed > 6000) rejectionReasons.push('p99-speed-too-high');
  if (firstSpawnDistance != null && firstSpawnDistance > 250) {
    rejectionReasons.push('first-sample-not-near-spawn');
  }

  return {
    totalFamilySamples: entries.length,
    decodedSampleCount: decoded.length,
    mapPlausibleSampleCount: sorted.length,
    mapPlausibleRate: decoded.length ? roundMetric(sorted.length / decoded.length, 3) : null,
    uniquePayloadCount: payloads.size,
    uniquePositionCount: uniquePositions.size,
    uniqueTimeCount: uniqueTimes.size,
    firstTimeMs: sorted[0]?.timeMs ?? null,
    lastTimeMs: sorted.at(-1)?.timeMs ?? null,
    activeSpanMs: sorted.length ? sorted.at(-1).timeMs - sorted[0].timeMs : null,
    firstSpawnDistance: roundMetric(firstSpawnDistance, 2),
    bounds,
    xSpan: roundMetric(xSpan, 2),
    ySpan: roundMetric(ySpan, 2),
    xySpan: roundMetric(xySpan, 2),
    medianSpeed: roundMetric(medianSpeed, 2),
    p90Speed: roundMetric(p90Speed, 2),
    p99Speed: roundMetric(p99Speed, 2),
    maxStepDistance: roundMetric(maxStepDistance, 2),
    adjacentStepCount: adjacentSteps.length,
    passesMovementContinuity,
    rejectionReasons,
    firstSamples: sorted.slice(0, 8).map((sample) => ({
      timeMs: sample.timeMs,
      x: roundMetric(sample.x, 2),
      y: roundMetric(sample.y, 2),
    })),
    lastSamples: sorted.slice(-8).map((sample) => ({
      timeMs: sample.timeMs,
      x: roundMetric(sample.x, 2),
      y: roundMetric(sample.y, 2),
    })),
  };
}

function evaluateCandidates(candidates, samples) {
  const byFamily = new Map();
  for (const sample of samples) {
    const key = familyKeyFor(sample);
    if (!byFamily.has(key)) byFamily.set(key, []);
    byFamily.get(key).push(sample);
  }

  return candidates.map((candidate) => {
    const familySamples = byFamily.get(candidate.familyKey) ?? [];
    const stats = sampleStatsForCandidate(candidate, familySamples);
    const movementScore =
      (stats.passesMovementContinuity ? 1000 : 0) +
      Math.min(200, stats.uniquePositionCount * 4) +
      Math.min(200, stats.mapPlausibleSampleCount) +
      Math.min(100, stats.xySpan ?? 0) -
      Math.min(200, (stats.p90Speed ?? 0) / 20) -
      Math.min(200, (stats.p99Speed ?? 0) / 50);
    return {
      ...candidate,
      minSpawnDistance: roundMetric(candidate.minSpawnDistance, 2),
      movementScore: roundMetric(movementScore, 3),
      stats,
    };
  });
}

function summarizeStaticSpawnLeads(evaluated, limit) {
  return evaluated
    .filter((candidate) =>
      candidate.stats.rejectionReasons.includes('mostly-static-or-low-cardinality'),
    )
    .sort(
      (a, b) =>
        b.earlyMatchCount - a.earlyMatchCount ||
        b.stats.totalFamilySamples - a.stats.totalFamilySamples ||
        a.minSpawnDistance - b.minSpawnDistance,
    )
    .slice(0, limit);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_position_hypotheses.mjs --diagnostics replay.diagnostics.json --out position_hypotheses.report.json',
    );
    process.exit(1);
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics, options);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const spawnMatchedCandidates = collectSpawnMatchedCandidates(samples, players, options);
  const evaluated = evaluateCandidates(spawnMatchedCandidates, samples).sort(
    (a, b) =>
      b.movementScore - a.movementScore ||
      b.earlyMatchCount - a.earlyMatchCount ||
      b.stats.uniquePositionCount - a.stats.uniquePositionCount ||
      a.fieldHandle - b.fieldHandle,
  );
  const passing = evaluated.filter((candidate) => candidate.stats.passesMovementContinuity);

  const report = {
    generatedAt: new Date().toISOString(),
    input: { diagnostics: diagnosticsPath },
    options: {
      earlyToMs: options.earlyToMs,
      prefixBits: options.prefixBits,
      maxScanBits: options.maxScanBits,
      minEarlyMatches: options.minEarlyMatches,
      spawnTolerance: options.spawnTolerance,
      maxAxisMatchesPerSample: options.maxAxisMatchesPerSample,
      maxCandidatesToEvaluate: options.maxCandidatesToEvaluate,
    },
    source: {
      candidateFieldSampleCount: samples.length,
      knownPlayerOpenSampleCount: players.length,
      knownPlayerOpenSamples: players,
      spawnMatchedCandidateCount: spawnMatchedCandidates.length,
      passingCandidateCount: passing.length,
    },
    notes: [
      'This report scans fixed-width signed scalar pairs in ReplayController payload lanes.',
      'A candidate must match an actor-open spawn first, then keep producing distinct map-plausible positions with bounded adjacent speed.',
      'Passing candidates are still hypotheses until tied to the native ComponentDataStream record framing and view-yaw lane.',
    ],
    status:
      passing.length > 0
        ? 'fixed-width position hypotheses passed continuity checks; inspect before promoting to track output'
        : 'no fixed-width signed scalar position hypothesis passed spawn-plus-continuity checks',
    passingCandidates: passing.slice(0, options.topLimit),
    bestRejectedCandidates: evaluated.slice(0, options.topLimit),
    staticSpawnLeads: summarizeStaticSpawnLeads(evaluated, options.topLimit),
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else console.log(JSON.stringify(report, null, 2));
}

main();
