#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const YAW_FIELD_HANDLE = 122;
const YAW_PAYLOAD_BITS = 92;
const YAW_BIT_OFFSET = 50;
const YAW_BIT_COUNT = 18;

const ASCENT_TRANSFORM = {
  xMultiplier: 0.00007,
  yMultiplier: -0.00007,
  xScalarToAdd: 0.813895,
  yScalarToAdd: 0.573242,
  minPercent: -0.08,
  maxPercent: 1.08,
};

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    out: null,
    maxYawDeltaMs: 16,
    minGroupSamples: 40,
    minPartitionSamples: 20,
    maxGroups: 300,
    maxPairSpecsPerPartition: 2500,
    maxCandidates: 60,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--max-yaw-delta-ms') options.maxYawDeltaMs = Number(argv[++index]);
    else if (arg === '--min-group-samples') options.minGroupSamples = Number(argv[++index]);
    else if (arg === '--min-partition-samples') {
      options.minPartitionSamples = Number(argv[++index]);
    } else if (arg === '--max-groups') options.maxGroups = Number(argv[++index]);
    else if (arg === '--max-pair-specs-per-partition') {
      options.maxPairSpecsPerPartition = Number(argv[++index]);
    } else if (arg === '--max-candidates') options.maxCandidates = Number(argv[++index]);
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

function round(value, digits = 3) {
  if (value == null || !Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * fraction)))];
}

function increment(map, key, amount = 1) {
  map.set(key, (map.get(key) ?? 0) + amount);
}

function topCounts(valuesOrMap, limit = 12) {
  const map = valuesOrMap instanceof Map ? valuesOrMap : new Map();
  if (!(valuesOrMap instanceof Map)) {
    for (const value of valuesOrMap) increment(map, value);
  }
  return [...map.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || String(a.key).localeCompare(String(b.key)))
    .slice(0, limit);
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

function stableRanges(flags) {
  const ranges = [];
  let start = null;
  for (let bit = 0; bit <= flags.length; bit += 1) {
    if (bit < flags.length && flags[bit]) {
      if (start == null) start = bit;
    } else if (start != null) {
      ranges.push({ start, end: bit - 1, length: bit - start });
      start = null;
    }
  }
  return ranges;
}

function normalizeDegrees360(value) {
  const normalized = value % 360;
  return normalized < 0 ? normalized + 360 : normalized;
}

function circularDegreesDelta(a, b) {
  const delta = Math.abs(normalizeDegrees360(a) - normalizeDegrees360(b)) % 360;
  return delta > 180 ? 360 - delta : delta;
}

function transformYaw(rawYawDegrees, transform) {
  if (transform === 'as-read') return rawYawDegrees;
  if (transform === 'negated') return -rawYawDegrees;
  if (transform === 'plus-90') return rawYawDegrees + 90;
  if (transform === 'minus-90') return rawYawDegrees - 90;
  if (transform === 'plus-180') return rawYawDegrees + 180;
  throw new Error(`unknown yaw transform: ${transform}`);
}

function parseCandidateFieldSamples(diagnostics) {
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
      };
    })
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
      yaw: sample.rotation?.yaw ?? null,
    }))
    .filter((sample) => Number.isInteger(sample.netGuid) && Number.isFinite(sample.yaw))
    .sort((a, b) => a.netGuid - b.netGuid);
}

function firstYawDegrees(sample) {
  const signedValue = readBitsSigned(sample.buffer, YAW_BIT_OFFSET, YAW_BIT_COUNT);
  return (signedValue * 360) / 2 ** YAW_BIT_COUNT;
}

