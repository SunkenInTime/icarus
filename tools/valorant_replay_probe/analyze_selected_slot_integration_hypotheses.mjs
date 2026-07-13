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

const AXIS_VARIANTS = ['xyz', 'swapxy', 'negxy', 'negx', 'negy'];
const Z_MODES = ['use', 'ignore'];
const ROTATION_MODES = ['none', 'open-yaw', 'nearest-handle122-netguid'];
const INTEGRATION_MODES = ['delta', 'velocity-actual-dt', 'velocity-capped-dt'];
const GAP_POLICIES = ['continuous', 'reset-long-gap'];

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    decoderReport: null,
    yawSamples: null,
    out: null,
    minSamples: 40,
    minUniquePositions: 25,
    minWorldXySpan: 600,
    maxP90Speed3d: 5_500,
    maxSpeed3d: 14_000,
    maxP90ZStep: 140,
    maxZStep: 500,
    strictMaxP90Speed3d: 2_500,
    strictMaxSpeed3d: 5_000,
    strictMaxP90ZStep: 35,
    strictMaxZStep: 120,
    maxYawDeltaMs: 64,
    resetGapMs: 1000,
    cappedDtMs: 250,
    scaleMultipliers: [0.01, 0.1, 1, 10, 100, 1000],
    maxCandidatesPerSeries: 40,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--decoder-report') options.decoderReport = argv[++index];
    else if (arg === '--yaw-samples') options.yawSamples = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--min-samples') options.minSamples = Number(argv[++index]);
    else if (arg === '--min-unique-positions') {
      options.minUniquePositions = Number(argv[++index]);
    } else if (arg === '--min-world-xy-span') {
      options.minWorldXySpan = Number(argv[++index]);
    } else if (arg === '--max-p90-speed3d') {
      options.maxP90Speed3d = Number(argv[++index]);
    } else if (arg === '--max-speed3d') {
      options.maxSpeed3d = Number(argv[++index]);
    } else if (arg === '--max-p90-z-step') {
      options.maxP90ZStep = Number(argv[++index]);
    } else if (arg === '--max-z-step') {
      options.maxZStep = Number(argv[++index]);
    } else if (arg === '--strict-max-p90-speed3d') {
      options.strictMaxP90Speed3d = Number(argv[++index]);
    } else if (arg === '--strict-max-speed3d') {
      options.strictMaxSpeed3d = Number(argv[++index]);
    } else if (arg === '--strict-max-p90-z-step') {
      options.strictMaxP90ZStep = Number(argv[++index]);
    } else if (arg === '--strict-max-z-step') {
      options.strictMaxZStep = Number(argv[++index]);
    } else if (arg === '--max-yaw-delta-ms') {
      options.maxYawDeltaMs = Number(argv[++index]);
    } else if (arg === '--reset-gap-ms') {
      options.resetGapMs = Number(argv[++index]);
    } else if (arg === '--capped-dt-ms') {
      options.cappedDtMs = Number(argv[++index]);
    } else if (arg === '--scale-multipliers') {
      options.scaleMultipliers = argv[++index].split(',').map(Number).filter(Number.isFinite);
    } else if (arg === '--max-candidates-per-series') {
      options.maxCandidatesPerSeries = Number(argv[++index]);
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
  const index = Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * fraction)));
  return sorted[index];
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
    if (this.isError) return null;
    const componentBits = bitsAndInfo & 63;
    const extraInfo = bitsAndInfo >> 6;
    if (componentBits < 7 || componentBits > 24) return null;
    if (!this.canRead(componentBits * 3)) return null;
    const vector = {
      bitsAndInfo,
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

function selectedFamilies(decoderReport) {
  return (decoderReport.familyReports ?? [])
    .map((entry) => entry.family)
    .filter(Boolean)
    .map((family) => ({
      fieldHandle: family.fieldHandle,
      payloadBitCount: family.payloadBitCount,
      prefixHex: family.prefixHex,
      slotIndex: family.slotIndex,
      slotNetGuid: family.slotNetGuid,
      slotChIndex: family.slotChIndex,
      headerBits: family.headerBits,
      recordBits: family.recordBits,
      relativeOffset: family.relativeOffset,
      absoluteOffset: family.absoluteOffset,
      scaleFactor: family.scaleFactor,
      componentBits: family.componentBits,
      extraInfo: family.extraInfo,
    }));
}

function samplesForFamily(samples, family) {
  return samples.filter(
    (sample) =>
      sample.fieldHandle === family.fieldHandle &&
      sample.bitCount === family.payloadBitCount &&
      bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)) === family.prefixHex,
  );
}

function vectorAt(sample, bitOffset) {
  const reader = new BitCursor(sample.buffer, sample.bitCount, bitOffset);
  return reader.readPackedVectorRaw();
}

