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

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    decoderReport: null,
    out: null,
    minVectorSamples: 12,
    minWorldSamples: 40,
    minUniquePositions: 25,
    minWorldXySpan: 600,
    maxP90Speed3d: 5_500,
    maxSpeed3d: 14_000,
    maxP90ZStep: 140,
    maxZStep: 500,
    maxCandidatesPerFamily: 40,
    scaleFactors: [1, 10, 100, 1000],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--decoder-report') options.decoderReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--min-vector-samples') options.minVectorSamples = Number(argv[++index]);
    else if (arg === '--min-world-samples') options.minWorldSamples = Number(argv[++index]);
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
    } else if (arg === '--max-candidates-per-family') {
      options.maxCandidatesPerFamily = Number(argv[++index]);
    } else if (arg === '--scale-factors') {
      options.scaleFactors = argv[++index].split(',').map(Number).filter(Number.isFinite);
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
      selectedRelativeOffset: family.relativeOffset,
      selectedComponentBits: family.componentBits,
      selectedExtraInfo: family.extraInfo,
      selectedScaleFactor: family.scaleFactor,
      selectedPositionTransform: family.positionTransform,
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

function transformPoint(point, openSample, transformName) {
  const { x, y, z } = point;
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

function summarizeRows(rows) {
  const ordered = [...rows].sort((a, b) => a.timeMs - b.timeMs);
  const uniquePositions = new Set();
  const uniqueTimes = new Set();
  const dts = [];
  const steps3d = [];
  const speeds3d = [];
  const zSteps = [];
  let inBoundsCount = 0;
  let longGapCount = 0;
  let sameTimeConflictCount = 0;
  const byTime = new Map();
  const xs = [];
  const ys = [];
  const zs = [];

  for (const row of ordered) {
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

  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs > 1000) longGapCount += 1;
    if (dtMs <= 250) {
      const step3d = Math.hypot(current.x - previous.x, current.y - previous.y, current.z - previous.z);
      steps3d.push(step3d);
      speeds3d.push(step3d / (dtMs / 1000));
      zSteps.push(Math.abs(current.z - previous.z));
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
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    longGapCount,
    adjacentStepCount: speeds3d.length,
    p90Adjacent3dSpeed: round(percentile(speeds3d, 0.9), 1),
    maxAdjacent3dSpeed: round(speeds3d.length ? Math.max(...speeds3d) : null, 1),
    p90Adjacent3dStepDistance: round(percentile(steps3d, 0.9), 2),
    p90AdjacentZStep: round(percentile(zSteps, 0.9), 2),
    maxAdjacentZStep: round(zSteps.length ? Math.max(...zSteps) : null, 2),
    samples: ordered.slice(0, 6).map((row) => ({
      timeMs: row.timeMs,
      x: round(row.x, 2),
      y: round(row.y, 2),
      z: round(row.z, 2),
      inAscentBounds: isPlausibleAscentPoint(row),
    })),
  };
}

function addOpenReference(summary, rows, openSample) {
  if (!rows.length || !openSample?.location) return summary;
  const first = [...rows].sort((a, b) => a.timeMs - b.timeMs)[0];
  const open = openSample.location;
  return {
    ...summary,
    openReference: {
      openTimeMs: openSample.timeMs,
      firstSampleTimeMs: first.timeMs,
      deltaTimeMs: first.timeMs - openSample.timeMs,
      distance2d: round(Math.hypot(first.x - open.x, first.y - open.y), 2),
      distance3d: round(Math.hypot(first.x - open.x, first.y - open.y, first.z - open.z), 2),
    },
  };
}

function worldLeadRejectionReasons(summary, options) {
  const reasons = [];
  if (summary.count < options.minWorldSamples) reasons.push('too-few-samples');
  if (summary.uniqueTimeCount < options.minWorldSamples) reasons.push('too-few-unique-times');
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

function promotionRejectionReasons(candidate) {
  const reasons = [];
  if (!candidate.passesWorldPositionLeadGate) reasons.push('world-position-gate-failed');
  reasons.push('missing-native-shooter-character-netguid');
  reasons.push('missing-non-ambiguous-view-rotation');
  return reasons;
}

function groupVectorsByOffset(groupSamples, family, options) {
  const recordStart = family.headerBits + family.slotIndex * family.recordBits;
  const maxRelativeOffset = family.recordBits - (7 + 7 * 3);
  const rowsByKey = new Map();
  for (let relativeOffset = 0; relativeOffset <= maxRelativeOffset; relativeOffset += 1) {
    const absoluteOffset = recordStart + relativeOffset;
    for (const sample of groupSamples) {
      const rawVector = vectorAt(sample, absoluteOffset);
      if (!rawVector) continue;
      const key = [
        relativeOffset,
        rawVector.componentBits,
        rawVector.extraInfo,
        rawVector.bitsAndInfo,
      ].join('|');
      if (!rowsByKey.has(key)) rowsByKey.set(key, []);
      rowsByKey.get(key).push({ timeMs: sample.timeMs, rawVector });
    }
  }
  return [...rowsByKey.entries()]
    .map(([key, rows]) => {
      const [relativeOffset, componentBits, extraInfo, bitsAndInfo] = key.split('|').map(Number);
      return {
        relativeOffset,
        absoluteOffset: recordStart + relativeOffset,
        componentBits,
        extraInfo,
        bitsAndInfo,
        rows,
      };
    })
    .filter((entry) => entry.rows.length >= options.minVectorSamples);
}

function analyzeVectorGroup(vectorGroup, family, slotOpenSample, options) {
  const scaleFactors = vectorGroup.extraInfo ? options.scaleFactors : [1];
  const candidates = [];
  for (const scaleFactor of scaleFactors) {
    const scaledRows = vectorGroup.rows.map((row) => ({
      timeMs: row.timeMs,
      point: scaleRawVector(row.rawVector, scaleFactor),
    }));
    for (const transform of POSITION_TRANSFORMS) {
      if (transform !== 'raw' && !slotOpenSample) continue;
      const rows = scaledRows
        .map((row) => {
          const point = transformPoint(row.point, slotOpenSample, transform);
          return point ? { timeMs: row.timeMs, ...point } : null;
        })
        .filter(Boolean);
      const summary = addOpenReference(summarizeRows(rows), rows, slotOpenSample);
      const rejectionReasons = worldLeadRejectionReasons(summary, options);
      const candidate = {
        relativeOffset: vectorGroup.relativeOffset,
        absoluteOffset: vectorGroup.absoluteOffset,
        componentBits: vectorGroup.componentBits,
        extraInfo: vectorGroup.extraInfo,
        bitsAndInfo: vectorGroup.bitsAndInfo,
        scaleFactor,
        transform,
        selectedDecoderVector:
          vectorGroup.relativeOffset === family.selectedRelativeOffset &&
          vectorGroup.componentBits === family.selectedComponentBits &&
          vectorGroup.extraInfo === family.selectedExtraInfo &&
          scaleFactor === family.selectedScaleFactor,
        passesWorldPositionLeadGate: rejectionReasons.length === 0,
        rejectionReasons,
        summary,
      };
      const promotionReasons = promotionRejectionReasons(candidate);
      candidate.passesReplayTrackPromotionGate = promotionReasons.length === 0;
      candidate.promotionRejectionReasons = promotionReasons;
      candidates.push(candidate);
    }
  }
  return candidates;
}

function candidateSort(a, b) {
  return (
    Number(b.passesReplayTrackPromotionGate) - Number(a.passesReplayTrackPromotionGate) ||
    Number(b.passesWorldPositionLeadGate) - Number(a.passesWorldPositionLeadGate) ||
    Number(b.selectedDecoderVector) - Number(a.selectedDecoderVector) ||
    b.summary.inAscentBoundsRate - a.summary.inAscentBoundsRate ||
    b.summary.xySpan - a.summary.xySpan ||
    b.summary.uniquePositionCount - a.summary.uniquePositionCount ||
    (a.summary.p90Adjacent3dSpeed ?? Infinity) - (b.summary.p90Adjacent3dSpeed ?? Infinity) ||
    b.summary.count - a.summary.count ||
    a.relativeOffset - b.relativeOffset
  );
}

function analyzeFamily(family, samples, players, options) {
  const groupSamples = samplesForFamily(samples, family);
  const slotOpenSample = players[family.slotIndex] ?? null;
  const vectorGroups = groupVectorsByOffset(groupSamples, family, options);
  const candidates = vectorGroups
    .flatMap((vectorGroup) => analyzeVectorGroup(vectorGroup, family, slotOpenSample, options))
    .sort(candidateSort);
  const passing = candidates.filter((candidate) => candidate.passesWorldPositionLeadGate);
  const promotable = candidates.filter((candidate) => candidate.passesReplayTrackPromotionGate);
  return {
    family,
    groupSampleCount: groupSamples.length,
    vectorGroupCount: vectorGroups.length,
    slotOpenSample,
    status:
      promotable.length > 0
        ? 'selected slot family has replay-track promotable world-position candidates'
        : passing.length > 0
          ? 'selected slot family has world-position-shaped candidates but identity/yaw promotion still fails'
          : 'selected slot family has no packed-vector offset passing the world-position gate',
    worldPositionLeadCount: passing.length,
    replayTrackPromotableCount: promotable.length,
    promotableCandidates: promotable.slice(0, options.maxCandidatesPerFamily),
    worldPositionLeads: passing.slice(0, options.maxCandidatesPerFamily),
    bestRejectedCandidates: candidates
      .filter((candidate) => !candidate.passesWorldPositionLeadGate)
      .slice(0, options.maxCandidatesPerFamily),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const decoderReportPath = resolveUserPath(options.decoderReport);
  if (!diagnosticsPath || !decoderReportPath) {
    console.error(
      'usage: node analyze_selected_slot_world_position_leads.mjs --diagnostics replay.diagnostics.json --decoder-report decoder_leads.report.json --out selected_slot_world_positions.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const decoderReport = JSON.parse(fs.readFileSync(decoderReportPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const families = selectedFamilies(decoderReport);
  const familyReports = families.map((family) => analyzeFamily(family, samples, players, options));
  const worldPositionLeadCount = familyReports.reduce(
    (total, family) => total + family.worldPositionLeadCount,
    0,
  );
  const replayTrackPromotableCount = familyReports.reduce(
    (total, family) => total + family.replayTrackPromotableCount,
    0,
  );

  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
      decoderReport: decoderReportPath,
    },
    options: {
      minVectorSamples: options.minVectorSamples,
      minWorldSamples: options.minWorldSamples,
      minUniquePositions: options.minUniquePositions,
      minWorldXySpan: options.minWorldXySpan,
      maxP90Speed3d: options.maxP90Speed3d,
      maxSpeed3d: options.maxSpeed3d,
      maxP90ZStep: options.maxP90ZStep,
      maxZStep: options.maxZStep,
      maxCandidatesPerFamily: options.maxCandidatesPerFamily,
      scaleFactors: options.scaleFactors,
      transforms: POSITION_TRANSFORMS,
    },
    notes: [
      'This guardrail scans every packed-vector-looking offset inside the selected h24/h100 target slot records.',
      'Only the target slot actor-open transform is used for open-relative transforms; unrelated player opens are not allowed.',
      'A world-position lead must be map-bounded, broad enough in xy, and continuous enough in xyz; promotion additionally requires native ShooterCharacterNetGuidValue and non-ambiguous view rotation, which are not decoded yet.',
      'A passing world-position lead is still diagnostic until validated against labeled sparse snapshots or native identity/yaw in the same record.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      selectedFamilyCount: families.length,
      playerReferenceCount: players.length,
      players,
    },
    status:
      replayTrackPromotableCount > 0
        ? 'selected slot records include replay-track promotable candidates; inspect before emission'
        : worldPositionLeadCount > 0
          ? 'selected slot records include world-position-shaped candidates, but none are promotable replay tracks'
          : 'selected h24/h100 slot records have no simple packed-vector world-position transform',
    worldPositionLeadCount,
    replayTrackPromotableCount,
    familyReports,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  console.error(
    `analyzed ${familyReports.length} selected families; worldPositionLeads=${worldPositionLeadCount}; promotable=${replayTrackPromotableCount}`,
  );
}

main();
