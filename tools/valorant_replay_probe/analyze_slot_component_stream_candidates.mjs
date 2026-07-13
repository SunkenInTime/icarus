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

const POSITION_TRANSFORMS = [
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
    diagnostics: null,
    out: null,
    slotCount: 10,
    prefixBits: 32,
    minBitCount: 512,
    minGroupSamples: 80,
    minCandidateSamples: 20,
    minSameYawMatches: 4,
    minMovementXySpan: 200,
    minMovementUniquePositions: 30,
    maxYawDeltaMs: 32,
    minYawLaneSamples: 20,
    maxGroups: 80,
    maxCandidates: 200,
    maxFusedSamples: 120,
    scaleFactors: [1, 10, 100, 1000],
    samplesOut: null,
    trackOut: null,
    mapId: '/Game/Maps/Ascent/Ascent',
    sampleCandidateScope: 'movement',
    sampleDedupe: 'family',
    maxSampleCandidates: 12,
    maxSamplesPerCandidate: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--slot-count') options.slotCount = Number(argv[++index]);
    else if (arg === '--prefix-bits') options.prefixBits = Number(argv[++index]);
    else if (arg === '--min-bit-count') options.minBitCount = Number(argv[++index]);
    else if (arg === '--min-group-samples') options.minGroupSamples = Number(argv[++index]);
    else if (arg === '--min-candidate-samples') {
      options.minCandidateSamples = Number(argv[++index]);
    } else if (arg === '--min-same-yaw-matches') {
      options.minSameYawMatches = Number(argv[++index]);
    } else if (arg === '--min-movement-xy-span') {
      options.minMovementXySpan = Number(argv[++index]);
    } else if (arg === '--min-movement-unique-positions') {
      options.minMovementUniquePositions = Number(argv[++index]);
    } else if (arg === '--max-yaw-delta-ms') {
      options.maxYawDeltaMs = Number(argv[++index]);
    } else if (arg === '--min-yaw-lane-samples') {
      options.minYawLaneSamples = Number(argv[++index]);
    } else if (arg === '--max-groups') {
      options.maxGroups = Number(argv[++index]);
    } else if (arg === '--max-candidates') {
      options.maxCandidates = Number(argv[++index]);
    } else if (arg === '--max-fused-samples') {
      options.maxFusedSamples = Number(argv[++index]);
    } else if (arg === '--scale-factors') {
      options.scaleFactors = argv[++index].split(',').map(Number).filter(Number.isFinite);
    } else if (arg === '--samples-out') {
      options.samplesOut = argv[++index];
    } else if (arg === '--track-out') {
      options.trackOut = argv[++index];
    } else if (arg === '--map-id') {
      options.mapId = argv[++index];
    } else if (arg === '--sample-candidate-scope') {
      options.sampleCandidateScope = argv[++index];
    } else if (arg === '--sample-dedupe') {
      options.sampleDedupe = argv[++index];
    } else if (arg === '--max-sample-candidates') {
      options.maxSampleCandidates = Number(argv[++index]);
    } else if (arg === '--max-samples-per-candidate') {
      options.maxSamplesPerCandidate = Number(argv[++index]);
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

  readBitsSigned(bitCount) {
    const value = this.readBitsUnsigned(bitCount);
    const signBit = 2 ** (bitCount - 1);
    return (value ^ signBit) - signBit;
  }

  readSerializedInt(maxValue) {
    let value = 0;
    for (let mask = 1; value + mask < maxValue; mask *= 2) {
      if (this.readBit()) value |= mask;
    }
    return value;
  }

  readPackedVectorRaw() {
    const bitsAndInfo = this.readSerializedInt(1 << 7);
    const componentBits = bitsAndInfo & 63;
    const extraInfo = bitsAndInfo >> 6;
    if (componentBits < 7 || componentBits > 24) return null;
    if (!this.canRead(componentBits * 3)) return null;
    const vector = {
      componentBits,
      extraInfo,
      xSigned: this.readBitsSigned(componentBits),
      ySigned: this.readBitsSigned(componentBits),
      zSigned: this.readBitsSigned(componentBits),
    };
    return this.isError ? null : vector;
  }
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
    return { x: open.x + rotated.x, y: open.y + rotated.y, z: open.z + rotated.z };
  }
  if (transformName === 'open-rotOpenYaw') {
    return { x: open.x - rotated.x, y: open.y - rotated.y, z: open.z - rotated.z };
  }
  return null;
}

