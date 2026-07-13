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

const HANDLE122_FIELD_HANDLE = 122;
const HANDLE122_PAYLOAD_BITS = 92;
const AXIS_VARIANTS = ['xyz', 'swapxy', 'negxy', 'negx', 'negy'];
const INTEGRATION_MODES = ['velocity-actual-dt', 'velocity-capped-dt'];
const GAP_POLICIES = ['continuous', 'reset-long-gap'];

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    handle122IdentityReport: null,
    out: null,
    fieldHandle: 100,
    payloadBits: 1950,
    slotCount: 10,
    minGroupSamples: 40,
    minVectorSamples: 40,
    minUniquePositions: 25,
    minWorldXySpan: 600,
    maxP90Speed3d: 2500,
    maxSpeed3d: 5000,
    maxP90ZStep: 35,
    maxZStep: 120,
    maxSourceVectorP90Step3d: 500,
    maxSourceVectorMaxStep3d: 5_000,
    minSourceVectorPresenceRate: 0.75,
    minSourceUniqueVectorCount: 8,
    resetGapMs: 1000,
    cappedDtMs: 250,
    scaleFactors: [1, 10, 100, 1000],
    scaleMultipliers: [0.1, 1, 10, 100],
    maxCandidates: 80,
    maxExamplesPerCandidate: 6,
    yawWindowsMs: [16, 33, 64],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--handle122-identity-report') options.handle122IdentityReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--field-handle') options.fieldHandle = Number(argv[++index]);
    else if (arg === '--payload-bits') options.payloadBits = Number(argv[++index]);
    else if (arg === '--slot-count') options.slotCount = Number(argv[++index]);
    else if (arg === '--min-group-samples') options.minGroupSamples = Number(argv[++index]);
    else if (arg === '--min-vector-samples') options.minVectorSamples = Number(argv[++index]);
    else if (arg === '--min-unique-positions') options.minUniquePositions = Number(argv[++index]);
    else if (arg === '--min-world-xy-span') options.minWorldXySpan = Number(argv[++index]);
    else if (arg === '--max-p90-speed3d') options.maxP90Speed3d = Number(argv[++index]);
    else if (arg === '--max-speed3d') options.maxSpeed3d = Number(argv[++index]);
    else if (arg === '--max-p90-z-step') options.maxP90ZStep = Number(argv[++index]);
    else if (arg === '--max-z-step') options.maxZStep = Number(argv[++index]);
    else if (arg === '--max-source-vector-p90-step3d') {
      options.maxSourceVectorP90Step3d = Number(argv[++index]);
    } else if (arg === '--max-source-vector-max-step3d') {
      options.maxSourceVectorMaxStep3d = Number(argv[++index]);
    } else if (arg === '--min-source-vector-presence-rate') {
      options.minSourceVectorPresenceRate = Number(argv[++index]);
    } else if (arg === '--min-source-unique-vector-count') {
      options.minSourceUniqueVectorCount = Number(argv[++index]);
    }
    else if (arg === '--reset-gap-ms') options.resetGapMs = Number(argv[++index]);
    else if (arg === '--capped-dt-ms') options.cappedDtMs = Number(argv[++index]);
    else if (arg === '--scale-factors') {
      options.scaleFactors = argv[++index].split(',').map(Number).filter(Number.isFinite);
    } else if (arg === '--scale-multipliers') {
      options.scaleMultipliers = argv[++index].split(',').map(Number).filter(Number.isFinite);
    } else if (arg === '--max-candidates') {
      options.maxCandidates = Number(argv[++index]);
    } else if (arg === '--max-examples-per-candidate') {
      options.maxExamplesPerCandidate = Number(argv[++index]);
    } else if (arg === '--yaw-windows-ms') {
      options.yawWindowsMs = argv[++index].split(',').map(Number).filter(Number.isFinite);
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

function vectorAt(sample, bitOffset) {
  const reader = new BitCursor(sample.buffer, sample.bitCount, bitOffset);
  return reader.readPackedVectorRaw();
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

function buildGroups(samples, options) {
  const groups = new Map();
  for (const sample of samples) {
    if (sample.fieldHandle !== options.fieldHandle || sample.bitCount !== options.payloadBits) continue;
    const prefixHex = bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount));
    const key = `${sample.fieldHandle}|${sample.bitCount}|${prefixHex}`;
    if (!groups.has(key)) {
      const headerBits = sample.bitCount % options.slotCount;
      groups.set(key, {
        fieldHandle: sample.fieldHandle,
        payloadBitCount: sample.bitCount,
        prefixHex,
        headerBits,
        recordBits: (sample.bitCount - headerBits) / options.slotCount,
        rows: [],
      });
    }
    groups.get(key).rows.push(sample);
  }
  return [...groups.values()]
    .filter(
      (group) =>
        group.rows.length >= options.minGroupSamples &&
        Number.isInteger(group.recordBits) &&
        group.recordBits >= 80,
    )
    .sort((a, b) => b.rows.length - a.rows.length || a.prefixHex.localeCompare(b.prefixHex));
}

