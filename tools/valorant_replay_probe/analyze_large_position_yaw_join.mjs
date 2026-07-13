#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const YAW_FIELD_HANDLE = 122;
const YAW_PAYLOAD_BITS = 92;
const YAW_BIT_OFFSET = 50;
const YAW_BIT_COUNT = 18;

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    largeReport: null,
    out: null,
    maxYawDeltaMs: 33,
    minYawLaneSamples: 20,
    maxFusedSamples: 800,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--large-report') options.largeReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--max-yaw-delta-ms') options.maxYawDeltaMs = Number(argv[++index]);
    else if (arg === '--min-yaw-lane-samples') options.minYawLaneSamples = Number(argv[++index]);
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
    if (componentBits < 7 || componentBits > 24) return null;
    if (!this.canRead(componentBits * 3)) return null;
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
    .sort((a, b) => a.netGuid - b.netGuid);
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

function openYawMappingForLane(entries, playerOpenSamples) {
  const first = entries[0];
  if (!first || !playerOpenSamples.length) return null;
  const rawYaw =
    (readBitsSigned(first.buffer, YAW_BIT_OFFSET, YAW_BIT_COUNT) * 360) / 2 ** YAW_BIT_COUNT;
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
    if (!laneMap.has(prefixHex)) laneMap.set(prefixHex, new Map());
    laneMap.get(prefixHex).set(`${sample.timeMs}:${sample.payloadHex}`, { ...sample, prefixHex });
  }

  const lanes = [...laneMap.entries()]
    .map(([prefixHex, byDedupeKey]) => {
      const entries = [...byDedupeKey.values()].sort(
        (a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex,
      );
      const openYawMapping = openYawMappingForLane(entries, playerOpenSamples);
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

function nearestYawMatch(row, yawLanes, maxDeltaMs) {
  let best = null;
  for (const lane of yawLanes) {
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
  throw new Error(`unknown transform: ${transformName}`);
}

function samplesForSpec(samples, spec) {
  const prefixBits = Math.min(32, spec.bitCount);
  return samples.filter(
    (sample) =>
      sample.hasFullPayload &&
      sample.fieldHandle === spec.fieldHandle &&
      sample.bitCount === spec.bitCount &&
      bitsToHex(sample.buffer, 0, prefixBits) === spec.prefixHex,
  );
}

function reconstructPositionRows(samples, spec, transform, openSamplesByGuid) {
  const openSample = openSamplesByGuid.get(transform.openNetGuid) ?? null;
  const rows = [];
  for (const sample of samplesForSpec(samples, spec)) {
    const vector = vectorAt(sample, spec);
    if (!vector) continue;
    const point = transformPoint(vector, openSample, transform.transform);
    if (!point) continue;
    rows.push({
      timeMs: sample.timeMs,
      x: point.x,
      y: point.y,
      z: point.z,
      rawVector: vector,
    });
  }
  rows.sort((a, b) => a.timeMs - b.timeMs);
  return rows;
}

function positionTransformCandidates(largeReport) {
  const candidates = [];
  for (const group of largeReport.passingGroups ?? []) {
    for (const transform of group.passingTransforms ?? []) {
      const expectedNetGuid = Number.isInteger(group.sourceNetGuid)
        ? group.sourceNetGuid
        : transform.openNetGuid;
      candidates.push({
        key: [
          group.key,
          transform.transform,
          transform.openNetGuid ?? 'null',
          expectedNetGuid ?? 'null',
        ].join('|'),
        groupKey: group.key,
        spec: group.spec,
        transform,
        sourceNetGuid: group.sourceNetGuid,
        expectedNetGuid,
      });
    }
  }
  return candidates;
}

function summarizeLaneMatches(matchesByPrefix) {
  return [...matchesByPrefix.values()]
    .map((entry) => ({
      prefixHex: entry.prefixHex,
      count: entry.deltas.length,
      sameIdentityCount: entry.sameIdentityCount,
      sameIdentityRate: round(entry.sameIdentityCount / entry.deltas.length),
      medianDeltaMs: round(percentile(entry.deltas, 0.5), 0),
      p90DeltaMs: round(percentile(entry.deltas, 0.9), 0),
      candidateYawIdentity: entry.candidateYawIdentity,
      identityAmbiguous: entry.identityAmbiguous,
      firstYawSamples: entry.firstYawSamples,
    }))
    .sort(
      (a, b) =>
        b.sameIdentityCount - a.sameIdentityCount ||
        b.count - a.count ||
        a.medianDeltaMs - b.medianDeltaMs ||
        a.prefixHex.localeCompare(b.prefixHex),
    );
}

function analyzeCandidate(candidate, rows, yawLanes, options) {
  const matchesByPrefix = new Map();
  const fusedSamples = [];
  let yawMatchedRowCount = 0;
  let sameIdentityYawMatchCount = 0;
  let bestAnyDelta = Infinity;

  for (const row of rows) {
    const match = nearestYawMatch(row, yawLanes, options.maxYawDeltaMs);
    if (!match) continue;
    yawMatchedRowCount += 1;
    bestAnyDelta = Math.min(bestAnyDelta, match.deltaMs);
    const { lane, yawSample, deltaMs } = match;
    const sameIdentity =
      Number.isInteger(candidate.expectedNetGuid) &&
      lane.candidateYawIdentity?.netGuid === candidate.expectedNetGuid;
    if (sameIdentity) sameIdentityYawMatchCount += 1;

    if (!matchesByPrefix.has(lane.prefixHex)) {
      matchesByPrefix.set(lane.prefixHex, {
        prefixHex: lane.prefixHex,
        deltas: [],
        sameIdentityCount: 0,
        candidateYawIdentity: lane.candidateYawIdentity,
        identityAmbiguous: lane.identityAmbiguous,
        firstYawSamples: [],
      });
    }
    const laneStats = matchesByPrefix.get(lane.prefixHex);
    laneStats.deltas.push(deltaMs);
    if (sameIdentity) laneStats.sameIdentityCount += 1;
    if (laneStats.firstYawSamples.length < 5) {
      laneStats.firstYawSamples.push({
        positionTimeMs: row.timeMs,
        yawTimeMs: yawSample.timeMs,
        deltaMs,
        yawDegrees: yawSample.yawDegrees,
        yawDegrees360: yawSample.yawDegrees360,
      });
    }

    if (sameIdentity && fusedSamples.length < options.maxFusedSamples) {
      fusedSamples.push({
        timeMs: row.timeMs,
        netGuid: candidate.expectedNetGuid,
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
          vectorOffset: candidate.spec.offset,
          vectorEncoding: {
            scaleFactor: candidate.spec.scaleFactor,
            componentBits: candidate.spec.componentBits,
            extraInfo: candidate.spec.extraInfo,
          },
          positionTransform: candidate.transform.transform,
          yawFieldHandle: YAW_FIELD_HANDLE,
          yawPrefixHex: lane.prefixHex,
          yawDeltaMs: deltaMs,
        },
        confidence: Number.isInteger(candidate.sourceNetGuid)
          ? lane.identityAmbiguous
            ? 'candidate-authoritative-position-yaw-join-ambiguous-yaw-identity'
            : 'candidate-authoritative-position-yaw-join'
          : lane.identityAmbiguous
            ? 'candidate-inferred-position-yaw-join-ambiguous-yaw-identity'
            : 'candidate-inferred-position-yaw-join',
      });
    }
  }

  const laneMatches = summarizeLaneMatches(matchesByPrefix);
  const topLane = laneMatches[0] ?? null;
  const expectedNetGuid = candidate.expectedNetGuid;
  const expectedGuidKnown = Number.isInteger(expectedNetGuid);
  const sameIdentityRate = rows.length ? sameIdentityYawMatchCount / rows.length : 0;
  const matchedRate = rows.length ? yawMatchedRowCount / rows.length : 0;
  const hasAuthoritativeSourceGuid = Number.isInteger(candidate.sourceNetGuid);
  const inferredJoin =
    expectedGuidKnown &&
    sameIdentityYawMatchCount >= 10 &&
    sameIdentityRate >= 0.05 &&
    topLane?.candidateYawIdentity?.netGuid === expectedNetGuid;
  const strictJoin = inferredJoin && hasAuthoritativeSourceGuid;

  return {
    key: candidate.key,
    groupKey: candidate.groupKey,
    expectedNetGuid,
    sourceNetGuid: candidate.sourceNetGuid,
    transform: {
      transform: candidate.transform.transform,
      openNetGuid: candidate.transform.openNetGuid,
      openArchetypePath: candidate.transform.openArchetypePath,
      positionGateSummary: candidate.transform.summary,
    },
    spec: candidate.spec,
    rowCount: rows.length,
    yawMatchedRowCount,
    yawMatchedRate: round(matchedRate),
    sameIdentityYawMatchCount,
    sameIdentityYawMatchRate: round(sameIdentityRate),
    bestAnyYawDeltaMs: bestAnyDelta === Infinity ? null : bestAnyDelta,
    topYawLaneMatches: laneMatches.slice(0, 8),
    inferredJoin,
    strictJoin,
    strictJoinRejectionReasons: strictJoin
      ? []
      : [
          !hasAuthoritativeSourceGuid ? 'missing-authoritative-source-net-guid' : null,
          !expectedGuidKnown ? 'missing-position-net-guid' : null,
          sameIdentityYawMatchCount < 10 ? 'too-few-same-identity-yaw-matches' : null,
          sameIdentityRate < 0.05 ? 'weak-same-identity-yaw-rate' : null,
          topLane?.candidateYawIdentity?.netGuid !== expectedNetGuid
            ? 'top-yaw-lane-identity-mismatch'
            : null,
        ].filter(Boolean),
    fusedSamples,
  };
}

function analyzeLargePositionYawJoin(diagnostics, largeReport, options) {
  const samples = parseCandidateFieldSamples(diagnostics);
  const openSamples = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const openSamplesByGuid = new Map(openSamples.map((sample) => [sample.netGuid, sample]));
  const yawLanes = buildYawLanes(samples, openSamples, options.minYawLaneSamples);
  const candidates = positionTransformCandidates(largeReport);
  const analyses = [];

  for (const candidate of candidates) {
    const rows = reconstructPositionRows(samples, candidate.spec, candidate.transform, openSamplesByGuid);
    if (!rows.length) continue;
    analyses.push(analyzeCandidate(candidate, rows, yawLanes, options));
  }

  analyses.sort(
    (a, b) =>
      Number(b.strictJoin) - Number(a.strictJoin) ||
      b.sameIdentityYawMatchCount - a.sameIdentityYawMatchCount ||
      b.yawMatchedRowCount - a.yawMatchedRowCount ||
      b.rowCount - a.rowCount,
  );

  const strictJoins = analyses.filter((entry) => entry.strictJoin);
  const inferredJoins = analyses.filter((entry) => entry.inferredJoin);
  const fusedSamples = inferredJoins
    .flatMap((entry) => entry.fusedSamples)
    .sort((a, b) => a.netGuid - b.netGuid || a.timeMs - b.timeMs)
    .slice(0, options.maxFusedSamples);

  return {
    generatedAt: new Date().toISOString(),
    options,
    notes: [
      'Reconstructs large-payload position-like transforms that already passed the world-track continuity gate.',
      'Joins each position row to the nearest handle-122 yaw lane and checks whether the inferred yaw-lane NetGUID matches the position transform NetGUID.',
      'Open-transform identities are hypotheses. A strict join additionally requires an authoritative source NetGUID from the same vector record.',
      'This is a verifier for identity/yaw promotion. It does not parse the native ComponentDataStream record layout by itself.',
    ],
    source: {
      rawPacketsScanned: diagnostics.frameSummary?.rawPacketsScanned ?? null,
      movementRpcHitCount: diagnostics.frameSummary?.movementRpcHitCount ?? null,
      candidateFieldSampleCount:
        diagnostics.frameSummary?.replayControllerCandidateFieldSamples?.length ?? null,
      positionLikeGroupCount: largeReport.passingGroups?.length ?? 0,
      positionLikeTransformCount: candidates.length,
      yawLaneCount: yawLanes.length,
      playerOpenSampleCount: openSamples.length,
    },
    status:
      strictJoins.length > 0
        ? 'large position-like lanes have authoritative same-identity handle-122 yaw joins; inspect fused samples before promotion'
        : inferredJoins.length > 0
          ? 'large position-like lanes have inferred open-transform/yaw joins, but no authoritative source-NetGUID join'
          : 'no large position-like lane produced a same-identity handle-122 yaw join',
    yawLanes: yawLanes.map((lane) => ({
      prefixHex: lane.prefixHex,
      count: lane.count,
      firstTimeMs: lane.firstTimeMs,
      lastTimeMs: lane.lastTimeMs,
      candidateYawIdentity: lane.candidateYawIdentity,
      identityAmbiguous: lane.identityAmbiguous,
    })),
    inferredJoins: inferredJoins.slice(0, 80),
    strictJoins,
    bestRejectedJoins: analyses.filter((entry) => !entry.inferredJoin).slice(0, 80),
    fusedSamples,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const largeReportPath = resolveUserPath(options.largeReport);
  if (!diagnosticsPath || !largeReportPath) {
    console.error(
      'usage: node analyze_large_position_yaw_join.mjs --diagnostics replay.diagnostics.json --large-report large_payload_transform_hypotheses.report.json --out large_position_yaw_join.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const largeReport = JSON.parse(fs.readFileSync(largeReportPath, 'utf8'));
  const report = analyzeLargePositionYawJoin(diagnostics, largeReport, options);
  report.input = {
    diagnostics: diagnosticsPath,
    largeReport: largeReportPath,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  console.log(
    `analyzed ${report.source.positionLikeTransformCount} position transforms; inferredJoins=${report.inferredJoins.length}; strictJoins=${report.strictJoins.length}; fusedSamples=${report.fusedSamples.length}`,
  );
}

main();