function openYawMappingForLane(prefixHex, entries, playerOpenSamples) {
  const first = entries[0];
  if (!first || !playerOpenSamples.length) return null;
  const rawYaw = firstYawDegrees(first);
  const transforms = ['as-read', 'negated', 'plus-90', 'minus-90', 'plus-180'];
  const matches = transforms
    .map((transform) => {
      const transformedYaw = normalizeDegrees360(transformYaw(rawYaw, transform));
      const bestPlayer = playerOpenSamples
        .map((player) => ({
          netGuid: player.netGuid,
          chIndex: player.chIndex,
          archetypePath: player.archetypePath,
          openYaw: round(player.yaw, 3),
          deltaDegrees: round(circularDegreesDelta(transformedYaw, player.yaw), 3),
        }))
        .sort((a, b) => a.deltaDegrees - b.deltaDegrees || a.netGuid - b.netGuid)[0];
      return {
        transform,
        transformedYaw: round(transformedYaw, 3),
        bestPlayer,
      };
    })
    .sort((a, b) => a.bestPlayer.deltaDegrees - b.bestPlayer.deltaDegrees);
  return {
    prefixHex,
    firstTimeMs: first.timeMs,
    rawYawDegrees: round(rawYaw, 3),
    bestTransform: matches[0],
    transformMatches: matches.slice(0, 5),
  };
}

function buildYawLanes(samples, playerOpenSamples, minSamples) {
  const laneMap = new Map();
  for (const sample of samples) {
    if (
      sample.fieldHandle !== YAW_FIELD_HANDLE ||
      sample.bitCount !== YAW_PAYLOAD_BITS ||
      !sample.hasFullPayload
    ) {
      continue;
    }
    const prefixHex = bitsToHex(sample.buffer, 0, 32);
    if (!laneMap.has(prefixHex)) laneMap.set(prefixHex, []);
    const dedupeKey = `${sample.timeMs}:${sample.payloadHex}`;
    const entries = laneMap.get(prefixHex);
    if (!entries.some((entry) => entry.dedupeKey === dedupeKey)) {
      entries.push({ ...sample, dedupeKey, prefixHex });
    }
  }

  const lanes = [...laneMap.entries()]
    .map(([prefixHex, entries]) => {
      entries.sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
      return {
        prefixHex,
        entries,
        times: entries.map((entry) => entry.timeMs).sort((a, b) => a - b),
        count: entries.length,
        firstTimeMs: entries[0]?.timeMs ?? null,
        lastTimeMs: entries.at(-1)?.timeMs ?? null,
        openYawMapping: openYawMappingForLane(prefixHex, entries, playerOpenSamples),
      };
    })
    .filter((lane) => lane.count >= minSamples)
    .sort((a, b) => b.count - a.count || a.prefixHex.localeCompare(b.prefixHex));
  return lanes;
}

function nearestDelta(sortedTimes, value) {
  let low = 0;
  let high = sortedTimes.length;
  while (low < high) {
    const mid = (low + high) >> 1;
    if (sortedTimes[mid] < value) low = mid + 1;
    else high = mid;
  }
  let best = Infinity;
  if (low < sortedTimes.length) best = Math.min(best, Math.abs(sortedTimes[low] - value));
  if (low > 0) best = Math.min(best, Math.abs(sortedTimes[low - 1] - value));
  return best === Infinity ? null : best;
}

function matchingYawLanes(sample, yawLanes, maxDeltaMs) {
  const matches = [];
  for (const lane of yawLanes) {
    const deltaMs = nearestDelta(lane.times, sample.timeMs);
    if (deltaMs != null && deltaMs <= maxDeltaMs) matches.push({ lane, deltaMs });
  }
  matches.sort((a, b) => a.deltaMs - b.deltaMs || b.lane.count - a.lane.count);
  return matches;
}

