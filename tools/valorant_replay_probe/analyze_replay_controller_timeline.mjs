#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const DEFAULT_PREFIX_BITS = 32;
const DEFAULT_MIN_GROUP_COUNT = 20;
const DEFAULT_MAX_DEEP_GROUPS = 180;
const DEFAULT_GUID_SCAN_ENTRY_LIMIT = 384;
const DEFAULT_VARIABLE_SCAN_ENTRY_LIMIT = 768;

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    out: null,
    prefixBits: DEFAULT_PREFIX_BITS,
    minGroupCount: DEFAULT_MIN_GROUP_COUNT,
    maxDeepGroups: DEFAULT_MAX_DEEP_GROUPS,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--prefix-bits') options.prefixBits = Number(argv[++index]);
    else if (arg === '--min-group-count') options.minGroupCount = Number(argv[++index]);
    else if (arg === '--max-deep-groups') options.maxDeepGroups = Number(argv[++index]);
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

function roundMetric(value, digits = 3) {
  if (!Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * fraction)));
  return sorted[index];
}

function topCounts(map, limit = 20) {
  return [...map.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || String(a.key).localeCompare(String(b.key)))
    .slice(0, limit);
}

function increment(map, key, amount = 1) {
  map.set(key, (map.get(key) ?? 0) + amount);
}

