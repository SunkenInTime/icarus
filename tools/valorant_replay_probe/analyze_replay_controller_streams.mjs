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
  maxZ: 900,
};

function parseArgs(argv) {
  const options = { diagnostics: null, out: null };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
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

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))];
}

function circularDegreesDelta(a, b) {
  const delta = Math.abs(a - b) % 360;
  return delta > 180 ? 360 - delta : delta;
}

function normalizeDegrees(value) {
  const normalized = value % 360;
  return normalized < 0 ? normalized + 360 : normalized;
}

function topCounts(values, limit = 20) {
  const counts = new Map();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return [...counts.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || String(a.key).localeCompare(String(b.key)))
    .slice(0, limit);
}

function stableRanges(flags) {
  const ranges = [];
  let start = null;
  for (let bit = 0; bit <= flags.length; bit += 1) {
    if (bit < flags.length && flags[bit]) {
      if (start == null) start = bit;
    } else if (start != null) {
      ranges.push({ start, end: bit - 1, length: bit - start });
      start = null;
    }
  }
  return ranges;
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
    .sort(
      (a, b) =>
        a.timeMs - b.timeMs ||
        a.sampleIndex - b.sampleIndex ||
        a.fieldHandle - b.fieldHandle,
    );
}

function knownPlayerGuidsFromDiagnostics(diagnostics) {
  return [
    ...new Set(
      (diagnostics.frameSummary?.channelOpenSamples ?? [])
        .filter((sample) => /Default__[^/]+_PC_C$/i.test(sample.archetypePath ?? ''))
        .filter((sample) => !/Ability|PostDeath/i.test(sample.archetypePath ?? ''))
        .map((sample) => sample.actorNetGuid)
        .filter((value) => Number.isInteger(value) && value > 0),
    ),
  ].sort((a, b) => a - b);
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
    .filter((sample) => Number.isInteger(sample.netGuid) && Number.isFinite(sample.yaw))
    .sort((a, b) => a.netGuid - b.netGuid);
}

const GUID_CATEGORY_RANK = {
  playerActor: 6,
  ownerInfoActor: 5,
  characterClassPath: 4,
  replayActor: 3,
  allOpenActor: 2,
  allPath: 1,
};

function addGuidReference(referenceMap, groups, category, netGuid, detail) {
  if (!Number.isInteger(netGuid) || netGuid <= 0) return;
  if (!groups[category]) groups[category] = new Set();
  groups[category].add(netGuid);

  if (!referenceMap.has(netGuid)) referenceMap.set(netGuid, []);
  const entries = referenceMap.get(netGuid);
  const key = `${category}:${detail ?? ''}`;
  if (!entries.some((entry) => entry.key === key)) {
    entries.push({
      key,
      category,
      detail: detail ?? null,
      rank: GUID_CATEGORY_RANK[category] ?? 0,
    });
  }
}

function summarizeGuidReferenceEntries(entries) {
  const bestByCategory = new Map();
  for (const entry of entries ?? []) {
    const current = bestByCategory.get(entry.category);
    if (!current || entry.rank > current.rank) bestByCategory.set(entry.category, entry);
  }
  return [...bestByCategory.values()]
    .sort((a, b) => b.rank - a.rank || a.category.localeCompare(b.category))
    .map(({ category, detail }) => ({ category, detail }))
    .slice(0, 5);
}

function guidReferenceFromDiagnostics(diagnostics, knownPlayerGuids = []) {
  const referenceMap = new Map();
  const groups = {};
  const channelOpenSamples = diagnostics.frameSummary?.channelOpenSamples ?? [];
  for (const sample of channelOpenSamples) {
    const netGuid = sample.actorNetGuid;
    const archetypePath = sample.archetypePath ?? '';
    addGuidReference(referenceMap, groups, 'allOpenActor', netGuid, archetypePath || null);
    if (
      /Default__[^/]+_PC_C$/i.test(archetypePath) &&
      !/Ability|PostDeath/i.test(archetypePath)
    ) {
      addGuidReference(referenceMap, groups, 'playerActor', netGuid, archetypePath);
    }
    if (/OwnerExclusivePlayerInfo/i.test(archetypePath)) {
      addGuidReference(referenceMap, groups, 'ownerInfoActor', netGuid, archetypePath);
    }
    if (/ReplayController/i.test(archetypePath)) {
      addGuidReference(referenceMap, groups, 'replayActor', netGuid, archetypePath);
    }
  }

  for (const netGuid of knownPlayerGuids) {
    addGuidReference(referenceMap, groups, 'playerActor', netGuid, 'known-player-open');
  }

  const pathSamples = [
    ...(diagnostics.frameSummary?.netGuidPathSamples ?? []),
    ...(diagnostics.frameSummary?.characterNetGuidPaths ?? []),
  ];
  for (const sample of pathSamples) {
    const netGuid = sample.netGuid;
    const pathName = sample.pathName ?? '';
    addGuidReference(referenceMap, groups, 'allPath', netGuid, pathName || null);
    if (/\/Game\/Characters\/[^/]+\/[^/]+_PC$/i.test(pathName)) {
      addGuidReference(referenceMap, groups, 'characterClassPath', netGuid, pathName);
    }
    if (/ReplayController/i.test(pathName)) {
      addGuidReference(referenceMap, groups, 'replayActor', netGuid, pathName);
    }
  }

  const groupValues = Object.fromEntries(
    Object.entries(groups).map(([category, values]) => [
      category,
      [...values].sort((a, b) => a - b),
    ]),
  );

  return {
    groupValues,
    counts: Object.fromEntries(
      Object.entries(groupValues).map(([category, values]) => [category, values.length]),
    ),
    classify(value) {
      return summarizeGuidReferenceEntries(referenceMap.get(value) ?? []);
    },
  };
}

function groupSmallFieldLanes(samples) {
  const groups = new Map();
  for (const sample of samples) {
    if (!sample.hasFullPayload || sample.bitCount <= 0 || sample.bitCount > 512) continue;
    const prefixHex = bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount));
    const key = [sample.fieldHandle, sample.fieldName ?? '', sample.bitCount, prefixHex].join('|');
    if (!groups.has(key)) {
      groups.set(key, {
        fieldHandle: sample.fieldHandle,
        fieldName: sample.fieldName ?? null,
        bitCount: sample.bitCount,
        prefixHex,
        rawEntries: [],
      });
    }
    groups.get(key).rawEntries.push(sample);
  }

  return [...groups.values()]
    .map((group) => {
      const dedup = new Map();
      for (const entry of group.rawEntries) dedup.set(`${entry.timeMs}:${entry.payloadHex}`, entry);
      const entries = [...dedup.values()].sort(
        (a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex,
      );
      const oneCounts = Array.from({ length: group.bitCount }, () => 0);
      for (const entry of entries) {
        for (let bit = 0; bit < group.bitCount; bit += 1) {
          if (readBit(entry.buffer, bit)) oneCounts[bit] += 1;
        }
      }
      const stableBits = oneCounts.map((count) => count === 0 || count === entries.length);
      const variableRanges = stableRanges(stableBits.map((stable) => !stable));
      return {
        ...group,
        entries,
        rawSampleCount: group.rawEntries.length,
        count: entries.length,
        firstTimeMs: entries[0]?.timeMs ?? null,
        lastTimeMs: entries.at(-1)?.timeMs ?? null,
        stableBitCount: stableBits.filter(Boolean).length,
        variableBitCount: stableBits.filter((stable) => !stable).length,
        stableRanges: stableRanges(stableBits),
        variableRanges,
      };
    })
    .filter((group) => group.count >= 3);
}

function summarizeScalarInterpretation(group, variableRange) {
  const series = group.entries
    .map((entry) => {
      const signed = readBitsSigned(entry.buffer, variableRange.start, variableRange.length);
      return {
        timeMs: entry.timeMs,
        signed,
        coordinateUnits: signed / 10,
        angleDegrees: (signed * 360) / 2 ** variableRange.length,
        payloadHex: entry.payloadHex,
      };
    })
    .sort((a, b) => a.timeMs - b.timeMs);

  const coordinateSpeeds = [];
  const angularSpeeds = [];
  for (let index = 1; index < series.length; index += 1) {
    const dtSeconds = (series[index].timeMs - series[index - 1].timeMs) / 1000;
    if (dtSeconds <= 0) continue;
    coordinateSpeeds.push(
      Math.abs(series[index].coordinateUnits - series[index - 1].coordinateUnits) / dtSeconds,
    );
    angularSpeeds.push(
      circularDegreesDelta(series[index].angleDegrees, series[index - 1].angleDegrees) /
        dtSeconds,
    );
  }

  const coordinateValues = series.map((entry) => entry.coordinateUnits);
  const angleValues = series.map((entry) => entry.angleDegrees);
  return {
    range: variableRange,
    coordinateUnits: {
      min: Math.min(...coordinateValues),
      max: Math.max(...coordinateValues),
      span: Math.max(...coordinateValues) - Math.min(...coordinateValues),
      medianSpeed: percentile(coordinateSpeeds, 0.5),
      p90Speed: percentile(coordinateSpeeds, 0.9),
    },
    angleDegrees: {
      min: Math.min(...angleValues),
      max: Math.max(...angleValues),
      medianAngularSpeed: percentile(angularSpeeds, 0.5),
      p90AngularSpeed: percentile(angularSpeeds, 0.9),
    },
    samples: series.slice(0, 12).map((entry) => ({
      timeMs: entry.timeMs,
      coordinateUnits: Number(entry.coordinateUnits.toFixed(1)),
      angleDegrees: Number(entry.angleDegrees.toFixed(2)),
      payloadHex: entry.payloadHex.slice(0, 96),
    })),
  };
}

function summarizeScalarCandidates(laneGroups) {
  const candidates = [];
  for (const group of laneGroups) {
    if (group.count < 20) continue;
    for (const variableRange of group.variableRanges) {
      if (variableRange.length < 12 || variableRange.length > 24) continue;
      const interpretation = summarizeScalarInterpretation(group, variableRange);
      candidates.push({
        fieldHandle: group.fieldHandle,
        fieldName: group.fieldName,
        bitCount: group.bitCount,
        prefixHex: group.prefixHex,
        count: group.count,
        rawSampleCount: group.rawSampleCount,
        firstTimeMs: group.firstTimeMs,
        lastTimeMs: group.lastTimeMs,
        variableRanges: group.variableRanges,
        interpretation,
      });
    }
  }

  const angleCandidates = candidates
    .filter(
      (candidate) =>
        candidate.count >= 100 &&
        candidate.interpretation.angleDegrees.p90AngularSpeed != null &&
        candidate.interpretation.angleDegrees.p90AngularSpeed < 5_000,
    )
    .sort(
      (a, b) =>
        b.count - a.count ||
        a.interpretation.angleDegrees.p90AngularSpeed -
          b.interpretation.angleDegrees.p90AngularSpeed,
    )
    .slice(0, 80);

  const coordinateCandidates = candidates
    .filter(
      (candidate) =>
        candidate.interpretation.coordinateUnits.min >= -14_000 &&
        candidate.interpretation.coordinateUnits.max <= 14_000 &&
        candidate.interpretation.coordinateUnits.span > 500 &&
        candidate.interpretation.coordinateUnits.p90Speed != null &&
        candidate.interpretation.coordinateUnits.p90Speed < 2_500,
    )
    .sort(
      (a, b) =>
        a.interpretation.coordinateUnits.p90Speed -
          b.interpretation.coordinateUnits.p90Speed ||
        b.count - a.count,
    )
    .slice(0, 80);

  return { angleCandidates, coordinateCandidates };
}