function scaleRawVector(vector, scaleFactor) {
  const scale = vector.extraInfo ? scaleFactor : 1;
  return {
    x: vector.xSigned / scale,
    y: vector.ySigned / scale,
    z: vector.zSigned / scale,
  };
}

function targetVectorRows(groupSamples, family) {
  const absoluteOffset = family.headerBits + family.slotIndex * family.recordBits + family.relativeOffset;
  return groupSamples
    .map((sample) => {
      const vector = vectorAt(sample, absoluteOffset);
      if (!vector) return null;
      if (vector.componentBits !== family.componentBits || vector.extraInfo !== family.extraInfo) {
        return null;
      }
      return {
        timeMs: sample.timeMs,
        sampleIndex: sample.sampleIndex,
        prefixHex: family.prefixHex,
        rawVector: vector,
        vector: scaleRawVector(vector, family.scaleFactor),
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
}

function familyLabel(family) {
  return `h${family.fieldHandle}/${family.payloadBitCount}/${family.prefixHex}/slot${family.slotIndex}`;
}

function seriesKeyWithoutPrefix(family) {
  return [
    family.fieldHandle,
    family.payloadBitCount,
    family.slotIndex,
    family.relativeOffset,
    family.scaleFactor,
    family.componentBits,
    family.extraInfo,
  ].join('|');
}

function buildSeriesReports(families, samples) {
  const individual = families.map((family) => ({
    kind: 'individual-prefix',
    label: familyLabel(family),
    family,
    prefixes: [family.prefixHex],
    rows: targetVectorRows(samplesForFamily(samples, family), family),
  }));

  const groups = new Map();
  for (const entry of individual) {
    const key = seriesKeyWithoutPrefix(entry.family);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(entry);
  }

  const merged = [];
  for (const entries of groups.values()) {
    if (entries.length < 2) continue;
    const [first] = entries;
    merged.push({
      kind: 'merged-prefixes',
      label: `${familyLabel(first.family).replace(`/${first.family.prefixHex}/`, '/merged-prefixes/')}`,
      family: { ...first.family, prefixHex: entries.map((entry) => entry.family.prefixHex).join('+') },
      prefixes: entries.map((entry) => entry.family.prefixHex),
      rows: entries
        .flatMap((entry) => entry.rows)
        .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex),
    });
  }

  return [...individual, ...merged];
}

function loadYawSamplesByNetGuid(yawSamplesPath) {
  if (!yawSamplesPath) return new Map();
  const yawReport = JSON.parse(fs.readFileSync(yawSamplesPath, 'utf8'));
  const byNetGuid = new Map();
  for (const lane of yawReport.lanes ?? []) {
    const netGuid = lane.candidateIdentity?.netGuid;
    if (!Number.isInteger(netGuid)) continue;
    if (!byNetGuid.has(netGuid)) byNetGuid.set(netGuid, []);
    for (const sample of lane.samples ?? []) {
      const yawDegrees =
        sample.viewRotation?.yawDegrees360 ?? sample.viewRotation?.yawDegrees ?? null;
      if (!Number.isFinite(yawDegrees)) continue;
      byNetGuid.get(netGuid).push({
        timeMs: sample.timeMs,
        yawDegrees,
        prefixHex: lane.prefixHex,
        confidence: lane.candidateIdentity?.confidence ?? null,
      });
    }
  }
  for (const rows of byNetGuid.values()) {
    rows.sort((a, b) => a.timeMs - b.timeMs || a.prefixHex.localeCompare(b.prefixHex));
  }
  return byNetGuid;
}

function nearestByTime(rows, targetTimeMs) {
  if (!rows?.length) return null;
  let low = 0;
  let high = rows.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (rows[middle].timeMs < targetTimeMs) low = middle + 1;
    else high = middle;
  }
  let best = null;
  for (const index of [low - 1, low]) {
    if (index < 0 || index >= rows.length) continue;
    const deltaMs = Math.abs(rows[index].timeMs - targetTimeMs);
    if (!best || deltaMs < best.deltaMs) best = { row: rows[index], deltaMs };
  }
  return best;
}

function applyAxisVariant(vector, axisVariant) {
  if (axisVariant === 'xyz') return { ...vector };
  if (axisVariant === 'swapxy') return { x: vector.y, y: vector.x, z: vector.z };
  if (axisVariant === 'negxy') return { x: -vector.x, y: -vector.y, z: vector.z };
  if (axisVariant === 'negx') return { x: -vector.x, y: vector.y, z: vector.z };
  if (axisVariant === 'negy') return { x: vector.x, y: -vector.y, z: vector.z };
  throw new Error(`unknown axis variant: ${axisVariant}`);
}

function rotateVector(vector, yawDegrees) {
  const radians = (yawDegrees * Math.PI) / 180;
  const cos = Math.cos(radians);
  const sin = Math.sin(radians);
  return {
    x: vector.x * cos - vector.y * sin,
    y: vector.x * sin + vector.y * cos,
    z: vector.z,
  };
}

function rotationForRow(row, series, slotOpenSample, yawSamplesByNetGuid, hypothesis, options) {
  if (hypothesis.rotationMode === 'none') return { yawDegrees: null, yawDeltaMs: null, yawPrefixHex: null };
  if (hypothesis.rotationMode === 'open-yaw') {
    if (!Number.isFinite(slotOpenSample?.yaw)) return null;
    return { yawDegrees: slotOpenSample.yaw, yawDeltaMs: null, yawPrefixHex: null };
  }
  if (hypothesis.rotationMode === 'nearest-handle122-netguid') {
    const yawRows = yawSamplesByNetGuid.get(series.family.slotNetGuid) ?? [];
    const nearest = nearestByTime(yawRows, row.timeMs);
    if (!nearest || nearest.deltaMs > options.maxYawDeltaMs) return null;
    return {
      yawDegrees: nearest.row.yawDegrees,
      yawDeltaMs: nearest.deltaMs,
      yawPrefixHex: nearest.row.prefixHex,
    };
  }
  throw new Error(`unknown rotation mode: ${hypothesis.rotationMode}`);
}

function hypothesisVector(row, series, slotOpenSample, yawSamplesByNetGuid, hypothesis, options) {
  let vector = applyAxisVariant(row.vector, hypothesis.axisVariant);
  const rotation = rotationForRow(row, series, slotOpenSample, yawSamplesByNetGuid, hypothesis, options);
  if (!rotation) return null;
  if (Number.isFinite(rotation.yawDegrees)) vector = rotateVector(vector, rotation.yawDegrees);
  if (hypothesis.zMode === 'ignore') vector = { ...vector, z: 0 };
  return { vector, rotation };
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

function integrationScale(row, previousTimeMs, hypothesis, options) {
  if (hypothesis.integrationMode === 'delta') return hypothesis.scaleMultiplier;
  if (previousTimeMs == null) return 0;
  const dtMs = Math.max(0, row.timeMs - previousTimeMs);
  const effectiveDtMs =
    hypothesis.integrationMode === 'velocity-capped-dt' ? Math.min(dtMs, options.cappedDtMs) : dtMs;
  return (effectiveDtMs / 1000) * hypothesis.scaleMultiplier;
}

function integrateSeries(series, slotOpenSample, yawSamplesByNetGuid, hypothesis, options) {
  if (!slotOpenSample?.location) return { rows: [], skippedForYawCount: 0, resetCount: 0 };

  let position = { ...slotOpenSample.location };
  let previousTimeMs = null;
  let skippedForYawCount = 0;
  let resetCount = 0;
  let integratedLongGapCount = 0;
  const rows = [];

  for (const row of series.rows) {
    const gapMs = previousTimeMs == null ? null : row.timeMs - previousTimeMs;
    if (
      previousTimeMs != null &&
      hypothesis.gapPolicy === 'reset-long-gap' &&
      gapMs > options.resetGapMs
    ) {
      position = { ...slotOpenSample.location };
      previousTimeMs = null;
      resetCount += 1;
    } else if (
      previousTimeMs != null &&
      hypothesis.integrationMode === 'velocity-actual-dt' &&
      gapMs > options.resetGapMs
    ) {
      integratedLongGapCount += 1;
    }

    const decoded = hypothesisVector(row, series, slotOpenSample, yawSamplesByNetGuid, hypothesis, options);
    if (!decoded) {
      skippedForYawCount += 1;
      continue;
    }

    const scale = integrationScale(row, previousTimeMs, hypothesis, options);
    position = {
      x: position.x + decoded.vector.x * scale,
      y: position.y + decoded.vector.y * scale,
      z: position.z + decoded.vector.z * scale,
    };
    rows.push({
      timeMs: row.timeMs,
      x: position.x,
      y: position.y,
      z: position.z,
      yawDeltaMs: decoded.rotation.yawDeltaMs,
      yawPrefixHex: decoded.rotation.yawPrefixHex,
    });
    previousTimeMs = row.timeMs;
  }

  return { rows, skippedForYawCount, resetCount, integratedLongGapCount };
}

function summarizeRows(rows, slotOpenSample, integrationStats) {
  const ordered = [...rows].sort((a, b) => a.timeMs - b.timeMs);
  const uniquePositions = new Set();
  const uniqueTimes = new Set();
  const dts = [];
  const steps2d = [];
  const steps3d = [];
  const speeds2d = [];
  const speeds3d = [];
  const zSteps = [];
  const yawDeltas = [];
  let inBoundsCount = 0;
  let longGapCount = 0;
  let sameTimeConflictCount = 0;
  const byTime = new Map();
  const xs = [];
  const ys = [];
  const zs = [];
  let path2d = 0;
  let path3d = 0;

  for (const row of ordered) {
    xs.push(row.x);
    ys.push(row.y);
    zs.push(row.z);
    uniqueTimes.add(row.timeMs);
    if (Number.isFinite(row.yawDeltaMs)) yawDeltas.push(row.yawDeltaMs);
    const key = `${Math.round(row.x)}:${Math.round(row.y)}:${Math.round(row.z)}`;
    uniquePositions.add(key);
    if (byTime.has(row.timeMs) && byTime.get(row.timeMs) !== key) sameTimeConflictCount += 1;
    byTime.set(row.timeMs, key);
    if (isPlausibleAscentPoint(row)) inBoundsCount += 1;
  }

  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs > 1000) longGapCount += 1;
    const step2d = Math.hypot(current.x - previous.x, current.y - previous.y);
    const step3d = Math.hypot(current.x - previous.x, current.y - previous.y, current.z - previous.z);
    path2d += step2d;
    path3d += step3d;
    if (dtMs <= 250) {
      steps2d.push(step2d);
      steps3d.push(step3d);
      speeds2d.push(step2d / (dtMs / 1000));
      speeds3d.push(step3d / (dtMs / 1000));
      zSteps.push(Math.abs(current.z - previous.z));
    }
  }

  const xSpan = xs.length ? Math.max(...xs) - Math.min(...xs) : 0;
  const ySpan = ys.length ? Math.max(...ys) - Math.min(...ys) : 0;
  const zSpan = zs.length ? Math.max(...zs) - Math.min(...zs) : 0;
  const first = ordered[0] ?? null;
  const last = ordered.at(-1) ?? null;
  const open = slotOpenSample?.location ?? null;

  return {
    count: ordered.length,
    skippedForYawCount: integrationStats.skippedForYawCount,
    resetCount: integrationStats.resetCount,
    integratedLongGapCount: integrationStats.integratedLongGapCount,
    firstTimeMs: first?.timeMs ?? null,
    lastTimeMs: last?.timeMs ?? null,
    activeSpanMs: ordered.length ? last.timeMs - first.timeMs : 0,
    uniqueTimeCount: uniqueTimes.size,
    uniquePositionCount: uniquePositions.size,
    sameTimeConflictCount,
    inAscentBoundsRate: ordered.length ? round(inBoundsCount / ordered.length) : 0,
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
    path2d: round(path2d, 2),
    path3d: round(path3d, 2),
    displacement2d: first && last ? round(Math.hypot(last.x - first.x, last.y - first.y), 2) : null,
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    longGapCount,
    adjacentStepCount: speeds3d.length,
    p90Adjacent2dSpeed: round(percentile(speeds2d, 0.9), 1),
    maxAdjacent2dSpeed: round(speeds2d.length ? Math.max(...speeds2d) : null, 1),
    p90Adjacent3dSpeed: round(percentile(speeds3d, 0.9), 1),
    maxAdjacent3dSpeed: round(speeds3d.length ? Math.max(...speeds3d) : null, 1),
    p90Adjacent2dStepDistance: round(percentile(steps2d, 0.9), 2),
    p90Adjacent3dStepDistance: round(percentile(steps3d, 0.9), 2),
    p90AdjacentZStep: round(percentile(zSteps, 0.9), 2),
    maxAdjacentZStep: round(zSteps.length ? Math.max(...zSteps) : null, 2),
    yawDeltaMs: yawDeltas.length
      ? {
          count: yawDeltas.length,
          median: round(percentile(yawDeltas, 0.5), 0),
          p90: round(percentile(yawDeltas, 0.9), 0),
          max: round(Math.max(...yawDeltas), 0),
        }
      : null,
    openReference:
      first && open
        ? {
            openTimeMs: slotOpenSample.timeMs,
            firstSampleTimeMs: first.timeMs,
            deltaTimeMs: first.timeMs - slotOpenSample.timeMs,
            firstDistance2d: round(Math.hypot(first.x - open.x, first.y - open.y), 2),
            lastDistance2d: last ? round(Math.hypot(last.x - open.x, last.y - open.y), 2) : null,
          }
        : null,
    samples: ordered.slice(0, 6).map((row) => ({
      timeMs: row.timeMs,
      x: round(row.x, 2),
      y: round(row.y, 2),
      z: round(row.z, 2),
      inAscentBounds: isPlausibleAscentPoint(row),
      yawDeltaMs: row.yawDeltaMs ?? null,
      yawPrefixHex: row.yawPrefixHex ?? null,
    })),
  };
}

