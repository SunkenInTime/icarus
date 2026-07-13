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
};

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    streamReport: null,
    out: null,
    maxCandidates: 80,
    minLaneSamples: 8,
    maxModulo: 12,
    maxIdWidth: 10,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--stream-report') options.streamReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--max-candidates') options.maxCandidates = Number(argv[++index]);
    else if (arg === '--min-lane-samples') options.minLaneSamples = Number(argv[++index]);
    else if (arg === '--max-modulo') options.maxModulo = Number(argv[++index]);
    else if (arg === '--max-id-width') options.maxIdWidth = Number(argv[++index]);
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

function round(value, digits = 3) {
  if (value == null || !Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * fraction))];
}

function projectAscent(x, y) {
  return {
    u: y * ASCENT_TRANSFORM.xMultiplier + ASCENT_TRANSFORM.xScalarToAdd,
    v: x * ASCENT_TRANSFORM.yMultiplier + ASCENT_TRANSFORM.yScalarToAdd,
  };
}

function isPlausibleAscentXY(x, y) {
  const percent = projectAscent(x, y);
  return (
    percent.u >= ASCENT_TRANSFORM.minPercent &&
    percent.u <= ASCENT_TRANSFORM.maxPercent &&
    percent.v >= ASCENT_TRANSFORM.minPercent &&
    percent.v <= ASCENT_TRANSFORM.maxPercent
  );
}

function overlapsRange(offset, bitCount, range) {
  return offset <= range.end && offset + bitCount - 1 >= range.start;
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
    .sort(
      (a, b) =>
        a.timeMs - b.timeMs ||
        a.sampleIndex - b.sampleIndex ||
        a.fieldHandle - b.fieldHandle,
    );
}

function candidateKey(candidate) {
  return [
    candidate.fieldHandle,
    candidate.bitCount,
    candidate.prefixHex,
    candidate.interpretation?.rangeX?.start,
    candidate.interpretation?.rangeX?.end,
    candidate.interpretation?.rangeY?.start,
    candidate.interpretation?.rangeY?.end,
    candidate.interpretation?.coordinateScale,
  ].join('|');
}

function candidateSortKey(candidate) {
  const stats = candidate.interpretation ?? {};
  return (
    (stats.inAscentBoundsRate ?? 0) * 1000 +
    Math.min(stats.adjacentStepCount ?? 0, 250) * 5 +
    Math.min(stats.uniquePositionCount ?? 0, 250) * 2 +
    Math.min(stats.xySpan ?? 0, 5000) / 20 -
    Math.min(stats.p90AdjacentSpeed ?? 100_000, 100_000) / 1000
  );
}

function loadCandidates(streamReport, limit) {
  const sources = [
    ...(streamReport.scalarPairCandidates?.rejectedHighJumpCandidates ?? []),
    ...(streamReport.scalarPairCandidates?.exploratoryCandidates ?? []),
  ];
  const byKey = new Map();
  for (const candidate of sources) {
    if (!candidate.interpretation?.rangeX || !candidate.interpretation?.rangeY) continue;
    const key = candidateKey(candidate);
    if (!byKey.has(key) || candidateSortKey(candidate) > candidateSortKey(byKey.get(key))) {
      byKey.set(key, candidate);
    }
  }
  return [...byKey.values()]
    .sort((a, b) => candidateSortKey(b) - candidateSortKey(a))
    .slice(0, limit);
}

function groupEntriesForCandidate(samples, candidate) {
  const entries = [];
  const seen = new Set();
  for (const sample of samples) {
    if (sample.fieldHandle !== candidate.fieldHandle) continue;
    if (sample.bitCount !== candidate.bitCount) continue;
    const prefixHex = bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount));
    if (prefixHex !== candidate.prefixHex) continue;
    const seenKey = `${sample.timeMs}:${sample.payloadHex}`;
    if (seen.has(seenKey)) continue;
    seen.add(seenKey);
    entries.push(sample);
  }
  return entries.sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
}

