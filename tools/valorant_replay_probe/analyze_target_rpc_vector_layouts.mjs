#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const TARGET_FUNCTION_RE =
  /ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous/i;

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

const UNREAL_HARDCODED_NAMES = new Map([
  [0, 'None'],
  [1, 'ByteProperty'],
  [2, 'IntProperty'],
  [3, 'BoolProperty'],
  [4, 'FloatProperty'],
  [5, 'ObjectProperty'],
  [6, 'NameProperty'],
  [8, 'DoubleProperty'],
  [9, 'ArrayProperty'],
  [10, 'StructProperty'],
  [11, 'VectorProperty'],
  [12, 'RotatorProperty'],
  [21, 'UInt32Property'],
  [22, 'UInt16Property'],
  [23, 'Int64Property'],
  [28, 'MapProperty'],
  [29, 'SetProperty'],
  [34, 'EnumProperty'],
  [54, 'Vector2D'],
  [57, 'Vector4'],
  [58, 'Name'],
  [59, 'Vector'],
  [60, 'Rotator'],
  [65, 'LinearColor'],
  [67, 'Pointer'],
  [69, 'Quat'],
  [70, 'Self'],
  [71, 'Transform'],
  [100, 'Object'],
  [102, 'Actor'],
  [106, 'ScriptStruct'],
  [107, 'Function'],
  [244, 'NetworkGUID'],
  [248, 'Location'],
  [249, 'Rotation'],
  [255, 'Control'],
]);

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    out: null,
    minExploratorySamples: 8,
    maxExploratory: 40,
    maxRejected: 40,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--min-exploratory-samples') {
      options.minExploratorySamples = Number(argv[++index]);
    } else if (arg === '--max-exploratory') options.maxExploratory = Number(argv[++index]);
    else if (arg === '--max-rejected') options.maxRejected = Number(argv[++index]);
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