function vectorAtRaw(sample, bitOffset) {
  const reader = new BitCursor(sample.buffer, sample.bitCount, bitOffset);
  return reader.readPackedVectorRaw();
}

function scaleRawVector(rawVector, scaleFactor) {
  const scale = rawVector.extraInfo ? scaleFactor : 1;
  return {
    componentBits: rawVector.componentBits,
    extraInfo: rawVector.extraInfo,
    x: rawVector.xSigned / scale,
    y: rawVector.ySigned / scale,
    z: rawVector.zSigned / scale,
  };
}

function summarizeRows(rows) {
  const ordered = [...rows].sort((a, b) => a.timeMs - b.timeMs);
  const xs = ordered.map((row) => row.x);
  const ys = ordered.map((row) => row.y);
  const zs = ordered.map((row) => row.z);
  const uniquePositions = new Set(
    ordered.map((row) => `${Math.round(row.x)}:${Math.round(row.y)}:${Math.round(row.z)}`),
  );
  const uniqueTimes = new Set(ordered.map((row) => row.timeMs));
  const dts = [];
  const speeds = [];
  const speeds3d = [];
  const steps = [];
  const steps3d = [];
  const zSteps = [];
  let longGapCount = 0;
  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs > 1000) longGapCount += 1;
    if (dtMs <= 250) {
      const dx = current.x - previous.x;
      const dy = current.y - previous.y;
      const dz = current.z - previous.z;
      const distance = Math.hypot(dx, dy);
      const distance3d = Math.hypot(dx, dy, dz);
      steps.push(distance);
      steps3d.push(distance3d);
      zSteps.push(Math.abs(dz));
      speeds.push(distance / (dtMs / 1000));
      speeds3d.push(distance3d / (dtMs / 1000));
    }
  }
  const xSpan = xs.length ? Math.max(...xs) - Math.min(...xs) : 0;
  const ySpan = ys.length ? Math.max(...ys) - Math.min(...ys) : 0;
  const zSpan = zs.length ? Math.max(...zs) - Math.min(...zs) : 0;
  return {
    count: ordered.length,
    firstTimeMs: ordered[0]?.timeMs ?? null,
    lastTimeMs: ordered.at(-1)?.timeMs ?? null,
    activeSpanMs: ordered.length ? ordered.at(-1).timeMs - ordered[0].timeMs : 0,
    uniqueTimeCount: uniqueTimes.size,
    uniquePositionCount: uniquePositions.size,
    inAscentBoundsRate: ordered.length
      ? round(ordered.filter(isPlausibleAscentPoint).length / ordered.length)
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
    p90Adjacent3dSpeed: round(percentile(speeds3d, 0.9), 1),
    maxAdjacent3dSpeed: round(speeds3d.length ? Math.max(...speeds3d) : null, 1),
    p90Adjacent3dStepDistance: round(percentile(steps3d, 0.9), 2),
    p90AdjacentZStep: round(percentile(zSteps, 0.9), 2),
    maxAdjacentZStep: round(zSteps.length ? Math.max(...zSteps) : null, 2),
    samples: ordered.slice(0, 8).map((row) => ({
      timeMs: row.timeMs,
      x: round(row.x, 2),
      y: round(row.y, 2),
      z: round(row.z, 2),
      inAscentBounds: isPlausibleAscentPoint(row),
    })),
  };
}

function addOpenReferenceSummary(summary, rows, slotPlayer) {
  if (!rows.length || !slotPlayer?.location) return summary;
  const first = [...rows].sort((a, b) => a.timeMs - b.timeMs)[0];
  const open = slotPlayer.location;
  return {
    ...summary,
    openReference: {
      openTimeMs: slotPlayer.timeMs ?? null,
      firstSampleTimeMs: first.timeMs,
      deltaTimeMs: Number.isFinite(slotPlayer.timeMs) ? first.timeMs - slotPlayer.timeMs : null,
      distance2d: round(Math.hypot(first.x - open.x, first.y - open.y), 2),
      distance3d: round(Math.hypot(first.x - open.x, first.y - open.y, first.z - open.z), 2),
    },
  };
}