function buildHandle122Lanes(samples) {
  const lanes = new Map();
  for (const sample of samples) {
    if (sample.fieldHandle !== HANDLE122_FIELD_HANDLE || sample.bitCount !== HANDLE122_PAYLOAD_BITS) continue;
    const prefixHex = bitsToHex(sample.buffer, 0, 32);
    if (!lanes.has(prefixHex)) lanes.set(prefixHex, new Map());
    lanes.get(prefixHex).set(`${sample.timeMs}:${sample.payloadHex}`, {
      timeMs: sample.timeMs,
      sampleIndex: sample.sampleIndex,
    });
  }
  const result = new Map();
  for (const [prefixHex, rowsByKey] of lanes.entries()) {
    result.set(
      prefixHex,
      [...rowsByKey.values()].sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex),
    );
  }
  return result;
}

function laneIdentityMap(handle122IdentityReport) {
  const map = new Map();
  for (const lane of handle122IdentityReport?.laneReports ?? []) {
    const best = lane.openYawMatches?.[0] ?? null;
    map.set(lane.prefixHex, {
      bestSlotIndex: best?.player?.slotIndex ?? null,
      bestNetGuid: best?.player?.netGuid ?? null,
      bestChIndex: best?.player?.chIndex ?? null,
      openYawIdentityStatus: lane.openYawIdentityStatus ?? null,
      bestTransform: best?.transform ?? null,
      bestDeltaDegrees: best?.deltaDegrees ?? null,
    });
  }
  return map;
}

function nearestByTime(rows, timeMs) {
  if (!rows?.length) return null;
  let low = 0;
  let high = rows.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (rows[middle].timeMs < timeMs) low = middle + 1;
    else high = middle;
  }
  let best = null;
  for (const index of [low - 1, low]) {
    if (index < 0 || index >= rows.length) continue;
    const deltaMs = Math.abs(rows[index].timeMs - timeMs);
    if (!best || deltaMs < best.deltaMs) best = { row: rows[index], deltaMs };
  }
  return best;
}

function summarizeYawCooccurrence(seriesRows, slotIndex, yawContext, options) {
  if (!yawContext?.lanes?.size) return null;
  const laneStats = [];
  for (const [prefixHex, laneRows] of yawContext.lanes.entries()) {
    const counts = Object.fromEntries(options.yawWindowsMs.map((windowMs) => [`within${windowMs}Ms`, 0]));
    const deltas = [];
    for (const row of seriesRows) {
      const nearest = nearestByTime(laneRows, row.timeMs);
      if (!nearest) continue;
      deltas.push(nearest.deltaMs);
      for (const windowMs of options.yawWindowsMs) {
        if (nearest.deltaMs <= windowMs) counts[`within${windowMs}Ms`] += 1;
      }
    }
    const rates = Object.fromEntries(
      options.yawWindowsMs.map((windowMs) => [
        `within${windowMs}MsRate`,
        seriesRows.length ? round(counts[`within${windowMs}Ms`] / seriesRows.length, 3) : 0,
      ]),
    );
    const identity = yawContext.identity.get(prefixHex) ?? null;
    laneStats.push({
      prefixHex,
      ...identity,
      ...counts,
      ...rates,
      deltaMs: deltas.length
        ? {
            median: round(percentile(deltas, 0.5), 0),
            p90: round(percentile(deltas, 0.9), 0),
            min: round(Math.min(...deltas), 0),
            max: round(Math.max(...deltas), 0),
          }
        : null,
    });
  }
  const rateKey = `within${Math.max(...options.yawWindowsMs)}MsRate`;
  const countKey = `within${Math.max(...options.yawWindowsMs)}Ms`;
  const sorted = laneStats.sort(
    (a, b) =>
      b[rateKey] - a[rateKey] ||
      b[countKey] - a[countKey] ||
      a.prefixHex.localeCompare(b.prefixHex),
  );
  return {
    rowCount: seriesRows.length,
    windowsMs: options.yawWindowsMs,
    topAnyLane: sorted[0] ?? null,
    topSameSlotLane:
      sorted.find((lane) => lane.bestSlotIndex === slotIndex) ?? null,
    topLanes: sorted.slice(0, 5),
  };
}