function groupCandidateSamples(samples, options) {
  const groups = new Map();
  for (const sample of samples) {
    if (
      !sample.hasFullPayload ||
      sample.fieldHandle === YAW_FIELD_HANDLE ||
      sample.fieldHandle === 3 ||
      sample.bitCount < 24 ||
      sample.bitCount > 512
    ) {
      continue;
    }
    const prefixHex = bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount));
    const key = [sample.fieldHandle, sample.fieldName ?? '', sample.bitCount, prefixHex].join('|');
    if (!groups.has(key)) {
      groups.set(key, {
        key,
        fieldHandle: sample.fieldHandle,
        fieldName: sample.fieldName ?? null,
        bitCount: sample.bitCount,
        prefixHex,
        samples: [],
      });
    }
    groups.get(key).samples.push(sample);
  }

  return [...groups.values()]
    .filter((group) => group.samples.length >= options.minGroupSamples)
    .map((group) => {
      const uniquePayloads = new Set(group.samples.map((sample) => sample.payloadHex));
      group.samples.sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
      group.uniquePayloadCount = uniquePayloads.size;
      group.uniquePayloadRate = uniquePayloads.size / group.samples.length;
      group.firstTimeMs = group.samples[0]?.timeMs ?? null;
      group.lastTimeMs = group.samples.at(-1)?.timeMs ?? null;
      return group;
    })
    .sort(
      (a, b) =>
        b.samples.length - a.samples.length ||
        b.uniquePayloadRate - a.uniquePayloadRate ||
        a.fieldHandle - b.fieldHandle,
    );
}

function summarizeCooccurrence(groups, yawLanes, options) {
  return groups
    .map((group) => {
      const laneCounts = new Map();
      const deltaBuckets = { within8: 0, within16: 0, within33: 0 };
      for (const sample of group.samples) {
        const matches33 = matchingYawLanes(sample, yawLanes, 33);
        if (!matches33.length) continue;
        deltaBuckets.within33 += 1;
        if (matches33[0].deltaMs <= 16) deltaBuckets.within16 += 1;
        if (matches33[0].deltaMs <= 8) deltaBuckets.within8 += 1;
        for (const match of matches33) increment(laneCounts, match.lane.prefixHex);
      }
      return {
        fieldHandle: group.fieldHandle,
        fieldName: group.fieldName,
        bitCount: group.bitCount,
        prefixHex: group.prefixHex,
        count: group.samples.length,
        uniquePayloadRate: round(group.uniquePayloadRate),
        firstTimeMs: group.firstTimeMs,
        lastTimeMs: group.lastTimeMs,
        yawOverlap: {
          within8: deltaBuckets.within8,
          within16: deltaBuckets.within16,
          within33: deltaBuckets.within33,
          within8Rate: round(deltaBuckets.within8 / group.samples.length),
          within16Rate: round(deltaBuckets.within16 / group.samples.length),
          within33Rate: round(deltaBuckets.within33 / group.samples.length),
          topYawPrefixes: topCounts(laneCounts, 10),
        },
      };
    })
    .filter((summary) => summary.yawOverlap.within33 > 0)
    .sort(
      (a, b) =>
        b.yawOverlap.within16 - a.yawOverlap.within16 ||
        b.count - a.count ||
        a.fieldHandle - b.fieldHandle,
    )
    .slice(0, options.maxGroups);
}

function variableRangesForRows(rows, bitCount) {
  const oneCounts = Array.from({ length: bitCount }, () => 0);
  for (const row of rows) {
    for (let bit = 0; bit < bitCount; bit += 1) {
      if (readBit(row.buffer, bit)) oneCounts[bit] += 1;
    }
  }
  const stableBits = oneCounts.map((count) => count === 0 || count === rows.length);
  return stableRanges(stableBits.map((stable) => !stable));
}

function scalarSpecsFromRanges(ranges, bitCount) {
  const specs = new Map();
  const widths = [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 20];
  for (const range of ranges) {
    if (range.length < 6 || range.length > 24) continue;
    for (const width of [...new Set([range.length, ...widths])]) {
      if (width < 6 || width > 24) continue;
      for (let start = range.start - 2; start <= range.start + 2; start += 1) {
        if (start < 0 || start + width > bitCount) continue;
        specs.set(`${start}:${width}`, { start, bitCount: width });
      }
    }
  }
  return [...specs.values()].sort((a, b) => a.start - b.start || a.bitCount - b.bitCount);
}