function integrationRejectionReasons(summary, options) {
  const reasons = [];
  if (summary.count < options.minSamples) reasons.push('too-few-samples');
  if (summary.uniqueTimeCount < options.minSamples) reasons.push('too-few-unique-times');
  if (summary.uniquePositionCount < options.minUniquePositions) reasons.push('too-few-unique-positions');
  if (summary.sameTimeConflictCount > 0) reasons.push('same-time-position-conflicts');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-or-z-bounds');
  if (summary.xySpan < options.minWorldXySpan) reasons.push('low-world-xy-span');
  if (summary.adjacentStepCount < Math.min(16, summary.count - 2)) {
    reasons.push('too-few-adjacent-steps');
  }
  if (summary.p90Adjacent3dSpeed == null || summary.p90Adjacent3dSpeed > options.maxP90Speed3d) {
    reasons.push('high-or-missing-p90-3d-speed');
  }
  if (summary.maxAdjacent3dSpeed == null || summary.maxAdjacent3dSpeed > options.maxSpeed3d) {
    reasons.push('high-or-missing-max-3d-speed');
  }
  if (summary.p90AdjacentZStep == null || summary.p90AdjacentZStep > options.maxP90ZStep) {
    reasons.push('large-or-missing-p90-z-step');
  }
  if (summary.maxAdjacentZStep == null || summary.maxAdjacentZStep > options.maxZStep) {
    reasons.push('large-or-missing-max-z-step');
  }
  return reasons;
}