function roundMetric(value, digits = 1) {
  if (value == null || !Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function isPlausibleAscentXY(x, y) {
  const u = y * ASCENT_TRANSFORM.xMultiplier + ASCENT_TRANSFORM.xScalarToAdd;
  const v = x * ASCENT_TRANSFORM.yMultiplier + ASCENT_TRANSFORM.yScalarToAdd;
  return (
    u >= ASCENT_TRANSFORM.minPercent &&
    u <= ASCENT_TRANSFORM.maxPercent &&
    v >= ASCENT_TRANSFORM.minPercent &&
    v <= ASCENT_TRANSFORM.maxPercent &&
    Math.abs(x) > 50 &&
    Math.abs(y) > 50
  );
}

function summarizeScalarPairInterpretation(group, xRange, yRange, coordinateScale) {
  const series = group.entries
    .map((entry) => {
      const x = readBitsSigned(entry.buffer, xRange.start, xRange.length) / coordinateScale;
      const y = readBitsSigned(entry.buffer, yRange.start, yRange.length) / coordinateScale;
      return {
        timeMs: entry.timeMs,
        x,
        y,
        inAscentBounds: isPlausibleAscentXY(x, y),
        payloadHex: entry.payloadHex,
      };
    })
    .sort((a, b) => a.timeMs - b.timeMs || a.x - b.x || a.y - b.y);

  const xs = series.map((entry) => entry.x);
  const ys = series.map((entry) => entry.y);
  const xSpan = Math.max(...xs) - Math.min(...xs);
  const ySpan = Math.max(...ys) - Math.min(...ys);
  const xySpan = Math.hypot(xSpan, ySpan);
  const uniquePositionCount = new Set(
    series.map((entry) => `${Math.round(entry.x)}:${Math.round(entry.y)}`),
  ).size;

  const positionsByTime = new Map();
  for (const entry of series) {
    const key = String(entry.timeMs);
    if (!positionsByTime.has(key)) positionsByTime.set(key, new Set());
    positionsByTime.get(key).add(`${Math.round(entry.x)}:${Math.round(entry.y)}`);
  }
  const sameTimeConflictCount = [...positionsByTime.values()].filter(
    (positions) => positions.size > 1,
  ).length;

  const allStepDistances = [];
  const allSpeeds = [];
  const adjacentStepDistances = [];
  const adjacentSpeeds = [];
  const adjacentDts = [];
  let longGapCount = 0;
  let largeAdjacentJumpCount = 0;
  for (let index = 1; index < series.length; index += 1) {
    const previous = series[index - 1];
    const current = series[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    const distance = Math.hypot(current.x - previous.x, current.y - previous.y);
    const speed = distance / (dtMs / 1000);
    allStepDistances.push(distance);
    allSpeeds.push(speed);
    if (dtMs > 1000) longGapCount += 1;
    if (dtMs <= 250) {
      adjacentStepDistances.push(distance);
      adjacentSpeeds.push(speed);
      adjacentDts.push(dtMs);
      if (distance > 1200 || speed > 9000) largeAdjacentJumpCount += 1;
    }
  }

  const inBoundsCount = series.filter((entry) => entry.inAscentBounds).length;
  const firstTimeMs = series[0]?.timeMs ?? null;
  const lastTimeMs = series.at(-1)?.timeMs ?? null;
  return {
    rangeX: xRange,
    rangeY: yRange,
    coordinateScale,
    count: series.length,
    firstTimeMs,
    lastTimeMs,
    activeSpanMs:
      firstTimeMs == null || lastTimeMs == null ? null : Math.max(0, lastTimeMs - firstTimeMs),
    uniqueTimeCount: positionsByTime.size,
    uniquePositionCount,
    sameTimeConflictCount,
    inAscentBoundsRate: Number((inBoundsCount / Math.max(1, series.length)).toFixed(3)),
    bounds: {
      minX: roundMetric(Math.min(...xs)),
      maxX: roundMetric(Math.max(...xs)),
      minY: roundMetric(Math.min(...ys)),
      maxY: roundMetric(Math.max(...ys)),
    },
    xSpan: roundMetric(xSpan),
    ySpan: roundMetric(ySpan),
    xySpan: roundMetric(xySpan),
    staticAxisCount: [xSpan, ySpan].filter((span) => span < 50).length,
    longGapCount,
    allStepCount: allSpeeds.length,
    medianAllSpeed: roundMetric(percentile(allSpeeds, 0.5)),
    p90AllSpeed: roundMetric(percentile(allSpeeds, 0.9)),
    maxAllSpeed: roundMetric(allSpeeds.length ? Math.max(...allSpeeds) : null),
    p90AllStepDistance: roundMetric(percentile(allStepDistances, 0.9)),
    adjacentThresholdMs: 250,
    adjacentStepCount: adjacentSpeeds.length,
    medianAdjacentDtMs: roundMetric(percentile(adjacentDts, 0.5), 0),
    medianAdjacentSpeed: roundMetric(percentile(adjacentSpeeds, 0.5)),
    p90AdjacentSpeed: roundMetric(percentile(adjacentSpeeds, 0.9)),
    maxAdjacentSpeed: roundMetric(adjacentSpeeds.length ? Math.max(...adjacentSpeeds) : null),
    p90AdjacentStepDistance: roundMetric(percentile(adjacentStepDistances, 0.9)),
    largeAdjacentJumpCount,
    firstSamples: series.slice(0, 8).map((entry) => ({
      timeMs: entry.timeMs,
      x: roundMetric(entry.x),
      y: roundMetric(entry.y),
      inAscentBounds: entry.inAscentBounds,
      payloadHex: entry.payloadHex.slice(0, 96),
    })),
  };
}

function isStrictScalarPairPositionCandidate(candidate) {
  const stats = candidate.interpretation;
  return (
    stats.inAscentBoundsRate >= 0.9 &&
    stats.uniquePositionCount >= 20 &&
    stats.xySpan >= 500 &&
    stats.staticAxisCount === 0 &&
    stats.sameTimeConflictCount <= Math.max(2, Math.floor(stats.uniqueTimeCount * 0.02)) &&
    stats.adjacentStepCount >= 30 &&
    stats.p90AdjacentSpeed != null &&
    stats.p90AdjacentSpeed < 4500 &&
    stats.maxAdjacentSpeed != null &&
    stats.maxAdjacentSpeed < 12000 &&
    stats.largeAdjacentJumpCount === 0
  );
}

function rejectionReasonForScalarPair(candidate) {
  const stats = candidate.interpretation;
  const reasons = [];
  if (stats.inAscentBoundsRate < 0.9) reasons.push('low-map-bounds-rate');
  if (stats.uniquePositionCount < 20) reasons.push('low-unique-position-count');
  if (stats.xySpan < 500) reasons.push('low-xy-span');
  if (stats.staticAxisCount > 0) reasons.push('static-axis');
  if (stats.sameTimeConflictCount > Math.max(2, Math.floor(stats.uniqueTimeCount * 0.02))) {
    reasons.push('same-time-conflicts');
  }
  if (stats.adjacentStepCount < 30) reasons.push('too-few-adjacent-steps');
  if (stats.p90AdjacentSpeed == null || stats.p90AdjacentSpeed >= 4500) {
    reasons.push('high-p90-adjacent-speed');
  }
  if (stats.maxAdjacentSpeed == null || stats.maxAdjacentSpeed >= 12000) {
    reasons.push('high-max-adjacent-speed');
  }
  if (stats.largeAdjacentJumpCount > 0) reasons.push('large-adjacent-jumps');
  return reasons;
}

function scalarPairSortKey(candidate) {
  const stats = candidate.interpretation;
  const speedPenalty = Math.min(stats.p90AdjacentSpeed ?? 100_000, 100_000) / 1000;
  return (
    stats.inAscentBoundsRate * 1000 +
    stats.adjacentStepCount * 4 +
    stats.uniquePositionCount * 2 +
    Math.min(stats.xySpan, 5000) / 10 -
    stats.sameTimeConflictCount * 20 -
    stats.staticAxisCount * 200 -
    speedPenalty
  );
}

function summarizeScalarPairCandidates(laneGroups) {
  const candidates = [];
  let examinedPairCount = 0;

  for (const group of laneGroups) {
    if (group.count < 20) continue;
    const numericRanges = group.variableRanges
      .filter((range) => range.length >= 8 && range.length <= 28)
      .slice(0, 24);
    if (numericRanges.length < 2) continue;

    for (const xRange of numericRanges) {
      for (const yRange of numericRanges) {
        if (xRange.start === yRange.start && xRange.end === yRange.end) continue;
        for (const coordinateScale of [1, 10, 100]) {
          examinedPairCount += 1;
          const interpretation = summarizeScalarPairInterpretation(
            group,
            xRange,
            yRange,
            coordinateScale,
          );
          if (
            interpretation.uniquePositionCount < 5 ||
            interpretation.xySpan < 100 ||
            (interpretation.inAscentBoundsRate < 0.5 && interpretation.adjacentStepCount < 5)
          ) {
            continue;
          }
          const candidate = {
            fieldHandle: group.fieldHandle,
            fieldName: group.fieldName,
            bitCount: group.bitCount,
            prefixHex: group.prefixHex,
            groupCount: group.count,
            rawSampleCount: group.rawSampleCount,
            variableRanges: group.variableRanges,
            interpretation,
          };
          candidate.rejectionReasons = rejectionReasonForScalarPair(candidate);
          candidates.push(candidate);
        }
      }
    }
  }

  const strictCandidates = candidates
    .filter(isStrictScalarPairPositionCandidate)
    .sort(
      (a, b) =>
        (a.interpretation.p90AdjacentSpeed ?? Infinity) -
          (b.interpretation.p90AdjacentSpeed ?? Infinity) ||
        b.interpretation.adjacentStepCount - a.interpretation.adjacentStepCount,
    )
    .slice(0, 40);

  const rejectedHighJumpCandidates = candidates
    .filter(
      (candidate) =>
        candidate.interpretation.inAscentBoundsRate >= 0.8 &&
        candidate.interpretation.uniquePositionCount >= 10 &&
        candidate.interpretation.xySpan >= 500 &&
        candidate.interpretation.adjacentStepCount > 0 &&
        !isStrictScalarPairPositionCandidate(candidate),
    )
    .sort(
      (a, b) =>
        b.interpretation.adjacentStepCount - a.interpretation.adjacentStepCount ||
        b.interpretation.largeAdjacentJumpCount - a.interpretation.largeAdjacentJumpCount ||
        (b.interpretation.maxAdjacentSpeed ?? 0) - (a.interpretation.maxAdjacentSpeed ?? 0),
    )
    .slice(0, 60);

  const exploratoryCandidates = candidates
    .filter((candidate) => !isStrictScalarPairPositionCandidate(candidate))
    .sort((a, b) => scalarPairSortKey(b) - scalarPairSortKey(a))
    .slice(0, 80);

  return {
    status:
      'Ordered scalar-pair scan of variable ranges in each small replay-controller lane. Strict candidates must survive adjacent-frame continuity checks; rejected candidates document map-shaped false positives.',
    examinedPairCount,
    retainedCandidateCount: candidates.length,
    strictCandidates,
    rejectedHighJumpCandidates,
    exploratoryCandidates,
  };
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

function readIntPackedSequence(buffer, bitLimit, limit = 8) {
  const sequence = [];
  let offset = 0;
  while (offset < bitLimit && sequence.length < limit) {
    const packed = readIntPacked(buffer, offset, bitLimit);
    sequence.push({ ...packed, bitOffset: offset });
    if (!packed.ok || packed.bitCount <= 0) break;
    offset += packed.bitCount;
  }
  return sequence;
}

function formatIntPackedSequence(sequence) {
  return sequence
    .map((packed) =>
      packed.ok
        ? `${packed.value}@${packed.bitOffset}/${packed.bitCount}`
        : `bad:${packed.value}@${packed.bitOffset}/${packed.bitCount}`,
    )
    .join(' ');
}

function summarizeGuidAnchors(samples, knownPlayerGuids) {
  const known = new Set(knownPlayerGuids);
  const recurrences = new Map();
  if (!known.size) return [];

  for (const sample of samples) {
    if (!sample.hasFullPayload || sample.bitCount <= 0 || sample.bitCount > 8192) continue;
    for (let bitOffset = 0; bitOffset < sample.bitCount; bitOffset += 1) {
      const packed = readIntPacked(sample.buffer, bitOffset, sample.bitCount);
      if (!packed.ok || !known.has(packed.value)) continue;
      const prefixHex = bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount));
      const key = [
        sample.fieldHandle,
        sample.bitCount,
        bitOffset,
        packed.bitCount,
        packed.value,
        prefixHex,
      ].join('|');
      let entry = recurrences.get(key);
      if (!entry) {
        entry = {
          fieldHandle: sample.fieldHandle,
          fieldName: sample.fieldName ?? null,
          payloadBitCount: sample.bitCount,
          bitOffset,
          bitCount: packed.bitCount,
          value: packed.value,
          prefixHex,
          count: 0,
          firstTimeMs: sample.timeMs,
          lastTimeMs: sample.timeMs,
          samples: [],
        };
        recurrences.set(key, entry);
      }
      entry.count += 1;
      entry.firstTimeMs = Math.min(entry.firstTimeMs, sample.timeMs);
      entry.lastTimeMs = Math.max(entry.lastTimeMs, sample.timeMs);
      if (entry.samples.length < 8) {
        entry.samples.push({
          timeMs: sample.timeMs,
          payloadHex: sample.payloadHex.slice(0, 160),
        });
      }
    }
  }

  return [...recurrences.values()]
    .filter((entry) => entry.count >= 2)
    .sort(
      (a, b) =>
        b.count - a.count ||
        a.fieldHandle - b.fieldHandle ||
        a.bitOffset - b.bitOffset,
    )
    .slice(0, 80);
}

function summarizeVariableRanges(entries, bitCount, baseOffset = 0) {
  const oneCounts = Array.from({ length: bitCount }, () => 0);
  for (const entry of entries) {
    for (let bit = 0; bit < bitCount; bit += 1) {
      if (readBit(entry.buffer, baseOffset + bit)) oneCounts[bit] += 1;
    }
  }
  const stableBits = oneCounts.map((count) => count === 0 || count === entries.length);
  return {
    stableBitCount: stableBits.filter(Boolean).length,
    variableBitCount: stableBits.filter((stable) => !stable).length,
    stableRanges: stableRanges(stableBits),
    variableRanges: stableRanges(stableBits.map((stable) => !stable)),
  };
}

function summarizeTargetRpcNativeHeads(targetSamples, knownPlayerGuids) {
  const known = new Set(knownPlayerGuids);
  const firstValues = [];
  const sequences = [];
  const exactKnownGuidHits = [];
  const families = new Map();

  for (const sample of targetSamples) {
    const prefixHex = bitsToHex(sample.buffer, 0, Math.min(24, sample.bitCount));
    const familyKey = [sample.bitCount, prefixHex].join('|');
    if (!families.has(familyKey)) {
      families.set(familyKey, {
        bitCount: sample.bitCount,
        prefixHex,
        count: 0,
        firstTimeMs: sample.timeMs,
        lastTimeMs: sample.timeMs,
        firstValues: [],
        sequences: [],
        exactKnownGuidHits: [],
        examples: [],
      });
    }
    const family = families.get(familyKey);
    family.count += 1;
    family.firstTimeMs = Math.min(family.firstTimeMs, sample.timeMs);
    family.lastTimeMs = Math.max(family.lastTimeMs, sample.timeMs);

    const sequence = readIntPackedSequence(sample.buffer, sample.bitCount, 10);
    const sequenceText = formatIntPackedSequence(sequence);
    sequences.push(sequenceText);
    family.sequences.push(sequenceText);
    if (sequence[0]?.ok) {
      const firstValueText = String(sequence[0].value);
      firstValues.push(firstValueText);
      family.firstValues.push(firstValueText);
    }

    if (known.size) {
      for (let bitOffset = 0; bitOffset < sample.bitCount; bitOffset += 1) {
        const packed = readIntPacked(sample.buffer, bitOffset, sample.bitCount);
        if (packed.ok && known.has(packed.value)) {
          const hit = `intPacked:${packed.value}@${bitOffset}/${packed.bitCount}`;
          exactKnownGuidHits.push(hit);
          family.exactKnownGuidHits.push(hit);
        }
        if (bitOffset + 32 <= sample.bitCount) {
          const value = readBitsUnsigned(sample.buffer, bitOffset, 32);
          if (known.has(value)) {
            const hit = `uint32:${value}@${bitOffset}/32`;
            exactKnownGuidHits.push(hit);
            family.exactKnownGuidHits.push(hit);
          }
        }
      }
    }

    if (family.examples.length < 6) {
      family.examples.push({
        timeMs: sample.timeMs,
        payloadHex: sample.payloadHex.slice(0, 96),
        intPackedHead: sequenceText,
      });
    }
  }

  return {
    status:
      'Native-head probe for target RPC payloads. Int-packed heads are structural clues only; exact known-player GUID hits are scanned independently across each payload.',
    firstIntPackedValues: topCounts(firstValues, 20),
    topIntPackedHeadSequences: topCounts(sequences, 20),
    exactKnownGuidHits: topCounts(exactKnownGuidHits, 30),
    payloadFamilies: [...families.values()]
      .map((family) => ({
        bitCount: family.bitCount,
        prefixHex: family.prefixHex,
        count: family.count,
        firstTimeMs: family.firstTimeMs,
        lastTimeMs: family.lastTimeMs,
        topFirstIntPackedValues: topCounts(family.firstValues, 8),
        topIntPackedHeadSequences: topCounts(family.sequences, 8),
        exactKnownGuidHits: topCounts(family.exactKnownGuidHits, 12),
        examples: family.examples,
      }))
      .sort((a, b) => b.count - a.count || a.bitCount - b.bitCount)
      .slice(0, 60),
  };
}

function parseTargetPropertyStreamAt(sample, bitOffset, maxFields = 8) {
  const fields = [];
  let offset = bitOffset;
  for (let index = 0; index < maxFields && offset < sample.bitCount; index += 1) {
    const rawHandle = readIntPacked(sample.buffer, offset, sample.bitCount);
    if (!rawHandle.ok) {
      return { ok: false, bitOffset, fields, error: 'raw-handle' };
    }
    offset += rawHandle.bitCount;
    if (rawHandle.value === 0) {
      return { ok: true, bitOffset, fields, terminated: true, consumedBits: offset - bitOffset };
    }

    const handle = rawHandle.value - 1;
    const numBits = readIntPacked(sample.buffer, offset, sample.bitCount);
    if (!numBits.ok) {
      return { ok: false, bitOffset, fields, error: 'num-bits', handle };
    }
    offset += numBits.bitCount;
    if (numBits.value > sample.bitCount - offset) {
      return {
        ok: false,
        bitOffset,
        fields,
        error: 'payload-overrun',
        handle,
        numBits: numBits.value,
        remainingBits: sample.bitCount - offset,
      };
    }
    fields.push({ handle, numBits: numBits.value });
    offset += numBits.value;
  }

  return { ok: true, bitOffset, fields, terminated: false, consumedBits: offset - bitOffset };
}

function summarizeTargetRpcPropertyAlignment(targetSamples) {
  const alignmentScores = [];
  for (let bitOffset = 0; bitOffset < 16; bitOffset += 1) {
    let parseOkCount = 0;
    let terminatedCount = 0;
    let nonEmptyValidTargetFieldCount = 0;
    let emptyTerminatorCount = 0;
    const examples = [];

    for (const sample of targetSamples) {
      const parsed = parseTargetPropertyStreamAt(sample, bitOffset);
      if (!parsed.ok) continue;
      parseOkCount += 1;
      if (parsed.terminated) terminatedCount += 1;
      if (parsed.fields.length === 0 && parsed.terminated) emptyTerminatorCount += 1;

      const allFieldsAreTargetFields = parsed.fields.every(
        (field) => field.handle >= 0 && field.handle <= 3,
      );
      if (parsed.fields.length > 0 && allFieldsAreTargetFields) {
        nonEmptyValidTargetFieldCount += 1;
      }
      if (
        examples.length < 8 &&
        (parsed.fields.length > 0 || (parsed.terminated && bitOffset <= 3))
      ) {
        examples.push({
          timeMs: sample.timeMs,
          bitCount: sample.bitCount,
          fields: parsed.fields.slice(0, 6),
          terminated: parsed.terminated,
          consumedBits: parsed.consumedBits,
          payloadPrefixHex: sample.payloadHex.slice(0, 32),
        });
      }
    }

    alignmentScores.push({
      bitOffset,
      parseOkCount,
      terminatedCount,
      emptyTerminatorCount,
      nonEmptyValidTargetFieldCount,
      examples,
    });
  }

  return {
    status:
      'Target RPC payloads do not parse as a recurring normal target-function RepLayout property stream at bit offsets 0-15. Successful parses are mostly empty terminators; the only non-empty handles-0..3 parse in the current sample is a one-off collision-level lead.',
    targetExportHandles: [
      '0:bIsReplayFastForwardImportant',
      '1:RemoteCharacterUpdates',
      '2:ShooterCharacterNetGuidValue',
      '3:ComponentDataStream',
    ],
    sampleCount: targetSamples.length,
    alignmentScores,
  };
}

function summarizeTargetRpcPayloads(samples, knownPlayerGuids = []) {
  const targetSamples = samples.filter(
    (sample) =>
      sample.fieldHandle === 3 &&
      /ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous/i.test(
        sample.fieldName ?? '',
      ),
  );
  if (!targetSamples.length) {
    return {
      count: 0,
      status: 'Target RPC payload was not captured in this diagnostics file.',
    };
  }

  const bitCountGroups = new Map();
  for (const sample of targetSamples) {
    if (!bitCountGroups.has(sample.bitCount)) bitCountGroups.set(sample.bitCount, []);
    bitCountGroups.get(sample.bitCount).push(sample);
  }

  const payloadBitCounts = [...bitCountGroups.entries()]
    .map(([bitCount, entries]) => ({
      bitCount,
      count: entries.length,
      firstTimeMs: Math.min(...entries.map((entry) => entry.timeMs)),
      lastTimeMs: Math.max(...entries.map((entry) => entry.timeMs)),
      topPrefixes8: topCounts(
        entries.map((entry) => bitsToHex(entry.buffer, 0, Math.min(8, entry.bitCount))),
        12,
      ),
      topPrefixes24: topCounts(
        entries.map((entry) => bitsToHex(entry.buffer, 0, Math.min(24, entry.bitCount))),
        12,
      ),
    }))
    .sort((a, b) => b.count - a.count || a.bitCount - b.bitCount);

  const smallPayloadLanes = [];
  for (const [bitCount, entries] of bitCountGroups.entries()) {
    if (bitCount > 128 || entries.length < 3) continue;
    const prefixGroups = new Map();
    for (const entry of entries) {
      const prefixHex = bitsToHex(entry.buffer, 0, Math.min(8, bitCount));
      if (!prefixGroups.has(prefixHex)) prefixGroups.set(prefixHex, []);
      prefixGroups.get(prefixHex).push(entry);
    }
    for (const [prefixHex, laneEntries] of prefixGroups.entries()) {
      if (laneEntries.length < 3) continue;
      const ranges = summarizeVariableRanges(laneEntries, bitCount);
      smallPayloadLanes.push({
        bitCount,
        prefixHex,
        count: laneEntries.length,
        firstTimeMs: Math.min(...laneEntries.map((entry) => entry.timeMs)),
        lastTimeMs: Math.max(...laneEntries.map((entry) => entry.timeMs)),
        ...ranges,
        samples: laneEntries.slice(0, 8).map((entry) => ({
          timeMs: entry.timeMs,
          payloadHex: entry.payloadHex.slice(0, 64),
        })),
      });
    }
  }

  const fixedRecordSplitHypotheses = [];
  for (const [bitCount, entries] of bitCountGroups.entries()) {
    if (entries.length < 3 || bitCount < 512) continue;
    for (const recordCount of [4, 5, 8, 10, 12]) {
      for (const headerBits of [0, 1, 2, 4, 8, 16, 24, 32]) {
        const remainingBits = bitCount - headerBits;
        if (remainingBits <= 0 || remainingBits % recordCount !== 0) continue;
        const recordBits = remainingBits / recordCount;
        if (recordBits < 32 || recordBits > 512) continue;
        const records = [];
        for (let recordIndex = 0; recordIndex < recordCount; recordIndex += 1) {
          const recordOffset = headerBits + recordIndex * recordBits;
          const prefixes = entries.map((entry) =>
            bitsToHex(entry.buffer, recordOffset, Math.min(32, recordBits)),
          );
          const firstPackedValues = entries
            .map((entry) => readIntPacked(entry.buffer, recordOffset, entry.bitCount))
            .filter((packed) => packed?.ok)
            .map((packed) => `${packed.value}:${packed.bitCount}`);
          records.push({
            recordIndex,
            recordOffset,
            recordBits,
            uniquePrefixCount: new Set(prefixes).size,
            topPrefixes: topCounts(prefixes, 6),
            topFirstIntPacked: topCounts(firstPackedValues, 8),
            ...summarizeVariableRanges(entries, recordBits, recordOffset),
          });
        }
        fixedRecordSplitHypotheses.push({
          bitCount,
          sampleCount: entries.length,
          headerBits,
          recordCount,
          recordBits,
          constantRecordCount: records.filter((record) => record.variableBitCount === 0).length,
          lowVariationRecordCount: records.filter((record) => record.uniquePrefixCount <= 2).length,
          records,
        });
      }
    }
  }

  return {
    count: targetSamples.length,
    status:
      'Target RPC payloads are captured, but still look native/custom rather than normal RepLayout fields.',
    payloadBitCounts,
    propertyAlignmentSummary: summarizeTargetRpcPropertyAlignment(targetSamples),
    nativeHeadSummary: summarizeTargetRpcNativeHeads(targetSamples, knownPlayerGuids),
    smallPayloadLanes: smallPayloadLanes
      .sort((a, b) => b.count - a.count || a.bitCount - b.bitCount)
      .slice(0, 40),
    fixedRecordSplitHypotheses: fixedRecordSplitHypotheses
      .sort(
        (a, b) =>
          b.sampleCount - a.sampleCount ||
          b.lowVariationRecordCount - a.lowVariationRecordCount ||
          a.recordBits - b.recordBits,
      )
      .slice(0, 20),
  };
}

const TARGET_SLOT_IDENTITY_ENCODINGS = [
  { name: 'uint10', kind: 'uint', bitCount: 10 },
  { name: 'uint11', kind: 'uint', bitCount: 11 },
  { name: 'uint12', kind: 'uint', bitCount: 12 },
  { name: 'uint13', kind: 'uint', bitCount: 13 },
  { name: 'uint14', kind: 'uint', bitCount: 14 },
  { name: 'uint15', kind: 'uint', bitCount: 15 },
  { name: 'uint16', kind: 'uint', bitCount: 16 },
  { name: 'uint24', kind: 'uint', bitCount: 24 },
  { name: 'uint32', kind: 'uint', bitCount: 32 },
  { name: 'intPacked', kind: 'intPacked', bitCount: null },
];

function readSlotIdentityValue(sample, slotOffset, localOffset, slotBitCount, encoding) {
  const absoluteOffset = slotOffset + localOffset;
  const bitLimit = slotOffset + slotBitCount;
  if (encoding.kind === 'intPacked') {
    return readIntPacked(sample.buffer, absoluteOffset, bitLimit);
  }
  if (localOffset + encoding.bitCount > slotBitCount) {
    return { ok: false, value: null, bitCount: 0 };
  }
  return {
    ok: true,
    value: readBitsUnsigned(sample.buffer, absoluteOffset, encoding.bitCount),
    bitCount: encoding.bitCount,
  };
}

function bestGuidCategoryRank(categories) {
  return Math.max(0, ...categories.map((entry) => GUID_CATEGORY_RANK[entry.category] ?? 0));
}

function collisionRiskForIdentityHit(decodedBitCount, categories) {
  const rank = bestGuidCategoryRank(categories);
  if (decodedBitCount <= 8) return 'high-small-width-collision-risk';
  if (decodedBitCount <= 10 && rank < GUID_CATEGORY_RANK.playerActor) {
    return 'medium-small-width-collision-risk';
  }
  if (rank <= GUID_CATEGORY_RANK.allOpenActor) return 'weak-reference-set';
  return 'lower';
}

function summarizeIdentityLayoutCandidate(encoding, localOffset, stableSlots, slotCount) {
  const categorySlotCounts = {};
  const categoryValueSets = {};
  for (const slot of stableSlots) {
    for (const category of slot.categories.map((entry) => entry.category)) {
      categorySlotCounts[category] = (categorySlotCounts[category] ?? 0) + 1;
      if (!categoryValueSets[category]) categoryValueSets[category] = new Set();
      categoryValueSets[category].add(slot.value);
    }
  }
  const categoryDistinctValueCounts = Object.fromEntries(
    Object.entries(categoryValueSets).map(([category, values]) => [category, values.size]),
  );
  const values = stableSlots.map((slot) => slot.value);
  const distinctValueCount = new Set(values).size;
  const knownSlotCount = stableSlots.filter((slot) => slot.categories.length > 0).length;
  const observedBitWidth =
    encoding.bitCount ?? Math.max(0, ...stableSlots.map((slot) => slot.decodedBitCount ?? 0));
  const duplicateValueCount = stableSlots.length - distinctValueCount;
  const smallWidthPenalty = observedBitWidth <= 8 ? 140 : observedBitWidth <= 10 ? 60 : 0;
  const weakReferencePenalty =
    knownSlotCount > 0 &&
    (categoryDistinctValueCounts.playerActor ?? 0) === 0 &&
    (categoryDistinctValueCounts.ownerInfoActor ?? 0) === 0
      ? 25
      : 0;
  const highWidthIdentityBonus =
    encoding.name === 'uint32' && stableSlots.length >= 8 && distinctValueCount >= 6 ? 30 : 0;
  const score =
    (categoryDistinctValueCounts.playerActor ?? 0) * 120 +
    (categoryDistinctValueCounts.ownerInfoActor ?? 0) * 70 +
    (categoryDistinctValueCounts.characterClassPath ?? 0) * 30 +
    (categoryDistinctValueCounts.replayActor ?? 0) * 12 +
    (categoryDistinctValueCounts.allOpenActor ?? 0) * 8 +
    (categoryDistinctValueCounts.allPath ?? 0) * 3 +
    knownSlotCount * 5 +
    stableSlots.length * 2 +
    highWidthIdentityBonus -
    duplicateValueCount * 12 -
    smallWidthPenalty -
    weakReferencePenalty;

  return {
    encoding: encoding.name,
    localOffset,
    bitCount: encoding.bitCount,
    observedBitWidth,
    stableSlotCount: stableSlots.length,
    slotCount,
    knownSlotCount,
    distinctValueCount,
    duplicateValueCount,
    categorySlotCounts,
    categoryDistinctValueCounts,
    score,
    slots: stableSlots.map((slot) => ({
      slotIndex: slot.slotIndex,
      value: slot.value,
      decodedBitCount: slot.decodedBitCount,
      categories: slot.categories,
    })),
  };
}

function summarizeTargetRpc1498SlotIdentityScan(targetSamples, guidReference, hypothesis) {
  const { slotHeaderBits, slotBitCount, slotCount } = hypothesis;
  const stableKnownSlotHits = [];
  const layoutCandidates = [];

  for (const encoding of TARGET_SLOT_IDENTITY_ENCODINGS) {
    const maxLocalOffset =
      encoding.kind === 'intPacked' ? slotBitCount - 1 : slotBitCount - encoding.bitCount;
    for (let localOffset = 0; localOffset <= maxLocalOffset; localOffset += 1) {
      const stableSlots = [];
      for (let slotIndex = 0; slotIndex < slotCount; slotIndex += 1) {
        const slotOffset = slotHeaderBits + slotIndex * slotBitCount;
        const values = [];
        const bitCounts = [];
        let ok = true;
        for (const sample of targetSamples) {
          const decoded = readSlotIdentityValue(
            sample,
            slotOffset,
            localOffset,
            slotBitCount,
            encoding,
          );
          if (!decoded.ok) {
            ok = false;
            break;
          }
          values.push(decoded.value);
          bitCounts.push(decoded.bitCount);
        }
        if (!ok || new Set(values).size !== 1) continue;

        const value = values[0];
        const decodedBitCount = bitCounts[0] ?? encoding.bitCount ?? null;
        const categories = guidReference.classify(value);
        const stableSlot = {
          slotIndex,
          value,
          decodedBitCount,
          categories,
        };
        stableSlots.push(stableSlot);

        if (categories.length > 0) {
          stableKnownSlotHits.push({
            slotIndex,
            encoding: encoding.name,
            localOffset,
            value,
            decodedBitCount,
            categories,
            bestCategoryRank: bestGuidCategoryRank(categories),
            collisionRisk: collisionRiskForIdentityHit(decodedBitCount, categories),
          });
        }
      }

      if (!stableSlots.length) continue;
      const candidate = summarizeIdentityLayoutCandidate(
        encoding,
        localOffset,
        stableSlots,
        slotCount,
      );
      const isStableUnknownUint32 =
        encoding.name === 'uint32' &&
        candidate.stableSlotCount >= 8 &&
        candidate.distinctValueCount >= 6;
      if (candidate.knownSlotCount > 0 || isStableUnknownUint32) {
        layoutCandidates.push(candidate);
      }
    }
  }

  const sortedLayouts = layoutCandidates.sort(
    (a, b) =>
      b.score - a.score ||
      b.knownSlotCount - a.knownSlotCount ||
      b.distinctValueCount - a.distinctValueCount ||
      a.localOffset - b.localOffset,
  );
  const strongPlayerLayout = sortedLayouts.find(
    (candidate) =>
      (candidate.categoryDistinctValueCounts.playerActor ?? 0) >= 8 &&
      candidate.stableSlotCount >= 8,
  );
  const ownerInfoLayout = sortedLayouts.find(
    (candidate) =>
      (candidate.categoryDistinctValueCounts.ownerInfoActor ?? 0) >= 8 &&
      candidate.stableSlotCount >= 8,
  );
  const weakPlayerLayout = sortedLayouts.find(
    (candidate) => (candidate.categoryDistinctValueCounts.playerActor ?? 0) >= 2,
  );
  const status = strongPlayerLayout
    ? 'A same-offset stable slot layout maps most 149-bit slots to known player actor NetGUIDs; inspect before promoting to a decoder.'
    : ownerInfoLayout
      ? 'A same-offset stable slot layout maps most 149-bit slots to owner-info actor GUIDs, but not directly to player actor NetGUIDs.'
      : weakPlayerLayout
        ? 'Only weak same-offset player-GUID coincidences were found; treat them as structure leads, not identities.'
        : 'No same-offset stable identity layout maps the ten 149-bit slots to known player actor or owner-info GUIDs; single-slot exact hits remain collision-prone.';

  return {
    status,
    sampleCount: targetSamples.length,
    guidReferenceCounts: guidReference.counts,
    encodingsScanned: TARGET_SLOT_IDENTITY_ENCODINGS.map((encoding) => encoding.name),
    stableKnownSlotHits: stableKnownSlotHits
      .sort(
        (a, b) =>
          b.bestCategoryRank - a.bestCategoryRank ||
          b.decodedBitCount - a.decodedBitCount ||
          a.slotIndex - b.slotIndex ||
          a.localOffset - b.localOffset,
      )
      .slice(0, 80)
      .map(({ bestCategoryRank, ...hit }) => hit),
    layoutCandidates: sortedLayouts.slice(0, 40),
    stableUnknownUint32Layouts: sortedLayouts
      .filter(
        (candidate) =>
          candidate.encoding === 'uint32' &&
          candidate.knownSlotCount === 0 &&
          candidate.stableSlotCount >= 8 &&
          candidate.distinctValueCount >= 6,
      )
      .slice(0, 20),
  };
}

function summarizeTargetRpc1498Slots(samples, guidReference) {
  const known = new Set(guidReference.groupValues.playerActor ?? []);
  const targetSamples = samples.filter(
    (sample) =>
      sample.hasFullPayload &&
      sample.fieldHandle === 3 &&
      sample.bitCount === 1498 &&
      /ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous/i.test(
        sample.fieldName ?? '',
      ),
  );
  const slotHeaderBits = 8;
  const slotBitCount = 149;
  const slotCount = 10;
  if (!targetSamples.length) {
    return {
      status: 'No 1498-bit target RPC burst payloads were captured.',
      sampleCount: 0,
      hypothesis: { slotHeaderBits, slotBitCount, slotCount },
      slots: [],
    };
  }

  const slots = [];
  for (let slotIndex = 0; slotIndex < slotCount; slotIndex += 1) {
    const slotOffset = slotHeaderBits + slotIndex * slotBitCount;
    const oneCounts = Array.from({ length: slotBitCount }, () => 0);
    const prefixHexes = [];
    const suffixHexes = [];
    const intPackedHeads = [];
    const exactKnownGuidHits = [];

    for (const sample of targetSamples) {
      for (let bit = 0; bit < slotBitCount; bit += 1) {
        if (readBit(sample.buffer, slotOffset + bit)) oneCounts[bit] += 1;
      }
      prefixHexes.push(bitsToHex(sample.buffer, slotOffset, Math.min(48, slotBitCount)));
      suffixHexes.push(bitsToHex(sample.buffer, slotOffset + slotBitCount - 32, 32));

      const head = [];
      let localOffset = 0;
      for (let index = 0; index < 8 && localOffset < slotBitCount; index += 1) {
        const packed = readIntPacked(
          sample.buffer,
          slotOffset + localOffset,
          slotOffset + slotBitCount,
        );
        head.push(
          packed.ok
            ? `${packed.value}@${localOffset}/${packed.bitCount}`
            : `bad:${packed.value}@${localOffset}/${packed.bitCount}`,
        );
        if (!packed.ok || packed.bitCount <= 0) break;
        localOffset += packed.bitCount;
      }
      intPackedHeads.push(head.join(' '));

      if (!known.size) continue;
      for (let bitOffset = 0; bitOffset < slotBitCount; bitOffset += 1) {
        const packed = readIntPacked(
          sample.buffer,
          slotOffset + bitOffset,
          slotOffset + slotBitCount,
        );
        if (packed.ok && known.has(packed.value)) {
          exactKnownGuidHits.push(`intPacked:${packed.value}@${bitOffset}/${packed.bitCount}`);
        }
        if (bitOffset + 32 <= slotBitCount) {
          const uint32 = readBitsUnsigned(sample.buffer, slotOffset + bitOffset, 32);
          if (known.has(uint32)) exactKnownGuidHits.push(`uint32:${uint32}@${bitOffset}/32`);
        }
      }
    }

    const stableBits = oneCounts.map(
      (count) => count === 0 || count === targetSamples.length,
    );
    const variableRanges = stableRanges(stableBits.map((stable) => !stable));
    const numericVariableRanges = variableRanges
      .filter((range) => range.length >= 8 && range.length <= 24)
      .slice(0, 12)
      .map((range) => {
        const signedValues = targetSamples.map((sample) =>
          readBitsSigned(sample.buffer, slotOffset + range.start, range.length),
        );
        const coordinateValues = signedValues.map((value) => value / 10);
        const angleValues = signedValues.map((value) => (value * 360) / 2 ** range.length);
        return {
          range,
          signed: {
            min: Math.min(...signedValues),
            max: Math.max(...signedValues),
            uniqueCount: new Set(signedValues).size,
            samples: signedValues.slice(0, 12),
          },
          coordinateUnits: {
            min: Number(Math.min(...coordinateValues).toFixed(1)),
            max: Number(Math.max(...coordinateValues).toFixed(1)),
          },
          angleDegrees: {
            min: Number(Math.min(...angleValues).toFixed(1)),
            max: Number(Math.max(...angleValues).toFixed(1)),
          },
        };
      });

    slots.push({
      slotIndex,
      bitOffset: slotOffset,
      bitCount: slotBitCount,
      stableBitCount: stableBits.filter(Boolean).length,
      variableBitCount: stableBits.filter((stable) => !stable).length,
      stableRanges: stableRanges(stableBits)
        .sort((a, b) => b.length - a.length || a.start - b.start)
        .slice(0, 10),
      variableRanges,
      topPrefixes: topCounts(prefixHexes, 8),
      topSuffixes: topCounts(suffixHexes, 8),
      topIntPackedHeads: topCounts(intPackedHeads, 8),
      exactKnownGuidHits: topCounts(exactKnownGuidHits, 12),
      numericVariableRanges,
      firstSamples: targetSamples.slice(0, 4).map((sample) => ({
        timeMs: sample.timeMs,
        slotHex: bitsToHex(sample.buffer, slotOffset, Math.min(80, slotBitCount)),
      })),
    });
  }

  return {
    status:
      '1498-bit target RPC bursts fit 8 header bits plus ten 149-bit slots. Slot summaries test the ten-player-array hypothesis, but no slot is decoded as confirmed movement yet.',
    sampleCount: targetSamples.length,
    firstTimeMs: targetSamples[0]?.timeMs ?? null,
    lastTimeMs: targetSamples.at(-1)?.timeMs ?? null,
    hypothesis: { slotHeaderBits, slotBitCount, slotCount },
    identityScan: summarizeTargetRpc1498SlotIdentityScan(targetSamples, guidReference, {
      slotHeaderBits,
      slotBitCount,
      slotCount,
    }),
    slots,
  };
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
    if (this.isError) return null;
    return vector;
  }
}

function isPlausibleAscentVector(vector) {
  const u = vector.y * ASCENT_TRANSFORM.xMultiplier + ASCENT_TRANSFORM.xScalarToAdd;
  const v = vector.x * ASCENT_TRANSFORM.yMultiplier + ASCENT_TRANSFORM.yScalarToAdd;
  return (
    u >= ASCENT_TRANSFORM.minPercent &&
    u <= ASCENT_TRANSFORM.maxPercent &&
    v >= ASCENT_TRANSFORM.minPercent &&
    v <= ASCENT_TRANSFORM.maxPercent &&
    vector.z >= ASCENT_TRANSFORM.minZ &&
    vector.z <= ASCENT_TRANSFORM.maxZ &&
    Math.abs(vector.x) > 50 &&
    Math.abs(vector.y) > 50
  );
}

function vectorAt(sample, offset, scaleFactor, componentBits, extraInfo) {
  const reader = new BitCursor(sample.buffer, sample.bitCount, offset);
  const vector = reader.readPackedVector(scaleFactor);
  if (
    !vector ||
    reader.isError ||
    vector.componentBits !== componentBits ||
    vector.extraInfo !== extraInfo ||
    !isPlausibleAscentVector(vector)
  ) {
    return null;
  }
  return vector;
}

function summarizeLargeVectorCandidates(samples) {
  const groups = new Map();
  for (const sample of samples) {
    if (!sample.hasFullPayload || sample.bitCount <= 512 || sample.bitCount > 8192) continue;
    const prefixHex = bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount));
    const key = [sample.fieldHandle, sample.fieldName ?? '', sample.bitCount, prefixHex].join('|');
    if (!groups.has(key)) {
      groups.set(key, {
        fieldHandle: sample.fieldHandle,
        fieldName: sample.fieldName ?? null,
        bitCount: sample.bitCount,
        prefixHex,
        entries: [],
      });
    }
    groups.get(key).entries.push(sample);
  }

  const candidates = [];
  const sortedGroups = [...groups.values()]
    .filter((group) => group.entries.length >= 8)
    .sort((a, b) => b.entries.length - a.entries.length)
    .slice(0, 80);

  for (const group of sortedGroups) {
    const probeEntries = group.entries.slice(0, Math.min(40, group.entries.length));
    const probeCounts = new Map();
    const maxOffset = Math.min(group.bitCount - 32, 4096);
    for (const entry of probeEntries) {
      for (let offset = 0; offset < maxOffset; offset += 1) {
        for (const scaleFactor of [1, 10, 100]) {
          const reader = new BitCursor(entry.buffer, group.bitCount, offset);
          const vector = reader.readPackedVector(scaleFactor);
          if (!vector || reader.isError || !isPlausibleAscentVector(vector)) continue;
          const key = [
            offset,
            scaleFactor,
            vector.componentBits,
            vector.extraInfo,
          ].join('|');
          probeCounts.set(key, (probeCounts.get(key) ?? 0) + 1);
        }
      }
    }

    const recurringKeys = [...probeCounts.entries()]
      .filter(([, count]) => count >= Math.max(5, Math.floor(probeEntries.length * 0.25)))
      .sort((a, b) => b[1] - a[1])
      .slice(0, 120);

    for (const [key, probeCount] of recurringKeys) {
      const [offset, scaleFactor, componentBits, extraInfo] = key.split('|').map(Number);
      const byTime = new Map();
      for (const entry of group.entries) {
        const vector = vectorAt(entry, offset, scaleFactor, componentBits, extraInfo);
        if (vector) byTime.set(entry.timeMs, { timeMs: entry.timeMs, ...vector });
      }
      const series = [...byTime.values()].sort((a, b) => a.timeMs - b.timeMs);
      if (series.length < Math.max(8, Math.floor(group.entries.length * 0.25))) continue;

      const stepDistances = [];
      const speeds = [];
      for (let index = 1; index < series.length; index += 1) {
        const dtSeconds = (series[index].timeMs - series[index - 1].timeMs) / 1000;
        if (dtSeconds <= 0) continue;
        const distance = Math.hypot(
          series[index].x - series[index - 1].x,
          series[index].y - series[index - 1].y,
        );
        stepDistances.push(distance);
        speeds.push(distance / dtSeconds);
      }

      const uniquePositions = new Set(
        series.map(
          (entry) =>
            `${Math.round(entry.x)}:${Math.round(entry.y)}:${Math.round(entry.z)}`,
        ),
      );
      const xs = series.map((entry) => entry.x);
      const ys = series.map((entry) => entry.y);
      const zs = series.map((entry) => entry.z);
      const span = Math.hypot(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys));
      candidates.push({
        fieldHandle: group.fieldHandle,
        fieldName: group.fieldName,
        bitCount: group.bitCount,
        prefixHex: group.prefixHex,
        groupCount: group.entries.length,
        offset,
        scaleFactor,
        componentBits,
        extraInfo,
        probeCount,
        count: series.length,
        uniquePositionCount: uniquePositions.size,
        xySpan: span,
        bounds: {
          minX: Math.min(...xs),
          maxX: Math.max(...xs),
          minY: Math.min(...ys),
          maxY: Math.max(...ys),
          minZ: Math.min(...zs),
          maxZ: Math.max(...zs),
        },
        medianSpeed: percentile(speeds, 0.5),
        p90Speed: percentile(speeds, 0.9),
        p90StepDistance: percentile(stepDistances, 0.9),
        firstSamples: series.slice(0, 6).map((entry) => ({
          timeMs: entry.timeMs,
          x: Number(entry.x.toFixed(2)),
          y: Number(entry.y.toFixed(2)),
          z: Number(entry.z.toFixed(2)),
        })),
      });
    }
  }

  return {
    dynamicCandidates: candidates
      .filter((candidate) => candidate.uniquePositionCount >= 20 && candidate.xySpan >= 500)
      .sort((a, b) => (a.p90Speed ?? Infinity) - (b.p90Speed ?? Infinity))
      .slice(0, 120),
    highCoverageCandidates: candidates
      .filter((candidate) => candidate.uniquePositionCount >= 10 && candidate.xySpan >= 200)
      .sort((a, b) => b.count - a.count || (a.p90Speed ?? Infinity) - (b.p90Speed ?? Infinity))
      .slice(0, 120),
  };
}