function stableRanges(flags) {
  const ranges = [];
  let start = null;
  for (let index = 0; index <= flags.length; index += 1) {
    if (index < flags.length && flags[index]) {
      if (start == null) start = index;
    } else if (start != null) {
      ranges.push({ start, end: index - 1, length: index - start });
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
    .filter((sample) => Number.isInteger(sample.netGuid) && sample.netGuid > 0)
    .sort((a, b) => a.netGuid - b.netGuid);
}

function timeStats(entries) {
  if (!entries.length) return null;
  const times = entries.map((entry) => entry.timeMs).sort((a, b) => a - b);
  const uniqueTimes = [...new Set(times)];
  const dts = [];
  const uniqueDts = [];
  for (let index = 1; index < times.length; index += 1) {
    dts.push(times[index] - times[index - 1]);
  }
  for (let index = 1; index < uniqueTimes.length; index += 1) {
    uniqueDts.push(uniqueTimes[index] - uniqueTimes[index - 1]);
  }
  return {
    count: entries.length,
    firstTimeMs: times[0],
    lastTimeMs: times.at(-1),
    activeSpanMs: times.at(-1) - times[0],
    uniqueTimeCount: uniqueTimes.length,
    sameTimeDuplicateCount: times.length - uniqueTimes.length,
    medianDtMs: percentile(dts, 0.5),
    p90DtMs: percentile(dts, 0.9),
    p99DtMs: percentile(dts, 0.99),
    medianUniqueDtMs: percentile(uniqueDts, 0.5),
    p90UniqueDtMs: percentile(uniqueDts, 0.9),
    p99UniqueDtMs: percentile(uniqueDts, 0.99),
    nearTickStepCount: uniqueDts.filter((dt) => dt > 0 && dt <= 40).length,
    longGapCount: uniqueDts.filter((dt) => dt > 1000).length,
    maxGapMs: uniqueDts.length ? Math.max(...uniqueDts) : null,
  };
}

function summarizeVariableBits(entries, bitCount, entryLimit = DEFAULT_VARIABLE_SCAN_ENTRY_LIMIT) {
  if (!entries.length || bitCount <= 0) return null;
  const scanEntries = entries.slice(0, entryLimit);
  const oneCounts = Array.from({ length: bitCount }, () => 0);
  for (const entry of scanEntries) {
    for (let bit = 0; bit < bitCount; bit += 1) {
      if (readBit(entry.buffer, bit)) oneCounts[bit] += 1;
    }
  }
  const stableBits = oneCounts.map((count) => count === 0 || count === scanEntries.length);
  return {
    scannedEntryCount: scanEntries.length,
    stableBitCount: stableBits.filter(Boolean).length,
    variableBitCount: stableBits.filter((stable) => !stable).length,
    stableRanges: stableRanges(stableBits).filter((range) => range.length >= 4).slice(0, 16),
    variableRanges: stableRanges(stableBits.map((stable) => !stable))
      .filter((range) => range.length >= 2)
      .slice(0, 16),
  };
}

function summarizeKnownGuidHits(entries, knownPlayerGuids, entryLimit = DEFAULT_GUID_SCAN_ENTRY_LIMIT) {
  const known = new Set(knownPlayerGuids);
  if (!known.size || !entries.length) return [];
  const hits = new Map();
  const scanEntries = entries.slice(0, entryLimit);
  for (const entry of scanEntries) {
    if (!entry.hasFullPayload || entry.bitCount <= 0 || entry.bitCount > 8192) continue;
    for (let bitOffset = 0; bitOffset < entry.bitCount; bitOffset += 1) {
      const packed = readIntPacked(entry.buffer, bitOffset, entry.bitCount);
      if (!packed.ok || !known.has(packed.value)) continue;
      const key = [packed.value, bitOffset, packed.bitCount].join('|');
      let hit = hits.get(key);
      if (!hit) {
        hit = {
          netGuid: packed.value,
          bitOffset,
          bitCount: packed.bitCount,
          count: 0,
          firstTimeMs: entry.timeMs,
          lastTimeMs: entry.timeMs,
          samplePayloads: [],
        };
        hits.set(key, hit);
      }
      hit.count += 1;
      hit.firstTimeMs = Math.min(hit.firstTimeMs, entry.timeMs);
      hit.lastTimeMs = Math.max(hit.lastTimeMs, entry.timeMs);
      if (hit.samplePayloads.length < 4) {
        hit.samplePayloads.push({
          timeMs: entry.timeMs,
          payloadHex: entry.payloadHex.slice(0, 128),
        });
      }
    }
  }
  const minRecurringCount = Math.max(2, Math.ceil(scanEntries.length * 0.05));
  return [...hits.values()]
    .filter((hit) => hit.count >= minRecurringCount)
    .sort((a, b) => b.count - a.count || a.netGuid - b.netGuid || a.bitOffset - b.bitOffset)
    .slice(0, 12);
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

function summarizeYawTimeOverlap(entries, yawTimes) {
  if (!entries.length || !yawTimes.length) return null;
  const deltas = entries.map((entry) => nearestDelta(yawTimes, entry.timeMs)).filter((v) => v != null);
  const within8 = deltas.filter((delta) => delta <= 8).length;
  const within16 = deltas.filter((delta) => delta <= 16).length;
  const within33 = deltas.filter((delta) => delta <= 33).length;
  return {
    comparedCount: deltas.length,
    within8ms: within8,
    within16ms: within16,
    within33ms: within33,
    within8Rate: roundMetric(within8 / deltas.length),
    within16Rate: roundMetric(within16 / deltas.length),
    within33Rate: roundMetric(within33 / deltas.length),
    medianNearestYawMs: percentile(deltas, 0.5),
    p90NearestYawMs: percentile(deltas, 0.9),
  };
}

function addGroup(groups, key, sample, prefixHex) {
  let group = groups.get(key);
  if (!group) {
    group = {
      fieldHandle: sample.fieldHandle,
      fieldName: sample.fieldName ?? null,
      bitCount: sample.bitCount,
      prefixHex,
      entries: [],
      uniquePayloads: new Set(),
    };
    groups.set(key, group);
  }
  group.entries.push(sample);
  group.uniquePayloads.add(sample.payloadHex);
  return group;
}

function groupSamples(samples, prefixBits) {
  const laneGroups = new Map();
  const fieldBitGroups = new Map();
  for (const sample of samples) {
    if (!sample.hasFullPayload || sample.bitCount < 0 || sample.bitCount > 8192) continue;
    const prefixHex = bitsToHex(sample.buffer, 0, Math.min(prefixBits, sample.bitCount));
    const laneKey = [sample.fieldHandle, sample.fieldName ?? '', sample.bitCount, prefixHex].join('|');
    addGroup(laneGroups, laneKey, sample, prefixHex);

    const fieldBitKey = [sample.fieldHandle, sample.fieldName ?? '', sample.bitCount].join('|');
    let fieldBitGroup = fieldBitGroups.get(fieldBitKey);
    if (!fieldBitGroup) {
      fieldBitGroup = {
        fieldHandle: sample.fieldHandle,
        fieldName: sample.fieldName ?? null,
        bitCount: sample.bitCount,
        entries: [],
        prefixCounts: new Map(),
        uniquePayloads: new Set(),
      };
      fieldBitGroups.set(fieldBitKey, fieldBitGroup);
    }
    fieldBitGroup.entries.push(sample);
    fieldBitGroup.uniquePayloads.add(sample.payloadHex);
    increment(fieldBitGroup.prefixCounts, prefixHex);
  }
  return { laneGroups, fieldBitGroups };
}

function summarizeLaneGroup(group, knownPlayerGuids, yawTimes) {
  const stats = timeStats(group.entries);
  const variableBits = summarizeVariableBits(group.entries, group.bitCount);
  const knownGuidHits = summarizeKnownGuidHits(group.entries, knownPlayerGuids);
  const yawTimeOverlap = summarizeYawTimeOverlap(group.entries, yawTimes);
  return {
    fieldHandle: group.fieldHandle,
    fieldName: group.fieldName,
    bitCount: group.bitCount,
    prefixHex: group.prefixHex,
    count: group.entries.length,
    uniquePayloadCount: group.uniquePayloads.size,
    uniquePayloadRate: roundMetric(group.uniquePayloads.size / group.entries.length),
    firstTimeMs: stats.firstTimeMs,
    lastTimeMs: stats.lastTimeMs,
    activeSpanMs: stats.activeSpanMs,
    uniqueTimeCount: stats.uniqueTimeCount,
    sameTimeDuplicateCount: stats.sameTimeDuplicateCount,
    medianUniqueDtMs: stats.medianUniqueDtMs,
    p90UniqueDtMs: stats.p90UniqueDtMs,
    p99UniqueDtMs: stats.p99UniqueDtMs,
    longGapCount: stats.longGapCount,
    maxGapMs: stats.maxGapMs,
    variableBits,
    knownGuidHits,
    yawTimeOverlap,
    firstPayloads: group.entries.slice(0, 6).map((entry) => ({
      timeMs: entry.timeMs,
      payloadHex: entry.payloadHex.slice(0, 160),
    })),
  };
}

function movementFamilyScore(summary) {
  const laneScore = Math.min(10, summary.laneCountAtMinGroup);
  const countScore = Math.min(10, Math.log10(Math.max(1, summary.count)) * 3);
  const uniqueScore = Math.min(6, summary.uniquePayloadRate * 6);
  const yawScore = Math.min(6, (summary.bestYawWithin33Rate ?? 0) * 6);
  const guidScore = Math.min(5, summary.knownGuidHitCount);
  const cadencePenalty = summary.medianUniqueDtMs != null && summary.medianUniqueDtMs > 250 ? 2 : 0;
  return roundMetric(laneScore + countScore + uniqueScore + yawScore + guidScore - cadencePenalty);
}

function summarizeFieldBitFamily(group, laneSummaries, minGroupCount) {
  const stats = timeStats(group.entries);
  const laneCounts = topCounts(group.prefixCounts, 16);
  const lanesAtMin = laneCounts.filter((entry) => entry.count >= minGroupCount);
  const relevantLanes = laneSummaries.filter(
    (lane) =>
      lane.fieldHandle === group.fieldHandle &&
      lane.fieldName === group.fieldName &&
      lane.bitCount === group.bitCount &&
      lane.count >= minGroupCount,
  );
  const bestYawWithin33Rate = Math.max(
    0,
    ...relevantLanes.map((lane) => lane.yawTimeOverlap?.within33Rate ?? 0),
  );
  const knownGuidHitCount = relevantLanes.reduce(
    (sum, lane) => sum + (lane.knownGuidHits?.length ?? 0),
    0,
  );
  const summary = {
    fieldHandle: group.fieldHandle,
    fieldName: group.fieldName,
    bitCount: group.bitCount,
    count: group.entries.length,
    uniquePayloadCount: group.uniquePayloads.size,
    uniquePayloadRate: roundMetric(group.uniquePayloads.size / group.entries.length),
    firstTimeMs: stats.firstTimeMs,
    lastTimeMs: stats.lastTimeMs,
    activeSpanMs: stats.activeSpanMs,
    medianUniqueDtMs: stats.medianUniqueDtMs,
    p90UniqueDtMs: stats.p90UniqueDtMs,
    p99UniqueDtMs: stats.p99UniqueDtMs,
    longGapCount: stats.longGapCount,
    prefixCount: group.prefixCounts.size,
    laneCountAtMinGroup: lanesAtMin.length,
    topPrefixes: laneCounts,
    bestYawWithin33Rate,
    knownGuidHitCount,
  };
  return {
    ...summary,
    movementFamilyScore: movementFamilyScore(summary),
  };
}

function summarizeTargetField(samples) {
  const target = samples.filter(
    (sample) =>
      sample.fieldHandle === 3 &&
      /ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous/i.test(
        sample.fieldName ?? '',
      ),
  );
  const byBitCount = new Map();
  for (const sample of target) {
    let group = byBitCount.get(sample.bitCount);
    if (!group) {
      group = {
        bitCount: sample.bitCount,
        entries: [],
        prefixes: new Map(),
      };
      byBitCount.set(sample.bitCount, group);
    }
    group.entries.push(sample);
    increment(group.prefixes, bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)));
  }
  return {
    count: target.length,
    timeStats: timeStats(target),
    bitCountFamilies: [...byBitCount.values()]
      .map((group) => ({
        bitCount: group.bitCount,
        count: group.entries.length,
        firstTimeMs: group.entries[0]?.timeMs ?? null,
        lastTimeMs: group.entries.at(-1)?.timeMs ?? null,
        topPrefixes: topCounts(group.prefixes, 8),
      }))
      .sort((a, b) => b.count - a.count || a.bitCount - b.bitCount),
    firstSamples: target.slice(0, 16).map((sample) => ({
      timeMs: sample.timeMs,
      bitCount: sample.bitCount,
      payloadHex: sample.payloadHex.slice(0, 160),
    })),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_replay_controller_timeline.mjs --diagnostics replay.diagnostics.json --out replay_controller_timeline.report.json',
    );
    process.exit(1);
  }
  const outPath = resolveUserPath(options.out);
  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics);
  const playerOpenSamples = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const knownPlayerGuids = [...new Set(playerOpenSamples.map((sample) => sample.netGuid))].sort(
    (a, b) => a - b,
  );
  const { laneGroups, fieldBitGroups } = groupSamples(samples, options.prefixBits);
  const yawTimes = [...laneGroups.values()]
    .filter((group) => group.fieldHandle === 122 && group.bitCount === 92)
    .flatMap((group) => group.entries.map((entry) => entry.timeMs))
    .sort((a, b) => a - b);

  const deepGroups = [...laneGroups.values()]
    .filter((group) => group.entries.length >= options.minGroupCount)
    .sort((a, b) => b.entries.length - a.entries.length)
    .slice(0, options.maxDeepGroups);
  const laneSummaries = deepGroups
    .map((group) => summarizeLaneGroup(group, knownPlayerGuids, yawTimes))
    .sort(
      (a, b) =>
        b.count - a.count ||
        a.fieldHandle - b.fieldHandle ||
        a.bitCount - b.bitCount ||
        a.prefixHex.localeCompare(b.prefixHex),
    );

  const fieldBitFamilies = [...fieldBitGroups.values()]
    .filter((group) => group.entries.length >= options.minGroupCount)
    .map((group) => summarizeFieldBitFamily(group, laneSummaries, options.minGroupCount))
    .sort(
      (a, b) =>
        b.movementFamilyScore - a.movementFamilyScore ||
        b.count - a.count ||
        a.fieldHandle - b.fieldHandle,
    );

  const report = {
    generatedAt: new Date().toISOString(),
    input: diagnosticsPath,
    source: {
      sampleCount: samples.length,
      fullPayloadSampleCount: samples.filter((sample) => sample.hasFullPayload).length,
      prefixBits: options.prefixBits,
      minGroupCount: options.minGroupCount,
      maxDeepGroups: options.maxDeepGroups,
      knownPlayerGuids,
      playerOpenSamples,
      yawReference: {
        fieldHandle: 122,
        bitCount: 92,
        sampleTimeCount: yawTimes.length,
      },
    },
    notes: [
      'This report ranks ReplayController ClassNetCache payload families by cadence, lane prefixes, GUID recurrences, and time overlap with the handle-122 yaw candidate.',
      'High scores are decoder leads only. A movement track still requires identity, map-plausible position, and continuity to pass together.',
    ],
    targetField3Timeline: summarizeTargetField(samples),
    candidateMovementFamilies: fieldBitFamilies
      .filter(
        (family) =>
          family.count >= 80 &&
          family.uniquePayloadRate >= 0.05 &&
          (family.laneCountAtMinGroup >= 4 ||
            family.knownGuidHitCount > 0 ||
            family.bestYawWithin33Rate >= 0.5),
      )
      .slice(0, 80),
    fieldBitFamilies: fieldBitFamilies.slice(0, 160),
    payloadLaneGroups: laneSummaries.slice(0, 220),
    guidBearingLaneGroups: laneSummaries
      .filter((group) => group.knownGuidHits.length)
      .sort((a, b) => b.knownGuidHits[0].count - a.knownGuidHits[0].count || b.count - a.count)
      .slice(0, 80),
    yawOverlappingLaneGroups: laneSummaries
      .filter((group) => (group.yawTimeOverlap?.within33Rate ?? 0) >= 0.8)
      .sort(
        (a, b) =>
          (b.yawTimeOverlap?.within8Rate ?? 0) - (a.yawTimeOverlap?.within8Rate ?? 0) ||
          b.count - a.count,
      )
      .slice(0, 80),
  };

  if (outPath) writeJson(outPath, report);
  else console.log(JSON.stringify(report, null, 2));
}

main();
