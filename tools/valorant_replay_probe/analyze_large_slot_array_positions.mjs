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
  minZ: -500,
  maxZ: 1200,
};

const TRANSFORMS = [
  'raw',
  'open+raw',
  'open-raw',
  'open+swap',
  'open-swap',
  'open+rotOpenYaw',
  'open-rotOpenYaw',
];
const YAW_FIELD_HANDLE = 122;
const YAW_PAYLOAD_BITS = 92;
const YAW_BIT_OFFSET = 50;
const YAW_BIT_COUNT = 18;
const YAW_TRANSFORMS = ['as-read', 'negated', 'plus-90', 'minus-90', 'plus-180'];

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    largeReport: null,
    out: null,
    slotCount: 10,
    minYawLaneSamples: 20,
    maxYawDeltaMs: 32,
    maxFusedSamples: 80,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--large-report') options.largeReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--slot-count') options.slotCount = Number(argv[++index]);
    else if (arg === '--min-yaw-lane-samples') options.minYawLaneSamples = Number(argv[++index]);
    else if (arg === '--max-yaw-delta-ms') options.maxYawDeltaMs = Number(argv[++index]);
    else if (arg === '--max-fused-samples') options.maxFusedSamples = Number(argv[++index]);
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

function round(value, digits = 3) {
  if (value == null || !Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * fraction)))];
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

function increment(map, key, amount = 1) {
  map.set(key, (map.get(key) ?? 0) + amount);
}

class BitCursor {
  constructor(buffer, bitLimit, bitOffset = 0) {
    this.buffer = buffer;
    this.bitLimit = bitLimit;
    this.offset = bitOffset;
    this.isError = false;
  }

  canRead(bitCount) {
    return this.offset + bitCount <= this.bitLimit;
  }

  readBit() {
    if (!this.canRead(1)) {
      this.isError = true;
      return 0;
    }
    const value = readBit(this.buffer, this.offset);
    this.offset += 1;
    return value;
  }

  readBitsUnsigned(bitCount) {
    let value = 0;
    let bitValue = 1;
    for (let bit = 0; bit < bitCount; bit += 1) {
      if (this.readBit()) value += bitValue;
      bitValue *= 2;
    }
    return value;
  }

  readSerializedInt(maxValue) {
    let value = 0;
    for (let mask = 1; value + mask < maxValue; mask *= 2) {
      if (this.readBit()) value |= mask;
    }
    return value;
  }

  readPackedVector(scaleFactor) {
    const bitsAndInfo = this.readSerializedInt(1 << 7);
    const componentBits = bitsAndInfo & 63;
    const extraInfo = bitsAndInfo >> 6;
    if (componentBits < 7 || componentBits > 24 || !this.canRead(componentBits * 3)) {
      return null;
    }
    const readComponent = () => {
      const unsigned = this.readBitsUnsigned(componentBits);
      const signBit = 2 ** (componentBits - 1);
      const signed = (unsigned ^ signBit) - signBit;
      return extraInfo ? signed / scaleFactor : signed;
    };
    const vector = {
      componentBits,
      extraInfo,
      x: readComponent(),
      y: readComponent(),
      z: readComponent(),
    };
    return this.isError ? null : vector;
  }
}

function projectAscent(point) {
  return {
    u: point.y * ASCENT_TRANSFORM.xMultiplier + ASCENT_TRANSFORM.xScalarToAdd,
    v: point.x * ASCENT_TRANSFORM.yMultiplier + ASCENT_TRANSFORM.yScalarToAdd,
  };
}

function isPlausibleAscentPoint(point) {
  const percent = projectAscent(point);
  return (
    percent.u >= ASCENT_TRANSFORM.minPercent &&
    percent.u <= ASCENT_TRANSFORM.maxPercent &&
    percent.v >= ASCENT_TRANSFORM.minPercent &&
    percent.v <= ASCENT_TRANSFORM.maxPercent &&
    point.z >= ASCENT_TRANSFORM.minZ &&
    point.z <= ASCENT_TRANSFORM.maxZ
  );
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
    .filter((sample) => sample.hasFullPayload)
    .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
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
    .filter((sample) => Number.isInteger(sample.netGuid) && sample.location)
    .sort((a, b) => a.chIndex - b.chIndex || a.netGuid - b.netGuid);
}