function trackGateRejectionReasons(summary, options) {
  const reasons = [];
  if (summary.count < options.minCandidateSamples) reasons.push('too-few-samples');
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

function position3dRejectionReasons(summary) {
  const reasons = [];
  if (summary.count < 20) reasons.push('too-few-samples');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-or-z-bounds');
  if (summary.adjacentStepCount < 8) reasons.push('too-few-adjacent-steps');
  if (summary.p90Adjacent3dSpeed == null || summary.p90Adjacent3dSpeed > 5_000) {
    reasons.push('high-or-missing-p90-3d-speed');
  }
  if (summary.maxAdjacent3dSpeed == null || summary.maxAdjacent3dSpeed > 12_000) {
    reasons.push('high-or-missing-max-3d-speed');
  }
  if (summary.p90AdjacentZStep == null || summary.p90AdjacentZStep > 120) {
    reasons.push('large-or-missing-p90-z-step');
  }
  if (summary.maxAdjacentZStep == null || summary.maxAdjacentZStep > 450) {
    reasons.push('large-or-missing-max-z-step');
  }
  if (
    summary.openReference?.deltaTimeMs != null &&
    summary.openReference.deltaTimeMs >= 0 &&
    summary.openReference.deltaTimeMs <= 30_000 &&
    summary.openReference.distance2d > 5_000
  ) {
    reasons.push('early-sample-far-from-actor-open');
  }
  return reasons;
}

function movementGateRejectionReasons(candidate, options) {
  const reasons = [];
  if (!candidate.hasSameIdentityYawJoin) reasons.push('weak-same-slot-yaw-join');
  if (candidate.summary.uniquePositionCount < options.minMovementUniquePositions) {
    reasons.push('too-few-unique-positions-for-movement');
  }
  if (candidate.summary.xySpan < options.minMovementXySpan) reasons.push('low-movement-xy-span');
  if (candidate.summary.p90AdjacentSpeed === 0) reasons.push('mostly-static-adjacent-motion');
  if (candidate.topYawLaneMatches.some((match) => match.identityAmbiguous)) {
    reasons.push('ambiguous-yaw-identity');
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

function summarizeYawJoin(rows, yawLanes, slotPlayer, options, source) {
  const slotNetGuid = slotPlayer?.netGuid ?? null;
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
          ...source,
          yawFieldHandle: YAW_FIELD_HANDLE,
          yawPrefixHex: lane.prefixHex,
          yawDeltaMs: deltaMs,
          identity: 'slot-index-from-player-channel-order',
        },
        confidence: lane.identityAmbiguous
          ? 'candidate-slot-scan-position-yaw-join-ambiguous-yaw-identity'
          : 'candidate-slot-scan-position-yaw-join',
      });
    }
  }

  const topYawLaneMatches = [...matchesByPrefix.values()]
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

  return {
    anyYawMatchedRowCount,
    anyYawMatchedRate: rows.length ? round(anyYawMatchedRowCount / rows.length) : 0,
    sameIdentityYawMatchCount,
    sameIdentityYawMatchRate: rows.length ? round(sameIdentityYawMatchCount / rows.length) : 0,
    bestAnyYawDeltaMs: Number.isFinite(bestAnyYawDeltaMs) ? bestAnyYawDeltaMs : null,
    bestSameIdentityYawDeltaMs: Number.isFinite(bestSameIdentityYawDeltaMs)
      ? bestSameIdentityYawDeltaMs
      : null,
    topYawLaneMatches: topYawLaneMatches.slice(0, 5),
    fusedSamples,
  };
}

function candidateReportSummary(candidate) {
  const { fusedSamples, diagnosticSamples, ...summary } = candidate;
  return summary;
}

function confidenceForCandidate(candidate, hasDecodedYaw) {
  if (candidate.passesStrictMovementGate && hasDecodedYaw) {
    return 'candidate-slot-component-position-yaw-joined';
  }
  if (candidate.passesStrictMovementGate) {
    return 'candidate-slot-component-position-yaw-sparse';
  }
  if (candidate.passesPosition3dGate && candidate.passesMovementShapeGate && hasDecodedYaw) {
    return 'candidate-slot-component-position3d-ambiguous-yaw-identity';
  }
  if (candidate.passesPosition3dGate && candidate.passesMovementShapeGate) {
    return 'candidate-slot-component-position3d-only';
  }
  if (candidate.passesPosition3dGate) {
    return 'candidate-slot-component-position3d-shape-only';
  }
  if (candidate.passesMovementShapeGate && hasDecodedYaw) {
    return 'candidate-slot-component-position-ambiguous-yaw-identity';
  }
  if (candidate.passesMovementShapeGate) {
    return 'candidate-slot-component-position-only';
  }
  return 'candidate-slot-component-shape-only';
}

