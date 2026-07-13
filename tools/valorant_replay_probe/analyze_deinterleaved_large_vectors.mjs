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

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    streamReport: null,
    out: null,
    maxSpecs: 60,
    minRows: 80,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--stream-report') options.streamReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--max-specs') options.maxSpecs = Number(argv[++index]);
    else if (arg === '--min-rows') options.minRows = Number(argv[++index]);
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

function readIntPacked(buffer, bitOffset, bitLimit) {
  let value = 0;
  let shift = 1;
  let offset = bitOffset;
  for (let index = 0; index < 5; index += 1) {
    if (offset + 8 > bitLimit) return { ok: false, value, bitCount: offset - bitOffset };
    const currentByte = readBitsUnsigned(buffer, offset, 8);
    offset += 8;
    value += (currentByte >> 1) * shift;
    if ((currentByte & 1) === 0) {
      return { ok: true, value, bitCount: offset - bitOffset };
    }
    shift *= 128;
  }
  return { ok: false, value, bitCount: offset - bitOffset };
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
      const payloadHex =
        sample.payloadHex.length % 2 === 0 ? sample.payloadHex : `${sample.payloadHex}0`;
      const bitCount = sample.numPayloadBits;
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

function sourceNetGuid(spec) {
  const netGuid = spec.sourceSummary?.netGuid;
  return Number.isInteger(netGuid) ? netGuid : null;
}

function sampleMatchesSourceAnchor(sample, spec) {
  const netGuid = sourceNetGuid(spec);
  if (!Number.isInteger(netGuid)) return true;
  const guidOffset = spec.sourceSummary?.guidOffset;
  const guidBitCount = spec.sourceSummary?.guidBitCount;
  if (!Number.isInteger(guidOffset)) return false;
  const packed = readIntPacked(sample.buffer, guidOffset, sample.bitCount);
  return (
    packed.ok &&
    packed.value === netGuid &&
    (!Number.isInteger(guidBitCount) || packed.bitCount === guidBitCount)
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
  throw new Error(`unknown transform: ${transformName}`);
}

function summarizeSeries(rows) {
  const ordered = [...rows].sort((a, b) => a.timeMs - b.timeMs);
  const uniquePositions = new Set();
  const dts = [];
  const adjacentSpeeds = [];
  const adjacentSteps = [];
  let inBoundsCount = 0;
  let sameTimeConflictCount = 0;
  let largeAdjacentJumpCount = 0;
  let longGapCount = 0;
  let minX = Infinity;
  let maxX = -Infinity;
  let minY = Infinity;
  let maxY = -Infinity;
  let minZ = Infinity;
  let maxZ = -Infinity;
  const positionsByTime = new Map();

  for (const row of ordered) {
    const positionKey = `${Math.round(row.x)}:${Math.round(row.y)}:${Math.round(row.z)}`;
    const previousPosition = positionsByTime.get(row.timeMs);
    if (previousPosition && previousPosition !== positionKey) sameTimeConflictCount += 1;
    positionsByTime.set(row.timeMs, positionKey);
    uniquePositions.add(positionKey);
    if (isPlausibleAscentPoint(row)) inBoundsCount += 1;
    minX = Math.min(minX, row.x);
    maxX = Math.max(maxX, row.x);
    minY = Math.min(minY, row.y);
    maxY = Math.max(maxY, row.y);
    minZ = Math.min(minZ, row.z);
    maxZ = Math.max(maxZ, row.z);
  }

  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs > 1000) longGapCount += 1;
    const distance = Math.hypot(current.x - previous.x, current.y - previous.y);
    const speed = distance / (dtMs / 1000);
    if (dtMs <= 250) {
      adjacentSteps.push(distance);
      adjacentSpeeds.push(speed);
      if (distance > 900 || speed > 12_000) largeAdjacentJumpCount += 1;
    }
  }

  const xSpan = ordered.length ? maxX - minX : 0;
  const ySpan = ordered.length ? maxY - minY : 0;
  const zSpan = ordered.length ? maxZ - minZ : 0;
  return {
    count: ordered.length,
    firstTimeMs: ordered[0]?.timeMs ?? null,
    lastTimeMs: ordered.at(-1)?.timeMs ?? null,
    activeSpanMs: ordered.length > 1 ? ordered.at(-1).timeMs - ordered[0].timeMs : 0,
    uniqueTimeCount: new Set(ordered.map((row) => row.timeMs)).size,
    uniquePositionCount: uniquePositions.size,
    sameTimeConflictCount,
    inAscentBoundsRate: ordered.length ? round(inBoundsCount / ordered.length) : 0,
    bounds: ordered.length
      ? {
          minX: round(minX, 2),
          maxX: round(maxX, 2),
          minY: round(minY, 2),
          maxY: round(maxY, 2),
          minZ: round(minZ, 2),
          maxZ: round(maxZ, 2),
        }
      : null,
    xSpan: round(xSpan, 2),
    ySpan: round(ySpan, 2),
    zSpan: round(zSpan, 2),
    xySpan: round(Math.hypot(xSpan, ySpan), 2),
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    longGapCount,
    adjacentStepCount: adjacentSpeeds.length,
    p90AdjacentSpeed: round(percentile(adjacentSpeeds, 0.9), 1),
    maxAdjacentSpeed: round(adjacentSpeeds.length ? Math.max(...adjacentSpeeds) : null, 1),
    p90AdjacentStepDistance: round(percentile(adjacentSteps, 0.9), 2),
    largeAdjacentJumpCount,
    firstSamples: ordered.slice(0, 6).map((row) => ({
      timeMs: row.timeMs,
      x: round(row.x, 2),
      y: round(row.y, 2),
      z: round(row.z, 2),
      inAscentBounds: isPlausibleAscentPoint(row),
    })),
  };
}