function normalizeDegrees360(value) {
  const normalized = value % 360;
  return normalized < 0 ? normalized + 360 : normalized;
}

function normalizeDegrees180(value) {
  const normalized = normalizeDegrees360(value);
  return normalized >= 180 ? normalized - 360 : normalized;
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

function openYawMappingForLane(entries, players) {
  const first = entries[0];
  if (!first || !players.length) return null;
  const rawYaw =
    (readBitsSigned(first.buffer, YAW_BIT_OFFSET, YAW_BIT_COUNT) * 360) / 2 ** YAW_BIT_COUNT;
  const matches = YAW_TRANSFORMS.map((transform) => {
    const transformedYaw = normalizeDegrees360(transformYaw(rawYaw, transform));
    const bestPlayer = players
      .map((player) => ({
        netGuid: player.netGuid,
        chIndex: player.chIndex,
        archetypePath: player.archetypePath,
        openYaw: round(player.yaw, 3),
        deltaDegrees: round(circularDegreesDelta(transformedYaw, player.yaw), 3),
      }))
      .sort((a, b) => a.deltaDegrees - b.deltaDegrees || a.chIndex - b.chIndex)[0];
    return {
      transform,
      transformedYaw: round(transformedYaw, 3),
      bestPlayer,
    };
  }).sort((a, b) => a.bestPlayer.deltaDegrees - b.bestPlayer.deltaDegrees);
  return {
    rawYawDegrees: round(rawYaw, 3),
    bestTransform: matches[0],
    transformMatches: matches.slice(0, 5),
  };
}

function buildYawLanes(samples, players, minSamples) {
  const laneMap = new Map();
  for (const sample of samples) {
    if (sample.fieldHandle !== YAW_FIELD_HANDLE || sample.bitCount !== YAW_PAYLOAD_BITS) {
      continue;
    }
    const prefixHex = bitsToHex(sample.buffer, 0, 32);
    if (!laneMap.has(prefixHex)) laneMap.set(prefixHex, new Map());
    laneMap.get(prefixHex).set(`${sample.timeMs}:${sample.payloadHex}`, { ...sample, prefixHex });
  }

  const lanes = [...laneMap.entries()]
    .map(([prefixHex, byDedupeKey]) => {
      const entries = [...byDedupeKey.values()].sort(
        (a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex,
      );
      const openYawMapping = openYawMappingForLane(entries, players);
      const transform = openYawMapping?.bestTransform?.transform ?? 'as-read';
      const candidateNetGuid = openYawMapping?.bestTransform?.bestPlayer?.netGuid ?? null;
      const yawSamples = entries.map((entry) => {
        const rawSignedValue = readBitsSigned(entry.buffer, YAW_BIT_OFFSET, YAW_BIT_COUNT);
        const rawYawDegrees = (rawSignedValue * 360) / 2 ** YAW_BIT_COUNT;
        const transformedYawDegrees = transformYaw(rawYawDegrees, transform);
        return {
          timeMs: entry.timeMs,
          yawDegrees: round(normalizeDegrees180(transformedYawDegrees)),
          yawDegrees360: round(normalizeDegrees360(transformedYawDegrees)),
          rawYawDegrees: round(rawYawDegrees),
          rawSignedValue,
          prefixHex,
          candidateNetGuid,
        };
      });
      return {
        prefixHex,
        count: entries.length,
        firstTimeMs: entries[0]?.timeMs ?? null,
        lastTimeMs: entries.at(-1)?.timeMs ?? null,
        candidateYawIdentity: openYawMapping?.bestTransform?.bestPlayer
          ? {
              ...openYawMapping.bestTransform.bestPlayer,
              transform,
            }
          : null,
        openYawMapping,
        times: yawSamples.map((entry) => entry.timeMs),
        yawSamples,
      };
    })
    .filter((lane) => lane.count >= minSamples)
    .sort((a, b) => b.count - a.count || a.prefixHex.localeCompare(b.prefixHex));

  const identityCounts = new Map();
  for (const lane of lanes) {
    const netGuid = lane.candidateYawIdentity?.netGuid;
    if (Number.isInteger(netGuid)) increment(identityCounts, netGuid);
  }
  for (const lane of lanes) {
    const netGuid = lane.candidateYawIdentity?.netGuid;
    lane.identityAmbiguous = Number.isInteger(netGuid) && identityCounts.get(netGuid) > 1;
  }
  return lanes;
}

function transformPoint(vector, openSample, transformName) {
  const x = vector.x;
  const y = vector.y;
  const z = vector.z ?? 0;
  if (transformName === 'raw') return { x, y, z };
  if (!openSample?.location) return null;

  const open = openSample.location;
  if (transformName === 'open+raw') return { x: open.x + x, y: open.y + y, z: open.z + z };
  if (transformName === 'open-raw') return { x: open.x - x, y: open.y - y, z: open.z - z };
  if (transformName === 'open+swap') return { x: open.x + y, y: open.y + x, z: open.z + z };
  if (transformName === 'open-swap') return { x: open.x - y, y: open.y - x, z: open.z - z };

  const yawRadians = ((openSample.yaw ?? 0) * Math.PI) / 180;
  const cos = Math.cos(yawRadians);
  const sin = Math.sin(yawRadians);
  const rotated = {
    x: x * cos - y * sin,
    y: x * sin + y * cos,
    z,
  };
  if (transformName === 'open+rotOpenYaw') {
    return { x: open.x + rotated.x, y: open.y + rotated.y, z: open.z + z };
  }
  if (transformName === 'open-rotOpenYaw') {
    return { x: open.x - rotated.x, y: open.y - rotated.y, z: open.z - z };
  }
  return null;
}

function vectorAt(sample, spec) {
  const reader = new BitCursor(sample.buffer, sample.bitCount, spec.offset);
  const vector = reader.readPackedVector(spec.scaleFactor);
  if (
    !vector ||
    reader.isError ||
    vector.componentBits !== spec.componentBits ||
    vector.extraInfo !== spec.extraInfo
  ) {
    return null;
  }
  return vector;
}

function summarizeRows(rows) {
  const ordered = [...rows].sort((a, b) => a.timeMs - b.timeMs);
  const xs = ordered.map((row) => row.x);
  const ys = ordered.map((row) => row.y);
  const zs = ordered.map((row) => row.z);
  const uniquePositions = new Set(
    ordered.map((row) => `${Math.round(row.x)}:${Math.round(row.y)}:${Math.round(row.z)}`),
  );
  const dts = [];
  const speeds = [];
  const steps = [];
  let longGapCount = 0;
  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs > 1000) longGapCount += 1;
    if (dtMs <= 250) {
      const distance = Math.hypot(current.x - previous.x, current.y - previous.y);
      steps.push(distance);
      speeds.push(distance / (dtMs / 1000));
    }
  }
  const xSpan = xs.length ? Math.max(...xs) - Math.min(...xs) : 0;
  const ySpan = ys.length ? Math.max(...ys) - Math.min(...ys) : 0;
  const zSpan = zs.length ? Math.max(...zs) - Math.min(...zs) : 0;
  return {
    count: ordered.length,
    firstTimeMs: ordered[0]?.timeMs ?? null,
    lastTimeMs: ordered.at(-1)?.timeMs ?? null,
    uniquePositionCount: uniquePositions.size,
    inAscentBoundsRate: ordered.length
      ? round(ordered.filter(isPlausibleAscentPoint).length / ordered.length, 3)
      : 0,
    bounds: ordered.length
      ? {
          minX: round(Math.min(...xs), 2),
          maxX: round(Math.max(...xs), 2),
          minY: round(Math.min(...ys), 2),
          maxY: round(Math.max(...ys), 2),
          minZ: round(Math.min(...zs), 2),
          maxZ: round(Math.max(...zs), 2),
        }
      : null,
    xSpan: round(xSpan, 2),
    ySpan: round(ySpan, 2),
    zSpan: round(zSpan, 2),
    xySpan: round(Math.hypot(xSpan, ySpan), 2),
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    longGapCount,
    adjacentStepCount: speeds.length,
    p90AdjacentSpeed: round(percentile(speeds, 0.9), 1),
    maxAdjacentSpeed: round(speeds.length ? Math.max(...speeds) : null, 1),
    p90AdjacentStepDistance: round(percentile(steps, 0.9), 2),
    samples: ordered.slice(0, 12).map((row) => ({
      timeMs: row.timeMs,
      x: round(row.x, 2),
      y: round(row.y, 2),
      z: round(row.z, 2),
      inAscentBounds: isPlausibleAscentPoint(row),
    })),
  };
}