function scaleRawVector(vector, scaleFactor) {
  const scale = vector.extraInfo ? scaleFactor : 1;
  return {
    x: vector.xSigned / scale,
    y: vector.ySigned / scale,
    z: vector.zSigned / scale,
  };
}

function collectVectorSeries(group, options) {
  const series = [];
  const maxRelativeOffset = group.recordBits - (7 + 7 * 3);
  for (let slotIndex = 0; slotIndex < options.slotCount; slotIndex += 1) {
    const recordStart = group.headerBits + slotIndex * group.recordBits;
    for (let relativeOffset = 0; relativeOffset <= maxRelativeOffset; relativeOffset += 1) {
      const rowsByEncoding = new Map();
      for (const sample of group.rows) {
        const rawVector = vectorAt(sample, recordStart + relativeOffset);
        if (!rawVector) continue;
        const key = `${rawVector.componentBits}|${rawVector.extraInfo}|${rawVector.bitsAndInfo}`;
        if (!rowsByEncoding.has(key)) rowsByEncoding.set(key, []);
        rowsByEncoding.get(key).push({
          timeMs: sample.timeMs,
          sampleIndex: sample.sampleIndex,
          rawVector,
        });
      }
      for (const [key, rawRows] of rowsByEncoding.entries()) {
        if (rawRows.length < options.minVectorSamples) continue;
        const [componentBitsText, extraInfoText, bitsAndInfoText] = key.split('|');
        const componentBits = Number(componentBitsText);
        const extraInfo = Number(extraInfoText);
        const scaleFactors = extraInfo ? options.scaleFactors : [1];
        for (const scaleFactor of scaleFactors) {
          series.push({
            fieldHandle: group.fieldHandle,
            payloadBitCount: group.payloadBitCount,
            prefixHex: group.prefixHex,
            slotIndex,
            headerBits: group.headerBits,
            recordBits: group.recordBits,
            groupSampleCount: group.rows.length,
            relativeOffset,
            absoluteOffset: recordStart + relativeOffset,
            componentBits,
            extraInfo,
            bitsAndInfo: Number(bitsAndInfoText),
            scaleFactor,
            sourceRowCount: rawRows.length,
            rows: rawRows
              .map((row) => ({
                ...row,
                vector: scaleRawVector(row.rawVector, scaleFactor),
              }))
              .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex),
          });
        }
      }
    }
  }
  return series;
}

function mergeSeries(series) {
  const groups = new Map();
  for (const entry of series) {
    const key = [
      entry.fieldHandle,
      entry.payloadBitCount,
      entry.slotIndex,
      entry.relativeOffset,
      entry.componentBits,
      entry.extraInfo,
      entry.bitsAndInfo,
      entry.scaleFactor,
    ].join('|');
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(entry);
  }
  const merged = [];
  for (const entries of groups.values()) {
    if (entries.length < 2) continue;
    const [first] = entries;
    merged.push({
      ...first,
      prefixHex: entries.map((entry) => entry.prefixHex).join('+'),
      kind: 'merged-prefixes',
      sourceRowCount: entries.reduce((sum, entry) => sum + entry.sourceRowCount, 0),
      groupSampleCount: entries.reduce((sum, entry) => sum + entry.groupSampleCount, 0),
      rows: entries
        .flatMap((entry) =>
          entry.rows.map((row) => ({
            ...row,
            sourcePrefixHex: entry.prefixHex,
          })),
        )
        .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex),
    });
  }
  return [
    ...series.map((entry) => ({
      ...entry,
      kind: 'individual-prefix',
      rows: entry.rows.map((row) => ({ ...row, sourcePrefixHex: entry.prefixHex })),
    })),
    ...merged,
  ];
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

function integrationScale(row, previousTimeMs, hypothesis, options) {
  if (previousTimeMs == null) return 0;
  const dtMs = Math.max(0, row.timeMs - previousTimeMs);
  const effectiveDtMs =
    hypothesis.integrationMode === 'velocity-capped-dt' ? Math.min(dtMs, options.cappedDtMs) : dtMs;
  return (effectiveDtMs / 1000) * hypothesis.scaleMultiplier;
}

