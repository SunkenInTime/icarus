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
    maxSpecs: 180,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--stream-report') options.streamReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--max-specs') options.maxSpecs = Number(argv[++index]);
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
    firstSamples: ordered.slice(0, 8).map((row) => ({
      timeMs: row.timeMs,
      x: round(row.x, 2),
      y: round(row.y, 2),
      z: round(row.z, 2),
      inAscentBounds: isPlausibleAscentPoint(row),
    })),
  };
}

function passesTrackGate(summary) {
  return (
    summary.count >= 40 &&
    summary.uniqueTimeCount >= 40 &&
    summary.uniquePositionCount >= 20 &&
    summary.sameTimeConflictCount === 0 &&
    summary.activeSpanMs >= 5000 &&
    summary.inAscentBoundsRate >= 0.9 &&
    summary.xySpan >= 300 &&
    summary.adjacentStepCount >= Math.min(30, summary.count - 2) &&
    summary.p90AdjacentSpeed != null &&
    summary.p90AdjacentSpeed <= 3000 &&
    summary.maxAdjacentSpeed != null &&
    summary.maxAdjacentSpeed <= 10_000 &&
    summary.largeAdjacentJumpCount === 0
  );
}

function sourceNetGuid(spec) {
  const netGuid = spec.sourceSummary?.netGuid;
  return Number.isInteger(netGuid) ? netGuid : null;
}

function transformUsesMatchingIdentity(spec, transform) {
  const netGuid = sourceNetGuid(spec);
  if (!Number.isInteger(netGuid)) return false;
  if (transform.transform === 'raw') return true;
  return transform.openNetGuid === netGuid;
}

function promotionRejectionReasons(spec, transform) {
  const reasons = [];
  if (!transform.passesTrackGate) reasons.push('position-gate-failed');
  if (!Number.isInteger(sourceNetGuid(spec))) reasons.push('missing-source-net-guid');
  if (!transformUsesMatchingIdentity(spec, transform)) reasons.push('transform-net-guid-mismatch');
  if (!transform.yawOverlap) reasons.push('missing-yaw-overlap');
  else {
    if (transform.yawOverlap.within33Rate < 0.5) reasons.push('weak-temporal-yaw-overlap');
    if (transform.yawOverlap.medianNearestYawMs > 50) reasons.push('yaw-samples-too-far-away');
  }
  return reasons;
}

function passesReplayTrackPromotionGate(spec, transform) {
  return promotionRejectionReasons(spec, transform).length === 0;
}