function decodePoint(entry, candidate) {
  const { rangeX, rangeY, coordinateScale } = candidate.interpretation;
  const x = readBitsSigned(entry.buffer, rangeX.start, rangeX.length) / coordinateScale;
  const y = readBitsSigned(entry.buffer, rangeY.start, rangeY.length) / coordinateScale;
  return {
    timeMs: entry.timeMs,
    x,
    y,
    inAscentBounds: isPlausibleAscentXY(x, y),
    payloadHex: entry.payloadHex,
  };
}

function summarizePointSeries(points, adjacentThresholdMs = 250, includeSegments = true) {
  const ordered = [...points].sort((a, b) => a.timeMs - b.timeMs);
  const byPosition = new Set();
  let minX = Infinity;
  let maxX = -Infinity;
  let minY = Infinity;
  let maxY = -Infinity;
  let inBoundsCount = 0;
  let sameTimeConflictCount = 0;
  const positionsByTime = new Map();
  for (const point of ordered) {
    byPosition.add(`${round(point.x, 3)}:${round(point.y, 3)}`);
    minX = Math.min(minX, point.x);
    maxX = Math.max(maxX, point.x);
    minY = Math.min(minY, point.y);
    maxY = Math.max(maxY, point.y);
    if (point.inAscentBounds) inBoundsCount += 1;
    const timeKey = point.timeMs;
    const posKey = `${round(point.x, 3)}:${round(point.y, 3)}`;
    const previous = positionsByTime.get(timeKey);
    if (previous && previous !== posKey) sameTimeConflictCount += 1;
    positionsByTime.set(timeKey, posKey);
  }

  const allSpeeds = [];
  const adjacentSpeeds = [];
  const adjacentSteps = [];
  const adjacentDts = [];
  const allDts = [];
  const segments = [];
  let currentSegment = [];
  let largeAdjacentJumpCount = 0;
  for (let index = 0; index < ordered.length; index += 1) {
    const current = ordered[index];
    const previous = ordered[index - 1];
    if (!previous) {
      currentSegment.push(current);
      continue;
    }
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs > 1000) {
      if (currentSegment.length) segments.push(currentSegment);
      currentSegment = [current];
    } else {
      currentSegment.push(current);
    }
    if (dtMs <= 0) continue;
    allDts.push(dtMs);
    const distance = Math.hypot(current.x - previous.x, current.y - previous.y);
    const speed = distance / (dtMs / 1000);
    allSpeeds.push(speed);
    if (dtMs <= adjacentThresholdMs) {
      adjacentSpeeds.push(speed);
      adjacentSteps.push(distance);
      adjacentDts.push(dtMs);
      if (distance > 900 || speed > 12_000) largeAdjacentJumpCount += 1;
    }
  }
  if (currentSegment.length) segments.push(currentSegment);

  const topSegments = includeSegments
    ? segments
        .filter((segment) => segment.length >= 2)
        .map((segment) => summarizePointSeries(segment, adjacentThresholdMs, false))
        .sort(
          (a, b) =>
            b.count - a.count ||
            b.adjacentStepCount - a.adjacentStepCount ||
            (a.p90AdjacentSpeed ?? Infinity) - (b.p90AdjacentSpeed ?? Infinity),
        )
        .slice(0, 5)
    : [];

  const longGapCount = allDts.filter((dt) => dt > 1000).length;
  const maxGapMs = allDts.length ? Math.max(...allDts) : null;

  const xSpan = ordered.length ? maxX - minX : 0;
  const ySpan = ordered.length ? maxY - minY : 0;
  return {
    count: ordered.length,
    firstTimeMs: ordered[0]?.timeMs ?? null,
    lastTimeMs: ordered.at(-1)?.timeMs ?? null,
    activeSpanMs:
      ordered.length > 1 ? ordered.at(-1).timeMs - ordered[0].timeMs : 0,
    uniqueTimeCount: new Set(ordered.map((point) => point.timeMs)).size,
    uniquePositionCount: byPosition.size,
    inAscentBoundsRate: ordered.length ? round(inBoundsCount / ordered.length, 3) : 0,
    sameTimeConflictCount,
    bounds: ordered.length
      ? {
          minX: round(minX, 2),
          maxX: round(maxX, 2),
          minY: round(minY, 2),
          maxY: round(maxY, 2),
        }
      : null,
    xSpan: round(xSpan, 2),
    ySpan: round(ySpan, 2),
    xySpan: round(Math.hypot(xSpan, ySpan), 2),
    allStepCount: allSpeeds.length,
    medianDtMs: round(percentile(allDts, 0.5), 0),
    p90DtMs: round(percentile(allDts, 0.9), 0),
    maxGapMs,
    longGapCount,
    segmentCount: segments.length,
    adjacentStepCount: adjacentSpeeds.length,
    medianAdjacentDtMs: round(percentile(adjacentDts, 0.5), 0),
    medianAdjacentSpeed: round(percentile(adjacentSpeeds, 0.5)),
    p90AdjacentSpeed: round(percentile(adjacentSpeeds, 0.9)),
    maxAdjacentSpeed: round(adjacentSpeeds.length ? Math.max(...adjacentSpeeds) : null),
    p90AdjacentStepDistance: round(percentile(adjacentSteps, 0.9)),
    largeAdjacentJumpCount,
    topSegments: topSegments.map((segment) => ({
      count: segment.count,
      firstTimeMs: segment.firstTimeMs,
      lastTimeMs: segment.lastTimeMs,
      activeSpanMs: segment.activeSpanMs,
      uniquePositionCount: segment.uniquePositionCount,
      inAscentBoundsRate: segment.inAscentBoundsRate,
      xySpan: segment.xySpan,
      adjacentStepCount: segment.adjacentStepCount,
      p90AdjacentSpeed: segment.p90AdjacentSpeed,
      maxAdjacentSpeed: segment.maxAdjacentSpeed,
      largeAdjacentJumpCount: segment.largeAdjacentJumpCount,
      bounds: segment.bounds,
      firstSamples: segment.firstSamples.slice(0, 4),
    })),
    firstSamples: ordered.slice(0, 8).map((point) => ({
      timeMs: point.timeMs,
      x: round(point.x, 2),
      y: round(point.y, 2),
      inAscentBounds: point.inAscentBounds,
      payloadHex: point.payloadHex.slice(0, 64),
    })),
  };
}