function summarizeViewYawCoverage(rows, yawRows, options) {
  if (!yawRows?.length) {
    return {
      candidateNetGuidYawSampleCount: 0,
      matchedWithinMaxDeltaCount: 0,
      matchedWithinMaxDeltaRate: 0,
      maxDeltaMs: options.maxYawDeltaMs,
      deltaMs: null,
      topPrefixes: [],
    };
  }

  const deltas = [];
  const prefixCounts = new Map();
  for (const row of rows) {
    const nearest = nearestByTime(yawRows, row.timeMs);
    if (!nearest || nearest.deltaMs > options.maxYawDeltaMs) continue;
    deltas.push(nearest.deltaMs);
    prefixCounts.set(nearest.row.prefixHex, (prefixCounts.get(nearest.row.prefixHex) ?? 0) + 1);
  }
  return {
    candidateNetGuidYawSampleCount: yawRows.length,
    matchedWithinMaxDeltaCount: deltas.length,
    matchedWithinMaxDeltaRate: rows.length ? round(deltas.length / rows.length) : 0,
    maxDeltaMs: options.maxYawDeltaMs,
    deltaMs: deltas.length
      ? {
          median: round(percentile(deltas, 0.5), 0),
          p90: round(percentile(deltas, 0.9), 0),
          max: round(Math.max(...deltas), 0),
        }
      : null,
    topPrefixes: [...prefixCounts.entries()]
      .map(([prefixHex, count]) => ({ prefixHex, count }))
      .sort((a, b) => b.count - a.count || a.prefixHex.localeCompare(b.prefixHex))
      .slice(0, 6),
  };
}

