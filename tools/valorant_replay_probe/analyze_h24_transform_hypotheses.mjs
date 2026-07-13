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
    maxGroups: 80,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--stream-report') options.streamReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--max-groups') options.maxGroups = Number(argv[++index]);
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

function topCounts(map, limit = 12) {
  return [...map.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || String(a.key).localeCompare(String(b.key)))
    .slice(0, limit);
}

function readBitsUnsigned(buffer, bitOffset, bitCount) {
  let value = 0;
  for (let index = 0; index < bitCount; index += 1) {
    const bit = (buffer[(bitOffset + index) >> 3] >> ((bitOffset + index) & 7)) & 1;
    value += bit * 2 ** index;
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

function h24PayloadEntriesFromDiagnostics(diagnostics) {
  return (diagnostics.frameSummary?.replayControllerCandidateFieldSamples ?? [])
    .filter(
      (sample) =>
        sample.fieldHandle === 24 &&
        sample.numPayloadBits === 3286 &&
        !sample.payloadHexTruncated &&
        sample.payloadHex,
    )
    .map((sample) => ({
      timeMs: sample.timeMs,
      bitCount: sample.numPayloadBits,
      buffer: Buffer.from(sample.payloadHex, 'hex'),
    }))
    .sort((a, b) => a.timeMs - b.timeMs);
}

function summarizeTimeRuns(rows, gapMs = 1000) {
  const runs = [];
  let current = null;
  for (const row of rows) {
    if (!current || row.timeMs - current.lastTimeMs > gapMs) {
      current = {
        firstTimeMs: row.timeMs,
        lastTimeMs: row.timeMs,
        sampleCount: 1,
      };
      runs.push(current);
      continue;
    }
    current.lastTimeMs = row.timeMs;
    current.sampleCount += 1;
  }
  return runs.map((run) => ({
    ...run,
    durationMs: run.lastTimeMs - run.firstTimeMs,
  }));
}

function summarizeAnchorSequenceDiagnostics(diagnostics, streamReport) {
  const entries = h24PayloadEntriesFromDiagnostics(diagnostics);
  const anchors = streamReport.h24SubrecordNeighborhoods?.anchors ?? [];
  if (!entries.length || !anchors.length) {
    return {
      status: 'h24 anchor sequence diagnostics unavailable',
      h24EntryCount: entries.length,
      anchorCount: anchors.length,
      persistentIdentityLikeAnchorCount: 0,
      anchors: [],
    };
  }

  const anchorSummaries = anchors.slice(0, 24).map((anchor) => {
    const valueCounts = new Map();
    const exactRows = [];
    for (const entry of entries) {
      const packed = readIntPacked(entry.buffer, anchor.bitOffset, entry.bitCount);
      if (!packed.ok) continue;
      const key = `${packed.value}/${packed.bitCount}`;
      valueCounts.set(key, (valueCounts.get(key) ?? 0) + 1);
      if (packed.value === anchor.netGuid && packed.bitCount === anchor.bitCount) {
        exactRows.push({ timeMs: entry.timeMs });
      }
    }
    const exactRuns = summarizeTimeRuns(exactRows);
    const exactRate = entries.length ? exactRows.length / entries.length : 0;
    const topValuesAtOffset = topCounts(valueCounts, 10);
    const persistentIdentityLike =
      exactRows.length >= Math.max(10, entries.length * 0.75) &&
      exactRuns.length <= 2 &&
      topValuesAtOffset[0]?.key === `${anchor.netGuid}/${anchor.bitCount}`;
    return {
      netGuid: anchor.netGuid,
      bitOffset: anchor.bitOffset,
      bitCount: anchor.bitCount,
      exactHitCount: exactRows.length,
      exactRate: round(exactRate),
      exactRunCount: exactRuns.length,
      exactRuns: exactRuns.slice(0, 12),
      topValuesAtOffset,
      classification: persistentIdentityLike
        ? 'persistent-identity-like'
        : exactRows.length >= 5
          ? 'bursty-known-guid-match'
          : 'sparse-or-collision-level-match',
      persistentIdentityLike,
    };
  });

  const persistentIdentityLikeAnchorCount = anchorSummaries.filter(
    (summary) => summary.persistentIdentityLike,
  ).length;
  return {
    status:
      persistentIdentityLikeAnchorCount > 0
        ? 'some h24 anchors behave like persistent identity slots; inspect before track promotion'
        : 'no h24 known-GUID anchor behaves like a persistent identity slot across the captured payloads',
    h24EntryCount: entries.length,
    anchorCount: anchors.length,
    persistentIdentityLikeAnchorCount,
    anchors: anchorSummaries,
  };
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

function transformPoint(vector, openSample, transformName) {
  const x = vector.x;
  const y = vector.y;
  const z = vector.z ?? 0;
  if (transformName === 'raw') return { x, y, z };
  if (!openSample?.location) return null;

  const open = openSample.location;
  if (transformName === 'open+raw') {
    return { x: open.x + x, y: open.y + y, z: open.z + z };
  }
  if (transformName === 'open-raw') {
    return { x: open.x - x, y: open.y - y, z: open.z - z };
  }
  if (transformName === 'open+swap') {
    return { x: open.x + y, y: open.y + x, z: open.z + z };
  }
  if (transformName === 'open-swap') {
    return { x: open.x - y, y: open.y - x, z: open.z - z };
  }

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
  const allSpeeds = [];
  const allSteps = [];
  let inBoundsCount = 0;
  let largeAdjacentJumpCount = 0;
  let longGapCount = 0;
  let minX = Infinity;
  let maxX = -Infinity;
  let minY = Infinity;
  let maxY = -Infinity;
  let minZ = Infinity;
  let maxZ = -Infinity;

  for (const row of ordered) {
    uniquePositions.add(`${Math.round(row.x)}:${Math.round(row.y)}:${Math.round(row.z)}`);
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
    allSteps.push(distance);
    allSpeeds.push(speed);
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
    activeSpanMs:
      ordered.length > 1 ? ordered.at(-1).timeMs - ordered[0].timeMs : 0,
    uniqueTimeCount: new Set(ordered.map((row) => row.timeMs)).size,
    uniquePositionCount: uniquePositions.size,
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
    p90AllSpeed: round(percentile(allSpeeds, 0.9), 1),
    p90AllStepDistance: round(percentile(allSteps, 0.9), 2),
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
    summary.count >= 30 &&
    summary.uniquePositionCount >= 12 &&
    summary.activeSpanMs >= 5000 &&
    summary.inAscentBoundsRate >= 0.9 &&
    summary.xySpan >= 300 &&
    summary.adjacentStepCount >= Math.min(20, summary.count - 2) &&
    summary.p90AdjacentSpeed != null &&
    summary.p90AdjacentSpeed <= 2500 &&
    summary.maxAdjacentSpeed != null &&
    summary.maxAdjacentSpeed <= 8000 &&
    summary.largeAdjacentJumpCount === 0
  );
}

function gateRejectionReasons(summary) {
  const reasons = [];
  if (summary.count < 30) reasons.push('too-few-samples');
  if (summary.uniquePositionCount < 12) reasons.push('too-few-unique-positions');
  if (summary.activeSpanMs < 5000) reasons.push('too-short-active-span');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-bounds');
  if (summary.xySpan < 300) reasons.push('low-xy-span');
  if (summary.adjacentStepCount < Math.min(20, summary.count - 2)) {
    reasons.push('too-few-adjacent-steps');
  }
  if (summary.p90AdjacentSpeed == null || summary.p90AdjacentSpeed > 2500) {
    reasons.push('high-or-missing-p90-adjacent-speed');
  }
  if (summary.maxAdjacentSpeed == null || summary.maxAdjacentSpeed > 8000) {
    reasons.push('high-or-missing-max-adjacent-speed');
  }
  if (summary.largeAdjacentJumpCount > 0) reasons.push('large-adjacent-jumps');
  return reasons;
}

function h24GroupKey(row) {
  const source = row.source ?? {};
  const encoding = source.vectorEncoding ?? {};
  return [
    row.netGuid,
    source.guidOffset,
    source.vectorOffset,
    encoding.scaleFactor,
    encoding.componentBits,
    encoding.extraInfo,
  ].join('|');
}

function h24GroupSource(row) {
  const source = row.source ?? {};
  return {
    fieldHandle: source.fieldHandle ?? 24,
    payloadBitCount: source.payloadBitCount ?? 3286,
    prefixHex: source.prefixHex ?? 'd55af0b3',
    guidOffset: source.guidOffset ?? null,
    vectorOffset: source.vectorOffset ?? null,
    relativeOffset: source.relativeOffset ?? null,
    vectorEncoding: source.vectorEncoding ?? null,
    anchorIdentityConfidence: source.anchorIdentityConfidence ?? null,
    clusterRank: source.clusterRank ?? null,
    clusterRelativeOffset: source.clusterRelativeOffset ?? null,
  };
}

function scoreHypothesis(group, transform) {
  const summary = transform.summary;
  const anchorConfidence = group.source.anchorIdentityConfidence ?? '';
  const anchorScore =
    anchorConfidence === 'strong-intermittent-identity-lead'
      ? 3000
      : anchorConfidence === 'intermittent-identity-lead'
        ? 1000
        : anchorConfidence === 'numeric-neighbor-collision-risk'
          ? -1000
          : -1500;
  const speedPenalty =
    summary.p90AdjacentSpeed == null ? 1000 : Math.min(summary.p90AdjacentSpeed, 20_000) / 5;
  return round(
    anchorScore +
      summary.count * 12 +
      summary.uniquePositionCount * 40 +
      summary.inAscentBoundsRate * 500 +
      Math.min(summary.xySpan, 3000) -
      speedPenalty -
      summary.largeAdjacentJumpCount * 1000,
    3,
  );
}

function analyzeGroup(key, rows, openSamplesByGuid) {
  const first = rows[0];
  const openSample = openSamplesByGuid.get(first.netGuid) ?? null;
  const source = h24GroupSource(first);
  const transforms = TRANSFORMS.map((transformName) => {
    const transformedRows = rows
      .map((row) => {
        const point = transformPoint(row.position, openSample, transformName);
        return point ? { timeMs: row.timeMs, ...point } : null;
      })
      .filter(Boolean);
    const summary = summarizeSeries(transformedRows);
    const passes = passesTrackGate(summary);
    return {
      transform: transformName,
      passesTrackGate: passes,
      rejectionReasons: passes ? [] : gateRejectionReasons(summary),
      summary,
    };
  });

  const group = {
    key,
    netGuid: first.netGuid,
    source,
    openSample: openSample
      ? {
          timeMs: openSample.timeMs,
          chIndex: openSample.chIndex,
          archetypePath: openSample.archetypePath,
          location: openSample.location,
          yaw: round(openSample.yaw, 3),
        }
      : null,
    sampleCount: rows.length,
    transforms: transforms
      .map((transform) => ({
        ...transform,
        score: scoreHypothesis({ source }, transform),
      }))
      .sort(
        (a, b) =>
          Number(b.passesTrackGate) - Number(a.passesTrackGate) ||
          b.score - a.score ||
          b.summary.count - a.summary.count,
      ),
  };
  group.bestTransform = group.transforms[0] ?? null;
  return group;
}

function analyzeH24TransformHypotheses(diagnostics, streamReport, options) {
  const openSamples = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const openSamplesByGuid = new Map(openSamples.map((sample) => [sample.netGuid, sample]));
  const rows = streamReport.h24SubrecordNeighborhoods?.candidateMovementLikeSamples ?? [];
  const groups = new Map();
  for (const row of rows) {
    if (!row.position || !Number.isInteger(row.netGuid)) continue;
    const key = h24GroupKey(row);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }

  const analyzedGroups = [...groups.entries()]
    .map(([key, groupRows]) =>
      analyzeGroup(
        key,
        groupRows.sort((a, b) => a.timeMs - b.timeMs),
        openSamplesByGuid,
      ),
    )
    .sort(
      (a, b) =>
        Number(b.bestTransform?.passesTrackGate) - Number(a.bestTransform?.passesTrackGate) ||
        (b.bestTransform?.score ?? -Infinity) - (a.bestTransform?.score ?? -Infinity) ||
        b.sampleCount - a.sampleCount,
    )
    .slice(0, options.maxGroups);

  const passing = analyzedGroups.filter((group) =>
    group.transforms.some((transform) => transform.passesTrackGate),
  );

  return {
    generatedAt: new Date().toISOString(),
    options: {
      maxGroups: options.maxGroups,
      transforms: TRANSFORMS,
    },
    notes: [
      'Scores h24 GUID-adjacent vector candidates as raw and spawn-relative transforms.',
      'Open-spawn transforms are only a verifier heuristic; they do not prove round-local world coordinates.',
      'Known-GUID anchors must also behave like persistent identity slots; burst-local exact matches are structure clues only.',
      'passesTrackGate must be true before a transform is considered promotable to replay-track samples.',
    ],
    source: {
      rawPacketsScanned: diagnostics.frameSummary?.rawPacketsScanned ?? null,
      movementRpcHitCount: diagnostics.frameSummary?.movementRpcHitCount ?? null,
      h24CandidateSampleCount: rows.length,
      h24GroupCount: groups.size,
      playerOpenSampleCount: openSamples.length,
      playerOpenSamples: openSamples,
    },
    anchorSequenceDiagnostics: summarizeAnchorSequenceDiagnostics(diagnostics, streamReport),
    status:
      passing.length > 0
        ? 'h24 transform hypotheses passed the strict track gate; inspect before promoting'
        : 'no h24 transform hypothesis passed the strict continuous world-track gate',
    passingGroups: passing,
    bestRejectedGroups: analyzedGroups.filter((group) => !passing.includes(group)).slice(0, 40),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const streamReportPath = resolveUserPath(options.streamReport);
  if (!diagnosticsPath || !streamReportPath) {
    console.error(
      'usage: node analyze_h24_transform_hypotheses.mjs --diagnostics replay.diagnostics.json --stream-report replay_controller_streams.report.json --out h24_transform_hypotheses.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const streamReport = JSON.parse(fs.readFileSync(streamReportPath, 'utf8'));
  const report = analyzeH24TransformHypotheses(diagnostics, streamReport, options);
  report.input = {
    diagnostics: diagnosticsPath,
    streamReport: streamReportPath,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main();