function pairSpecsFromScalarSpecs(scalarSpecs, maxPairs) {
  const pairs = [];
  for (const xSpec of scalarSpecs) {
    for (const ySpec of scalarSpecs) {
      if (xSpec.start === ySpec.start && xSpec.bitCount === ySpec.bitCount) continue;
      pairs.push({ xSpec, ySpec });
      if (pairs.length >= maxPairs) return pairs;
    }
  }
  return pairs;
}

function isPlausibleAscentXY(x, y) {
  const u = y * ASCENT_TRANSFORM.xMultiplier + ASCENT_TRANSFORM.xScalarToAdd;
  const v = x * ASCENT_TRANSFORM.yMultiplier + ASCENT_TRANSFORM.yScalarToAdd;
  return (
    u >= ASCENT_TRANSFORM.minPercent &&
    u <= ASCENT_TRANSFORM.maxPercent &&
    v >= ASCENT_TRANSFORM.minPercent &&
    v <= ASCENT_TRANSFORM.maxPercent
  );
}

function summarizePositionRows(rows) {
  const ordered = [...rows].sort((a, b) => a.timeMs - b.timeMs || a.x - b.x || a.y - b.y);
  const uniquePositions = new Set();
  const positionsByTime = new Map();
  let inBoundsCount = 0;
  let realMagnitudeCount = 0;
  let minX = Infinity;
  let maxX = -Infinity;
  let minY = Infinity;
  let maxY = -Infinity;
  for (const row of ordered) {
    const positionKey = `${Math.round(row.x)}:${Math.round(row.y)}`;
    uniquePositions.add(positionKey);
    if (!positionsByTime.has(row.timeMs)) positionsByTime.set(row.timeMs, new Set());
    positionsByTime.get(row.timeMs).add(positionKey);
    if (isPlausibleAscentXY(row.x, row.y)) inBoundsCount += 1;
    if (Math.max(Math.abs(row.x), Math.abs(row.y)) >= 500) realMagnitudeCount += 1;
    minX = Math.min(minX, row.x);
    maxX = Math.max(maxX, row.x);
    minY = Math.min(minY, row.y);
    maxY = Math.max(maxY, row.y);
  }

  const adjacentSpeeds = [];
  const adjacentSteps = [];
  const dts = [];
  let largeAdjacentJumpCount = 0;
  let longGapCount = 0;
  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs > 1000) longGapCount += 1;
    const distance = Math.hypot(current.x - previous.x, current.y - previous.y);
    if (dtMs <= 250) {
      const speed = distance / (dtMs / 1000);
      adjacentSteps.push(distance);
      adjacentSpeeds.push(speed);
      if (distance > 900 || speed > 12_000) largeAdjacentJumpCount += 1;
    }
  }

  const xSpan = ordered.length ? maxX - minX : 0;
  const ySpan = ordered.length ? maxY - minY : 0;
  return {
    count: ordered.length,
    firstTimeMs: ordered[0]?.timeMs ?? null,
    lastTimeMs: ordered.at(-1)?.timeMs ?? null,
    activeSpanMs: ordered.length > 1 ? ordered.at(-1).timeMs - ordered[0].timeMs : 0,
    uniqueTimeCount: positionsByTime.size,
    uniquePositionCount: uniquePositions.size,
    sameTimeConflictCount: [...positionsByTime.values()].filter((set) => set.size > 1).length,
    inAscentBoundsRate: ordered.length ? round(inBoundsCount / ordered.length) : 0,
    realMagnitudeRate: ordered.length ? round(realMagnitudeCount / ordered.length) : 0,
    bounds: ordered.length
      ? {
          minX: round(minX, 1),
          maxX: round(maxX, 1),
          minY: round(minY, 1),
          maxY: round(maxY, 1),
        }
      : null,
    xSpan: round(xSpan, 1),
    ySpan: round(ySpan, 1),
    xySpan: round(Math.hypot(xSpan, ySpan), 1),
    staticAxisCount: [xSpan, ySpan].filter((span) => span < 50).length,
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    longGapCount,
    adjacentStepCount: adjacentSpeeds.length,
    p90AdjacentSpeed: round(percentile(adjacentSpeeds, 0.9), 1),
    maxAdjacentSpeed: round(adjacentSpeeds.length ? Math.max(...adjacentSpeeds) : null, 1),
    p90AdjacentStepDistance: round(percentile(adjacentSteps, 0.9), 1),
    largeAdjacentJumpCount,
    samples: ordered.slice(0, 8).map((row) => ({
      timeMs: row.timeMs,
      x: round(row.x, 1),
      y: round(row.y, 1),
      inAscentBounds: isPlausibleAscentXY(row.x, row.y),
      payloadHex: row.payloadHex.slice(0, 96),
    })),
  };
}