function strictIntegrationRejectionReasons(summary, hypothesis, options, shapeRejectionReasons) {
  const reasons = [...shapeRejectionReasons];
  if (
    hypothesis.integrationMode === 'velocity-actual-dt' &&
    summary.integratedLongGapCount > 0
  ) {
    reasons.push('velocity-integrated-across-long-gaps');
  }
  if (
    summary.p90Adjacent3dSpeed == null ||
    summary.p90Adjacent3dSpeed > options.strictMaxP90Speed3d
  ) {
    reasons.push('strict-high-or-missing-p90-3d-speed');
  }
  if (
    summary.maxAdjacent3dSpeed == null ||
    summary.maxAdjacent3dSpeed > options.strictMaxSpeed3d
  ) {
    reasons.push('strict-high-or-missing-max-3d-speed');
  }
  if (summary.p90AdjacentZStep == null || summary.p90AdjacentZStep > options.strictMaxP90ZStep) {
    reasons.push('strict-large-or-missing-p90-z-step');
  }
  if (summary.maxAdjacentZStep == null || summary.maxAdjacentZStep > options.strictMaxZStep) {
    reasons.push('strict-large-or-missing-max-z-step');
  }
  return [...new Set(reasons)];
}

function buildHypotheses(options, hasYawSamples) {
  const hypotheses = [];
  for (const integrationMode of INTEGRATION_MODES) {
    for (const gapPolicy of GAP_POLICIES) {
      for (const axisVariant of AXIS_VARIANTS) {
        for (const zMode of Z_MODES) {
          for (const rotationMode of ROTATION_MODES) {
            if (rotationMode === 'nearest-handle122-netguid' && !hasYawSamples) continue;
            for (const scaleMultiplier of options.scaleMultipliers) {
              hypotheses.push({
                integrationMode,
                gapPolicy,
                axisVariant,
                zMode,
                rotationMode,
                scaleMultiplier,
              });
            }
          }
        }
      }
    }
  }
  return hypotheses;
}

