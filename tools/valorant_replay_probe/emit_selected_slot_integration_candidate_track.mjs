#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const TRACK_COLORS = ['#38BDF8', '#F97316', '#A3E635', '#F43F5E', '#C084FC'];
const DEFAULT_HANDLE122_PREFIX = '69cf8efb';
const DEFAULT_HANDLE122_TRANSFORM = 'plus-180';
const HANDLE122_FIELD_HANDLE = 122;
const HANDLE122_PAYLOAD_BITS = 92;
const HANDLE122_YAW_BIT_OFFSET = 50;
const HANDLE122_YAW_BIT_COUNT = 18;
const DEFAULT_TARGETS = ['h100-merged', 'h100-d85fa616', 'h100-f85fa616'];

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

const FALLBACK_HYPOTHESES = new Map([
  [
    'h100/1950/d85fa616/slot6',
    {
      integrationMode: 'velocity-actual-dt',
      gapPolicy: 'reset-long-gap',
      axisVariant: 'xyz',
      zMode: 'use',
      rotationMode: 'open-yaw',
      scaleMultiplier: 10,
    },
  ],
  [
    'h100/1950/f85fa616/slot6',
    {
      integrationMode: 'velocity-capped-dt',
      gapPolicy: 'continuous',
      axisVariant: 'xyz',
      zMode: 'use',
      rotationMode: 'open-yaw',
      scaleMultiplier: 10,
    },
  ],
  [
    'h100/1950/merged-prefixes/slot6',
    {
      integrationMode: 'velocity-capped-dt',
      gapPolicy: 'continuous',
      axisVariant: 'xyz',
      zMode: 'use',
      rotationMode: 'open-yaw',
      scaleMultiplier: 10,
    },
  ],
]);

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    decoderReport: null,
    integrationReport: null,
    out: null,
    samplesOut: null,
    mapId: '/Game/Maps/Ascent/Ascent',
    targets: DEFAULT_TARGETS,
    handle122Prefix: DEFAULT_HANDLE122_PREFIX,
    handle122Transform: DEFAULT_HANDLE122_TRANSFORM,
    maxYawDeltaMs: 64,
    resetGapMs: 1000,
    cappedDtMs: 250,
    maxSamplesPerCandidate: Infinity,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--decoder-report') options.decoderReport = argv[++index];
    else if (arg === '--integration-report') options.integrationReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--samples-out') options.samplesOut = argv[++index];
    else if (arg === '--map-id') options.mapId = argv[++index];
    else if (arg === '--targets') {
      options.targets = argv[++index].split(',').map((value) => value.trim()).filter(Boolean);
    } else if (arg === '--handle122-prefix') {
      options.handle122Prefix = argv[++index].toLowerCase();
    } else if (arg === '--handle122-transform') {
      options.handle122Transform = argv[++index];
    } else if (arg === '--max-yaw-delta-ms') {
      options.maxYawDeltaMs = Number(argv[++index]);
    } else if (arg === '--reset-gap-ms') {
      options.resetGapMs = Number(argv[++index]);
    } else if (arg === '--capped-dt-ms') {
      options.cappedDtMs = Number(argv[++index]);
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
      positionTransform: family.positionTransform ?? 'raw',
    }));
}

function familyLabel(family) {
  return `h${family.fieldHandle}/${family.payloadBitCount}/${family.prefixHex}/slot${family.slotIndex}`;
}

function seriesLabel(series) {
  if (series.kind === 'merged-prefixes') {
    return `h${series.family.fieldHandle}/${series.family.payloadBitCount}/merged-prefixes/slot${series.family.slotIndex}`;
  }
  return familyLabel(series.family);
}

function seriesTargetId(series) {
  const prefix = series.kind === 'merged-prefixes' ? 'merged' : series.family.prefixHex;
  return `h${series.family.fieldHandle}-${prefix}`;
}