function passesPositionLaneGate(summary) {
  return (
    summary.count >= 30 &&
    summary.uniqueTimeCount >= 30 &&
    summary.uniquePositionCount >= 10 &&
    summary.sameTimeConflictCount === 0 &&
    summary.activeSpanMs >= 3000 &&
    summary.inAscentBoundsRate >= 0.9 &&
    summary.xySpan >= 300 &&
    summary.adjacentStepCount >= Math.min(20, summary.count - 2) &&
    summary.p90AdjacentSpeed != null &&
    summary.p90AdjacentSpeed <= 3000 &&
    summary.maxAdjacentSpeed != null &&
    summary.maxAdjacentSpeed <= 10_000 &&
    summary.largeAdjacentJumpCount === 0
  );
}

function laneRejectionReasons(summary) {
  const reasons = [];
  if (summary.count < 30) reasons.push('too-few-samples');
  if (summary.uniqueTimeCount < 30) reasons.push('too-few-unique-times');
  if (summary.uniquePositionCount < 10) reasons.push('too-few-unique-positions');
  if (summary.sameTimeConflictCount > 0) reasons.push('same-time-position-conflicts');
  if (summary.activeSpanMs < 3000) reasons.push('too-short-active-span');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-bounds');
  if (summary.xySpan < 300) reasons.push('low-xy-span');
  if (summary.adjacentStepCount < Math.min(20, summary.count - 2)) {
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

function splitByContinuity(rows) {
  const ordered = [...rows].sort((a, b) => a.timeMs - b.timeMs);
  const lanes = [];
  for (const row of ordered) {
    let best = null;
    for (const lane of lanes) {
      const previous = lane.rows.at(-1);
      const dtMs = row.timeMs - previous.timeMs;
      if (dtMs <= 0 || dtMs > 250) continue;
      const distance = Math.hypot(row.x - previous.x, row.y - previous.y);
      const speed = distance / (dtMs / 1000);
      if (distance <= 450 && speed <= 3500) {
        const score = distance + dtMs * 0.01;
        if (!best || score < best.score) best = { lane, score };
      }
    }
    if (best) best.lane.rows.push(row);
    else lanes.push({ rows: [row] });
  }
  return lanes
    .map((lane, laneIndex) => ({
      laneIndex,
      summary: summarizeSeries(lane.rows),
    }))
    .sort(
      (a, b) =>
        b.summary.count - a.summary.count ||
        b.summary.uniquePositionCount - a.summary.uniquePositionCount ||
        b.summary.xySpan - a.summary.xySpan,
    );
}

function specKey(spec) {
  return [
    spec.fieldHandle,
    spec.bitCount,
    spec.prefixHex,
    spec.offset,
    spec.scaleFactor,
    spec.componentBits,
    spec.extraInfo,
  ].join('|');
}

function specsFromStreamReport(streamReport, maxSpecs) {
  const specs = new Map();
  const addSpec = (candidate, sourceKind) => {
    if (!candidate) return;
    const spec = {
      fieldHandle: candidate.fieldHandle,
      fieldName: candidate.fieldName ?? null,
      bitCount: candidate.bitCount ?? candidate.payloadBitCount,
      prefixHex: candidate.prefixHex,
      offset: candidate.offset ?? candidate.vectorOffset,
      scaleFactor: candidate.scaleFactor ?? candidate.vectorEncoding?.scaleFactor,
      componentBits: candidate.componentBits ?? candidate.vectorEncoding?.componentBits,
      extraInfo: candidate.extraInfo ?? candidate.vectorEncoding?.extraInfo,
      sourceKind,
      sourceSummary: {
        groupCount: candidate.groupCount ?? null,
        count: candidate.count ?? candidate.joinedVectorSampleCount ?? null,
        uniquePositionCount: candidate.uniquePositionCount ?? null,
        xySpan: candidate.xySpan ?? null,
        p90Speed: candidate.p90Speed ?? null,
        netGuid: candidate.netGuid ?? null,
        guidOffset: candidate.guidOffset ?? null,
        guidBitCount: candidate.guidBitCount ?? null,
        relativeOffset: candidate.relativeOffset ?? null,
      },
    };
    if (
      !Number.isInteger(spec.fieldHandle) ||
      !Number.isInteger(spec.bitCount) ||
      !spec.prefixHex ||
      !Number.isInteger(spec.offset) ||
      !Number.isFinite(spec.scaleFactor) ||
      !Number.isInteger(spec.componentBits) ||
      !Number.isInteger(spec.extraInfo)
    ) {
      return;
    }
    const key = specKey(spec);
    const existing = specs.get(key);
    if (!existing || (!Number.isInteger(sourceNetGuid(existing)) && Number.isInteger(sourceNetGuid(spec)))) {
      specs.set(key, spec);
    }
  };

  for (const candidate of streamReport.largeVectorCandidates?.dynamicCandidates ?? []) {
    addSpec(candidate, 'large-dynamic');
  }
  for (const candidate of streamReport.largeVectorCandidates?.highCoverageCandidates ?? []) {
    addSpec(candidate, 'large-high-coverage');
  }
  for (const record of streamReport.decoderLeads?.guidVectorRecordCandidates ?? []) {
    for (const join of record.joins ?? []) {
      addSpec(
        {
          ...join,
          fieldHandle: record.fieldHandle,
          bitCount: record.payloadBitCount,
          prefixHex: record.prefixHex,
        },
        'guid-vector-record',
      );
    }
  }

  const sortedSpecs = [...specs.values()].sort((a, b) => {
    const countA = a.sourceSummary.count ?? 0;
    const countB = b.sourceSummary.count ?? 0;
    const p90A = a.sourceSummary.p90Speed ?? Infinity;
    const p90B = b.sourceSummary.p90Speed ?? Infinity;
    return countB - countA || p90A - p90B || a.fieldHandle - b.fieldHandle || a.offset - b.offset;
  });
  const limited = sortedSpecs.slice(0, maxSpecs);
  const identityAttributed = sortedSpecs.filter((spec) => Number.isInteger(sourceNetGuid(spec)));
  return [...new Map([...limited, ...identityAttributed].map((spec) => [specKey(spec), spec])).values()];
}

function reconstructSeries(spec, samples) {
  const rows = [];
  const prefixBits = Math.min(32, spec.bitCount);
  for (const sample of samples) {
    if (
      !sample.hasFullPayload ||
      sample.fieldHandle !== spec.fieldHandle ||
      sample.bitCount !== spec.bitCount ||
      bitsToHex(sample.buffer, 0, prefixBits) !== spec.prefixHex
    ) {
      continue;
    }
    if (!sampleMatchesSourceAnchor(sample, spec)) continue;
    const vector = vectorAt(sample, spec);
    if (!vector) continue;
    rows.push({
      timeMs: sample.timeMs,
      x: vector.x,
      y: vector.y,
      z: vector.z,
    });
  }
  return rows;
}

function analyzeSpec(spec, rows, openSamples) {
  const transformGroups = [
    { openSample: null, transformNames: ['raw'] },
    ...openSamples.map((openSample) => ({
      openSample,
      transformNames: TRANSFORMS.filter((name) => name !== 'raw'),
    })),
  ];
  const analyses = [];
  for (const group of transformGroups) {
    for (const transformName of group.transformNames) {
      const transformedRows = rows
        .map((row) => {
          const point = transformPoint(row, group.openSample, transformName);
          return point ? { timeMs: row.timeMs, ...point } : null;
        })
        .filter(Boolean);
      const lanes = splitByContinuity(transformedRows);
      const passingLanes = lanes.filter((lane) => passesPositionLaneGate(lane.summary));
      analyses.push({
        transform: transformName,
        openNetGuid: group.openSample?.netGuid ?? null,
        openArchetypePath: group.openSample?.archetypePath ?? null,
        passingLaneCount: passingLanes.length,
        passingLanes: passingLanes.slice(0, 6),
        bestLanes: lanes.slice(0, 8).map((lane) => ({
          ...lane,
          rejectionReasons: passesPositionLaneGate(lane.summary)
            ? []
            : laneRejectionReasons(lane.summary),
        })),
      });
    }
  }
  analyses.sort(
    (a, b) =>
      b.passingLaneCount - a.passingLaneCount ||
      (b.bestLanes[0]?.summary.count ?? 0) - (a.bestLanes[0]?.summary.count ?? 0) ||
      (b.bestLanes[0]?.summary.uniquePositionCount ?? 0) -
        (a.bestLanes[0]?.summary.uniquePositionCount ?? 0) ||
      (b.bestLanes[0]?.summary.xySpan ?? 0) - (a.bestLanes[0]?.summary.xySpan ?? 0),
  );
  return {
    key: specKey(spec),
    spec,
    sourceNetGuid: sourceNetGuid(spec),
    rawSampleCount: rows.length,
    passingTransforms: analyses.filter((analysis) => analysis.passingLaneCount > 0),
    bestTransform: analyses[0] ?? null,
  };
}

function analyzeDeinterleavedLargeVectors(diagnostics, streamReport, options) {
  const samples = parseCandidateFieldSamples(diagnostics);
  const openSamples = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const specs = specsFromStreamReport(streamReport, options.maxSpecs);
  const analyzed = [];
  for (const spec of specs) {
    const rows = reconstructSeries(spec, samples);
    if (rows.length < options.minRows && !Number.isInteger(sourceNetGuid(spec))) continue;
    if (rows.length < 3) continue;
    analyzed.push(analyzeSpec(spec, rows, openSamples));
  }
  analyzed.sort(
    (a, b) =>
      Number(b.passingTransforms.length > 0) - Number(a.passingTransforms.length > 0) ||
      b.rawSampleCount - a.rawSampleCount ||
      (b.bestTransform?.bestLanes[0]?.summary.count ?? 0) -
        (a.bestTransform?.bestLanes[0]?.summary.count ?? 0),
  );
  const passingCandidates = analyzed.filter((entry) => entry.passingTransforms.length > 0);
  const identityAttributedCandidates = analyzed.filter((entry) => Number.isInteger(entry.sourceNetGuid));
  const rejectedCandidates = analyzed.filter((entry) => entry.passingTransforms.length === 0);
  const bestRejectedCandidates = [
    ...new Map(
      [...rejectedCandidates.slice(0, 60), ...identityAttributedCandidates]
        .filter((entry) => entry.passingTransforms.length === 0)
        .map((entry) => [entry.key, entry]),
    ).values(),
  ];
  return {
    generatedAt: new Date().toISOString(),
    options: {
      maxSpecs: options.maxSpecs,
      minRows: options.minRows,
      transforms: TRANSFORMS,
    },
    notes: [
      'Tests whether high-volume packed-vector candidates are mixed multi-entity streams that become plausible after greedy continuity deinterleaving.',
      'Passing lanes are still position-like decoder leads only; this report does not prove NetGUID or view-yaw attribution.',
    ],
    source: {
      candidateFieldSampleCount: diagnostics.frameSummary?.replayControllerCandidateFieldSamples?.length ?? null,
      movementRpcHitCount: diagnostics.frameSummary?.movementRpcHitCount ?? null,
      playerOpenSampleCount: openSamples.length,
      specCount: specs.length,
      analyzedSpecCount: analyzed.length,
      identityAttributedCandidateCount: identityAttributedCandidates.length,
      passingCandidateCount: passingCandidates.length,
    },
    status:
      passingCandidates.length > 0
        ? 'deinterleaved large-vector position-like lanes found; inspect before promotion'
        : 'no deinterleaved large-vector transform produced a strict position-like lane',
    passingCandidates,
    identityAttributedCandidates,
    bestRejectedCandidates,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const streamReportPath = resolveUserPath(options.streamReport);
  if (!diagnosticsPath || !streamReportPath) {
    console.error(
      'usage: node analyze_deinterleaved_large_vectors.mjs --diagnostics replay.diagnostics.json --stream-report replay_controller_streams.report.json --out deinterleaved_large_vectors.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const streamReport = JSON.parse(fs.readFileSync(streamReportPath, 'utf8'));
  const report = analyzeDeinterleavedLargeVectors(diagnostics, streamReport, options);
  report.input = {
    diagnostics: diagnosticsPath,
    streamReport: streamReportPath,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main();