function payloadGroupKey(fieldHandle, bitCount, prefixHex) {
  return [fieldHandle, bitCount, prefixHex].join('|');
}

function indexSamplesByPayloadGroup(samples) {
  const groups = new Map();
  for (const sample of samples) {
    if (!sample.hasFullPayload || sample.bitCount <= 0 || sample.bitCount > 8192) continue;
    const prefixHex = bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount));
    const key = payloadGroupKey(sample.fieldHandle, sample.bitCount, prefixHex);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(sample);
  }
  for (const entries of groups.values()) {
    entries.sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
  }
  return groups;
}

function summarizeVectorSeries(series) {
  const stepDistances = [];
  const speeds = [];
  for (let index = 1; index < series.length; index += 1) {
    const dtSeconds = (series[index].timeMs - series[index - 1].timeMs) / 1000;
    if (dtSeconds <= 0) continue;
    const distance = Math.hypot(
      series[index].x - series[index - 1].x,
      series[index].y - series[index - 1].y,
    );
    stepDistances.push(distance);
    speeds.push(distance / dtSeconds);
  }

  const xs = series.map((entry) => entry.x);
  const ys = series.map((entry) => entry.y);
  const zs = series.map((entry) => entry.z);
  const uniquePositions = new Set(
    series.map(
      (entry) => `${Math.round(entry.x)}:${Math.round(entry.y)}:${Math.round(entry.z)}`,
    ),
  );
  return {
    count: series.length,
    uniquePositionCount: uniquePositions.size,
    xySpan: Math.hypot(Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys)),
    bounds: {
      minX: Math.min(...xs),
      maxX: Math.max(...xs),
      minY: Math.min(...ys),
      maxY: Math.max(...ys),
      minZ: Math.min(...zs),
      maxZ: Math.max(...zs),
    },
    medianSpeed: percentile(speeds, 0.5),
    p90Speed: percentile(speeds, 0.9),
    p90StepDistance: percentile(stepDistances, 0.9),
    firstSamples: series.slice(0, 8).map((entry) => ({
      timeMs: entry.timeMs,
      x: Number(entry.x.toFixed(2)),
      y: Number(entry.y.toFixed(2)),
      z: Number(entry.z.toFixed(2)),
    })),
  };
}