function targetMatchesSeries(target, series) {
  const normalized = target.toLowerCase();
  if (normalized === 'all') return true;
  if (normalized === 'h100') return series.family.fieldHandle === 100;
  if (normalized === 'h100-merged') return series.kind === 'merged-prefixes' && series.family.fieldHandle === 100;
  if (normalized === `h${series.family.fieldHandle}-${series.family.prefixHex}`) return true;
  if (normalized === `h${series.family.fieldHandle}-merged` && series.kind === 'merged-prefixes') return true;
  return normalized === seriesLabel(series).toLowerCase();
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
        sourcePrefixHex: family.prefixHex,
        payloadHex: sample.payloadHex,
        rawVector: vector,
        vector: scaleRawVector(vector, family.scaleFactor),
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
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

function buildSeries(families, samples) {
  const individual = families.map((family) => ({
    kind: 'individual-prefix',
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
      family: {
        ...first.family,
        prefixHex: entries.map((entry) => entry.family.prefixHex).join('+'),
      },
      prefixes: entries.map((entry) => entry.family.prefixHex),
      rows: entries
        .flatMap((entry) => entry.rows)
        .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex),
    });
  }

  return [...individual, ...merged];
}

function hypothesisFromIntegrationReport(integrationReport, label) {
  const report = (integrationReport?.seriesReports ?? []).find((entry) => entry.label === label);
  return report?.strictFullPositionPasses?.[0]?.hypothesis ?? null;
}

function hypothesisForSeries(series, integrationReport) {
  const label = seriesLabel(series);
  return hypothesisFromIntegrationReport(integrationReport, label) ?? FALLBACK_HYPOTHESES.get(label) ?? null;
}

function buildHandle122Lane(samples, options) {
  const laneRows = [];
  const deduped = new Set();
  for (const sample of samples) {
    if (sample.fieldHandle !== HANDLE122_FIELD_HANDLE || sample.bitCount !== HANDLE122_PAYLOAD_BITS) continue;
    const prefixHex = bitsToHex(sample.buffer, 0, 32);
    if (prefixHex !== options.handle122Prefix) continue;
    const dedupeKey = `${sample.timeMs}:${sample.payloadHex}`;
    if (deduped.has(dedupeKey)) continue;
    deduped.add(dedupeKey);
    const rawSignedValue = readBitsSigned(sample.buffer, HANDLE122_YAW_BIT_OFFSET, HANDLE122_YAW_BIT_COUNT);
    const rawYawDegrees = (rawSignedValue * 360) / 2 ** HANDLE122_YAW_BIT_COUNT;
    const yawDegrees360 = normalizeDegrees360(transformYaw(rawYawDegrees, options.handle122Transform));
    laneRows.push({
      timeMs: sample.timeMs,
      sampleIndex: sample.sampleIndex,
      prefixHex,
      rawSignedValue,
      rawYawDegrees,
      yawDegrees: normalizeDegrees180(yawDegrees360),
      yawDegrees360,
      payloadHex: sample.payloadHex,
    });
  }
  laneRows.sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
  return laneRows;
}

function nearestByTime(rows, targetTimeMs) {
  if (!rows.length) return null;
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

function decodedVectorForHypothesis(row, slotOpenSample, hypothesis) {
  let vector = applyAxisVariant(row.vector, hypothesis.axisVariant);
  if (hypothesis.rotationMode === 'open-yaw') {
    vector = rotateVector(vector, slotOpenSample.yaw);
  } else if (hypothesis.rotationMode !== 'none') {
    throw new Error(`unsupported emitter rotation mode: ${hypothesis.rotationMode}`);
  }
  if (hypothesis.zMode === 'ignore') vector = { ...vector, z: 0 };
  return vector;
}

function integrationScale(row, previousTimeMs, hypothesis, options) {
  if (hypothesis.integrationMode === 'delta') return hypothesis.scaleMultiplier;
  if (previousTimeMs == null) return 0;
  const dtMs = Math.max(0, row.timeMs - previousTimeMs);
  const effectiveDtMs =
    hypothesis.integrationMode === 'velocity-capped-dt' ? Math.min(dtMs, options.cappedDtMs) : dtMs;
  if (hypothesis.integrationMode !== 'velocity-actual-dt' && hypothesis.integrationMode !== 'velocity-capped-dt') {
    throw new Error(`unknown integration mode: ${hypothesis.integrationMode}`);
  }
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

    const vector = decodedVectorForHypothesis(row, slotOpenSample, hypothesis);
    const scale = integrationScale(row, previousTimeMs, hypothesis, options);
    position = {
      x: position.x + vector.x * scale,
      y: position.y + vector.y * scale,
      z: position.z + vector.z * scale,
    };
    rows.push({
      timeMs: row.timeMs,
      position: { ...position },
      sourceVector: vector,
      sourcePrefixHex: row.sourcePrefixHex,
      sourceSampleIndex: row.sampleIndex,
      rawVector: row.rawVector,
      scaledLocalVector: row.vector,
      integrationScale: scale,
      gapMs,
    });
    previousTimeMs = row.timeMs;
  }

  return { rows, resetCount, integratedLongGapCount };
}