function buildDiagnosticSamplesForCandidate(rows, yawLanes, slotPlayer, options, source, candidate) {
  const slotNetGuid = slotPlayer?.netGuid ?? null;
  const orderedRows = [...rows].sort((a, b) => a.timeMs - b.timeMs || a.x - b.x || a.y - b.y);
  const limitedRows = Number.isFinite(options.maxSamplesPerCandidate)
    ? orderedRows.slice(0, options.maxSamplesPerCandidate)
    : orderedRows;

  return limitedRows.map((row) => {
    const sameMatch = Number.isInteger(slotNetGuid)
      ? nearestYawMatch(row, yawLanes, options.maxYawDeltaMs, slotNetGuid)
      : null;
    const hasDecodedYaw = Boolean(sameMatch);
    return {
      timeMs: row.timeMs,
      netGuid: slotNetGuid,
      position: {
        x: round(row.x, 2),
        y: round(row.y, 2),
        z: round(row.z, 2),
      },
      viewRotation: {
        yawDegrees: hasDecodedYaw ? sameMatch.yawSample.yawDegrees : null,
        yawDegrees360: hasDecodedYaw ? sameMatch.yawSample.yawDegrees360 : null,
        pitchDegrees: null,
        rollDegrees: null,
      },
      source: {
        ...source,
        yawFieldHandle: hasDecodedYaw ? YAW_FIELD_HANDLE : null,
        yawPrefixHex: hasDecodedYaw ? sameMatch.lane.prefixHex : null,
        yawDeltaMs: hasDecodedYaw ? sameMatch.deltaMs : null,
        yawIdentityAmbiguous: hasDecodedYaw ? sameMatch.lane.identityAmbiguous : null,
        identity: 'slot-index-from-player-channel-order',
      },
      confidence: confidenceForCandidate(candidate, hasDecodedYaw),
    };
  });
}

function candidateMatchesSampleScope(candidate, scope) {
  if (scope === 'strict') return candidate.passesStrictMovementGate;
  if (scope === 'position3d') return candidate.passesPosition3dGate;
  if (scope === 'position3d-movement') {
    return candidate.passesPosition3dGate && candidate.passesMovementShapeGate;
  }
  if (scope === 'movement') return candidate.passesMovementShapeGate;
  if (scope === 'same-yaw') return candidate.hasSameIdentityYawJoin;
  if (scope === 'all') return true;
  throw new Error(`unknown sample candidate scope: ${scope}`);
}

function sampleDedupeKey(candidate, mode) {
  if (mode === 'none' || mode === 'candidate') return candidate.key;
  if (mode === 'netGuid') return String(candidate.slotNetGuid ?? candidate.key);
  if (mode === 'family') {
    return [
      candidate.fieldHandle,
      candidate.payloadBitCount,
      candidate.prefixHex,
      candidate.slotIndex,
      candidate.relativeOffset,
      candidate.componentBits,
      candidate.extraInfo,
    ].join('|');
  }
  throw new Error(`unknown sample dedupe mode: ${mode}`);
}

function selectSampleCandidates(allCandidates, options) {
  const selected = [];
  const seen = new Set();
  for (const candidate of [...allCandidates].sort(candidateSort)) {
    if (!candidateMatchesSampleScope(candidate, options.sampleCandidateScope)) continue;
    if (!candidate.diagnosticSamples?.length) continue;
    const key = sampleDedupeKey(candidate, options.sampleDedupe);
    if (seen.has(key)) continue;
    seen.add(key);
    selected.push(candidate);
    if (selected.length >= options.maxSampleCandidates) break;
  }
  return selected;
}