function trackGateRejectionReasons(summary) {
  const reasons = [];
  if (summary.count < 20) reasons.push('too-few-samples');
  if (summary.uniquePositionCount < 10) reasons.push('too-few-unique-positions');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-bounds');
  if (summary.xySpan < 50) reasons.push('low-xy-span');
  if (summary.adjacentStepCount < 8) reasons.push('too-few-adjacent-steps');
  if (summary.p90AdjacentSpeed == null || summary.p90AdjacentSpeed > 5_000) {
    reasons.push('high-or-missing-p90-speed');
  }
  if (summary.maxAdjacentSpeed == null || summary.maxAdjacentSpeed > 12_000) {
    reasons.push('high-or-missing-max-speed');
  }
  return reasons;
}

function nearestInSorted(values, target) {
  if (!values.length) return null;
  let low = 0;
  let high = values.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (values[middle] < target) low = middle + 1;
    else high = middle;
  }
  let bestIndex = null;
  let bestDelta = Infinity;
  for (const index of [low - 1, low]) {
    if (index < 0 || index >= values.length) continue;
    const delta = Math.abs(values[index] - target);
    if (delta < bestDelta) {
      bestDelta = delta;
      bestIndex = index;
    }
  }
  return bestIndex == null ? null : { index: bestIndex, deltaMs: bestDelta };
}