function integrateSeries(series, slotOpenSample, hypothesis, options) {
  let position = { ...slotOpenSample.location };
  let previousTimeMs = null;
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
    let vector = applyAxisVariant(row.vector, hypothesis.axisVariant);
    vector = rotateVector(vector, slotOpenSample.yaw);
    const scale = integrationScale(row, previousTimeMs, hypothesis, options);
    position = {
      x: position.x + vector.x * scale,
      y: position.y + vector.y * scale,
      z: position.z + vector.z * scale,
    };
    rows.push({
      timeMs: row.timeMs,
      x: position.x,
      y: position.y,
      z: position.z,
      sourcePrefixHex: row.sourcePrefixHex,
      scaledVector: row.vector,
      integratedVector: vector,
      rawVector: row.rawVector,
      gapMs,
    });
    previousTimeMs = row.timeMs;
  }
  return { rows, resetCount, integratedLongGapCount };
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

function summarizeRows(rows, integrationStats) {
  const xs = [];
  const ys = [];
  const zs = [];
  const uniquePositions = new Set();
  const uniqueTimes = new Set();
  const dts = [];
  const speeds2d = [];
  const speeds3d = [];
  const steps2d = [];
  const steps3d = [];
  const zSteps = [];
  let longGapCount = 0;
  let inBoundsCount = 0;
  let sameTimeConflictCount = 0;
  const byTime = new Map();

  for (const row of rows) {
    xs.push(row.x);
    ys.push(row.y);
    zs.push(row.z);
    uniqueTimes.add(row.timeMs);
    const key = `${Math.round(row.x)}:${Math.round(row.y)}:${Math.round(row.z)}`;
    uniquePositions.add(key);
    if (byTime.has(row.timeMs) && byTime.get(row.timeMs) !== key) sameTimeConflictCount += 1;
    byTime.set(row.timeMs, key);
    if (isPlausibleAscentPoint(row)) inBoundsCount += 1;
  }

  for (let index = 1; index < rows.length; index += 1) {
    const previous = rows[index - 1];
    const current = rows[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs > 1000) longGapCount += 1;
    if (dtMs <= 250) {
      const dx = current.x - previous.x;
      const dy = current.y - previous.y;
      const dz = current.z - previous.z;
      const step2d = Math.hypot(dx, dy);
      const step3d = Math.hypot(dx, dy, dz);
      steps2d.push(step2d);
      steps3d.push(step3d);
      speeds2d.push(step2d / (dtMs / 1000));
      speeds3d.push(step3d / (dtMs / 1000));
      zSteps.push(Math.abs(dz));
    }
  }

  const xSpan = xs.length ? Math.max(...xs) - Math.min(...xs) : 0;
  const ySpan = ys.length ? Math.max(...ys) - Math.min(...ys) : 0;
  const zSpan = zs.length ? Math.max(...zs) - Math.min(...zs) : 0;
  return {
    count: rows.length,
    firstTimeMs: rows[0]?.timeMs ?? null,
    lastTimeMs: rows.at(-1)?.timeMs ?? null,
    activeSpanMs: rows.length ? rows.at(-1).timeMs - rows[0].timeMs : 0,
    uniqueTimeCount: uniqueTimes.size,
    uniquePositionCount: uniquePositions.size,
    sameTimeConflictCount,
    inAscentBoundsRate: rows.length ? round(inBoundsCount / rows.length) : 0,
    bounds: rows.length
      ? {
          minX: round(Math.min(...xs), 2),
          maxX: round(Math.max(...xs), 2),
          minY: round(Math.min(...ys), 2),
          maxY: round(Math.max(...ys), 2),
          minZ: round(Math.min(...zs), 2),
          maxZ: round(Math.max(...zs), 2),
        }
      : null,
    xySpan: round(Math.hypot(xSpan, ySpan), 2),
    zSpan: round(zSpan, 2),
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    longGapCount,
    adjacentStepCount: speeds3d.length,
    resetCount: integrationStats.resetCount,
    integratedLongGapCount: integrationStats.integratedLongGapCount,
    p90Adjacent2dSpeed: round(percentile(speeds2d, 0.9), 1),
    maxAdjacent2dSpeed: round(speeds2d.length ? Math.max(...speeds2d) : null, 1),
    p90Adjacent3dSpeed: round(percentile(speeds3d, 0.9), 1),
    maxAdjacent3dSpeed: round(speeds3d.length ? Math.max(...speeds3d) : null, 1),
    p90Adjacent2dStepDistance: round(percentile(steps2d, 0.9), 2),
    p90Adjacent3dStepDistance: round(percentile(steps3d, 0.9), 2),
    p90AdjacentZStep: round(percentile(zSteps, 0.9), 2),
    maxAdjacentZStep: round(zSteps.length ? Math.max(...zSteps) : null, 2),
    samples: rows.slice(0, 6).map((row) => ({
      timeMs: row.timeMs,
      x: round(row.x, 2),
      y: round(row.y, 2),
      z: round(row.z, 2),
      sourcePrefixHex: row.sourcePrefixHex,
    })),
  };
}