function buildCandidateSamplesOutput(selectedCandidates, options, diagnosticsPath) {
  const candidates = selectedCandidates.map((candidate) => {
    const decodedYawSampleCount = candidate.diagnosticSamples.filter(
      (sample) => sample.viewRotation?.yawDegrees != null,
    ).length;
    return {
      candidate: candidateReportSummary(candidate),
      decodedYawSampleCount,
      sampleCount: candidate.diagnosticSamples.length,
      samples: candidate.diagnosticSamples,
    };
  });
  const flatSamples = candidates
    .flatMap((entry) => entry.samples)
    .sort((a, b) => a.timeMs - b.timeMs || (a.netGuid ?? 0) - (b.netGuid ?? 0));
  return {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
    },
    options: {
      sampleCandidateScope: options.sampleCandidateScope,
      sampleDedupe: options.sampleDedupe,
      maxSampleCandidates: options.maxSampleCandidates,
      maxSamplesPerCandidate: options.maxSamplesPerCandidate,
      maxYawDeltaMs: options.maxYawDeltaMs,
    },
    notes: [
      'Samples are reconstructed from slot-aware ComponentDataStream candidate families.',
      'Position is continuous for each selected candidate family; viewRotation yaw is populated only when a same-slot handle-122 lane matches within maxYawDeltaMs.',
      'Use sampleCandidateScope=position3d or position3d-movement to select candidates that pass the full xyz gate instead of the older 2D/yaw movement gate.',
      'Slot identity is inferred from player actor channel order until ShooterCharacterNetGuidValue is decoded natively.',
    ],
    sampleShape: '{timeMs, netGuid, position:{x,y,z}, viewRotation:{yawDegrees,yawDegrees360,pitchDegrees,rollDegrees}, source, confidence}',
    selectedCandidateCount: selectedCandidates.length,
    flatSampleCount: flatSamples.length,
    decodedYawSampleCount: flatSamples.filter((sample) => sample.viewRotation?.yawDegrees != null)
      .length,
    status:
      selectedCandidates.length > 0
        ? 'slot-aware movement candidate samples emitted'
        : 'no slot-aware movement candidate samples selected',
    candidates,
    flatSamples,
  };
}

function fallbackYawDegrees(samples, index) {
  const sample = samples[index];
  const reference = samples[index + 1] ?? samples[index - 1];
  if (!sample || !reference) return 0;
  const dx = reference.position.x - sample.position.x;
  const dy = reference.position.y - sample.position.y;
  if (dx === 0 && dy === 0) return 0;
  return round((Math.atan2(dy, dx) * 180) / Math.PI, 2);
}

function viewerSamplesFromDiagnosticSamples(samples) {
  const ordered = [...samples].sort((a, b) => a.timeMs - b.timeMs);
  return ordered.map((sample, index) => {
    const decodedYaw = sample.viewRotation?.yawDegrees;
    return {
      timeMs: sample.timeMs,
      x: sample.position.x,
      y: sample.position.y,
      z: sample.position.z,
      yawDegrees: Number.isFinite(decodedYaw) ? decodedYaw : fallbackYawDegrees(ordered, index),
      pitchDegrees: sample.viewRotation?.pitchDegrees ?? null,
      yawSource: Number.isFinite(decodedYaw) ? 'decoded-handle122' : 'movement-fallback',
    };
  });
}

function buildCandidateTrackOutput(selectedCandidates, options, diagnosticsPath) {
  const players = selectedCandidates.map((candidate, index) => {
    const decodedYawSampleCount = candidate.diagnosticSamples.filter(
      (sample) => sample.viewRotation?.yawDegrees != null,
    ).length;
    const sourceTag = [
      `h${candidate.fieldHandle}`,
      `${candidate.payloadBitCount}b`,
      `p${candidate.prefixHex}`,
      `slot${candidate.slotIndex}`,
      `rel${candidate.relativeOffset}`,
      `${candidate.componentBits}+${candidate.extraInfo}`,
      candidate.positionTransform,
    ].join(' ');
    return {
      id: `slot-${candidate.slotNetGuid ?? 'unknown'}-${candidate.fieldHandle}-${candidate.prefixHex}-${candidate.relativeOffset}-${candidate.positionTransform}`,
      displayName: `g${candidate.slotNetGuid ?? '?'} h${candidate.fieldHandle} rel${candidate.relativeOffset}`,
      agent: candidate.slotArchetypePath ?? `NetGUID ${candidate.slotNetGuid ?? '?'}`,
      teamColor: TRACK_COLORS[index % TRACK_COLORS.length],
      kind: 'candidate-slot-component-stream',
      sourceTag,
      confidence: confidenceForCandidate(candidate, decodedYawSampleCount > 0),
      notes:
        `Diagnostic slot-aware ComponentDataStream candidate. ` +
        `${decodedYawSampleCount}/${candidate.diagnosticSamples.length} samples have decoded handle-122 yaw; ` +
        'viewer yaw falls back to movement direction when decoded yaw is absent.',
      samples: viewerSamplesFromDiagnosticSamples(candidate.diagnosticSamples),
    };
  });

  return {
    sourceLabel: 'VRF slot ComponentDataStream candidates',
    coordinateSpace: 'game',
    mapId: options.mapId,
    notes:
      'Generated from slot-aware ReplayController ComponentDataStream candidate families. These are reverse-engineering tracks, not confirmed native replay-decoder output.',
    sourceReport: diagnosticsPath,
    players,
  };
}