function movementFallbackYaw(samples, index, fallbackYaw = 0) {
  const sample = samples[index];
  const reference = samples[index + 1] ?? samples[index - 1];
  if (!sample || !reference) return normalizeDegrees180(fallbackYaw);
  const dx = reference.position.x - sample.position.x;
  const dy = reference.position.y - sample.position.y;
  if (dx === 0 && dy === 0) return normalizeDegrees180(fallbackYaw);
  return normalizeDegrees180((Math.atan2(dy, dx) * 180) / Math.PI);
}

function attachYaw(integratedRows, yawLane, slotOpenSample, options) {
  return integratedRows.map((row, index) => {
    const nearest = nearestByTime(yawLane, row.timeMs);
    const decodedYaw = nearest && nearest.deltaMs <= options.maxYawDeltaMs ? nearest : null;
    const fallbackYaw = movementFallbackYaw(integratedRows, index, slotOpenSample.yaw);
    const yawDegrees = decodedYaw ? decodedYaw.row.yawDegrees : fallbackYaw;
    return {
      ...row,
      viewRotation: {
        yawDegrees: round(yawDegrees, 3),
        yawDegrees360: round(normalizeDegrees360(yawDegrees), 3),
        pitchDegrees: null,
        rollDegrees: null,
      },
      decodedYaw: decodedYaw
        ? {
            prefixHex: decodedYaw.row.prefixHex,
            deltaMs: decodedYaw.deltaMs,
            yawDegrees: round(decodedYaw.row.yawDegrees, 3),
            yawDegrees360: round(decodedYaw.row.yawDegrees360, 3),
            rawYawDegrees: round(decodedYaw.row.rawYawDegrees, 3),
            rawSignedValue: decodedYaw.row.rawSignedValue,
            transform: options.handle122Transform,
          }
        : null,
      yawSource: decodedYaw ? 'handle122-nearest-prefix' : 'movement-direction-fallback',
    };
  });
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

function summarizeCandidate(samples, integrationStats) {
  const ordered = [...samples].sort((a, b) => a.timeMs - b.timeMs);
  const xs = ordered.map((row) => row.position.x);
  const ys = ordered.map((row) => row.position.y);
  const zs = ordered.map((row) => row.position.z);
  const dts = [];
  const speeds2d = [];
  const speeds3d = [];
  const steps2d = [];
  const steps3d = [];
  const zSteps = [];
  const decodedYawDeltas = [];
  let longGapCount = 0;

  for (const row of ordered) {
    if (row.decodedYaw) decodedYawDeltas.push(row.decodedYaw.deltaMs);
  }

  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs > 1000) longGapCount += 1;
    const dx = current.position.x - previous.position.x;
    const dy = current.position.y - previous.position.y;
    const dz = current.position.z - previous.position.z;
    const step2d = Math.hypot(dx, dy);
    const step3d = Math.hypot(dx, dy, dz);
    if (dtMs <= 250) {
      steps2d.push(step2d);
      steps3d.push(step3d);
      zSteps.push(Math.abs(dz));
      speeds2d.push(step2d / (dtMs / 1000));
      speeds3d.push(step3d / (dtMs / 1000));
    }
  }

  const uniquePositions = new Set(
    ordered.map(
      (row) =>
        `${Math.round(row.position.x)}:${Math.round(row.position.y)}:${Math.round(row.position.z)}`,
    ),
  );
  const decodedYawSampleCount = ordered.filter((row) => row.decodedYaw).length;

  return {
    sampleCount: ordered.length,
    firstTimeMs: ordered[0]?.timeMs ?? null,
    lastTimeMs: ordered.at(-1)?.timeMs ?? null,
    activeSpanMs: ordered.length ? ordered.at(-1).timeMs - ordered[0].timeMs : 0,
    uniquePositionCount: uniquePositions.size,
    inAscentBoundsRate: ordered.length
      ? round(ordered.filter((row) => isPlausibleAscentPoint(row.position)).length / ordered.length)
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
    xySpan: ordered.length ? round(Math.hypot(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys)), 2) : 0,
    zSpan: ordered.length ? round(Math.max(...zs) - Math.min(...zs), 2) : 0,
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    longGapCount,
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
    decodedYawSampleCount,
    decodedYawSampleRate: ordered.length ? round(decodedYawSampleCount / ordered.length, 3) : 0,
    fallbackYawSampleCount: ordered.length - decodedYawSampleCount,
    decodedYawDeltaMs: decodedYawDeltas.length
      ? {
          median: round(percentile(decodedYawDeltas, 0.5), 0),
          p90: round(percentile(decodedYawDeltas, 0.9), 0),
          max: round(Math.max(...decodedYawDeltas), 0),
        }
      : null,
  };
}