function isExploratoryLane(summary, minLaneSamples) {
  return (
    summary.count >= minLaneSamples &&
    summary.uniquePositionCount >= 4 &&
    summary.inAscentBoundsRate >= 0.8 &&
    summary.xySpan >= 50 &&
    summary.adjacentStepCount >= Math.min(5, summary.count - 1) &&
    (summary.p90AdjacentSpeed ?? Infinity) <= 4_500 &&
    summary.largeAdjacentJumpCount === 0
  );
}

function isStrictLane(summary, minLaneSamples) {
  const segmentMinSamples = Math.max(20, minLaneSamples);
  return (summary.topSegments ?? []).some(
    (segment) =>
      segment.count >= segmentMinSamples &&
      segment.uniquePositionCount >= 8 &&
      segment.inAscentBoundsRate >= 0.9 &&
      segment.xySpan >= 75 &&
      segment.adjacentStepCount >= segment.count - 2 &&
      (segment.p90AdjacentSpeed ?? Infinity) <= 2_500 &&
      (segment.maxAdjacentSpeed ?? Infinity) <= 6_000 &&
      segment.largeAdjacentJumpCount === 0,
  );
}

function summarizePartition(kind, key, laneEntries, candidate, options) {
  const lanes = [...laneEntries.entries()]
    .map(([laneKey, entries]) => {
      const points = entries.map((entry) => decodePoint(entry, candidate));
      const summary = summarizePointSeries(points);
      return {
        laneKey,
        summary,
        exploratory: isExploratoryLane(summary, options.minLaneSamples),
        strict: isStrictLane(summary, options.minLaneSamples),
      };
    })
    .filter((lane) => lane.summary.count >= options.minLaneSamples)
    .sort(
      (a, b) =>
        Number(b.strict) - Number(a.strict) ||
        Number(b.exploratory) - Number(a.exploratory) ||
        (a.summary.p90AdjacentSpeed ?? Infinity) - (b.summary.p90AdjacentSpeed ?? Infinity) ||
        b.summary.count - a.summary.count,
    );

  const exploratory = lanes.filter((lane) => lane.exploratory);
  const strict = lanes.filter((lane) => lane.strict);
  const totalAdjacentSteps = lanes.reduce(
    (total, lane) => total + lane.summary.adjacentStepCount,
    0,
  );
  const worstExploratoryP90 = exploratory.length
    ? Math.max(...exploratory.map((lane) => lane.summary.p90AdjacentSpeed ?? Infinity))
    : null;
  const score =
    strict.length * 5000 +
    exploratory.length * 1000 +
    Math.min(totalAdjacentSteps, 500) * 2 +
    lanes.length * 20 -
    Math.min(worstExploratoryP90 ?? 100_000, 100_000) / 100;

  return {
    kind,
    key,
    laneCount: lanes.length,
    exploratoryLaneCount: exploratory.length,
    strictLaneCount: strict.length,
    promisingLaneCount: exploratory.length,
    totalAdjacentSteps,
    score: round(score, 3),
    lanes: lanes.slice(0, 12),
  };
}