function candidateGroups(samples, options) {
  const groups = new Map();
  for (const sample of samples) {
    if (sample.bitCount < options.minBitCount) continue;
    if (sample.fieldHandle === YAW_FIELD_HANDLE) continue;
    const prefixHex = bitsToHex(sample.buffer, 0, Math.min(options.prefixBits, sample.bitCount));
    const key = [sample.fieldHandle, sample.bitCount, prefixHex].join('|');
    if (!groups.has(key)) {
      const headerBits = sample.bitCount % options.slotCount;
      groups.set(key, {
        key,
        fieldHandle: sample.fieldHandle,
        fieldName: sample.fieldName ?? null,
        bitCount: sample.bitCount,
        prefixHex,
        headerBits,
        recordBits: (sample.bitCount - headerBits) / options.slotCount,
        samples: [],
      });
    }
    groups.get(key).samples.push(sample);
  }
  return [...groups.values()]
    .filter(
      (group) =>
        group.samples.length >= options.minGroupSamples &&
        Number.isInteger(group.recordBits) &&
        group.recordBits >= 80,
    )
    .sort((a, b) => b.samples.length - a.samples.length || b.bitCount - a.bitCount)
    .slice(0, options.maxGroups);
}

function decodedRowsForSlotOffset(group, slotIndex, relativeOffset) {
  const absoluteOffset = group.headerBits + slotIndex * group.recordBits + relativeOffset;
  const byEncoding = new Map();
  for (const sample of group.samples) {
    const rawVector = vectorAtRaw(sample, absoluteOffset);
    if (!rawVector) continue;
    const key = `${rawVector.componentBits}|${rawVector.extraInfo}`;
    if (!byEncoding.has(key)) byEncoding.set(key, []);
    byEncoding.get(key).push({
      timeMs: sample.timeMs,
      rawVector,
    });
  }
  return [...byEncoding.entries()].map(([key, rows]) => {
    const [componentBitsText, extraInfoText] = key.split('|');
    return {
      componentBits: Number(componentBitsText),
      extraInfo: Number(extraInfoText),
      rows,
    };
  });
}

function candidateSort(a, b) {
  return (
    Number(b.passesStrictMovementGate) - Number(a.passesStrictMovementGate) ||
    Number(b.passesPosition3dGate) - Number(a.passesPosition3dGate) ||
    Number(b.passesMovementShapeGate) - Number(a.passesMovementShapeGate) ||
    b.sameIdentityYawMatchCount - a.sameIdentityYawMatchCount ||
    b.sameIdentityYawMatchRate - a.sameIdentityYawMatchRate ||
    Number(b.passesTrackGate) - Number(a.passesTrackGate) ||
    b.summary.uniquePositionCount - a.summary.uniquePositionCount ||
    b.summary.inAscentBoundsRate - a.summary.inAscentBoundsRate ||
    (a.summary.p90AdjacentSpeed ?? Infinity) - (b.summary.p90AdjacentSpeed ?? Infinity) ||
    b.summary.count - a.summary.count
  );
}