function uniqueVectorCandidates(largeVectorCandidates) {
  const byKey = new Map();
  for (const candidate of [
    ...(largeVectorCandidates.highCoverageCandidates ?? []),
    ...(largeVectorCandidates.dynamicCandidates ?? []),
  ]) {
    const key = [
      candidate.fieldHandle,
      candidate.bitCount,
      candidate.prefixHex,
      candidate.offset,
      candidate.scaleFactor,
      candidate.componentBits,
      candidate.extraInfo,
    ].join('|');
    const existing = byKey.get(key);
    if (!existing || candidate.count > existing.count) byKey.set(key, candidate);
  }
  return [...byKey.values()];
}

function summarizeGuidVectorJoins(samples, guidAnchors, largeVectorCandidates) {
  const samplesByGroup = indexSamplesByPayloadGroup(samples);
  const vectorCandidates = uniqueVectorCandidates(largeVectorCandidates);
  const vectorCandidatesByGroup = new Map();
  for (const candidate of vectorCandidates) {
    const key = payloadGroupKey(candidate.fieldHandle, candidate.bitCount, candidate.prefixHex);
    if (!vectorCandidatesByGroup.has(key)) vectorCandidatesByGroup.set(key, []);
    vectorCandidatesByGroup.get(key).push(candidate);
  }

  const joins = [];
  for (const anchor of guidAnchors) {
    if (anchor.payloadBitCount <= 512 || anchor.count < 3) continue;
    const key = payloadGroupKey(anchor.fieldHandle, anchor.payloadBitCount, anchor.prefixHex);
    const groupEntries = samplesByGroup.get(key) ?? [];
    const candidates = vectorCandidatesByGroup.get(key) ?? [];
    if (!groupEntries.length || !candidates.length) continue;

    const anchorEntries = groupEntries.filter((entry) => {
      const packed = readIntPacked(entry.buffer, anchor.bitOffset, entry.bitCount);
      return packed.ok && packed.value === anchor.value && packed.bitCount === anchor.bitCount;
    });
    if (anchorEntries.length < 3) continue;

    for (const candidate of candidates) {
      const byTime = new Map();
      for (const entry of anchorEntries) {
        const vector = vectorAt(
          entry,
          candidate.offset,
          candidate.scaleFactor,
          candidate.componentBits,
          candidate.extraInfo,
        );
        if (vector) byTime.set(entry.timeMs, { timeMs: entry.timeMs, ...vector });
      }
      const series = [...byTime.values()].sort((a, b) => a.timeMs - b.timeMs);
      if (series.length < 3) continue;
      const seriesStats = summarizeVectorSeries(series);
      joins.push({
        fieldHandle: anchor.fieldHandle,
        fieldName: anchor.fieldName,
        payloadBitCount: anchor.payloadBitCount,
        prefixHex: anchor.prefixHex,
        netGuid: anchor.value,
        guidOffset: anchor.bitOffset,
        guidBitCount: anchor.bitCount,
        guidSampleCount: anchorEntries.length,
        vectorOffset: candidate.offset,
        relativeOffset: candidate.offset - anchor.bitOffset,
        vectorEncoding: {
          scaleFactor: candidate.scaleFactor,
          componentBits: candidate.componentBits,
          extraInfo: candidate.extraInfo,
        },
        vectorCandidateCount: candidate.count,
        joinedVectorSampleCount: seriesStats.count,
        vectorCoverage: Number((seriesStats.count / anchorEntries.length).toFixed(3)),
        vectorStats: seriesStats,
      });
    }
  }

  joins.sort(
    (a, b) =>
      b.joinedVectorSampleCount - a.joinedVectorSampleCount ||
      b.vectorCoverage - a.vectorCoverage ||
      Math.abs(a.relativeOffset) - Math.abs(b.relativeOffset),
  );

  const clusters = [];
  for (const join of joins) {
    const existing = clusters.find(
      (cluster) =>
        cluster.fieldHandle === join.fieldHandle &&
        cluster.payloadBitCount === join.payloadBitCount &&
        cluster.prefixHex === join.prefixHex &&
        Math.abs(cluster.centerRelativeOffset - join.relativeOffset) <= 4,
    );
    if (existing) {
      existing.joins.push(join);
      existing.relativeOffsets.push(join.relativeOffset);
      existing.centerRelativeOffset =
        existing.relativeOffsets.reduce((sum, value) => sum + value, 0) /
        existing.relativeOffsets.length;
      continue;
    }
    clusters.push({
      fieldHandle: join.fieldHandle,
      payloadBitCount: join.payloadBitCount,
      prefixHex: join.prefixHex,
      centerRelativeOffset: join.relativeOffset,
      relativeOffsets: [join.relativeOffset],
      joins: [join],
    });
  }

  const relativeOffsetClusters = clusters
    .map((cluster) => {
      const netGuids = [...new Set(cluster.joins.map((join) => join.netGuid))].sort(
        (a, b) => a - b,
      );
      return {
        fieldHandle: cluster.fieldHandle,
        payloadBitCount: cluster.payloadBitCount,
        prefixHex: cluster.prefixHex,
        centerRelativeOffset: Number(cluster.centerRelativeOffset.toFixed(1)),
        relativeOffsets: [...new Set(cluster.relativeOffsets)].sort((a, b) => a - b),
        joinCount: cluster.joins.length,
        uniqueNetGuidCount: netGuids.length,
        netGuids,
        totalJoinedVectorSamples: cluster.joins.reduce(
          (sum, join) => sum + join.joinedVectorSampleCount,
          0,
        ),
        guidOffsets: [...new Set(cluster.joins.map((join) => join.guidOffset))].sort(
          (a, b) => a - b,
        ),
        vectorOffsets: [...new Set(cluster.joins.map((join) => join.vectorOffset))].sort(
          (a, b) => a - b,
        ),
        joins: cluster.joins.slice(0, 12).map((join) => ({
          netGuid: join.netGuid,
          guidOffset: join.guidOffset,
          vectorOffset: join.vectorOffset,
          relativeOffset: join.relativeOffset,
          joinedVectorSampleCount: join.joinedVectorSampleCount,
          vectorCoverage: join.vectorCoverage,
          vectorEncoding: join.vectorEncoding,
          xySpan: Number(join.vectorStats.xySpan.toFixed(1)),
          p90Speed:
            join.vectorStats.p90Speed == null
              ? null
              : Number(join.vectorStats.p90Speed.toFixed(1)),
          bounds: join.vectorStats.bounds,
          firstSamples: join.vectorStats.firstSamples.slice(0, 3),
        })),
      };
    })
    .sort(
      (a, b) =>
        b.uniqueNetGuidCount - a.uniqueNetGuidCount ||
        b.totalJoinedVectorSamples - a.totalJoinedVectorSamples ||
        Math.abs(a.centerRelativeOffset) - Math.abs(b.centerRelativeOffset),
    )
    .slice(0, 80);

  return {
    joins: joins.slice(0, 160),
    relativeOffsetClusters,
  };
}