function unrealHardcodedName(value) {
  return UNREAL_HARDCODED_NAMES.get(value) ?? null;
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

function parseTargetSamples(diagnostics) {
  return (diagnostics.frameSummary?.replayControllerCandidateFieldSamples ?? [])
    .filter(
      (sample) =>
        sample.fieldHandle === 3 &&
        TARGET_FUNCTION_RE.test(sample.fieldName ?? '') &&
        sample.payloadHex != null &&
        Number.isInteger(sample.numPayloadBits),
    )
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

function knownPlayerRefs(diagnostics) {
  return (diagnostics.frameSummary?.channelOpenSamples ?? [])
    .filter((sample) => /Default__[^/]+_PC_C$/i.test(sample.archetypePath ?? ''))
    .filter((sample) => !/Ability|PostDeath/i.test(sample.archetypePath ?? ''))
    .map((sample) => ({
      netGuid: sample.actorNetGuid,
      chIndex: sample.chIndex,
      archetypePath: sample.archetypePath ?? null,
      openTimeMs: sample.timeMs,
      location: sample.location ?? null,
      yaw: sample.rotation?.yaw ?? null,
    }))
    .filter((sample) => Number.isInteger(sample.netGuid) && Number.isInteger(sample.chIndex))
    .sort((a, b) => a.netGuid - b.netGuid);
}

function relationForFirstPacked(value, players) {
  const matches = [];
  for (const player of players) {
    const checks = [
      ['chIndex', player.chIndex],
      ['chIndex>>1', player.chIndex / 2],
      ['chIndex&0x7f', player.chIndex & 0x7f],
      ['netGuid&0x7f', player.netGuid & 0x7f],
    ];
    for (const [label, candidate] of checks) {
      if (Number.isInteger(candidate) && candidate === value) {
        matches.push({
          playerNetGuid: player.netGuid,
          chIndex: player.chIndex,
          label,
        });
      }
    }
  }
  return matches;
}

function scanAuthoritativeGuidHits(buffer, bitLimit, knownGuids) {
  const hits = [];
  const known = new Set(knownGuids);
  if (!known.size) return hits;
  for (let bitOffset = 0; bitOffset < bitLimit; bitOffset += 1) {
    const packed = readIntPacked(buffer, bitOffset, bitLimit);
    if (packed.ok && known.has(packed.value)) {
      hits.push({
        encoding: 'intPacked',
        bitOffset,
        bitCount: packed.bitCount,
        value: packed.value,
      });
    }
    if (bitOffset + 32 <= bitLimit) {
      const uint32 = readBitsUnsigned(buffer, bitOffset, 32);
      if (known.has(uint32)) {
        hits.push({
          encoding: 'uint32',
          bitOffset,
          bitCount: 32,
          value: uint32,
        });
      }
    }
  }
  return hits;
}

function recordsFromTargetSamples(samples, players) {
  const knownGuids = players.map((player) => player.netGuid);
  const records = [];
  for (const sample of samples) {
    const recordCount = Math.floor(sample.bitCount / 80);
    const trailingBits = sample.bitCount % 80;
    for (let recordIndex = 0; recordIndex < recordCount; recordIndex += 1) {
      const bitOffset = recordIndex * 80;
      const buffer = copyBits(sample.buffer, bitOffset, 80);
      const firstPacked = readIntPacked(buffer, 0, 80);
      records.push({
        timeMs: sample.timeMs,
        sampleIndex: sample.sampleIndex,
        parentPayloadBits: sample.bitCount,
        parentRecordCount: recordCount,
        parentTrailingBits: trailingBits,
        recordIndex,
        recordBitOffset: bitOffset,
        prefix3: buffer.toString('hex').slice(0, 6),
        prefix4: buffer.toString('hex').slice(0, 8),
        firstPackedValue: firstPacked.ok ? firstPacked.value : null,
        firstPackedBitCount: firstPacked.ok ? firstPacked.bitCount : null,
        firstPackedUnrealHardcodedName: firstPacked.ok
          ? unrealHardcodedName(firstPacked.value)
          : null,
        firstPackedPlayerRelations: firstPacked.ok
          ? relationForFirstPacked(firstPacked.value, players)
          : [],
        authoritativeGuidHits: scanAuthoritativeGuidHits(buffer, 80, knownGuids),
        hex: buffer.toString('hex'),
        buffer,
      });
    }
  }
  return records;
}

function summarizeTargetPayloadFamilies(samples) {
  const groups = new Map();
  for (const sample of samples) {
    let group = groups.get(sample.bitCount);
    if (!group) {
      group = {
        bitCount: sample.bitCount,
        count: 0,
        firstTimeMs: sample.timeMs,
        lastTimeMs: sample.timeMs,
        prefixes: [],
      };
      groups.set(sample.bitCount, group);
    }
    group.count += 1;
    group.firstTimeMs = Math.min(group.firstTimeMs, sample.timeMs);
    group.lastTimeMs = Math.max(group.lastTimeMs, sample.timeMs);
    group.prefixes.push(bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)));
  }

  return [...groups.values()]
    .map((group) => ({
      bitCount: group.bitCount,
      count: group.count,
      firstTimeMs: group.firstTimeMs,
      lastTimeMs: group.lastTimeMs,
      full80RecordCount: Math.floor(group.bitCount / 80),
      trailingBitsAfter80Records: group.bitCount % 80,
      topPrefixes: topCounts(group.prefixes, 8),
    }))
    .sort((a, b) => b.count - a.count || a.bitCount - b.bitCount);
}