function analyzeGroup(group, players, yawLanes, options) {
  const candidates = [];
  const maxRelativeOffset = group.recordBits - (7 + 7 * 3);
  for (let slotIndex = 0; slotIndex < options.slotCount; slotIndex += 1) {
    const slotPlayer = players[slotIndex] ?? null;
    for (let relativeOffset = 0; relativeOffset <= maxRelativeOffset; relativeOffset += 1) {
      const encodingRows = decodedRowsForSlotOffset(group, slotIndex, relativeOffset);
      for (const encoding of encodingRows) {
        if (encoding.rows.length < options.minCandidateSamples) continue;
        const scaleFactors = encoding.extraInfo ? options.scaleFactors : [1];
        for (const scaleFactor of scaleFactors) {
          const vectorRows = encoding.rows.map((row) => ({
            timeMs: row.timeMs,
            vector: scaleRawVector(row.rawVector, scaleFactor),
          }));
          for (const transform of POSITION_TRANSFORMS) {
            const rows = vectorRows
              .map((row) => {
                const point = transformPoint(row.vector, slotPlayer, transform);
                return point ? { timeMs: row.timeMs, ...point } : null;
              })
              .filter(Boolean);
            const summary = addOpenReferenceSummary(summarizeRows(rows), rows, slotPlayer);
            const rejectionReasons = trackGateRejectionReasons(summary, options);
            if (rejectionReasons.length) continue;

            const absoluteOffset =
              group.headerBits + slotIndex * group.recordBits + relativeOffset;
            const source = {
              fieldHandle: group.fieldHandle,
              payloadBitCount: group.bitCount,
              prefixHex: group.prefixHex,
              slotIndex,
              headerBits: group.headerBits,
              recordBits: group.recordBits,
              relativeOffset,
              absoluteOffset,
              positionTransform: transform,
              vectorEncoding: {
                scaleFactor,
                componentBits: encoding.componentBits,
                extraInfo: encoding.extraInfo,
              },
            };
            const yawJoin = summarizeYawJoin(rows, yawLanes, slotPlayer, options, source);
            const candidate = {
              key: [
                group.fieldHandle,
                group.bitCount,
                group.prefixHex,
                slotIndex,
                relativeOffset,
                scaleFactor,
                encoding.componentBits,
                encoding.extraInfo,
                transform,
              ].join('|'),
              fieldHandle: group.fieldHandle,
              fieldName: group.fieldName,
              payloadBitCount: group.bitCount,
              prefixHex: group.prefixHex,
              groupSampleCount: group.samples.length,
              slotIndex,
              slotNetGuid: slotPlayer?.netGuid ?? null,
              slotChIndex: slotPlayer?.chIndex ?? null,
              slotArchetypePath: slotPlayer?.archetypePath ?? null,
              headerBits: group.headerBits,
              recordBits: group.recordBits,
              relativeOffset,
              absoluteOffset,
              scaleFactor,
              componentBits: encoding.componentBits,
              extraInfo: encoding.extraInfo,
              positionTransform: transform,
              passesTrackGate: true,
              rejectionReasons,
              summary,
              ...yawJoin,
              hasSameIdentityYawJoin: yawJoin.sameIdentityYawMatchCount >= options.minSameYawMatches,
            };
            const movementRejectionReasons = movementGateRejectionReasons(candidate, options);
            const strictMovementRejectionReasons = movementRejectionReasons.filter(
              (reason) => reason !== 'ambiguous-yaw-identity',
            );
            const position3dRejectionReasonsForCandidate = position3dRejectionReasons(
              candidate.summary,
            );
            const completeCandidate = {
              ...candidate,
              passesMovementShapeGate: strictMovementRejectionReasons.length === 0,
              movementRejectionReasons,
              passesStrictMovementGate: movementRejectionReasons.length === 0,
              passesPosition3dGate: position3dRejectionReasonsForCandidate.length === 0,
              position3dRejectionReasons: position3dRejectionReasonsForCandidate,
            };
            if (options.samplesOut || options.trackOut) {
              completeCandidate.diagnosticSamples = buildDiagnosticSamplesForCandidate(
                rows,
                yawLanes,
                slotPlayer,
                options,
                source,
                completeCandidate,
              );
            }
            candidates.push(completeCandidate);
          }
        }
      }
    }
  }
  return candidates.sort(candidateSort);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_slot_component_stream_candidates.mjs --diagnostics replay.diagnostics.json --out slot_component_stream_candidates.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const yawLanes = buildYawLanes(samples, players, options.minYawLaneSamples);
  const groups = candidateGroups(samples, options);
  const groupReports = [];
  const allCandidates = [];

  for (const group of groups) {
    const candidates = analyzeGroup(group, players, yawLanes, options);
    groupReports.push({
      key: group.key,
      fieldHandle: group.fieldHandle,
      fieldName: group.fieldName,
      bitCount: group.bitCount,
      prefixHex: group.prefixHex,
      sampleCount: group.samples.length,
      firstTimeMs: group.samples[0]?.timeMs ?? null,
      lastTimeMs: group.samples.at(-1)?.timeMs ?? null,
      headerBits: group.headerBits,
      recordBits: group.recordBits,
      candidateCount: candidates.length,
      sameIdentityYawCandidateCount: candidates.filter((candidate) => candidate.hasSameIdentityYawJoin)
        .length,
      topCandidates: candidates.slice(0, 8).map(candidateReportSummary),
    });
    allCandidates.push(...candidates);
  }

  allCandidates.sort(candidateSort);
  const retainedCandidates = allCandidates.slice(0, options.maxCandidates);
  const sameIdentityYawCandidates = allCandidates.filter((candidate) => candidate.hasSameIdentityYawJoin);
  const movementShapeCandidates = allCandidates.filter((candidate) => candidate.passesMovementShapeGate);
  const position3dCandidates = allCandidates.filter((candidate) => candidate.passesPosition3dGate);
  const strictMovementCandidates = allCandidates.filter((candidate) => candidate.passesStrictMovementGate);
  const selectedSampleCandidates =
    options.samplesOut || options.trackOut ? selectSampleCandidates(allCandidates, options) : [];
  const fusedCandidateSamples = sameIdentityYawCandidates
    .sort(candidateSort)
    .flatMap((candidate) => candidate.fusedSamples)
    .slice(0, options.maxFusedSamples)
    .sort((a, b) => a.timeMs - b.timeMs || a.netGuid - b.netGuid);

  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
    },
    options: {
      slotCount: options.slotCount,
      prefixBits: options.prefixBits,
      minBitCount: options.minBitCount,
      minGroupSamples: options.minGroupSamples,
      minCandidateSamples: options.minCandidateSamples,
      minSameYawMatches: options.minSameYawMatches,
      minMovementXySpan: options.minMovementXySpan,
      minMovementUniquePositions: options.minMovementUniquePositions,
      maxYawDeltaMs: options.maxYawDeltaMs,
      minYawLaneSamples: options.minYawLaneSamples,
      maxGroups: options.maxGroups,
      maxCandidates: options.maxCandidates,
      maxFusedSamples: options.maxFusedSamples,
      scaleFactors: options.scaleFactors,
      samplesOut: options.samplesOut,
      trackOut: options.trackOut,
      mapId: options.mapId,
      sampleCandidateScope: options.sampleCandidateScope,
      sampleDedupe: options.sampleDedupe,
      maxSampleCandidates: options.maxSampleCandidates,
      maxSamplesPerCandidate: options.maxSamplesPerCandidate,
    },
    notes: [
      'This scanner treats repeated large ReplayController payload groups as headerBits plus fixed slot records.',
      'Slot identity is inferred from known player actor channel order and is not an authoritative ShooterCharacterNetGuidValue decode.',
      'Candidates are retained only after a map/continuity gate, then ranked by same-slot handle-122 yaw matches.',
      'Fused samples are diagnostic only until the native ComponentDataStream identity and position transform are proven.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      playerReferenceCount: players.length,
      yawLaneCount: yawLanes.length,
      scannedGroupCount: groups.length,
      players,
    },
    status:
      strictMovementCandidates.length > 0
        ? 'slot-aware scan found strict movement-shaped position/yaw candidates'
        : movementShapeCandidates.length > 0
          ? 'slot-aware scan found movement-shaped candidates, but yaw identity remains ambiguous'
          : sameIdentityYawCandidates.length > 0
        ? 'slot-aware scan found position-like candidates with same-slot handle-122 yaw joins'
        : retainedCandidates.length > 0
          ? 'slot-aware scan found position-like candidates but no same-slot yaw join'
          : 'slot-aware scan found no position-like candidates',
    candidateCount: allCandidates.length,
    retainedCandidateCount: retainedCandidates.length,
    sameIdentityYawCandidateCount: sameIdentityYawCandidates.length,
    movementShapeCandidateCount: movementShapeCandidates.length,
    position3dCandidateCount: position3dCandidates.length,
    strictMovementCandidateCount: strictMovementCandidates.length,
    fusedCandidateSampleCount: fusedCandidateSamples.length,
    selectedSampleCandidateCount: selectedSampleCandidates.length,
    groupReports,
    candidates: retainedCandidates.map(candidateReportSummary),
    fusedCandidateSamples,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  const samplesOutPath = resolveUserPath(options.samplesOut);
  if (samplesOutPath) {
    writeJson(
      samplesOutPath,
      buildCandidateSamplesOutput(selectedSampleCandidates, options, diagnosticsPath),
    );
  }

  const trackOutPath = resolveUserPath(options.trackOut);
  if (trackOutPath) {
    writeJson(
      trackOutPath,
      buildCandidateTrackOutput(selectedSampleCandidates, options, diagnosticsPath),
    );
  }

  console.error(
    `scanned ${groups.length} groups; candidates=${allCandidates.length}; sameIdentityYawCandidates=${sameIdentityYawCandidates.length}; movementShapeCandidates=${movementShapeCandidates.length}; position3dCandidates=${position3dCandidates.length}; strictMovementCandidates=${strictMovementCandidates.length}; fusedSamples=${fusedCandidateSamples.length}; selectedSampleCandidates=${selectedSampleCandidates.length}`,
  );
}

main();