function summarizeSourceVectorRows(rows, groupSampleCount) {
  const uniqueVectors = new Set();
  const gaps = [];
  const steps3d = [];
  for (const row of rows) {
    uniqueVectors.add(
      `${round(row.vector.x, 4)}:${round(row.vector.y, 4)}:${round(row.vector.z, 4)}`,
    );
  }
  for (let index = 1; index < rows.length; index += 1) {
    const previous = rows[index - 1];
    const current = rows[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    gaps.push(dtMs);
    if (dtMs <= 250) {
      steps3d.push(
        Math.hypot(
          current.vector.x - previous.vector.x,
          current.vector.y - previous.vector.y,
          current.vector.z - previous.vector.z,
        ),
      );
    }
  }
  return {
    count: rows.length,
    groupSampleCount,
    presenceRate: groupSampleCount ? round(rows.length / groupSampleCount) : 0,
    uniqueVectorCount: uniqueVectors.size,
    medianDtMs: round(percentile(gaps, 0.5), 0),
    p90DtMs: round(percentile(gaps, 0.9), 0),
    adjacentStepCount: steps3d.length,
    p90Step3d: round(percentile(steps3d, 0.9), 3),
    maxStep3d: round(steps3d.length ? Math.max(...steps3d) : null, 3),
  };
}

function sourceVectorRejectionReasons(sourceVectorSummary, options) {
  const reasons = [];
  if (!sourceVectorSummary) return ['missing-source-vector-summary'];
  if (sourceVectorSummary.presenceRate < options.minSourceVectorPresenceRate) {
    reasons.push('low-source-vector-presence-rate');
  }
  if (sourceVectorSummary.uniqueVectorCount < options.minSourceUniqueVectorCount) {
    reasons.push('too-few-source-unique-vectors');
  }
  if (
    sourceVectorSummary.p90Step3d == null ||
    sourceVectorSummary.p90Step3d > options.maxSourceVectorP90Step3d
  ) {
    reasons.push('jumpy-source-vector-p90-step');
  }
  if (
    sourceVectorSummary.maxStep3d == null ||
    sourceVectorSummary.maxStep3d > options.maxSourceVectorMaxStep3d
  ) {
    reasons.push('jumpy-source-vector-max-step');
  }
  return reasons;
}

function rejectionReasons(summary, hypothesis, options) {
  const reasons = [];
  if (summary.count < options.minVectorSamples) reasons.push('too-few-samples');
  if (summary.uniqueTimeCount < options.minVectorSamples) reasons.push('too-few-unique-times');
  if (summary.uniquePositionCount < options.minUniquePositions) reasons.push('too-few-unique-positions');
  if (summary.sameTimeConflictCount > 0) reasons.push('same-time-position-conflicts');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-or-z-bounds');
  if (summary.xySpan < options.minWorldXySpan) reasons.push('low-world-xy-span');
  if (summary.adjacentStepCount < Math.min(16, summary.count - 2)) reasons.push('too-few-adjacent-steps');
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
  if (hypothesis.integrationMode === 'velocity-actual-dt' && summary.integratedLongGapCount > 0) {
    reasons.push('velocity-integrated-across-long-gaps');
  }
  return reasons;
}

function hypotheses(options) {
  const result = [];
  for (const integrationMode of INTEGRATION_MODES) {
    for (const gapPolicy of GAP_POLICIES) {
      for (const axisVariant of AXIS_VARIANTS) {
        for (const scaleMultiplier of options.scaleMultipliers) {
          result.push({ integrationMode, gapPolicy, axisVariant, zMode: 'use', rotationMode: 'open-yaw', scaleMultiplier });
        }
      }
    }
  }
  return result;
}

function candidateSort(a, b) {
  return (
    Number(b.passesStrictFullPositionGate) - Number(a.passesStrictFullPositionGate) ||
    b.summary.inAscentBoundsRate - a.summary.inAscentBoundsRate ||
    b.summary.xySpan - a.summary.xySpan ||
    b.summary.uniquePositionCount - a.summary.uniquePositionCount ||
    (a.summary.p90Adjacent3dSpeed ?? Infinity) - (b.summary.p90Adjacent3dSpeed ?? Infinity) ||
    (a.summary.p90AdjacentZStep ?? Infinity) - (b.summary.p90AdjacentZStep ?? Infinity) ||
    b.summary.count - a.summary.count
  );
}

function analyzeSeries(series, players, allHypotheses, yawContext, options) {
  const slotOpenSample = players[series.slotIndex] ?? null;
  if (!slotOpenSample?.location || !Number.isFinite(slotOpenSample.yaw)) return [];
  const sourceVectorSummary = summarizeSourceVectorRows(series.rows, series.groupSampleCount);
  const sourceVectorReasons = sourceVectorRejectionReasons(sourceVectorSummary, options);
  const handle122Cooccurrence = summarizeYawCooccurrence(
    series.rows,
    series.slotIndex,
    yawContext,
    options,
  );
  return allHypotheses.map((hypothesis) => {
    const integrated = integrateSeries(series, slotOpenSample, hypothesis, options);
    const summary = summarizeRows(integrated.rows, integrated);
    const reasons = rejectionReasons(summary, hypothesis, options);
    return {
      kind: series.kind,
      family: {
        fieldHandle: series.fieldHandle,
        payloadBitCount: series.payloadBitCount,
        prefixHex: series.prefixHex,
        slotIndex: series.slotIndex,
        slotNetGuid: slotOpenSample.netGuid,
        slotChIndex: slotOpenSample.chIndex,
        slotArchetypePath: slotOpenSample.archetypePath,
        headerBits: series.headerBits,
        recordBits: series.recordBits,
        relativeOffset: series.relativeOffset,
        absoluteOffset: series.absoluteOffset,
        componentBits: series.componentBits,
        extraInfo: series.extraInfo,
        bitsAndInfo: series.bitsAndInfo,
        scaleFactor: series.scaleFactor,
      },
      sourceVectorSampleCount: series.rows.length,
      hypothesis,
      passesStrictFullPositionGate: reasons.length === 0,
      rejectionReasons: reasons,
      passesSourceVectorStabilityGate: sourceVectorReasons.length === 0,
      sourceVectorRejectionReasons: sourceVectorReasons,
      sourceVectorSummary,
      handle122Cooccurrence,
      summary,
    };
  });
}

function buildConclusions(candidates, passing) {
  const conclusions = [];
  const sourceStablePassing = passing.filter((candidate) => candidate.passesSourceVectorStabilityGate);
  conclusions.push(
    `${passing.length} h100 slot/offset integration hypotheses pass the strict full-xyz gate across ${new Set(passing.map((candidate) => candidate.family.slotIndex)).size} slots.`,
  );
  conclusions.push(
    `${sourceStablePassing.length} of those also pass the source-vector stability guardrail before integration.`,
  );
  const bySlot = new Map();
  for (const candidate of passing) {
    const slot = candidate.family.slotIndex;
    if (!bySlot.has(slot)) bySlot.set(slot, []);
    bySlot.get(slot).push(candidate);
  }
  for (const [slot, rows] of [...bySlot.entries()].sort((a, b) => a[0] - b[0])) {
    const best = [...rows].sort(candidateSort)[0];
    conclusions.push(
      `slot ${slot} best h${best.family.fieldHandle}/${best.family.prefixHex}/rel${best.family.relativeOffset}/${best.family.componentBits}+${best.family.extraInfo}/scaleFactor=${best.family.scaleFactor} uses ${best.hypothesis.integrationMode}/${best.hypothesis.gapPolicy}/${best.hypothesis.axisVariant}/scale=${best.hypothesis.scaleMultiplier} (samples=${best.summary.count}, xySpan=${best.summary.xySpan}, p90Speed3d=${best.summary.p90Adjacent3dSpeed}, p90ZStep=${best.summary.p90AdjacentZStep}).`,
    );
    const stableRows = rows.filter((candidate) => candidate.passesSourceVectorStabilityGate);
    if (stableRows.length > 0) {
      const stableBest = [...stableRows].sort(candidateSort)[0];
      conclusions.push(
        `slot ${slot} source-stable best is h${stableBest.family.fieldHandle}/${stableBest.family.prefixHex}/rel${stableBest.family.relativeOffset}/${stableBest.family.componentBits}+${stableBest.family.extraInfo}/scaleFactor=${stableBest.family.scaleFactor} (samples=${stableBest.summary.count}, sourcePresence=${stableBest.sourceVectorSummary.presenceRate}, sourceP90Step3d=${stableBest.sourceVectorSummary.p90Step3d}).`,
      );
    }
  }
  const topAnyCounts = topHandle122LaneCounts(passing, false);
  const dominantTopAny = topAnyCounts[0];
  if (dominantTopAny) {
    conclusions.push(
      `Dominant top-any handle122 overlap among strict h100 passers is ${dominantTopAny.key} for ${dominantTopAny.count}/${passing.length} candidates; treat cross-slot h100 shape passes as timing-collision risks unless same-slot yaw/identity also lines up.`,
    );
  }
  const yawQualifiedBySlot = new Map();
  for (const candidate of passing) {
    const sameSlotLane = candidate.handle122Cooccurrence?.topSameSlotLane;
    if (!sameSlotLane) continue;
    const existing = yawQualifiedBySlot.get(candidate.family.slotIndex);
    const rate = sameSlotLane.within64MsRate ?? 0;
    const count = sameSlotLane.within64Ms ?? 0;
    const existingLane = existing?.handle122Cooccurrence?.topSameSlotLane;
    const existingRate = existingLane?.within64MsRate ?? -1;
    const existingCount = existingLane?.within64Ms ?? -1;
    if (!existing || rate > existingRate || (rate === existingRate && count > existingCount)) {
      yawQualifiedBySlot.set(candidate.family.slotIndex, candidate);
    }
  }
  for (const [slot, candidate] of [...yawQualifiedBySlot.entries()].sort((a, b) => a[0] - b[0])) {
    const lane = candidate.handle122Cooccurrence.topSameSlotLane;
    conclusions.push(
      `slot ${slot} best same-open-yaw handle122 overlap is lane ${lane.prefixHex} with ${lane.within64Ms}/${candidate.handle122Cooccurrence.rowCount} rows within 64ms (rate=${lane.within64MsRate}); identity status=${lane.openYawIdentityStatus ?? 'unknown'}.`,
    );
  }
  if (!passing.length) {
    const bestRejected = candidates[0];
    if (bestRejected) {
      conclusions.push(
        `best rejected h${bestRejected.family.fieldHandle}/${bestRejected.family.prefixHex}/slot${bestRejected.family.slotIndex}/rel${bestRejected.family.relativeOffset} failed ${bestRejected.rejectionReasons.join(', ')}.`,
      );
    }
  }
  conclusions.push(
    'This report is movement-shape evidence only; replay-track promotion still requires authoritative ShooterCharacterNetGuidValue decode and non-ambiguous view yaw identity.',
  );
  return conclusions;
}

function topHandle122LaneCounts(candidates, includeCandidateSlot) {
  const counts = new Map();
  for (const candidate of candidates) {
    const lane = candidate.handle122Cooccurrence?.topAnyLane;
    if (!lane) continue;
    const key = includeCandidateSlot
      ? `slot${candidate.family.slotIndex}->slot${lane.bestSlotIndex ?? 'unknown'}:${lane.prefixHex}`
      : `slot${lane.bestSlotIndex ?? 'unknown'}:${lane.prefixHex}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || a.key.localeCompare(b.key));
}

function analyze(diagnostics, options) {
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const groups = buildGroups(samples, options);
  const rawSeries = groups.flatMap((group) => collectVectorSeries(group, options));
  const series = mergeSeries(rawSeries);
  const allHypotheses = hypotheses(options);
  const handle122IdentityReport = options.handle122IdentityReport
    ? JSON.parse(fs.readFileSync(resolveUserPath(options.handle122IdentityReport), 'utf8'))
    : null;
  const yawContext = {
    lanes: buildHandle122Lanes(samples),
    identity: laneIdentityMap(handle122IdentityReport),
  };
  const candidates = series
    .flatMap((entry) => analyzeSeries(entry, players, allHypotheses, yawContext, options))
    .sort(candidateSort);
  const passing = candidates.filter((candidate) => candidate.passesStrictFullPositionGate);
  return {
    generatedAt: new Date().toISOString(),
    options: {
      fieldHandle: options.fieldHandle,
      payloadBits: options.payloadBits,
      slotCount: options.slotCount,
      minGroupSamples: options.minGroupSamples,
      minVectorSamples: options.minVectorSamples,
      minUniquePositions: options.minUniquePositions,
      minWorldXySpan: options.minWorldXySpan,
      maxP90Speed3d: options.maxP90Speed3d,
      maxSpeed3d: options.maxSpeed3d,
      maxP90ZStep: options.maxP90ZStep,
      maxZStep: options.maxZStep,
      maxSourceVectorP90Step3d: options.maxSourceVectorP90Step3d,
      maxSourceVectorMaxStep3d: options.maxSourceVectorMaxStep3d,
      minSourceVectorPresenceRate: options.minSourceVectorPresenceRate,
      minSourceUniqueVectorCount: options.minSourceUniqueVectorCount,
      resetGapMs: options.resetGapMs,
      cappedDtMs: options.cappedDtMs,
      scaleFactors: options.scaleFactors,
      scaleMultipliers: options.scaleMultipliers,
      yawWindowsMs: options.yawWindowsMs,
      axisVariants: AXIS_VARIANTS,
      integrationModes: INTEGRATION_MODES,
      gapPolicies: GAP_POLICIES,
      hypothesisCount: allHypotheses.length,
    },
    notes: [
      'This broad scan tests every decodable packed-vector offset in the selected h100 slot-array groups as an open-yaw velocity integration from each actor-open transform.',
      'It is a verifier for movement-shaped ComponentDataStream offsets; it does not prove native identity or view yaw.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      playerReferenceCount: players.length,
      players,
      groupCount: groups.length,
      groups: groups.map((group) => ({
        fieldHandle: group.fieldHandle,
        payloadBitCount: group.payloadBitCount,
        prefixHex: group.prefixHex,
        sampleCount: group.rows.length,
        headerBits: group.headerBits,
        recordBits: group.recordBits,
      })),
      rawVectorSeriesCount: rawSeries.length,
      analyzedSeriesCount: series.length,
      analyzedHypothesisCount: candidates.length,
      handle122LaneCount: yawContext.lanes.size,
      handle122IdentityReport: options.handle122IdentityReport ?? null,
    },
    status:
      passing.length > 0
        ? 'h100 slot integration candidates pass strict movement-shape gate; still diagnostic'
        : 'no h100 slot integration candidate passed strict movement-shape gate',
    strictFullPositionPassCount: passing.length,
    sourceStableStrictFullPositionPassCount: passing.filter(
      (candidate) => candidate.passesSourceVectorStabilityGate,
    ).length,
    passingSlotCount: new Set(passing.map((candidate) => candidate.family.slotIndex)).size,
    passingSlots: [...new Set(passing.map((candidate) => candidate.family.slotIndex))].sort((a, b) => a - b),
    topAnyHandle122LaneCounts: topHandle122LaneCounts(passing, false).slice(0, 12),
    topAnyHandle122LaneByCandidateSlotCounts: topHandle122LaneCounts(passing, true).slice(0, 24),
    conclusions: buildConclusions(candidates, passing),
    strictFullPositionPasses: passing.slice(0, options.maxCandidates),
    sourceStableStrictFullPositionPasses: passing
      .filter((candidate) => candidate.passesSourceVectorStabilityGate)
      .slice(0, options.maxCandidates),
    bestRejectedCandidates: candidates
      .filter((candidate) => !candidate.passesStrictFullPositionGate)
      .slice(0, options.maxCandidates),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_h100_slot_integration_candidates.mjs --diagnostics replay.diagnostics.json [--handle122-identity-report handle122.report.json] --out h100_slot_integration.report.json',
    );
    process.exitCode = 1;
    return;
  }
  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const report = analyze(diagnostics, options);
  report.input = {
    diagnostics: diagnosticsPath,
    handle122IdentityReport: resolveUserPath(options.handle122IdentityReport),
  };
  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  console.error(
    `scanned h${options.fieldHandle}/${options.payloadBits}; groups=${report.source.groupCount}; series=${report.source.analyzedSeriesCount}; hypotheses=${report.source.analyzedHypothesisCount}; strictPasses=${report.strictFullPositionPassCount}; slots=${report.passingSlots.join(',') || 'none'}`,
  );
}

main();