function summarizeGuidVectorRecordCandidates(guidVectorJoins) {
  return (guidVectorJoins.relativeOffsetClusters ?? [])
    .map((cluster) => {
      const stableJoins = cluster.joins.filter(
        (join) =>
          join.relativeOffset > 0 &&
          join.joinedVectorSampleCount >= 5 &&
          join.vectorCoverage >= 0.3 &&
          join.xySpan >= 50 &&
          join.p90Speed != null &&
          join.p90Speed < 2_500,
      );
      return {
        fieldHandle: cluster.fieldHandle,
        payloadBitCount: cluster.payloadBitCount,
        prefixHex: cluster.prefixHex,
        centerRelativeOffset: cluster.centerRelativeOffset,
        relativeOffsets: cluster.relativeOffsets,
        uniqueNetGuidCount: cluster.uniqueNetGuidCount,
        netGuids: cluster.netGuids,
        stableJoinCount: stableJoins.length,
        totalStableSamples: stableJoins.reduce(
          (sum, join) => sum + join.joinedVectorSampleCount,
          0,
        ),
        joins: stableJoins,
      };
    })
    .filter(
      (cluster) =>
        cluster.uniqueNetGuidCount >= 2 &&
        cluster.stableJoinCount >= 2 &&
        cluster.totalStableSamples >= 10,
    )
    .sort(
      (a, b) =>
        b.uniqueNetGuidCount - a.uniqueNetGuidCount ||
        b.stableJoinCount - a.stableJoinCount ||
        b.totalStableSamples - a.totalStableSamples ||
        a.centerRelativeOffset - b.centerRelativeOffset,
    )
    .slice(0, 12);
}