function summarizeNativeRecordFamilies(records) {
  const groups = new Map();
  for (const record of records) {
    let group = groups.get(record.prefix3);
    if (!group) {
      group = {
        prefix3: record.prefix3,
        firstPackedValue: record.firstPackedValue,
        firstPackedUnrealHardcodedName: record.firstPackedUnrealHardcodedName,
        firstPackedBitCount: record.firstPackedBitCount,
        firstPackedPlayerRelations: record.firstPackedPlayerRelations,
        count: 0,
        firstTimeMs: record.timeMs,
        lastTimeMs: record.timeMs,
        parentPayloadBits: [],
        recordIndexes: [],
        prefix4Values: [],
        authoritativeGuidHitValues: [],
        samples: [],
      };
      groups.set(record.prefix3, group);
    }
    group.count += 1;
    group.firstTimeMs = Math.min(group.firstTimeMs, record.timeMs);
    group.lastTimeMs = Math.max(group.lastTimeMs, record.timeMs);
    group.parentPayloadBits.push(record.parentPayloadBits);
    group.recordIndexes.push(record.recordIndex);
    group.prefix4Values.push(record.prefix4);
    for (const hit of record.authoritativeGuidHits) {
      group.authoritativeGuidHitValues.push(`${hit.encoding}:${hit.value}@${hit.bitOffset}`);
    }
    if (group.samples.length < 8) {
      group.samples.push({
        timeMs: record.timeMs,
        parentPayloadBits: record.parentPayloadBits,
        recordIndex: record.recordIndex,
        hex: record.hex,
      });
    }
  }

  return [...groups.values()]
    .map((group) => ({
      prefix3: group.prefix3,
      firstPackedValue: group.firstPackedValue,
      firstPackedUnrealHardcodedName: group.firstPackedUnrealHardcodedName,
      firstPackedBitCount: group.firstPackedBitCount,
      firstPackedPlayerRelations: group.firstPackedPlayerRelations,
      count: group.count,
      firstTimeMs: group.firstTimeMs,
      lastTimeMs: group.lastTimeMs,
      parentPayloadBits: topCounts(group.parentPayloadBits, 6),
      recordIndexes: topCounts(group.recordIndexes, 6),
      topPrefix4Values: topCounts(group.prefix4Values, 6),
      authoritativeGuidHits: topCounts(group.authoritativeGuidHitValues, 8),
      samples: group.samples,
    }))
    .sort((a, b) => b.count - a.count || a.prefix3.localeCompare(b.prefix3))
    .slice(0, 40);
}

function layoutSpecs() {
  const specs = [];
  for (const componentBits of [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]) {
    for (const scale of [1, 10, 100, 1000]) {
      for (let startBit = 0; startBit + componentBits * 3 <= 80; startBit += 1) {
        specs.push({ startBit, componentBits, scale });
      }
    }
  }
  return specs;
}

function decodeTriplet(record, spec) {
  return {
    x: readBitsSigned(record.buffer, spec.startBit, spec.componentBits) / spec.scale,
    y:
      readBitsSigned(record.buffer, spec.startBit + spec.componentBits, spec.componentBits) /
      spec.scale,
    z:
      readBitsSigned(record.buffer, spec.startBit + spec.componentBits * 2, spec.componentBits) /
      spec.scale,
  };
}

function addGroupRow(groups, key, row) {
  let rows = groups.get(key);
  if (!rows) {
    rows = [];
    groups.set(key, rows);
  }
  rows.push(row);
}