function moduloPartitions(entries, candidate, options) {
  const partitions = [];
  for (let modulo = 2; modulo <= options.maxModulo; modulo += 1) {
    const laneEntries = new Map();
    entries.forEach((entry, index) => {
      const laneKey = String(index % modulo);
      if (!laneEntries.has(laneKey)) laneEntries.set(laneKey, []);
      laneEntries.get(laneKey).push(entry);
    });
    partitions.push(summarizePartition('modulo', modulo, laneEntries, candidate, options));
  }
  return partitions;
}

function idBitPartitions(entries, candidate, options) {
  const partitions = [];
  const { rangeX, rangeY } = candidate.interpretation;
  for (let width = 1; width <= options.maxIdWidth; width += 1) {
    for (let offset = 0; offset + width <= candidate.bitCount; offset += 1) {
      if (overlapsRange(offset, width, rangeX) || overlapsRange(offset, width, rangeY)) continue;
      const laneEntries = new Map();
      for (const entry of entries) {
        const id = readBitsUnsigned(entry.buffer, offset, width);
        if (!laneEntries.has(id)) laneEntries.set(id, []);
        laneEntries.get(id).push(entry);
      }
      if (laneEntries.size < 2 || laneEntries.size > 16) continue;
      const populatedLaneCount = [...laneEntries.values()].filter(
        (lane) => lane.length >= options.minLaneSamples,
      ).length;
      if (populatedLaneCount < 2) continue;
      partitions.push(
        summarizePartition(
          'id-bits',
          { offset, width },
          new Map([...laneEntries.entries()].map(([laneKey, lane]) => [String(laneKey), lane])),
          candidate,
          options,
        ),
      );
    }
  }
  return partitions;
}