function diagnosticSamplesForCandidate(candidate, options) {
  const rows = Number.isFinite(options.maxSamplesPerCandidate)
    ? candidate.samples.slice(0, options.maxSamplesPerCandidate)
    : candidate.samples;
  return rows.map((row) => ({
    timeMs: row.timeMs,
    netGuid: candidate.family.slotNetGuid,
    position: {
      x: round(row.position.x, 3),
      y: round(row.position.y, 3),
      z: round(row.position.z, 3),
    },
    viewRotation: {
      yawDegrees: row.decodedYaw ? row.viewRotation.yawDegrees : null,
      yawDegrees360: row.decodedYaw ? row.viewRotation.yawDegrees360 : null,
      pitchDegrees: null,
      rollDegrees: null,
    },
    source: {
      fieldHandle: candidate.family.fieldHandle,
      payloadBitCount: candidate.family.payloadBitCount,
      prefixHex: row.sourcePrefixHex,
      targetPrefixes: candidate.prefixes,
      slotIndex: candidate.family.slotIndex,
      slotChIndex: candidate.family.slotChIndex,
      relativeOffset: candidate.family.relativeOffset,
      componentBits: candidate.family.componentBits,
      extraInfo: candidate.family.extraInfo,
      scaleFactor: candidate.family.scaleFactor,
      integrationHypothesis: candidate.hypothesis,
      integrationScale: round(row.integrationScale, 6),
      sourceVector: {
        x: round(row.sourceVector.x, 4),
        y: round(row.sourceVector.y, 4),
        z: round(row.sourceVector.z, 4),
      },
      scaledLocalVector: {
        x: round(row.scaledLocalVector.x, 4),
        y: round(row.scaledLocalVector.y, 4),
        z: round(row.scaledLocalVector.z, 4),
      },
      rawVector: {
        bitsAndInfo: row.rawVector.bitsAndInfo,
        componentBits: row.rawVector.componentBits,
        extraInfo: row.rawVector.extraInfo,
        xSigned: row.rawVector.xSigned,
        ySigned: row.rawVector.ySigned,
        zSigned: row.rawVector.zSigned,
      },
      handle122Yaw: row.decodedYaw,
      yawSource: row.yawSource,
    },
    confidence: 'diagnostic-selected-slot-integration-yaw-ambiguous',
  }));
}

function viewerSamplesForCandidate(candidate, options) {
  const rows = Number.isFinite(options.maxSamplesPerCandidate)
    ? candidate.samples.slice(0, options.maxSamplesPerCandidate)
    : candidate.samples;
  return rows.map((row) => ({
    timeMs: row.timeMs,
    x: round(row.position.x, 3),
    y: round(row.position.y, 3),
    z: round(row.position.z, 3),
    yawDegrees: row.viewRotation.yawDegrees,
    pitchDegrees: null,
    yawSource: row.yawSource,
    decodedYawDeltaMs: row.decodedYaw?.deltaMs ?? null,
  }));
}