function summarizeRows(rows) {
  const ordered = [...rows].sort(
    (a, b) => a.timeMs - b.timeMs || a.recordIndex - b.recordIndex || a.prefix3.localeCompare(b.prefix3),
  );
  const uniquePositions = new Set();
  const positionsByTime = new Map();
  const parentPayloadBits = new Map();
  const recordIndexes = new Map();
  const prefixes = new Map();
  const firstPackedValues = new Map();
  const firstPackedNames = new Map();
  const authoritativeGuidHits = new Map();
  let sameTimeConflictCount = 0;
  let inBoundsCount = 0;
  let minX = Infinity;
  let maxX = -Infinity;
  let minY = Infinity;
  let maxY = -Infinity;
  let minZ = Infinity;
  let maxZ = -Infinity;

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
    increment(parentPayloadBits, row.parentPayloadBits);
    increment(recordIndexes, row.recordIndex);
    increment(prefixes, row.prefix3);
    increment(firstPackedValues, row.firstPackedValue ?? 'bad');
    if (row.firstPackedUnrealHardcodedName) increment(firstPackedNames, row.firstPackedUnrealHardcodedName);
    for (const hit of row.authoritativeGuidHits ?? []) {
      increment(authoritativeGuidHits, `${hit.encoding}:${hit.value}@${hit.bitOffset}`);
    }
  }

  const dts = [];
  const adjacentSpeeds = [];
  const adjacentSteps = [];
  let largeAdjacentJumpCount = 0;
  let longGapCount = 0;
  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs > 1000) longGapCount += 1;
    const distance2d = Math.hypot(current.x - previous.x, current.y - previous.y);
    if (dtMs <= 250) {
      const speed = distance2d / (dtMs / 1000);
      adjacentSteps.push(distance2d);
      adjacentSpeeds.push(speed);
      if (distance2d > 900 || speed > 12_000) largeAdjacentJumpCount += 1;
    }
  }

  const xSpan = ordered.length ? maxX - minX : 0;
  const ySpan = ordered.length ? maxY - minY : 0;
  const zSpan = ordered.length ? maxZ - minZ : 0;
  const absMaxValues = ordered.map((row) => Math.max(Math.abs(row.x), Math.abs(row.y)));
  const realMagnitudeCount = absMaxValues.filter((value) => value >= 500).length;
  return {
    count: ordered.length,
    firstTimeMs: ordered[0]?.timeMs ?? null,
    lastTimeMs: ordered.at(-1)?.timeMs ?? null,
    activeSpanMs: ordered.length > 1 ? ordered.at(-1).timeMs - ordered[0].timeMs : 0,
    uniqueTimeCount: positionsByTime.size,
    uniquePositionCount: uniquePositions.size,
    sameTimeConflictCount,
    inAscentBoundsRate: ordered.length ? round(inBoundsCount / ordered.length) : 0,
    realMagnitudeRate: ordered.length ? round(realMagnitudeCount / ordered.length) : 0,
    medianAbsXYMax: round(percentile(absMaxValues, 0.5), 2),
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
    staticAxisCount: [xSpan, ySpan, zSpan].filter((span) => span < 25).length,
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    longGapCount,
    adjacentStepCount: adjacentSpeeds.length,
    p90AdjacentSpeed: round(percentile(adjacentSpeeds, 0.9), 1),
    maxAdjacentSpeed: round(adjacentSpeeds.length ? Math.max(...adjacentSpeeds) : null, 1),
    p90AdjacentStepDistance: round(percentile(adjacentSteps, 0.9), 2),
    largeAdjacentJumpCount,
    parentPayloadBits: topCounts(parentPayloadBits, 8),
    recordIndexes: topCounts(recordIndexes, 8),
    prefix3Counts: topCounts(prefixes, 8),
    firstPackedValues: topCounts(firstPackedValues, 8),
    firstPackedUnrealHardcodedNames: topCounts(firstPackedNames, 8),
    authoritativeGuidHits: topCounts(authoritativeGuidHits, 8),
    samples: ordered.slice(0, 8).map((row) => ({
      timeMs: row.timeMs,
      parentPayloadBits: row.parentPayloadBits,
      recordIndex: row.recordIndex,
      prefix3: row.prefix3,
      firstPackedValue: row.firstPackedValue,
      firstPackedUnrealHardcodedName: row.firstPackedUnrealHardcodedName,
      x: round(row.x, 2),
      y: round(row.y, 2),
      z: round(row.z, 2),
      inAscentBounds: isPlausibleAscentPoint(row),
      hex: row.hex,
    })),
  };
}