function analyzeHypothesis(series, slotOpenSample, yawSamplesByNetGuid, hypothesis, options) {
  const integration = integrateSeries(series, slotOpenSample, yawSamplesByNetGuid, hypothesis, options);
  const summary = {
    ...summarizeRows(integration.rows, slotOpenSample, integration),
    viewYawCoverage: summarizeViewYawCoverage(
      integration.rows,
      yawSamplesByNetGuid.get(series.family.slotNetGuid) ?? [],
      options,
    ),
  };
  const rejectionReasons = integrationRejectionReasons(summary, options);
  const strictRejectionReasons = strictIntegrationRejectionReasons(
    summary,
    hypothesis,
    options,
    rejectionReasons,
  );
  const passesIntegrationGate = rejectionReasons.length === 0;
  const passesStrictIntegrationGate = strictRejectionReasons.length === 0;
  const passesFullPositionGate = passesIntegrationGate && hypothesis.zMode === 'use';
  const passesHorizontalOnlyGate = passesIntegrationGate && hypothesis.zMode === 'ignore';
  const passesStrictFullPositionGate =
    passesStrictIntegrationGate && hypothesis.zMode === 'use';
  const passesStrictHorizontalOnlyGate =
    passesStrictIntegrationGate && hypothesis.zMode === 'ignore';
  const promotionRejectionReasons = [];
  if (!passesStrictFullPositionGate) {
    promotionRejectionReasons.push('strict-full-xyz-integration-gate-failed');
  }
  if (summary.viewYawCoverage.matchedWithinMaxDeltaRate < 0.8) {
    promotionRejectionReasons.push('insufficient-same-netguid-handle122-view-yaw-coverage');
  }
  promotionRejectionReasons.push('selected-slot-vector-is-still-diagnostic-not-native-world-position');
  promotionRejectionReasons.push('view-yaw-identity-is-unconfirmed-or-ambiguous');
  return {
    hypothesis,
    passesIntegrationGate,
    passesStrictIntegrationGate,
    passesFullPositionGate,
    passesHorizontalOnlyGate,
    passesStrictFullPositionGate,
    passesStrictHorizontalOnlyGate,
    passesReplayTrackPromotionGate: false,
    rejectionReasons,
    strictRejectionReasons,
    promotionRejectionReasons,
    summary,
  };
}

function candidateSort(a, b) {
  return (
    Number(b.passesReplayTrackPromotionGate) - Number(a.passesReplayTrackPromotionGate) ||
    Number(b.passesStrictFullPositionGate) - Number(a.passesStrictFullPositionGate) ||
    Number(b.passesStrictHorizontalOnlyGate) - Number(a.passesStrictHorizontalOnlyGate) ||
    Number(b.passesStrictIntegrationGate) - Number(a.passesStrictIntegrationGate) ||
    Number(b.passesFullPositionGate) - Number(a.passesFullPositionGate) ||
    Number(b.passesHorizontalOnlyGate) - Number(a.passesHorizontalOnlyGate) ||
    Number(b.passesIntegrationGate) - Number(a.passesIntegrationGate) ||
    b.summary.inAscentBoundsRate - a.summary.inAscentBoundsRate ||
    b.summary.xySpan - a.summary.xySpan ||
    b.summary.uniquePositionCount - a.summary.uniquePositionCount ||
    (a.summary.p90Adjacent3dSpeed ?? Infinity) - (b.summary.p90Adjacent3dSpeed ?? Infinity) ||
    b.summary.count - a.summary.count ||
    a.hypothesis.scaleMultiplier - b.hypothesis.scaleMultiplier
  );
}