function gateRejectionReasons(summary) {
  const reasons = [];
  if (summary.count < 40) reasons.push('too-few-samples');
  if (summary.uniqueTimeCount < 40) reasons.push('too-few-unique-times');
  if (summary.uniquePositionCount < 20) reasons.push('too-few-unique-positions');
  if (summary.sameTimeConflictCount > 0) reasons.push('same-time-position-conflicts');
  if (summary.activeSpanMs < 5000) reasons.push('too-short-active-span');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-bounds');
  if (summary.xySpan < 300) reasons.push('low-xy-span');
  if (summary.adjacentStepCount < Math.min(30, summary.count - 2)) {
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

  const sortedSpecs = [...specs.values()]
    .sort((a, b) => {
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

function nearestDelta(sortedTimes, value) {
  if (!sortedTimes.length) return null;
  let low = 0;
  let high = sortedTimes.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (sortedTimes[middle] < value) low = middle + 1;
    else high = middle;
  }
  let best = Infinity;
  if (low < sortedTimes.length) best = Math.min(best, Math.abs(sortedTimes[low] - value));
  if (low > 0) best = Math.min(best, Math.abs(sortedTimes[low - 1] - value));
  return best === Infinity ? null : best;
}

function summarizeYawOverlap(rows, yawTimes) {
  const deltas = rows.map((row) => nearestDelta(yawTimes, row.timeMs)).filter((value) => value != null);
  if (!deltas.length) return null;
  const within16 = deltas.filter((delta) => delta <= 16).length;
  const within33 = deltas.filter((delta) => delta <= 33).length;
  return {
    comparedCount: deltas.length,
    within16Rate: round(within16 / deltas.length),
    within33Rate: round(within33 / deltas.length),
    medianNearestYawMs: round(percentile(deltas, 0.5), 0),
    p90NearestYawMs: round(percentile(deltas, 0.9), 0),
  };
}

function yawTimesFromDiagnostics(samples) {
  return samples
    .filter((sample) => sample.fieldHandle === 122 && sample.bitCount === 92)
    .map((sample) => sample.timeMs)
    .sort((a, b) => a - b);
}

function analyzeSpec(spec, rows, openSamples, yawTimes) {
  const rawGroups = [
    {
      openSample: null,
      transformNames: ['raw'],
    },
    ...openSamples.map((openSample) => ({
      openSample,
      transformNames: TRANSFORMS.filter((name) => name !== 'raw'),
    })),
  ];

  const transforms = [];
  for (const group of rawGroups) {
    for (const transformName of group.transformNames) {
      const transformedRows = rows
        .map((row) => {
          const point = transformPoint(row, group.openSample, transformName);
          return point ? { timeMs: row.timeMs, ...point } : null;
        })
        .filter(Boolean);
      const summary = summarizeSeries(transformedRows);
      const passes = passesTrackGate(summary);
      transforms.push({
        transform: transformName,
        openNetGuid: group.openSample?.netGuid ?? null,
        openArchetypePath: group.openSample?.archetypePath ?? null,
        passesTrackGate: passes,
        rejectionReasons: passes ? [] : gateRejectionReasons(summary),
        yawOverlap: summarizeYawOverlap(transformedRows, yawTimes),
        summary,
      });
    }
  }

  for (const transform of transforms) {
    transform.passesReplayTrackPromotionGate = passesReplayTrackPromotionGate(spec, transform);
    transform.promotionRejectionReasons = transform.passesReplayTrackPromotionGate
      ? []
      : promotionRejectionReasons(spec, transform);
  }

  transforms.sort(
    (a, b) =>
      Number(b.passesReplayTrackPromotionGate) - Number(a.passesReplayTrackPromotionGate) ||
      Number(b.passesTrackGate) - Number(a.passesTrackGate) ||
      b.summary.count - a.summary.count ||
      b.summary.uniquePositionCount - a.summary.uniquePositionCount ||
      (a.summary.p90AdjacentSpeed ?? Infinity) - (b.summary.p90AdjacentSpeed ?? Infinity),
  );

  return {
    key: specKey(spec),
    spec,
    rawSampleCount: rows.length,
    bestTransform: transforms[0] ?? null,
    sourceNetGuid: sourceNetGuid(spec),
    promotableTransforms: transforms.filter((transform) => transform.passesReplayTrackPromotionGate),
    passingTransforms: transforms.filter((transform) => transform.passesTrackGate),
    rejectedTransforms: transforms.filter((transform) => !transform.passesTrackGate).slice(0, 8),
  };
}

function analyzeLargePayloadTransformHypotheses(diagnostics, streamReport, options) {
  const samples = parseCandidateFieldSamples(diagnostics);
  const openSamples = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const yawTimes = yawTimesFromDiagnostics(samples);
  const specs = specsFromStreamReport(streamReport, options.maxSpecs);
  const analyzed = [];
  for (const spec of specs) {
    const rows = reconstructSeries(spec, samples);
    if (rows.length < 3) continue;
    analyzed.push(analyzeSpec(spec, rows, openSamples, yawTimes));
  }

  analyzed.sort(
    (a, b) =>
      Number(b.passingTransforms.length > 0) - Number(a.passingTransforms.length > 0) ||
      b.rawSampleCount - a.rawSampleCount ||
      (a.bestTransform?.summary.p90AdjacentSpeed ?? Infinity) -
        (b.bestTransform?.summary.p90AdjacentSpeed ?? Infinity),
  );

  const passingGroups = analyzed.filter((entry) => entry.passingTransforms.length > 0);
  const promotableGroups = analyzed.filter((entry) => entry.promotableTransforms.length > 0);
  const identityAttributedGroups = analyzed.filter((entry) => Number.isInteger(entry.sourceNetGuid));
  return {
    generatedAt: new Date().toISOString(),
    options: {
      maxSpecs: options.maxSpecs,
      transforms: TRANSFORMS,
    },
    notes: [
      'Reconstructs recurring packed-vector candidates from large ReplayController payload families and tests raw plus player-open-relative transforms.',
      'The position track gate requires map bounds, short-step speed, and enough adjacent samples; it does not prove player identity by itself.',
      'The replay-track promotion gate also requires a source NetGUID, matching spawn-relative transform identity when applicable, and close temporal overlap with handle-122 yaw samples.',
      'A position-gate passing group is still a decoder lead until view yaw and NetGUID attribution are tied to the same native record.',
    ],
    source: {
      rawPacketsScanned: diagnostics.frameSummary?.rawPacketsScanned ?? null,
      movementRpcHitCount: diagnostics.frameSummary?.movementRpcHitCount ?? null,
      candidateFieldSampleCount: diagnostics.frameSummary?.replayControllerCandidateFieldSamples?.length ?? null,
      playerOpenSampleCount: openSamples.length,
      yawSampleTimeCount: yawTimes.length,
      specCount: specs.length,
      analyzedSpecCount: analyzed.length,
      identityAttributedSpecCount: specs.filter((spec) => Number.isInteger(sourceNetGuid(spec))).length,
      analyzedIdentityAttributedSpecCount: identityAttributedGroups.length,
    },
    status:
      promotableGroups.length > 0
        ? 'large payload transform hypotheses passed the replay-track promotion gate; inspect before emission'
        : passingGroups.length > 0
          ? 'position-like large payload transforms found, but none pass NetGUID/view-yaw promotion gate'
        : 'no large payload transform hypothesis passed the strict continuous world-track gate',
    promotableGroups,
    passingGroups,
    bestIdentityAttributedGroups: identityAttributedGroups.slice(0, 60),
    bestRejectedGroups: analyzed.filter((entry) => entry.passingTransforms.length === 0).slice(0, 60),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const streamReportPath = resolveUserPath(options.streamReport);
  if (!diagnosticsPath || !streamReportPath) {
    console.error(
      'usage: node analyze_large_payload_transform_hypotheses.mjs --diagnostics replay.diagnostics.json --stream-report replay_controller_streams.report.json --out large_payload_transform_hypotheses.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const streamReport = JSON.parse(fs.readFileSync(streamReportPath, 'utf8'));
  const report = analyzeLargePayloadTransformHypotheses(diagnostics, streamReport, options);
  report.input = {
    diagnostics: diagnosticsPath,
    streamReport: streamReportPath,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main();