function strictRejectionReasons(candidate) {
  const reasons = [];
  const summary = candidate.summary;
  if (candidate.scope === 'recordIndex') reasons.push('record-index-scope-mixes-prefix-families');
  if (candidate.layout.startBit < 24) reasons.push('layout-overlaps-24-bit-token-prefix');
  if (summary.count < 20) reasons.push('too-few-samples');
  if (summary.uniqueTimeCount < 20) reasons.push('too-few-unique-times');
  if (summary.uniquePositionCount < 10) reasons.push('too-few-unique-positions');
  if (summary.sameTimeConflictCount > 0) reasons.push('same-time-position-conflicts');
  if (summary.activeSpanMs < 3000) reasons.push('too-short-active-span');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-or-z-bounds');
  if (summary.realMagnitudeRate < 0.6) reasons.push('mostly-small-token-like-values');
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

function promotableRejectionReasons(candidate) {
  const reasons = strictRejectionReasons(candidate);
  if (!candidate.summary.authoritativeGuidHits.length) {
    reasons.push('no-authoritative-netguid-in-layout-group');
  }
  return reasons;
}

function exploratoryScore(candidate) {
  const summary = candidate.summary;
  const p90Speed = summary.p90AdjacentSpeed ?? 30_000;
  return (
    summary.count * 18 +
    summary.uniquePositionCount * 24 +
    summary.inAscentBoundsRate * 500 +
    summary.realMagnitudeRate * 250 +
    Math.min(summary.xySpan, 2000) * 0.15 +
    Math.min(summary.adjacentStepCount, 30) * 15 -
    (candidate.layout.startBit < 24 ? 1200 : 0) -
    (candidate.scope === 'recordIndex' ? 1000 : 0) -
    summary.staticAxisCount * 500 -
    Math.min(p90Speed, 30_000) * 0.05 -
    summary.largeAdjacentJumpCount * 350
  );
}

function isExploratory(candidate) {
  const summary = candidate.summary;
  return (
    summary.count >= 8 &&
    summary.uniquePositionCount >= 4 &&
    summary.activeSpanMs >= 50 &&
    summary.inAscentBoundsRate >= 0.65 &&
    summary.xySpan >= 25
  );
}

function compactCandidate(candidate, includeSamples = true) {
  const strictReasons = strictRejectionReasons(candidate);
  const promotableReasons = promotableRejectionReasons(candidate);
  return {
    scope: candidate.scope,
    key: candidate.key,
    layout: candidate.layout,
    score: round(candidate.score, 2),
    strictPositionLane: strictReasons.length === 0,
    strictRejectionReasons: strictReasons,
    promotable: promotableReasons.length === 0,
    promotableRejectionReasons: promotableReasons,
    summary: includeSamples
      ? candidate.summary
      : {
          ...candidate.summary,
          samples: undefined,
        },
  };
}

function analyzeVectorLayouts(records, options) {
  const exploratory = [];
  const strictPosition = [];
  const promotable = [];
  const bestRejected = [];

  for (const layout of layoutSpecs()) {
    const groups = {
      prefix3: new Map(),
      prefix3RecordIndex: new Map(),
      recordIndex: new Map(),
    };

    for (const record of records) {
      const point = decodeTriplet(record, layout);
      const row = {
        ...point,
        timeMs: record.timeMs,
        parentPayloadBits: record.parentPayloadBits,
        recordIndex: record.recordIndex,
        prefix3: record.prefix3,
        firstPackedValue: record.firstPackedValue,
        firstPackedUnrealHardcodedName: record.firstPackedUnrealHardcodedName,
        authoritativeGuidHits: record.authoritativeGuidHits,
        hex: record.hex,
      };
      addGroupRow(groups.prefix3, record.prefix3, row);
      addGroupRow(groups.prefix3RecordIndex, `${record.prefix3}@${record.recordIndex}`, row);
      addGroupRow(groups.recordIndex, String(record.recordIndex), row);
    }

    for (const [scope, map] of Object.entries(groups)) {
      for (const [key, rows] of map.entries()) {
        if (rows.length < options.minExploratorySamples) continue;
        const candidate = {
          scope,
          key,
          layout,
          summary: summarizeRows(rows),
        };
        candidate.score = exploratoryScore(candidate);
        const strictReasons = strictRejectionReasons(candidate);
        const promotableReasons = promotableRejectionReasons(candidate);
        if (isExploratory(candidate)) exploratory.push(candidate);
        if (strictReasons.length === 0) strictPosition.push(candidate);
        if (promotableReasons.length === 0) promotable.push(candidate);
        bestRejected.push(candidate);
      }
    }
  }

  const sortCandidates = (a, b) => b.score - a.score || b.summary.count - a.summary.count;
  const prefixScopedExploratory = exploratory.filter((candidate) => candidate.scope !== 'recordIndex');
  const mixedRecordIndexExploratory = exploratory.filter(
    (candidate) => candidate.scope === 'recordIndex',
  );
  const transformClueExploratory = prefixScopedExploratory.filter(
    (candidate) =>
      candidate.key.startsWith('8ef267') ||
      candidate.summary.firstPackedUnrealHardcodedNames.some((entry) => entry.key === 'Transform'),
  );
  return {
    exploratoryCandidateCount: exploratory.length,
    prefixScopedExploratoryCandidateCount: prefixScopedExploratory.length,
    mixedRecordIndexExploratoryCandidateCount: mixedRecordIndexExploratory.length,
    strictPositionLaneCandidateCount: strictPosition.length,
    promotableCandidateCount: promotable.length,
    exploratoryCandidates: prefixScopedExploratory
      .sort(sortCandidates)
      .slice(0, options.maxExploratory)
      .map((candidate) => compactCandidate(candidate)),
    mixedRecordIndexExploratoryCandidates: mixedRecordIndexExploratory
      .sort(sortCandidates)
      .slice(0, Math.min(options.maxExploratory, 12))
      .map((candidate) => compactCandidate(candidate)),
    transformClueExploratoryCandidates: transformClueExploratory
      .sort(sortCandidates)
      .slice(0, Math.min(options.maxExploratory, 20))
      .map((candidate) => compactCandidate(candidate)),
    strictPositionLaneCandidates: strictPosition
      .sort(sortCandidates)
      .slice(0, options.maxExploratory)
      .map((candidate) => compactCandidate(candidate)),
    promotableCandidates: promotable
      .sort(sortCandidates)
      .slice(0, options.maxExploratory)
      .map((candidate) => compactCandidate(candidate)),
    bestRejectedCandidates: bestRejected
      .filter((candidate) => promotableRejectionReasons(candidate).length > 0)
      .sort(sortCandidates)
      .slice(0, options.maxRejected)
      .map((candidate) => compactCandidate(candidate, false)),
  };
}

function statusForVectorLayout(vectorLayouts) {
  if (vectorLayouts.promotableCandidateCount > 0) {
    return 'promotable target-RPC vector layouts found; inspect before emitting movement tracks';
  }
  if (vectorLayouts.strictPositionLaneCandidateCount > 0) {
    return 'position-like target-RPC vector layouts found, but none include authoritative NetGUID attribution';
  }
  if (vectorLayouts.exploratoryCandidateCount > 0) {
    return 'only exploratory target-RPC vector-like layouts found; no strict/promotable movement lane passed';
  }
  return 'no target-RPC signed-triplet vector layout passed exploratory gates';
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_target_rpc_vector_layouts.mjs --diagnostics replay.diagnostics.json --out target_rpc_vector_layouts.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const targetSamples = parseTargetSamples(diagnostics);
  const players = knownPlayerRefs(diagnostics);
  const records = recordsFromTargetSamples(targetSamples, players);
  const vectorLayouts = analyzeVectorLayouts(records, options);
  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
    },
    options: {
      minExploratorySamples: options.minExploratorySamples,
      maxExploratory: options.maxExploratory,
      maxRejected: options.maxRejected,
      componentBits: [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18],
      scales: [1, 10, 100, 1000],
      startBitRange: [0, 56],
    },
    notes: [
      'This report scans the proven target RPC payloads as 80-bit native records and tests fixed signed xyz triplets at every bit offset.',
      'Exploratory candidates are useful clues only. Strict lanes reject layouts that overlap the first 24 token bits, mix prefix families, stay static, jump too fast, or lack enough continuity.',
      'Promotable movement rows additionally require authoritative actor NetGUID evidence inside the same layout group; collision-level channel or low-bit matches are not enough.',
    ],
    source: {
      targetSampleCount: targetSamples.length,
      native80RecordCount: records.length,
      playerReferenceCount: players.length,
      players,
      targetPayloadFamilies: summarizeTargetPayloadFamilies(targetSamples),
      topNativeRecordFamilies: summarizeNativeRecordFamilies(records),
    },
    status: statusForVectorLayout(vectorLayouts),
    vectorLayouts,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main();