function candidateSourceTag(candidate) {
  return [
    `h${candidate.family.fieldHandle}`,
    `${candidate.family.payloadBitCount}b`,
    `prefixes=${candidate.prefixes.join('+')}`,
    `slot${candidate.family.slotIndex}`,
    `rel${candidate.family.relativeOffset}`,
    `${candidate.family.componentBits}+${candidate.family.extraInfo}`,
    `${candidate.hypothesis.integrationMode}`,
    `${candidate.hypothesis.axisVariant}`,
    `scale=${candidate.hypothesis.scaleMultiplier}`,
  ].join(' ');
}

function buildTrack(candidates, options, inputs) {
  const players = candidates.map((candidate, index) => ({
    id: `selected-slot-${candidate.family.slotNetGuid}-${seriesTargetId(candidate)}`,
    displayName: `g${candidate.family.slotNetGuid} slot${candidate.family.slotIndex} ${seriesTargetId(candidate)}`,
    agent: candidate.slotOpenSample?.archetypePath ?? `NetGUID ${candidate.family.slotNetGuid}`,
    teamColor: TRACK_COLORS[index % TRACK_COLORS.length],
    kind: 'candidate-selected-slot-integration',
    sourceTag: candidateSourceTag(candidate),
    confidence: 'diagnostic-integration-shaped-yaw-ambiguous',
    diagnosticSummary: candidate.summary,
    notes:
      `Diagnostic selected-slot ComponentDataStream integration candidate. ` +
      `${candidate.summary.decodedYawSampleCount}/${candidate.summary.sampleCount} samples have decoded handle-122 yaw from ${options.handle122Prefix}; ` +
      'viewer yaw uses movement direction where decoded yaw is absent. Not confirmed native world-position/player-identity decode.',
    samples: viewerSamplesForCandidate(candidate, options),
  }));

  return {
    sourceLabel: 'VRF selected-slot integration candidates',
    coordinateSpace: 'game',
    mapId: options.mapId,
    notes:
      'Generated from selected h100 slot-6 ComponentDataStream vectors integrated from actor-open location. This is a reverse-engineering review artifact, not a confirmed replay-track decoder.',
    input: inputs,
    decoder: {
      targetRpc:
        '/Script/ShooterGame.ReplayPlayerController:ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous',
      movementSurface:
        'fieldHandle=100, payloadBits=1950, slot=6, relativeOffset=24, packed vector componentBits=14 extraInfo=1 scaleFactor=100',
      yawOverlay: {
        fieldHandle: HANDLE122_FIELD_HANDLE,
        payloadBits: HANDLE122_PAYLOAD_BITS,
        prefixHex: options.handle122Prefix,
        transform: options.handle122Transform,
        bitOffset: HANDLE122_YAW_BIT_OFFSET,
        bitCount: HANDLE122_YAW_BIT_COUNT,
        maxDeltaMs: options.maxYawDeltaMs,
      },
      promotionStatus:
        'diagnostic only: native world-position transform, authoritative ShooterCharacterNetGuidValue, and non-ambiguous view yaw identity remain unresolved',
    },
    players,
  };
}

function buildSamplesOutput(candidates, options, inputs) {
  const candidateOutputs = candidates.map((candidate) => {
    const samples = diagnosticSamplesForCandidate(candidate, options);
    return {
      candidate: {
        id: `selected-slot-${candidate.family.slotNetGuid}-${seriesTargetId(candidate)}`,
        sourceTag: candidateSourceTag(candidate),
        family: candidate.family,
        prefixes: candidate.prefixes,
        hypothesis: candidate.hypothesis,
        slotOpenSample: candidate.slotOpenSample,
        summary: candidate.summary,
      },
      samples,
    };
  });
  const flatSamples = candidateOutputs
    .flatMap((entry) => entry.samples)
    .sort((a, b) => a.timeMs - b.timeMs || a.source.fieldHandle - b.source.fieldHandle);

  return {
    generatedAt: new Date().toISOString(),
    input: inputs,
    notes: [
      'Samples are integrated from selected h100 slot-6 ComponentDataStream packed vectors.',
      'Position is continuous within each candidate series, but viewRotation yaw is only populated when handle-122 prefix 69cf8efb has a nearby sample.',
      'Slot identity still comes from actor channel order; this remains a diagnostic artifact until native identity/world-position decoding is proven.',
    ],
    sampleShape:
      '{timeMs, netGuid, position:{x,y,z}, viewRotation:{yawDegrees,yawDegrees360,pitchDegrees,rollDegrees}, source, confidence}',
    selectedCandidateCount: candidates.length,
    flatSampleCount: flatSamples.length,
    decodedYawSampleCount: flatSamples.filter((sample) => sample.viewRotation?.yawDegrees != null).length,
    status:
      candidates.length > 0
        ? 'selected-slot integration candidate samples emitted'
        : 'no selected-slot integration candidates emitted',
    candidates: candidateOutputs,
    flatSamples,
  };
}