function analyzeSeries(series, players, yawSamplesByNetGuid, hypotheses, options) {
  const slotOpenSample = players[series.family.slotIndex] ?? null;
  const candidates = hypotheses
    .map((hypothesis) =>
      analyzeHypothesis(series, slotOpenSample, yawSamplesByNetGuid, hypothesis, options),
    )
    .sort(candidateSort);
  const strictFullPositionPasses = candidates.filter(
    (candidate) => candidate.passesStrictFullPositionGate,
  );
  const strictHorizontalOnlyPasses = candidates.filter(
    (candidate) => candidate.passesStrictHorizontalOnlyGate,
  );
  const fullPositionPasses = candidates.filter((candidate) => candidate.passesFullPositionGate);
  const horizontalOnlyPasses = candidates.filter((candidate) => candidate.passesHorizontalOnlyGate);
  return {
    kind: series.kind,
    label: series.label,
    family: series.family,
    prefixes: series.prefixes,
    sourceVectorSampleCount: series.rows.length,
    slotOpenSample,
    status:
      strictFullPositionPasses.length > 0
        ? 'selected slot vector has strict full-xyz integration-shaped hypotheses; still diagnostic'
        : strictHorizontalOnlyPasses.length > 0
          ? 'selected slot vector has strict horizontal-only integration-shaped hypotheses; z/native transform still unresolved'
          : fullPositionPasses.length > 0
            ? 'selected slot vector has broad full-xyz integration-shaped hypotheses but fails strict replay gates'
            : horizontalOnlyPasses.length > 0
              ? 'selected slot vector has broad horizontal-only integration-shaped hypotheses but fails strict replay gates'
              : 'selected slot vector has no delta/velocity integration hypothesis passing map and continuity gates',
    strictFullPositionPassCount: strictFullPositionPasses.length,
    strictHorizontalOnlyPassCount: strictHorizontalOnlyPasses.length,
    fullPositionPassCount: fullPositionPasses.length,
    horizontalOnlyPassCount: horizontalOnlyPasses.length,
    strictFullPositionPasses: strictFullPositionPasses.slice(0, options.maxCandidatesPerSeries),
    strictHorizontalOnlyPasses: strictHorizontalOnlyPasses.slice(0, options.maxCandidatesPerSeries),
    fullPositionPasses: fullPositionPasses.slice(0, options.maxCandidatesPerSeries),
    horizontalOnlyPasses: horizontalOnlyPasses.slice(0, options.maxCandidatesPerSeries),
    bestRejectedCandidates: candidates
      .filter((candidate) => !candidate.passesIntegrationGate)
      .slice(0, options.maxCandidatesPerSeries),
  };
}