function nearestYawMatch(row, yawLanes, maxDeltaMs, expectedNetGuid = null) {
  let best = null;
  for (const lane of yawLanes) {
    if (
      Number.isInteger(expectedNetGuid) &&
      lane.candidateYawIdentity?.netGuid !== expectedNetGuid
    ) {
      continue;
    }
    const nearest = nearestInSorted(lane.times, row.timeMs);
    if (!nearest || nearest.deltaMs > maxDeltaMs) continue;
    const yawSample = lane.yawSamples[nearest.index];
    const candidate = { lane, yawSample, deltaMs: nearest.deltaMs };
    if (
      !best ||
      candidate.deltaMs < best.deltaMs ||
      (candidate.deltaMs === best.deltaMs && lane.count > best.lane.count)
    ) {
      best = candidate;
    }
  }
  return best;
}

function summarizeLaneMatches(matchesByPrefix) {
  return [...matchesByPrefix.values()]
    .map((entry) => ({
      prefixHex: entry.prefixHex,
      count: entry.deltas.length,
      medianDeltaMs: round(percentile(entry.deltas, 0.5), 0),
      p90DeltaMs: round(percentile(entry.deltas, 0.9), 0),
      candidateYawIdentity: entry.candidateYawIdentity,
      identityAmbiguous: entry.identityAmbiguous,
      firstYawSamples: entry.firstYawSamples,
    }))
    .sort(
      (a, b) =>
        b.count - a.count ||
        a.medianDeltaMs - b.medianDeltaMs ||
        a.prefixHex.localeCompare(b.prefixHex),
    );
}