function summarizeH24AnchorDiagnostics(entries, anchors) {
  const diagnostics = [];
  for (const anchor of anchors) {
    const valueReads = [];
    const okNumericValues = [];
    let exactValueCount = 0;
    let exactValueAndBitCountCount = 0;
    let nearbyValueCount = 0;
    const nearbyValues = [];

    for (const entry of entries) {
      const packed = readIntPacked(entry.buffer, anchor.bitOffset, entry.bitCount);
      if (!packed.ok) {
        valueReads.push(`bad:${packed.value}/${packed.bitCount}`);
        continue;
      }

      valueReads.push(`${packed.value}/${packed.bitCount}`);
      okNumericValues.push(packed.value);
      if (packed.value === anchor.netGuid) {
        exactValueCount += 1;
        if (packed.bitCount === anchor.bitCount) exactValueAndBitCountCount += 1;
      }
      if (Math.abs(packed.value - anchor.netGuid) <= 4) {
        nearbyValueCount += 1;
        nearbyValues.push(`${packed.value}/${packed.bitCount}`);
      }
    }

    let confidence = 'intermittent-identity-lead';
    const exactRate = exactValueAndBitCountCount / Math.max(1, entries.length);
    const nearbyNonExactCount = nearbyValueCount - exactValueCount;
    if (nearbyNonExactCount >= Math.max(3, exactValueCount * 0.25)) {
      confidence = 'numeric-neighbor-collision-risk';
    } else if (exactRate < 0.05) {
      confidence = 'sparse-collision-risk';
    } else if (exactRate >= 0.2 && nearbyNonExactCount === 0) {
      confidence = 'strong-intermittent-identity-lead';
    }

    diagnostics.push({
      netGuid: anchor.netGuid,
      bitOffset: anchor.bitOffset,
      bitCount: anchor.bitCount,
      exactValueCount,
      exactValueAndBitCountCount,
      exactRate: Number(exactRate.toFixed(3)),
      nearbyValueCount,
      nearbyNonExactCount,
      confidence,
      topValuesAtOffset: topCounts(valueReads, 16),
      nearbyValues: topCounts(nearbyValues, 10),
      sampleTimesMs: anchor.entries.slice(0, 10).map((entry) => entry.timeMs),
    });
  }

  return diagnostics.sort(
    (a, b) =>
      b.exactValueAndBitCountCount - a.exactValueAndBitCountCount ||
      a.bitOffset - b.bitOffset,
  );
}