function buildConclusions(seriesReports) {
  const conclusions = [];
  const strictFullCount = seriesReports.reduce(
    (sum, report) => sum + report.strictFullPositionPassCount,
    0,
  );
  const strictHorizontalCount = seriesReports.reduce(
    (sum, report) => sum + report.strictHorizontalOnlyPassCount,
    0,
  );
  const fullCount = seriesReports.reduce((sum, report) => sum + report.fullPositionPassCount, 0);
  const horizontalCount = seriesReports.reduce((sum, report) => sum + report.horizontalOnlyPassCount, 0);
  conclusions.push(
    strictFullCount > 0
      ? `${strictFullCount} strict full-xyz selected-slot integration hypotheses passed the diagnostic map/continuity gate, but none are promoted because native world-position/yaw identity is still unresolved.`
      : 'No selected h24/h100 delta or velocity integration hypothesis produced a strict full-xyz world-position candidate.',
  );
  conclusions.push(
    strictHorizontalCount > 0
      ? `${strictHorizontalCount} strict horizontal-only integrations passed after ignoring z; treat them as partial movement-shape evidence, not replay tracks.`
      : 'No strict horizontal-only selected-slot integration hypothesis passed either.',
  );
  conclusions.push(
    `${fullCount} broad full-xyz and ${horizontalCount} broad horizontal-only hypotheses passed the looser shape gate; broad passes are retained as leads, not proof.`,
  );
  for (const report of seriesReports) {
    const best = report.strictFullPositionPasses[0] ?? report.bestRejectedCandidates[0];
    if (!best) continue;
    if (best.passesStrictFullPositionGate) {
      conclusions.push(
        `${report.label} strongest strict lead is ${best.hypothesis.integrationMode}/${best.hypothesis.axisVariant}/${best.hypothesis.rotationMode}/scale=${best.hypothesis.scaleMultiplier} (xySpan=${best.summary.xySpan}, p90Speed3d=${best.summary.p90Adjacent3dSpeed}, p90ZStep=${best.summary.p90AdjacentZStep}, same-NetGUID yaw coverage=${best.summary.viewYawCoverage.matchedWithinMaxDeltaRate}).`,
      );
      continue;
    }
    conclusions.push(
      `${report.label} best rejected ${best.hypothesis.integrationMode}/${best.hypothesis.axisVariant}/${best.hypothesis.rotationMode}/scale=${best.hypothesis.scaleMultiplier} failed ${best.strictRejectionReasons.join(', ')} (xySpan=${best.summary.xySpan}, p90Speed3d=${best.summary.p90Adjacent3dSpeed}).`,
    );
  }
  return conclusions;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const decoderReportPath = resolveUserPath(options.decoderReport);
  const yawSamplesPath = resolveUserPath(options.yawSamples);
  if (!diagnosticsPath || !decoderReportPath) {
    console.error(
      'usage: node analyze_selected_slot_integration_hypotheses.mjs --diagnostics replay.diagnostics.json --decoder-report decoder_leads.report.json [--yaw-samples handle122_yaw.samples.json] --out integration_hypotheses.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const decoderReport = JSON.parse(fs.readFileSync(decoderReportPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const families = selectedFamilies(decoderReport);
  const series = buildSeriesReports(families, samples);
  const yawSamplesByNetGuid = loadYawSamplesByNetGuid(yawSamplesPath);
  const hypotheses = buildHypotheses(options, yawSamplesByNetGuid.size > 0);
  const seriesReports = series.map((entry) =>
    analyzeSeries(entry, players, yawSamplesByNetGuid, hypotheses, options),
  );
  const strictFullPositionPassCount = seriesReports.reduce(
    (sum, report) => sum + report.strictFullPositionPassCount,
    0,
  );
  const strictHorizontalOnlyPassCount = seriesReports.reduce(
    (sum, report) => sum + report.strictHorizontalOnlyPassCount,
    0,
  );
  const fullPositionPassCount = seriesReports.reduce(
    (sum, report) => sum + report.fullPositionPassCount,
    0,
  );
  const horizontalOnlyPassCount = seriesReports.reduce(
    (sum, report) => sum + report.horizontalOnlyPassCount,
    0,
  );

  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
      decoderReport: decoderReportPath,
      yawSamples: yawSamplesPath,
    },
    options: {
      minSamples: options.minSamples,
      minUniquePositions: options.minUniquePositions,
      minWorldXySpan: options.minWorldXySpan,
      maxP90Speed3d: options.maxP90Speed3d,
      maxSpeed3d: options.maxSpeed3d,
      maxP90ZStep: options.maxP90ZStep,
      maxZStep: options.maxZStep,
      strictMaxP90Speed3d: options.strictMaxP90Speed3d,
      strictMaxSpeed3d: options.strictMaxSpeed3d,
      strictMaxP90ZStep: options.strictMaxP90ZStep,
      strictMaxZStep: options.strictMaxZStep,
      maxYawDeltaMs: options.maxYawDeltaMs,
      resetGapMs: options.resetGapMs,
      cappedDtMs: options.cappedDtMs,
      scaleMultipliers: options.scaleMultipliers,
      axisVariants: AXIS_VARIANTS,
      zModes: Z_MODES,
      rotationModes: hypotheses.some((hypothesis) => hypothesis.rotationMode === 'nearest-handle122-netguid')
        ? ROTATION_MODES
        : ROTATION_MODES.filter((mode) => mode !== 'nearest-handle122-netguid'),
      integrationModes: INTEGRATION_MODES,
      gapPolicies: GAP_POLICIES,
      hypothesisCount: hypotheses.length,
      maxCandidatesPerSeries: options.maxCandidatesPerSeries,
    },
    notes: [
      'This report starts from selected h24/h100 slot-local packed vectors and tests whether they can be accumulated from the target slot actor-open location.',
      'Delta mode treats each vector as a per-sample displacement; velocity modes multiply by dt, optionally capping long gaps before integration.',
      'Rotation modes test no rotation, actor-open yaw, and nearest handle-122 yaw samples mapped to the same candidate NetGUID when a yaw artifact is provided.',
      'Horizontal-only passes ignore z and are not replay-track-promotable; full replay tracks require a native world-position transform plus non-ambiguous view yaw identity.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      selectedFamilyCount: families.length,
      analyzedSeriesCount: series.length,
      playerReferenceCount: players.length,
      yawNetGuidCount: yawSamplesByNetGuid.size,
      players,
    },
    status:
      strictFullPositionPassCount > 0
        ? 'selected slot vectors have strict full-xyz integration-shaped hypotheses, but none are replay-track promotable'
        : strictHorizontalOnlyPassCount > 0
          ? 'selected slot vectors have strict horizontal-only integration-shaped hypotheses, but no full-xyz replay-track candidate'
          : fullPositionPassCount > 0 || horizontalOnlyPassCount > 0
            ? 'selected slot vectors have broad integration-shaped hypotheses, but none pass strict replay gates'
            : 'selected slot vectors have no simple delta/velocity integration hypothesis passing map and continuity gates',
    strictFullPositionPassCount,
    strictHorizontalOnlyPassCount,
    fullPositionPassCount,
    horizontalOnlyPassCount,
    conclusions: buildConclusions(seriesReports),
    seriesReports,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  console.error(
    `analyzed ${seriesReports.length} selected series; strictFullPositionPasses=${strictFullPositionPassCount}; strictHorizontalOnlyPasses=${strictHorizontalOnlyPassCount}; broadFullPositionPasses=${fullPositionPassCount}; broadHorizontalOnlyPasses=${horizontalOnlyPassCount}`,
  );
}

main();