function strictRejectionReasons(candidate) {
  const summary = candidate.summary;
  const reasons = [];
  if (summary.count < 20) reasons.push('too-few-samples');
  if (summary.uniqueTimeCount < 20) reasons.push('too-few-unique-times');
  if (summary.uniquePositionCount < 10) reasons.push('too-few-unique-positions');
  if (summary.sameTimeConflictCount > 0) reasons.push('same-time-position-conflicts');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-bounds');
  if (summary.realMagnitudeRate < 0.5) reasons.push('mostly-small-values');
  if (summary.xySpan < 300) reasons.push('low-xy-span');
  if (summary.staticAxisCount > 0) reasons.push('static-axis');
  if (summary.adjacentStepCount < Math.min(8, summary.count - 2)) {
    reasons.push('too-few-adjacent-steps');
  }
  if (summary.p90AdjacentSpeed == null || summary.p90AdjacentSpeed > 3000) {
    reasons.push('high-or-missing-p90-adjacent-speed');
  }
  if (summary.maxAdjacentSpeed == null || summary.maxAdjacentSpeed > 10_000) {
    reasons.push('high-or-missing-max-adjacent-speed');
  }
  if (summary.largeAdjacentJumpCount > 0) reasons.push('large-adjacent-jumps');
  return reasons;
}

function candidateScore(candidate) {
  const summary = candidate.summary;
  const p90 = summary.p90AdjacentSpeed ?? 30_000;
  return (
    summary.count * 10 +
    summary.uniquePositionCount * 30 +
    summary.inAscentBoundsRate * 500 +
    summary.realMagnitudeRate * 300 +
    Math.min(summary.xySpan, 3000) * 0.4 +
    Math.min(summary.adjacentStepCount, 30) * 20 -
    Math.min(p90, 30_000) * 0.08 -
    summary.largeAdjacentJumpCount * 500 -
    summary.staticAxisCount * 500
  );
}

function evaluatePair(rows, pair, scale, context) {
  const decoded = rows.map((row) => ({
    timeMs: row.timeMs,
    x: readBitsSigned(row.buffer, pair.xSpec.start, pair.xSpec.bitCount) / scale,
    y: readBitsSigned(row.buffer, pair.ySpec.start, pair.ySpec.bitCount) / scale,
    payloadHex: row.payloadHex,
  }));
  const candidate = {
    ...context,
    layout: {
      xStart: pair.xSpec.start,
      xBits: pair.xSpec.bitCount,
      yStart: pair.ySpec.start,
      yBits: pair.ySpec.bitCount,
      scale,
    },
    summary: summarizePositionRows(decoded),
  };
  candidate.score = candidateScore(candidate);
  candidate.strictRejectionReasons = strictRejectionReasons(candidate);
  candidate.strictPositionLike = candidate.strictRejectionReasons.length === 0;
  return candidate;
}

function compactCandidate(candidate, includeSamples = true) {
  return {
    fieldHandle: candidate.fieldHandle,
    fieldName: candidate.fieldName,
    bitCount: candidate.bitCount,
    prefixHex: candidate.prefixHex,
    yawPrefixHex: candidate.yawPrefixHex,
    yawDeltaMs: candidate.yawDeltaMs,
    candidateYawIdentity: candidate.candidateYawIdentity,
    layout: candidate.layout,
    score: round(candidate.score, 2),
    strictPositionLike: candidate.strictPositionLike,
    strictRejectionReasons: candidate.strictRejectionReasons,
    summary: includeSamples ? candidate.summary : { ...candidate.summary, samples: undefined },
  };
}