function analyzeSlotYawJoin(candidate, transformEntry, rows, yawLanes, options) {
  const slotNetGuid = candidate.slotPlayer?.netGuid ?? null;
  const matchesByPrefix = new Map();
  const fusedSamples = [];
  let anyYawMatchedRowCount = 0;
  let sameIdentityYawMatchCount = 0;
  let bestAnyYawDeltaMs = Infinity;
  let bestSameIdentityYawDeltaMs = Infinity;

  for (const row of rows) {
    const anyMatch = nearestYawMatch(row, yawLanes, options.maxYawDeltaMs);
    if (anyMatch) {
      anyYawMatchedRowCount += 1;
      bestAnyYawDeltaMs = Math.min(bestAnyYawDeltaMs, anyMatch.deltaMs);
    }

    const sameMatch = Number.isInteger(slotNetGuid)
      ? nearestYawMatch(row, yawLanes, options.maxYawDeltaMs, slotNetGuid)
      : null;
    if (!sameMatch) continue;

    sameIdentityYawMatchCount += 1;
    bestSameIdentityYawDeltaMs = Math.min(bestSameIdentityYawDeltaMs, sameMatch.deltaMs);
    const { lane, yawSample, deltaMs } = sameMatch;
    if (!matchesByPrefix.has(lane.prefixHex)) {
      matchesByPrefix.set(lane.prefixHex, {
        prefixHex: lane.prefixHex,
        deltas: [],
        candidateYawIdentity: lane.candidateYawIdentity,
        identityAmbiguous: lane.identityAmbiguous,
        firstYawSamples: [],
      });
    }
    const laneStats = matchesByPrefix.get(lane.prefixHex);
    laneStats.deltas.push(deltaMs);
    if (laneStats.firstYawSamples.length < 5) {
      laneStats.firstYawSamples.push({
        positionTimeMs: row.timeMs,
        yawTimeMs: yawSample.timeMs,
        deltaMs,
        yawDegrees: yawSample.yawDegrees,
        yawDegrees360: yawSample.yawDegrees360,
      });
    }

    if (fusedSamples.length < options.maxFusedSamples) {
      fusedSamples.push({
        timeMs: row.timeMs,
        netGuid: slotNetGuid,
        position: {
          x: round(row.x, 2),
          y: round(row.y, 2),
          z: round(row.z, 2),
        },
        viewRotation: {
          yawDegrees: yawSample.yawDegrees,
          yawDegrees360: yawSample.yawDegrees360,
          pitchDegrees: null,
          rollDegrees: null,
        },
        source: {
          positionFieldHandle: candidate.spec.fieldHandle,
          positionPayloadBitCount: candidate.spec.bitCount,
          positionPrefixHex: candidate.spec.prefixHex,
          absoluteOffset: candidate.spec.offset,
          slotIndex: candidate.slotInfo.slotIndex,
          relativeOffset: candidate.slotInfo.relativeOffset,
          positionTransform: transformEntry.transform,
          yawFieldHandle: YAW_FIELD_HANDLE,
          yawPrefixHex: lane.prefixHex,
          yawDeltaMs: deltaMs,
          identity: 'slot-index-from-player-channel-order',
        },
        confidence: lane.identityAmbiguous
          ? 'candidate-slot-index-position-yaw-join-ambiguous-yaw-identity'
          : 'candidate-slot-index-position-yaw-join',
      });
    }
  }

  const rowCount = rows.length;
  return {
    key: [
      candidate.spec.fieldHandle,
      candidate.spec.bitCount,
      candidate.spec.prefixHex,
      candidate.slotInfo.slotIndex,
      transformEntry.transform,
      slotNetGuid ?? 'null',
    ].join('|'),
    fieldHandle: candidate.spec.fieldHandle,
    payloadBitCount: candidate.spec.bitCount,
    prefixHex: candidate.spec.prefixHex,
    slotIndex: candidate.slotInfo.slotIndex,
    relativeOffset: candidate.slotInfo.relativeOffset,
    slotNetGuid,
    slotChIndex: candidate.slotPlayer?.chIndex ?? null,
    slotArchetypePath: candidate.slotPlayer?.archetypePath ?? null,
    positionTransform: transformEntry.transform,
    rowCount,
    anyYawMatchedRowCount,
    anyYawMatchedRate: rowCount ? round(anyYawMatchedRowCount / rowCount) : 0,
    sameIdentityYawMatchCount,
    sameIdentityYawMatchRate: rowCount ? round(sameIdentityYawMatchCount / rowCount) : 0,
    bestAnyYawDeltaMs: Number.isFinite(bestAnyYawDeltaMs) ? bestAnyYawDeltaMs : null,
    bestSameIdentityYawDeltaMs: Number.isFinite(bestSameIdentityYawDeltaMs)
      ? bestSameIdentityYawDeltaMs
      : null,
    topYawLaneMatches: summarizeLaneMatches(matchesByPrefix).slice(0, 8),
    fusedSampleCount: fusedSamples.length,
    fusedSamples,
  };
}