function summarizeH24AnchorCooccurrence(entries, anchors) {
  const anchorSet = anchors.slice(0, 24);
  const signatures = [];
  for (const entry of entries) {
    const hits = [];
    for (const anchor of anchorSet) {
      const packed = readIntPacked(entry.buffer, anchor.bitOffset, entry.bitCount);
      if (
        packed.ok &&
        packed.value === anchor.netGuid &&
        packed.bitCount === anchor.bitCount
      ) {
        hits.push(`${anchor.netGuid}@${anchor.bitOffset}`);
      }
    }
    signatures.push(hits.length ? hits.join(' ') : '(none)');
  }

  const grouped = new Map();
  entries.forEach((entry, index) => {
    const signature = signatures[index];
    let group = grouped.get(signature);
    if (!group) {
      group = {
        signature,
        count: 0,
        firstTimeMs: entry.timeMs,
        lastTimeMs: entry.timeMs,
        sampleTimesMs: [],
      };
      grouped.set(signature, group);
    }
    group.count += 1;
    group.firstTimeMs = Math.min(group.firstTimeMs, entry.timeMs);
    group.lastTimeMs = Math.max(group.lastTimeMs, entry.timeMs);
    if (group.sampleTimesMs.length < 8) group.sampleTimesMs.push(entry.timeMs);
  });

  return [...grouped.values()]
    .sort((a, b) => b.count - a.count || a.firstTimeMs - b.firstTimeMs)
    .slice(0, 40);
}

function summarizeH24SubrecordNeighborhoods(samples, knownPlayerGuids) {
  const known = new Set(knownPlayerGuids);
  const entries = samples.filter(
    (sample) =>
      sample.hasFullPayload &&
      sample.fieldHandle === 24 &&
      sample.bitCount === 3286 &&
      bitsToHex(sample.buffer, 0, 32) === 'd55af0b3',
  );
  if (!entries.length || !known.size) {
    return {
      status: 'No focused h24 payload group was captured.',
      fieldHandle: 24,
      payloadBitCount: 3286,
      prefixHex: 'd55af0b3',
      sampleCount: entries.length,
      anchors: [],
      relativeOffsetClusters: [],
    };
  }

  const anchorCounts = new Map();
  for (const entry of entries) {
    for (let bitOffset = 0; bitOffset < entry.bitCount; bitOffset += 1) {
      const packed = readIntPacked(entry.buffer, bitOffset, entry.bitCount);
      if (!packed.ok || !known.has(packed.value)) continue;
      const key = [bitOffset, packed.bitCount, packed.value].join('|');
      anchorCounts.set(key, (anchorCounts.get(key) ?? 0) + 1);
    }
  }

  const anchors = [...anchorCounts.entries()]
    .map(([key, count]) => {
      const [bitOffset, bitCount, netGuid] = key.split('|').map(Number);
      const anchorEntries = entries.filter((entry) => {
        const packed = readIntPacked(entry.buffer, bitOffset, entry.bitCount);
        return packed.ok && packed.value === netGuid && packed.bitCount === bitCount;
      });
      return {
        bitOffset,
        bitCount,
        netGuid,
        count,
        firstTimeMs: anchorEntries[0]?.timeMs ?? null,
        lastTimeMs: anchorEntries.at(-1)?.timeMs ?? null,
        entries: anchorEntries,
      };
    })
    .filter((anchor) => anchor.count >= 5)
    .sort((a, b) => b.count - a.count || a.bitOffset - b.bitOffset);

  const anchorDiagnostics = summarizeH24AnchorDiagnostics(entries, anchors);
  const anchorDiagnosticsByKey = new Map(
    anchorDiagnostics.map((diagnostic) => [
      [diagnostic.netGuid, diagnostic.bitOffset, diagnostic.bitCount].join('|'),
      diagnostic,
    ]),
  );
  const anchorCooccurrence = summarizeH24AnchorCooccurrence(entries, anchors);

  const vectorHits = [];
  for (const anchor of anchors) {
    const anchorDiagnostic = anchorDiagnosticsByKey.get(
      [anchor.netGuid, anchor.bitOffset, anchor.bitCount].join('|'),
    );
    const probeCounts = new Map();
    const minRelativeOffset = 250;
    const maxRelativeOffset = 950;
    for (const entry of anchor.entries) {
      for (
        let offset = anchor.bitOffset + minRelativeOffset;
        offset <= anchor.bitOffset + maxRelativeOffset && offset < entry.bitCount - 32;
        offset += 1
      ) {
        for (const scaleFactor of [1, 10, 100]) {
          const reader = new BitCursor(entry.buffer, entry.bitCount, offset);
          const vector = reader.readPackedVector(scaleFactor);
          if (!vector || reader.isError || !isPlausibleAscentVector(vector)) continue;
          const normalizedScaleFactor = vector.extraInfo ? scaleFactor : 1;
          const key = [
            offset,
            normalizedScaleFactor,
            vector.componentBits,
            vector.extraInfo,
          ].join('|');
          probeCounts.set(key, (probeCounts.get(key) ?? 0) + 1);
        }
      }
    }

    const recurringKeys = [...probeCounts.entries()]
      .filter(([, count]) => count >= Math.max(3, Math.ceil(anchor.entries.length * 0.3)))
      .sort((a, b) => b[1] - a[1])
      .slice(0, 80);

    for (const [key, probeCount] of recurringKeys) {
      const [offset, scaleFactor, componentBits, extraInfo] = key.split('|').map(Number);
      const byTime = new Map();
      for (const entry of anchor.entries) {
        const vector = vectorAt(entry, offset, scaleFactor, componentBits, extraInfo);
        if (vector) byTime.set(entry.timeMs, { timeMs: entry.timeMs, ...vector });
      }
      const series = [...byTime.values()].sort((a, b) => a.timeMs - b.timeMs);
      if (series.length < 3) continue;
      const stats = summarizeVectorSeries(series);
      const staticAxisCount = [
        stats.bounds.minX === stats.bounds.maxX,
        stats.bounds.minY === stats.bounds.maxY,
        stats.bounds.minZ === stats.bounds.maxZ,
      ].filter(Boolean).length;
      vectorHits.push({
        netGuid: anchor.netGuid,
        guidOffset: anchor.bitOffset,
        guidBitCount: anchor.bitCount,
        guidSampleCount: anchor.count,
        anchorIdentity: anchorDiagnostic
          ? {
              confidence: anchorDiagnostic.confidence,
              exactRate: anchorDiagnostic.exactRate,
              nearbyNonExactCount: anchorDiagnostic.nearbyNonExactCount,
              topValuesAtOffset: anchorDiagnostic.topValuesAtOffset.slice(0, 5),
            }
          : null,
        vectorOffset: offset,
        relativeOffset: offset - anchor.bitOffset,
        vectorEncoding: {
          scaleFactor,
          componentBits,
          extraInfo,
        },
        probeCount,
        vectorCoverage: Number((series.length / anchor.entries.length).toFixed(3)),
        staticAxisCount,
        sampleRows: series.map((entry) => ({
          timeMs: entry.timeMs,
          x: Number(entry.x.toFixed(2)),
          y: Number(entry.y.toFixed(2)),
          z: Number(entry.z.toFixed(2)),
        })),
        ...stats,
      });
    }
  }

  vectorHits.sort(
    (a, b) =>
      b.vectorCoverage - a.vectorCoverage ||
      b.probeCount - a.probeCount ||
      (a.p90Speed ?? Infinity) - (b.p90Speed ?? Infinity),
  );

  const clusters = [];
  for (const hit of vectorHits) {
    const existing = clusters.find(
      (cluster) => Math.abs(cluster.centerRelativeOffset - hit.relativeOffset) <= 4,
    );
    if (existing) {
      existing.hits.push(hit);
      existing.relativeOffsets.push(hit.relativeOffset);
      existing.centerRelativeOffset =
        existing.relativeOffsets.reduce((sum, value) => sum + value, 0) /
        existing.relativeOffsets.length;
      continue;
    }
    clusters.push({
      centerRelativeOffset: hit.relativeOffset,
      relativeOffsets: [hit.relativeOffset],
      hits: [hit],
    });
  }

  const relativeOffsetClusters = clusters
    .map((cluster) => {
      const netGuids = [...new Set(cluster.hits.map((hit) => hit.netGuid))].sort(
        (a, b) => a - b,
      );
      const lowSpeedHits = cluster.hits.filter(
        (hit) => hit.p90Speed != null && hit.p90Speed < 2_500,
      );
      return {
        centerRelativeOffset: Number(cluster.centerRelativeOffset.toFixed(1)),
        relativeOffsets: [...new Set(cluster.relativeOffsets)].sort((a, b) => a - b),
        hitCount: cluster.hits.length,
        uniqueNetGuidCount: netGuids.length,
        netGuids,
        lowSpeedHitCount: lowSpeedHits.length,
        maxCoverage: Math.max(...cluster.hits.map((hit) => hit.vectorCoverage)),
        hits: cluster.hits
          .sort(
            (a, b) =>
              b.vectorCoverage - a.vectorCoverage ||
              (a.p90Speed ?? Infinity) - (b.p90Speed ?? Infinity),
          )
          .slice(0, 12)
          .map((hit) => ({
            netGuid: hit.netGuid,
            guidOffset: hit.guidOffset,
            vectorOffset: hit.vectorOffset,
            relativeOffset: hit.relativeOffset,
            vectorCoverage: hit.vectorCoverage,
            anchorIdentity: hit.anchorIdentity,
            vectorEncoding: hit.vectorEncoding,
            sampleCount: hit.probeCount,
            uniquePositionCount: hit.uniquePositionCount,
            staticAxisCount: hit.staticAxisCount,
            xySpan: Number(hit.xySpan.toFixed(1)),
            p90Speed: hit.p90Speed == null ? null : Number(hit.p90Speed.toFixed(1)),
            bounds: hit.bounds,
            firstSamples: hit.firstSamples.slice(0, 4),
          })),
      };
    })
    .sort(
      (a, b) =>
        b.uniqueNetGuidCount - a.uniqueNetGuidCount ||
        b.lowSpeedHitCount - a.lowSpeedHitCount ||
        b.maxCoverage - a.maxCoverage ||
        a.centerRelativeOffset - b.centerRelativeOffset,
    )
    .slice(0, 40);

  const isMovementLikeHit = (hit) =>
    hit.vectorCoverage >= 0.3 &&
    hit.uniquePositionCount >= 3 &&
    hit.staticAxisCount <= 1 &&
    hit.xySpan >= 50 &&
    hit.xySpan <= 4_000 &&
    hit.p90Speed != null &&
    hit.p90Speed <= 2_500;
  const formatHit = (hit) => ({
    netGuid: hit.netGuid,
    guidOffset: hit.guidOffset,
    vectorOffset: hit.vectorOffset,
    relativeOffset: hit.relativeOffset,
    vectorCoverage: hit.vectorCoverage,
    vectorEncoding: hit.vectorEncoding,
    anchorIdentity: hit.anchorIdentity,
    sampleCount: hit.probeCount,
    uniquePositionCount: hit.uniquePositionCount,
    staticAxisCount: hit.staticAxisCount,
    xySpan: Number(hit.xySpan.toFixed(1)),
    p90Speed: hit.p90Speed == null ? null : Number(hit.p90Speed.toFixed(1)),
    bounds: hit.bounds,
    firstSamples: hit.firstSamples.slice(0, 4),
  });
  const candidateMovementLikeClusters = clusters
    .map((cluster) => {
      const movementLikeHits = cluster.hits.filter(isMovementLikeHit);
      const netGuids = [...new Set(movementLikeHits.map((hit) => hit.netGuid))].sort(
        (a, b) => a - b,
      );
      return {
        centerRelativeOffset: Number(cluster.centerRelativeOffset.toFixed(1)),
        relativeOffsets: [...new Set(cluster.relativeOffsets)].sort((a, b) => a - b),
        movementLikeHitCount: movementLikeHits.length,
        uniqueNetGuidCount: netGuids.length,
        netGuids,
        maxCoverage:
          movementLikeHits.length === 0
            ? 0
            : Math.max(...movementLikeHits.map((hit) => hit.vectorCoverage)),
        hits: movementLikeHits
          .sort(
            (a, b) =>
              b.vectorCoverage - a.vectorCoverage ||
              b.uniquePositionCount - a.uniquePositionCount ||
              (a.p90Speed ?? Infinity) - (b.p90Speed ?? Infinity),
          )
          .slice(0, 12)
          .map(formatHit),
      };
    })
    .filter((cluster) => cluster.movementLikeHitCount > 0)
    .sort(
      (a, b) =>
        b.uniqueNetGuidCount - a.uniqueNetGuidCount ||
        b.movementLikeHitCount - a.movementLikeHitCount ||
        b.maxCoverage - a.maxCoverage ||
        a.centerRelativeOffset - b.centerRelativeOffset,
    )
    .slice(0, 24);
  const movementHitKey = (hit) =>
    [
      hit.netGuid,
      hit.guidOffset,
      hit.vectorOffset,
      hit.relativeOffset,
      hit.vectorEncoding.scaleFactor,
      hit.vectorEncoding.componentBits,
      hit.vectorEncoding.extraInfo,
    ].join('|');
  const sampleSourceRanks = new Map();
  candidateMovementLikeClusters.slice(0, 8).forEach((cluster, clusterRank) => {
    for (const hit of cluster.hits) {
      sampleSourceRanks.set(movementHitKey(hit), {
        clusterRank,
        clusterRelativeOffset: cluster.centerRelativeOffset,
      });
    }
  });
  const candidateMovementLikeSamples = clusters
    .flatMap((cluster) =>
      cluster.hits
        .filter(isMovementLikeHit)
        .filter((hit) => sampleSourceRanks.has(movementHitKey(hit)))
        .flatMap((hit) =>
          hit.sampleRows.slice(0, 80).map((sample) => ({
            timeMs: sample.timeMs,
            netGuid: hit.netGuid,
            position: { x: sample.x, y: sample.y, z: sample.z },
            viewRotation: null,
            source: {
              fieldHandle: 24,
              payloadBitCount: 3286,
              prefixHex: 'd55af0b3',
              guidOffset: hit.guidOffset,
              vectorOffset: hit.vectorOffset,
              relativeOffset: hit.relativeOffset,
              vectorEncoding: hit.vectorEncoding,
              anchorIdentityConfidence: hit.anchorIdentity?.confidence ?? null,
              clusterRank: sampleSourceRanks.get(movementHitKey(hit)).clusterRank,
              clusterRelativeOffset: sampleSourceRanks.get(movementHitKey(hit)).clusterRelativeOffset,
            },
            confidence: 'candidate-h24-guid-adjacent-vector',
          })),
        ),
    )
    .sort(
      (a, b) =>
        a.source.clusterRank - b.source.clusterRank ||
        a.netGuid - b.netGuid ||
        a.timeMs - b.timeMs ||
        a.source.vectorOffset - b.source.vectorOffset,
    )
    .slice(0, 600);

  return {
    status:
      'Focused h24 scan of known-player GUID anchors and nearby packed-vector-like fields. These are structural leads, not confirmed world positions.',
    fieldHandle: 24,
    payloadBitCount: 3286,
    prefixHex: 'd55af0b3',
    sampleCount: entries.length,
    anchorCount: anchors.length,
    anchors: anchors.slice(0, 40).map((anchor) => ({
      netGuid: anchor.netGuid,
      bitOffset: anchor.bitOffset,
      bitCount: anchor.bitCount,
      count: anchor.count,
      firstTimeMs: anchor.firstTimeMs,
      lastTimeMs: anchor.lastTimeMs,
    })),
    anchorDiagnostics,
    anchorCooccurrence,
    relativeOffsetClusters,
    candidateMovementLikeClusters,
    candidateMovementLikeSamples,
  };
}