function scanYawPartitionedPositions(groups, yawLanes, options) {
  const groupByKey = new Map(groups.map((group) => [group.key, group]));
  const candidates = [];
  const partitionSummaries = [];
  const groupsByOverlap = summarizeCooccurrence(groups, yawLanes, {
    ...options,
    maxGroups: groups.length,
  });

  for (const overlap of groupsByOverlap.slice(0, options.maxGroups)) {
    const key = [overlap.fieldHandle, overlap.fieldName ?? '', overlap.bitCount, overlap.prefixHex].join('|');
    const group = groupByKey.get(key);
    if (!group) continue;

    const rowsByYawPrefix = new Map();
    const deltaByYawPrefix = new Map();
    for (const sample of group.samples) {
      for (const match of matchingYawLanes(sample, yawLanes, options.maxYawDeltaMs)) {
        if (!rowsByYawPrefix.has(match.lane.prefixHex)) rowsByYawPrefix.set(match.lane.prefixHex, []);
        rowsByYawPrefix.get(match.lane.prefixHex).push(sample);
        if (!deltaByYawPrefix.has(match.lane.prefixHex)) deltaByYawPrefix.set(match.lane.prefixHex, []);
        deltaByYawPrefix.get(match.lane.prefixHex).push(match.deltaMs);
      }
    }

    for (const [yawPrefixHex, rows] of rowsByYawPrefix.entries()) {
      if (rows.length < options.minPartitionSamples) continue;
      const yawLane = yawLanes.find((lane) => lane.prefixHex === yawPrefixHex);
      const deltas = deltaByYawPrefix.get(yawPrefixHex) ?? [];
      const variableRanges = variableRangesForRows(rows, group.bitCount);
      const scalarSpecs = scalarSpecsFromRanges(variableRanges, group.bitCount);
      const pairSpecs = pairSpecsFromScalarSpecs(scalarSpecs, options.maxPairSpecsPerPartition);
      const context = {
        fieldHandle: group.fieldHandle,
        fieldName: group.fieldName,
        bitCount: group.bitCount,
        prefixHex: group.prefixHex,
        yawPrefixHex,
        yawDeltaMs: {
          median: round(percentile(deltas, 0.5), 0),
          p90: round(percentile(deltas, 0.9), 0),
          max: deltas.length ? Math.max(...deltas) : null,
        },
        candidateYawIdentity: yawLane?.openYawMapping?.bestTransform?.bestPlayer
          ? {
              netGuid: yawLane.openYawMapping.bestTransform.bestPlayer.netGuid,
              chIndex: yawLane.openYawMapping.bestTransform.bestPlayer.chIndex,
              archetypePath: yawLane.openYawMapping.bestTransform.bestPlayer.archetypePath,
              transform: yawLane.openYawMapping.bestTransform.transform,
              deltaDegrees: yawLane.openYawMapping.bestTransform.bestPlayer.deltaDegrees,
            }
          : null,
      };

      partitionSummaries.push({
        ...context,
        rowCount: rows.length,
        variableRanges: variableRanges.slice(0, 16),
        scalarSpecCount: scalarSpecs.length,
        pairSpecCount: pairSpecs.length,
      });

      for (const pair of pairSpecs) {
        for (const scale of [1, 10, 100]) {
          const candidate = evaluatePair(rows, pair, scale, context);
          if (
            candidate.summary.inAscentBoundsRate >= 0.65 &&
            candidate.summary.uniquePositionCount >= 4 &&
            candidate.summary.xySpan >= 50
          ) {
            candidates.push(candidate);
          }
        }
      }
    }
  }

  const strictCandidates = candidates
    .filter((candidate) => candidate.strictPositionLike)
    .sort((a, b) => b.score - a.score)
    .slice(0, options.maxCandidates);
  const bestRejectedCandidates = candidates
    .filter((candidate) => !candidate.strictPositionLike)
    .sort((a, b) => b.score - a.score)
    .slice(0, options.maxCandidates);

  return {
    analyzedGroupCount: Math.min(groupsByOverlap.length, options.maxGroups),
    analyzedPartitionCount: partitionSummaries.length,
    retainedCandidateCount: candidates.length,
    strictCandidateCount: strictCandidates.length,
    status:
      strictCandidates.length > 0
        ? 'yaw-partitioned scalar position candidates passed strict gates; inspect before promotion'
        : 'no yaw-partitioned scalar position candidate passed strict continuity and map gates',
    topPartitions: partitionSummaries
      .sort((a, b) => b.rowCount - a.rowCount || a.fieldHandle - b.fieldHandle)
      .slice(0, options.maxCandidates),
    strictCandidates: strictCandidates.map((candidate) => compactCandidate(candidate)),
    bestRejectedCandidates: bestRejectedCandidates.map((candidate) =>
      compactCandidate(candidate, false),
    ),
  };
}