function slotInfoForSpec(spec, slotCount) {
  const headerBits = spec.bitCount % slotCount;
  const recordBits = (spec.bitCount - headerBits) / slotCount;
  if (!Number.isInteger(recordBits) || spec.offset < headerBits) return null;
  const slotIndex = Math.floor((spec.offset - headerBits) / recordBits);
  if (slotIndex < 0 || slotIndex >= slotCount) return null;
  const relativeOffset = spec.offset - headerBits - slotIndex * recordBits;
  if (relativeOffset < 0 || relativeOffset >= recordBits) return null;
  return { headerBits, recordBits, slotIndex, relativeOffset };
}

function samplesForSpec(samples, spec) {
  return samples.filter(
    (sample) =>
      sample.fieldHandle === spec.fieldHandle &&
      sample.bitCount === spec.bitCount &&
      sample.payloadHex.startsWith(spec.prefixHex),
  );
}

function analyzeSlotCandidate(samples, spec, slotInfo, slotPlayer) {
  const decodedRows = [];
  for (const sample of samples) {
    const vector = vectorAt(sample, spec);
    if (!vector) continue;
    decodedRows.push({ timeMs: sample.timeMs, vector });
  }

  const rowsByTransform = new Map();
  const transforms = TRANSFORMS.map((transform) => {
    const rows = decodedRows
      .map((row) => {
        const point = transformPoint(row.vector, slotPlayer, transform);
        return point ? { timeMs: row.timeMs, ...point } : null;
      })
      .filter(Boolean);
    rowsByTransform.set(transform, rows);
    const summary = summarizeRows(rows);
    const rejectionReasons = trackGateRejectionReasons(summary);
    return {
      transform,
      slotNetGuid: slotPlayer?.netGuid ?? null,
      slotChIndex: slotPlayer?.chIndex ?? null,
      slotArchetypePath: slotPlayer?.archetypePath ?? null,
      passesTrackGate: rejectionReasons.length === 0,
      rejectionReasons,
      summary,
    };
  }).sort((a, b) => {
    if (Number(b.passesTrackGate) !== Number(a.passesTrackGate)) {
      return Number(b.passesTrackGate) - Number(a.passesTrackGate);
    }
    return (
      b.summary.inAscentBoundsRate - a.summary.inAscentBoundsRate ||
      b.summary.uniquePositionCount - a.summary.uniquePositionCount ||
      (a.summary.p90AdjacentSpeed ?? Infinity) - (b.summary.p90AdjacentSpeed ?? Infinity)
    );
  });

  const bestTransform = transforms[0] ?? null;
  return {
    candidate: {
      spec,
      slotInfo,
      slotPlayer: slotPlayer
        ? {
            netGuid: slotPlayer.netGuid,
            chIndex: slotPlayer.chIndex,
            archetypePath: slotPlayer.archetypePath,
            openLocation: slotPlayer.location,
            openYaw: slotPlayer.yaw,
          }
        : null,
      rawDecodedSampleCount: decodedRows.length,
      bestTransform,
      transforms,
    },
    rowsByTransform,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const largeReportPath = resolveUserPath(options.largeReport);
  if (!diagnosticsPath || !largeReportPath) {
    console.error(
      'usage: node analyze_large_slot_array_positions.mjs --diagnostics replay.diagnostics.json --large-report large_payload_transform_hypotheses.report.json --out large_slot_array_positions.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const largeReport = JSON.parse(fs.readFileSync(largeReportPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const yawLanes = buildYawLanes(samples, players, options.minYawLaneSamples);
  const specs = (largeReport.passingGroups ?? []).map((group) => group.spec).filter(Boolean);
  const analyzedSlotCandidates = [];
  for (const spec of specs) {
    const slotInfo = slotInfoForSpec(spec, options.slotCount);
    if (!slotInfo) continue;
    const slotPlayer = players[slotInfo.slotIndex] ?? null;
    const specSamples = samplesForSpec(samples, spec);
    analyzedSlotCandidates.push(analyzeSlotCandidate(specSamples, spec, slotInfo, slotPlayer));
  }
  const slotCandidates = analyzedSlotCandidates.map((entry) => entry.candidate);

  const passingSlotTransformCount = slotCandidates.reduce(
    (sum, candidate) =>
      sum + candidate.transforms.filter((transform) => transform.passesTrackGate).length,
    0,
  );
  const slotYawJoins = analyzedSlotCandidates
    .flatMap(({ candidate, rowsByTransform }) =>
      candidate.transforms
        .filter((transform) => transform.passesTrackGate)
        .map((transform) =>
          analyzeSlotYawJoin(
            candidate,
            transform,
            rowsByTransform.get(transform.transform) ?? [],
            yawLanes,
            options,
          ),
        ),
    )
    .sort(
      (a, b) =>
        b.sameIdentityYawMatchCount - a.sameIdentityYawMatchCount ||
        b.sameIdentityYawMatchRate - a.sameIdentityYawMatchRate ||
        (a.bestSameIdentityYawDeltaMs ?? Infinity) - (b.bestSameIdentityYawDeltaMs ?? Infinity),
    );
  const fusedCandidateSamples = slotYawJoins
    .flatMap((join) => join.fusedSamples)
    .slice(0, options.maxFusedSamples)
    .sort((a, b) => a.timeMs - b.timeMs || a.netGuid - b.netGuid);
  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
      largeReport: largeReportPath,
    },
    options: {
      slotCount: options.slotCount,
      minYawLaneSamples: options.minYawLaneSamples,
      maxYawDeltaMs: options.maxYawDeltaMs,
      maxFusedSamples: options.maxFusedSamples,
    },
    notes: [
      'This verifier reinterprets position-like large-payload offsets as offsets inside a fixed slot array.',
      'Slot identity is inferred from known player actor channel order, not yet from an encoded ShooterCharacterNetGuidValue.',
      'Handle-122 yaw joins are matched only when the yaw lane open-yaw attribution has the same slot-inferred NetGUID.',
      'Passing rows are still candidate replay tracks until the native ComponentDataStream identity binding and position transform are decoded.',
    ],
    source: {
      passingGroupCount: specs.length,
      playerReferenceCount: players.length,
      yawLaneCount: yawLanes.length,
      players,
    },
    status:
      fusedCandidateSamples.length > 0
        ? 'position-like large payload offsets align with slot records and produce slot-inferred position/yaw candidate samples'
        : passingSlotTransformCount > 0
        ? 'position-like large payload offsets align with slot records and produce slot-inferred candidate tracks'
        : 'position-like large payload offsets did not produce slot-inferred candidate tracks',
    passingSlotTransformCount,
    slotYawJoinCount: slotYawJoins.length,
    fusedCandidateSampleCount: fusedCandidateSamples.length,
    yawLanes: yawLanes.slice(0, 40).map((lane) => ({
      prefixHex: lane.prefixHex,
      count: lane.count,
      firstTimeMs: lane.firstTimeMs,
      lastTimeMs: lane.lastTimeMs,
      candidateYawIdentity: lane.candidateYawIdentity,
      identityAmbiguous: lane.identityAmbiguous,
      openYawMapping: lane.openYawMapping,
    })),
    slotCandidates,
    slotYawJoins: slotYawJoins.map((join) => {
      const { fusedSamples, ...summary } = join;
      return summary;
    }),
    fusedCandidateSamples,
    candidateSamples: slotCandidates
      .flatMap((candidate) =>
        candidate.transforms
          .filter((transform) => transform.passesTrackGate)
          .slice(0, 1)
          .flatMap((transform) =>
            transform.summary.samples.slice(0, 80).map((sample) => ({
              timeMs: sample.timeMs,
              netGuid: transform.slotNetGuid,
              position: { x: sample.x, y: sample.y, z: sample.z },
              viewRotation: null,
              source: {
                fieldHandle: candidate.spec.fieldHandle,
                payloadBitCount: candidate.spec.bitCount,
                prefixHex: candidate.spec.prefixHex,
                absoluteOffset: candidate.spec.offset,
                slotIndex: candidate.slotInfo.slotIndex,
                relativeOffset: candidate.slotInfo.relativeOffset,
                transform: transform.transform,
                identity: 'slot-index-from-player-channel-order',
              },
              confidence: 'candidate-slot-index-position-only',
            })),
          ),
      )
      .sort((a, b) => a.timeMs - b.timeMs || a.netGuid - b.netGuid),
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  console.error(
    `analyzed ${specs.length} large position specs; slotCandidates=${slotCandidates.length}; passingSlotTransforms=${passingSlotTransformCount}; fusedPositionYawSamples=${fusedCandidateSamples.length}`,
  );
}

main();