function buildCandidates(diagnostics, decoderReport, integrationReport, options) {
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const families = selectedFamilies(decoderReport).filter((family) => family.fieldHandle === 100);
  const allSeries = buildSeries(families, samples).filter((series) =>
    options.targets.some((target) => targetMatchesSeries(target, series)),
  );
  const yawLane = buildHandle122Lane(samples, options);
  const candidates = [];

  for (const series of allSeries) {
    const slotOpenSample = players[series.family.slotIndex] ?? null;
    const hypothesis = hypothesisForSeries(series, integrationReport);
    if (!slotOpenSample?.location || !hypothesis) continue;
    const integrationStats = integrateSeries(series, slotOpenSample, hypothesis, options);
    const samplesWithYaw = attachYaw(integrationStats.rows, yawLane, slotOpenSample, options);
    const summary = summarizeCandidate(samplesWithYaw, integrationStats);
    candidates.push({
      ...series,
      slotOpenSample,
      hypothesis,
      samples: samplesWithYaw,
      summary,
    });
  }

  return {
    samples,
    players,
    yawLane,
    candidates: candidates.sort(
      (a, b) =>
        Number(b.kind === 'merged-prefixes') - Number(a.kind === 'merged-prefixes') ||
        b.summary.sampleCount - a.summary.sampleCount ||
        a.family.prefixHex.localeCompare(b.family.prefixHex),
    ),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const decoderReportPath = resolveUserPath(options.decoderReport);
  const integrationReportPath = resolveUserPath(options.integrationReport);
  if (!diagnosticsPath || !decoderReportPath) {
    console.error(
      'usage: node emit_selected_slot_integration_candidate_track.mjs --diagnostics replay.diagnostics.json --decoder-report decoder_leads.report.json [--integration-report integration.report.json] --out selected_slot.track.json [--samples-out selected_slot.samples.json]',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const decoderReport = JSON.parse(fs.readFileSync(decoderReportPath, 'utf8'));
  const integrationReport = integrationReportPath
    ? JSON.parse(fs.readFileSync(integrationReportPath, 'utf8'))
    : null;
  const built = buildCandidates(diagnostics, decoderReport, integrationReport, options);
  const inputs = {
    diagnostics: diagnosticsPath,
    decoderReport: decoderReportPath,
    integrationReport: integrationReportPath,
    handle122Prefix: options.handle122Prefix,
    targets: options.targets,
  };
  const track = buildTrack(built.candidates, options, inputs);

  const outPath =
    resolveUserPath(options.out) ??
    path.resolve(process.env.INIT_CWD ?? process.cwd(), 'selected_slot_integration_candidate.track.json');
  writeJson(outPath, track);

  const samplesOutPath = resolveUserPath(options.samplesOut);
  if (samplesOutPath) {
    writeJson(samplesOutPath, buildSamplesOutput(built.candidates, options, inputs));
  }

  const sampleCount = built.candidates.reduce((sum, candidate) => sum + candidate.samples.length, 0);
  const decodedYawCount = built.candidates.reduce(
    (sum, candidate) => sum + candidate.summary.decodedYawSampleCount,
    0,
  );
  console.log(
    `wrote ${outPath} (${built.candidates.length} tracks, ${sampleCount} samples, ${decodedYawCount} decoded-yaw overlays, handle122 lane samples=${built.yawLane.length})`,
  );
  if (samplesOutPath) console.log(`wrote ${samplesOutPath}`);
}

main();