function analyzeCandidate(samples, candidate, options) {
  const entries = groupEntriesForCandidate(samples, candidate);
  if (entries.length < options.minLaneSamples * 2) return null;
  const collapsed = summarizePointSeries(entries.map((entry) => decodePoint(entry, candidate)));
  const partitions = [
    ...moduloPartitions(entries, candidate, options),
    ...idBitPartitions(entries, candidate, options),
  ]
    .filter((partition) => partition.exploratoryLaneCount > 0 || partition.strictLaneCount > 0)
    .sort(
      (a, b) =>
        b.strictLaneCount - a.strictLaneCount ||
        b.exploratoryLaneCount - a.exploratoryLaneCount ||
        b.score - a.score ||
        b.totalAdjacentSteps - a.totalAdjacentSteps,
    )
    .slice(0, 20);

  return {
    fieldHandle: candidate.fieldHandle,
    fieldName: candidate.fieldName ?? null,
    bitCount: candidate.bitCount,
    prefixHex: candidate.prefixHex,
    sourceGroupCount: candidate.groupCount,
    dedupedEntryCount: entries.length,
    coordinateInterpretation: {
      x: candidate.interpretation.rangeX,
      y: candidate.interpretation.rangeY,
      coordinateScale: candidate.interpretation.coordinateScale,
    },
    collapsed,
    bestPartitions: partitions,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const streamReportPath = resolveUserPath(options.streamReport);
  if (!diagnosticsPath || !streamReportPath) {
    console.error(
      'usage: node analyze_deinterleaved_position_lanes.mjs --diagnostics replay.diagnostics.json --stream-report replay_controller_streams.report.json --out deinterleaved.report.json',
    );
    process.exit(1);
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const streamReport = JSON.parse(fs.readFileSync(streamReportPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics);
  const candidates = loadCandidates(streamReport, options.maxCandidates);
  const results = candidates
    .map((candidate) => analyzeCandidate(samples, candidate, options))
    .filter(Boolean)
    .sort(
      (a, b) =>
        (b.bestPartitions[0]?.promisingLaneCount ?? 0) -
          (a.bestPartitions[0]?.promisingLaneCount ?? 0) ||
        (b.bestPartitions[0]?.score ?? -Infinity) - (a.bestPartitions[0]?.score ?? -Infinity),
    );

  const promisingCandidates = results.filter((result) => result.bestPartitions.length > 0);
  const strictCandidates = results.filter((result) =>
    result.bestPartitions.some((partition) => partition.strictLaneCount > 0),
  );
  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
      streamReport: streamReportPath,
    },
    options: {
      maxCandidates: options.maxCandidates,
      minLaneSamples: options.minLaneSamples,
      maxModulo: options.maxModulo,
      maxIdWidth: options.maxIdWidth,
    },
    notes: [
      'Re-tests map-shaped scalar pair candidates that failed as collapsed lanes.',
      'Partitions are exploratory deinterleavings by sample-order modulo and by unsigned ID bit slices outside the candidate x/y fields.',
      'A promising deinterleaved lane is still a hypothesis until tied to actor identity and view yaw.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      inputCandidateCount: candidates.length,
      analyzedCandidateCount: results.length,
      exploratoryCandidateCount: promisingCandidates.length,
      strictCandidateCount: strictCandidates.length,
      promisingCandidateCount: promisingCandidates.length,
    },
    status:
      strictCandidates.length > 0
        ? 'strict deinterleaved scalar position hypotheses found; still require identity/yaw validation'
        : promisingCandidates.length > 0
          ? 'only exploratory deinterleaved scalar position hypotheses found; no strict continuous lane passed'
          : 'no deinterleaved scalar position hypothesis passed continuity checks',
    strictCandidates: strictCandidates.slice(0, 40),
    promisingCandidates: promisingCandidates.slice(0, 40),
    allCandidateSummaries: results.slice(0, 80).map((result) => ({
      fieldHandle: result.fieldHandle,
      bitCount: result.bitCount,
      prefixHex: result.prefixHex,
      dedupedEntryCount: result.dedupedEntryCount,
      coordinateInterpretation: result.coordinateInterpretation,
      collapsed: {
        count: result.collapsed.count,
        uniquePositionCount: result.collapsed.uniquePositionCount,
        inAscentBoundsRate: result.collapsed.inAscentBoundsRate,
        xySpan: result.collapsed.xySpan,
        adjacentStepCount: result.collapsed.adjacentStepCount,
        p90AdjacentSpeed: result.collapsed.p90AdjacentSpeed,
        largeAdjacentJumpCount: result.collapsed.largeAdjacentJumpCount,
      },
      bestPartitionCount: result.bestPartitions.length,
      bestPartitionHead: result.bestPartitions[0]
        ? {
            kind: result.bestPartitions[0].kind,
            key: result.bestPartitions[0].key,
            promisingLaneCount: result.bestPartitions[0].promisingLaneCount,
            laneCount: result.bestPartitions[0].laneCount,
            score: result.bestPartitions[0].score,
          }
        : null,
    })),
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else console.log(JSON.stringify(report, null, 2));
}

main();