function summarizeHandle122OpenYawAlignment(lanes, playerOpenSamples) {
  if (!lanes.length || !playerOpenSamples.length) return [];
  const transforms = [
    { name: 'as-read', apply: (angle) => angle },
    { name: 'negated', apply: (angle) => -angle },
    { name: 'plus-90', apply: (angle) => angle + 90 },
    { name: 'minus-90', apply: (angle) => angle - 90 },
    { name: 'plus-180', apply: (angle) => angle + 180 },
  ];

  return lanes
    .map((lane) => {
      const firstSample = lane.interpretation.samples[0];
      if (!firstSample) return null;
      const rawAngle = firstSample.angleDegrees;
      const transformMatches = transforms.map((transform) => {
        const transformedAngle = normalizeDegrees(transform.apply(rawAngle));
        const bestMatches = playerOpenSamples
          .map((player) => ({
            netGuid: player.netGuid,
            archetypePath: player.archetypePath,
            openTimeMs: player.timeMs,
            openYaw: roundMetric(player.yaw, 3),
            deltaDegrees: roundMetric(circularDegreesDelta(transformedAngle, player.yaw), 3),
          }))
          .sort((a, b) => a.deltaDegrees - b.deltaDegrees)
          .slice(0, 3);
        return {
          transform: transform.name,
          transformedAngle: roundMetric(transformedAngle, 3),
          bestMatches,
        };
      });
      const bestTransformMatch = [...transformMatches].sort(
        (a, b) =>
          (a.bestMatches[0]?.deltaDegrees ?? Infinity) -
          (b.bestMatches[0]?.deltaDegrees ?? Infinity),
      )[0];
      return {
        prefixHex: lane.prefixHex,
        count: lane.count,
        rawSampleCount: lane.rawSampleCount,
        firstTimeMs: lane.firstTimeMs,
        firstAngleDegrees: roundMetric(rawAngle, 3),
        bestTransformMatch,
        transformMatches,
      };
    })
    .filter(Boolean)
    .sort(
      (a, b) =>
        (a.bestTransformMatch?.bestMatches[0]?.deltaDegrees ?? Infinity) -
          (b.bestTransformMatch?.bestMatches[0]?.deltaDegrees ?? Infinity) ||
        b.count - a.count,
    );
}

function summarizeHandle122Yaw(angleCandidates, playerOpenSamples = []) {
  const lanes = angleCandidates.filter(
    (candidate) =>
      candidate.fieldHandle === 122 &&
      candidate.bitCount === 92 &&
      candidate.interpretation.range.start === 50 &&
      candidate.interpretation.range.length === 18,
  );
  if (!lanes.length) return null;
  return {
    fieldHandle: 122,
    bitCount: 92,
    valueEncoding: 'signed 18-bit value at bits 50-67, degrees = signed * 360 / 2^18',
    laneCount: lanes.length,
    totalDedupedSamples: lanes.reduce((sum, lane) => sum + lane.count, 0),
    totalRawSamples: lanes.reduce((sum, lane) => sum + lane.rawSampleCount, 0),
    openYawAlignment: summarizeHandle122OpenYawAlignment(lanes, playerOpenSamples),
    prefixes: lanes.map((lane) => ({
      prefixHex: lane.prefixHex,
      count: lane.count,
      rawSampleCount: lane.rawSampleCount,
      firstTimeMs: lane.firstTimeMs,
      lastTimeMs: lane.lastTimeMs,
      angleRange: lane.interpretation.angleDegrees,
      coordinateUnitsRejection: lane.interpretation.coordinateUnits,
      samples: lane.interpretation.samples,
    })),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_replay_controller_streams.mjs --diagnostics replay.diagnostics.json --out replay_controller_streams.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics);
  const laneGroups = groupSmallFieldLanes(samples);
  const knownPlayerGuids = knownPlayerGuidsFromDiagnostics(diagnostics);
  const knownPlayerOpenSamples = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const guidReference = guidReferenceFromDiagnostics(diagnostics, knownPlayerGuids);
  const scalarCandidates = summarizeScalarCandidates(laneGroups);
  const scalarPairCandidates = summarizeScalarPairCandidates(laneGroups);
  const largeVectorCandidates = summarizeLargeVectorCandidates(samples);
  const guidAnchors = summarizeGuidAnchors(samples, knownPlayerGuids);
  const guidVectorJoins = summarizeGuidVectorJoins(samples, guidAnchors, largeVectorCandidates);
  const guidVectorRecordCandidates = summarizeGuidVectorRecordCandidates(guidVectorJoins);
  const h24SubrecordNeighborhoods = summarizeH24SubrecordNeighborhoods(samples, knownPlayerGuids);
  const targetRpcSummary = summarizeTargetRpcPayloads(samples, knownPlayerGuids);
  const targetRpc1498SlotSummary = summarizeTargetRpc1498Slots(samples, guidReference);

  const report = {
    generatedAt: new Date().toISOString(),
    input: { diagnostics: diagnosticsPath },
    source: {
      rawPacketsScanned: diagnostics.frameSummary?.rawPacketsScanned ?? null,
      movementRpcHitCount: diagnostics.frameSummary?.movementRpcHitCount ?? null,
      candidateFieldSampleCount: samples.length,
      candidateFieldCapture: diagnostics.frameSummary?.replayControllerCandidateFieldCapture ?? null,
      knownPlayerGuids,
      knownPlayerOpenSampleCount: knownPlayerOpenSamples.length,
      guidReferenceCounts: guidReference.counts,
    },
    notes: [
      'Scalar coordinate candidates treat signed values as game units / 10 and require plausible speed.',
      'Scalar angle candidates treat signed values as degrees = signed * 360 / 2^N and are useful for view-yaw hypotheses.',
      'Large packed-vector candidates are leads only; recurring offsets still need identity and speed validation before track emission.',
      'GUID/vector joins restrict vector probes to payloads that also contain a known player NetGUID at a recurring bit offset.',
    ],
    decoderLeads: {
      handle122YawCandidate: summarizeHandle122Yaw(
        scalarCandidates.angleCandidates,
        knownPlayerOpenSamples,
      ),
      coordinateStatus:
        scalarCandidates.coordinateCandidates.length === 0
          ? 'No small scalar lane currently passes coordinate span plus speed checks.'
          : 'Small scalar coordinate-like lanes exist, but none is yet tied to ten player identities.',
      scalarPairPositionStatus:
        scalarPairCandidates.strictCandidates.length === 0
          ? 'No ordered scalar-pair lane currently passes adjacent-frame continuity checks for world X/Y.'
          : 'Ordered scalar-pair lanes pass adjacent-frame continuity checks; inspect before promoting to track output.',
      scalarPairBestRejected: scalarPairCandidates.rejectedHighJumpCandidates.slice(0, 8),
      largeVectorStatus:
        largeVectorCandidates.dynamicCandidates.length === 0
          ? 'No recurring large-payload packed-vector candidate currently passes dynamic span checks.'
          : 'Large-payload packed-vector candidates exist but remain unconfirmed leads; inspect p90 speed, static axes, and identity joins.',
      guidVectorJoinStatus:
        guidVectorJoins.relativeOffsetClusters.length === 0
          ? 'No known player GUID anchor currently joins to recurring packed-vector candidates.'
          : 'Known player GUID anchors join to recurring packed-vector candidates; repeated relative offsets are the best next structure leads.',
      guidVectorRecordCandidates,
      h24SubrecordStatus: h24SubrecordNeighborhoods.status,
      h24SubrecordBestClusters: (
        h24SubrecordNeighborhoods.candidateMovementLikeClusters ?? []
      ).slice(0, 8),
      targetRpcStatus: targetRpcSummary.status,
      targetRpc1498Status: targetRpc1498SlotSummary.status,
    },
    targetRpcSummary,
    targetRpc1498SlotSummary,
    scalarCandidates,
    scalarPairCandidates,
    guidAnchors,
    h24SubrecordNeighborhoods,
    guidVectorJoins,
    largeVectorCandidates,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main();