function analyze(diagnostics, options) {
  const samples = parseCandidateFieldSamples(diagnostics);
  const playerOpenSamples = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const yawLanes = buildYawLanes(samples, playerOpenSamples, options.minPartitionSamples);
  const groups = groupCandidateSamples(samples, options);
  const cooccurrenceSummary = summarizeCooccurrence(groups, yawLanes, options);
  const positionScan = scanYawPartitionedPositions(groups, yawLanes, options);

  return {
    generatedAt: new Date().toISOString(),
    options: {
      maxYawDeltaMs: options.maxYawDeltaMs,
      minGroupSamples: options.minGroupSamples,
      minPartitionSamples: options.minPartitionSamples,
      maxGroups: options.maxGroups,
      maxPairSpecsPerPartition: options.maxPairSpecsPerPartition,
      maxCandidates: options.maxCandidates,
    },
    notes: [
      'Partitions non-yaw ReplayController lane samples by nearby handle-122 yaw prefixes, then scans signed scalar x/y pairs inside each partition.',
      'This tests whether a collapsed multi-player position lane only becomes coherent after using the continuous yaw lane as an identity partition.',
      'A strict candidate is still only a decoder lead unless the yaw-prefix identity is validated by an authoritative NetGUID join.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      fullPayloadSampleCount: samples.filter((sample) => sample.hasFullPayload).length,
      playerOpenSampleCount: playerOpenSamples.length,
      yawLaneCount: yawLanes.length,
      candidateGroupCount: groups.length,
      rawPacketsScanned: diagnostics.frameSummary?.rawPacketsScanned ?? null,
      movementRpcHitCount: diagnostics.frameSummary?.movementRpcHitCount ?? null,
    },
    yawLanes: yawLanes.map((lane) => ({
      prefixHex: lane.prefixHex,
      count: lane.count,
      firstTimeMs: lane.firstTimeMs,
      lastTimeMs: lane.lastTimeMs,
      candidateYawIdentity: lane.openYawMapping?.bestTransform?.bestPlayer
        ? {
            netGuid: lane.openYawMapping.bestTransform.bestPlayer.netGuid,
            chIndex: lane.openYawMapping.bestTransform.bestPlayer.chIndex,
            archetypePath: lane.openYawMapping.bestTransform.bestPlayer.archetypePath,
            transform: lane.openYawMapping.bestTransform.transform,
            deltaDegrees: lane.openYawMapping.bestTransform.bestPlayer.deltaDegrees,
          }
        : null,
    })),
    cooccurrenceSummary,
    positionScan,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_yaw_partitioned_positions.mjs --diagnostics replay.diagnostics.json --out yaw_partitioned_positions.report.json',
    );
    process.exitCode = 1;
    return;
  }
  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const report = analyze(diagnostics, options);
  report.input = { diagnostics: diagnosticsPath };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main();
