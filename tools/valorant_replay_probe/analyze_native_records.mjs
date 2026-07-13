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
    out: null,
  };
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

function increment(map, key, amount = 1) {
  map.set(key, (map.get(key) ?? 0) + amount);
}

function topCounts(map, limit = 20) {
  return [...map.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || String(a.key).localeCompare(String(b.key)))
    .slice(0, limit);
}

function percentile(sortedValues, fraction) {
  if (!sortedValues.length) return null;
  const index = Math.min(
    sortedValues.length - 1,
    Math.max(0, Math.floor(sortedValues.length * fraction)),
  );
  return sortedValues[index];
}

function readBitsUnsigned(buffer, bitOffset, bitCount) {
  let value = 0;
  let bitValue = 1;
  for (let bit = 0; bit < bitCount; bit += 1) {
    if ((buffer[(bitOffset + bit) >> 3] >> ((bitOffset + bit) & 7)) & 1) {
      value += bitValue;
    }
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
    if ((buffer[(sourceBitOffset + bit) >> 3] >> ((sourceBitOffset + bit) & 7)) & 1) {
      result[bit >> 3] |= 1 << (bit & 7);
    }
  }
  return result;
}

function bitsToHexPrefix(buffer, sourceBitOffset, bitCount) {
  return copyBits(buffer, sourceBitOffset, bitCount).toString('hex');
}

function readIntPacked(buffer, bitOffset, bitLimit = buffer.length * 8) {
  let value = 0;
  let shift = 1;
  let offset = bitOffset;
  for (let index = 0; index < 5; index += 1) {
    if (offset + 8 > bitLimit) return { value, bitCount: offset - bitOffset, ok: false };
    const currentByte = readBitsUnsigned(buffer, offset, 8);
    offset += 8;
    value += (currentByte >> 1) * shift;
    if ((currentByte & 1) === 0) {
      return { value, bitCount: offset - bitOffset, ok: true };
    }
    shift *= 128;
  }
  return { value, bitCount: offset - bitOffset, ok: false };
}

function readIntPackedSequence(buffer, bitLimit = buffer.length * 8) {
  const values = [];
  let bitOffset = 0;
  while (bitOffset < bitLimit) {
    const entry = readIntPacked(buffer, bitOffset, bitLimit);
    values.push({
      value: entry.value,
      bitOffset,
      bitCount: entry.bitCount,
      ok: entry.ok,
    });
    bitOffset += entry.bitCount;
    if (!entry.ok || entry.bitCount <= 0) break;
  }
  return values;
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

function overlapsRange(offset, bitCount, rangeStart, rangeEnd) {
  return offset < rangeEnd && offset + bitCount > rangeStart;
}

function parseRecords(diagnostics) {
  const samples = diagnostics.frameSummary?.replayControllerTargetNativeRecordSamples ?? [];
  return samples
    .filter((sample) => typeof sample.hex === 'string' && sample.hex.length >= 20)
    .map((sample) => {
      const buffer = Buffer.from(sample.hex.slice(0, 20), 'hex');
      const intPacked = readIntPackedSequence(buffer, 80);
      return {
        ...sample,
        buffer,
        firstIntPacked: intPacked[0]?.value ?? null,
        secondIntPacked: intPacked[1]?.value ?? null,
        intPacked,
      };
    });
}

function parsePayloadSamples(diagnostics) {
  const payloadSummary = diagnostics.frameSummary?.replayControllerTargetPayloadSummary ?? [];
  const payloads = [];
  const seen = new Set();
  for (const entry of payloadSummary) {
    for (const sample of entry.samples ?? []) {
      const bitCount = sample.bitCount ?? entry.numPayloadBits;
      if (!sample.payloadHex || bitCount < 1) continue;
      const key = `${sample.timeMs}:${bitCount}:${sample.payloadHex}`;
      if (seen.has(key)) continue;
      seen.add(key);
      payloads.push({
        timeMs: sample.timeMs,
        bitCount,
        payloadHex: sample.payloadHex,
        buffer: Buffer.from(sample.payloadHex, 'hex'),
        expectedFullRecordCount: entry.fullRecordCount,
        expectedTrailingBits: entry.trailingBits,
        groupCount: entry.count,
      });
    }
  }
  return payloads.sort((a, b) => a.timeMs - b.timeMs || a.bitCount - b.bitCount);
}

function summarizePayloadStride(diagnostics) {
  const payloadSummary = diagnostics.frameSummary?.replayControllerTargetPayloadSummary ?? [];
  return payloadSummary.map((entry) => ({
    numPayloadBits: entry.numPayloadBits,
    fullRecordCount: entry.fullRecordCount,
    trailingBits: entry.trailingBits,
    count: entry.count,
    firstTimeMs: entry.firstTimeMs,
    lastTimeMs: entry.lastTimeMs,
    exact80BitStride: entry.trailingBits === 0 || entry.fullRecordCount > 0,
  }));
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

function scanKnownGuidHitsInBuffer(buffer, bitCount, knownGuids, maxHits = 80) {
  const known = new Set(knownGuids);
  const hits = [];
  if (!known.size) return hits;

  for (let bitOffset = 0; bitOffset < bitCount && hits.length < maxHits; bitOffset += 1) {
    const packed = readIntPacked(buffer, bitOffset, bitCount);
    if (packed.ok && known.has(packed.value)) {
      hits.push({
        encoding: 'intPacked',
        bitOffset,
        bitCount: packed.bitCount,
        value: packed.value,
      });
    }

    if (bitOffset + 32 <= bitCount) {
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

    for (const width of [10, 11, 12, 13, 14, 15, 16]) {
      if (bitOffset + width > bitCount) continue;
      const fixed = readBitsUnsigned(buffer, bitOffset, width);
      if (known.has(fixed)) {
        hits.push({
          encoding: `uint${width}`,
          bitOffset,
          bitCount: width,
          value: fixed,
        });
      }
    }
  }

  return hits.slice(0, maxHits);
}

function scanStrongKnownGuidHitsInBuffer(buffer, bitCount, knownGuids) {
  const known = new Set(knownGuids);
  const hits = [];
  if (!known.size) return hits;

  for (let bitOffset = 0; bitOffset < bitCount; bitOffset += 1) {
    const packed = readIntPacked(buffer, bitOffset, bitCount);
    if (packed.ok && known.has(packed.value)) {
      hits.push({
        encoding: 'intPacked',
        bitOffset,
        bitCount: packed.bitCount,
        value: packed.value,
      });
    }

    if (bitOffset + 32 <= bitCount) {
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

function createRecurrenceAccumulator(fields) {
  return {
    count: 0,
    firstTimeMs: null,
    lastTimeMs: null,
    payloadBitCounts: new Map(),
    recordIndexes: new Map(),
    prefixes: new Map(),
    samples: [],
    ...fields,
  };
}

function addStrongGuidRecurrence(map, key, fields, sample, hit) {
  let entry = map.get(key);
  if (!entry) {
    entry = createRecurrenceAccumulator({
      ...fields,
      encoding: hit.encoding,
      bitOffset: hit.bitOffset,
      bitCount: hit.bitCount,
      value: hit.value,
    });
    map.set(key, entry);
  }

  entry.count += 1;
  entry.firstTimeMs =
    entry.firstTimeMs == null ? sample.timeMs : Math.min(entry.firstTimeMs, sample.timeMs);
  entry.lastTimeMs =
    entry.lastTimeMs == null ? sample.timeMs : Math.max(entry.lastTimeMs, sample.timeMs);
  increment(entry.payloadBitCounts, sample.bitCount ?? sample.parentPayloadBits ?? 'unknown');
  if (sample.recordIndex != null) increment(entry.recordIndexes, sample.recordIndex);
  if (sample.prefix3) increment(entry.prefixes, sample.prefix3);
  if (entry.samples.length < 8) {
    entry.samples.push({
      timeMs: sample.timeMs,
      bitCount: sample.bitCount ?? sample.parentPayloadBits ?? null,
      recordIndex: sample.recordIndex ?? null,
      prefix3: sample.prefix3 ?? null,
      hex: sample.hex ?? sample.payloadHex?.slice(0, 128) ?? null,
    });
  }
}

function summarizeStrongGuidRecurrences(payloads, records, knownPlayerGuids) {
  const payloadRecurrences = new Map();
  for (const payload of payloads) {
    const hits = scanStrongKnownGuidHitsInBuffer(payload.buffer, payload.bitCount, knownPlayerGuids);
    for (const hit of hits) {
      const key = [hit.encoding, hit.bitOffset, hit.bitCount, hit.value].join('|');
      addStrongGuidRecurrence(
        payloadRecurrences,
        key,
        { scope: 'payload' },
        payload,
        hit,
      );
    }
  }

  const recordRecurrences = new Map();
  const recordLaneRecurrences = new Map();
  for (const record of records) {
    const hits = scanStrongKnownGuidHitsInBuffer(record.buffer, 80, knownPlayerGuids);
    for (const hit of hits) {
      const recordKey = [
        hit.encoding,
        hit.bitOffset,
        hit.bitCount,
        hit.value,
        record.parentPayloadBits ?? 'unknown',
        record.recordIndex ?? 'unknown',
      ].join('|');
      addStrongGuidRecurrence(
        recordRecurrences,
        recordKey,
        {
          scope: 'record-index',
          parentPayloadBits: record.parentPayloadBits ?? null,
          recordIndex: record.recordIndex ?? null,
        },
        record,
        hit,
      );

      const laneKey = [
        hit.encoding,
        hit.bitOffset,
        hit.bitCount,
        hit.value,
        record.prefix3 ?? 'unknown',
      ].join('|');
      addStrongGuidRecurrence(
        recordLaneRecurrences,
        laneKey,
        {
          scope: 'record-lane',
          prefix3: record.prefix3 ?? null,
        },
        record,
        hit,
      );
    }
  }

  const finalize = (map, limit = 40) =>
    [...map.values()]
      .filter((entry) => entry.count >= 2)
      .map((entry) => ({
        ...entry,
        payloadBitCounts: topCounts(entry.payloadBitCounts, 8),
        recordIndexes: topCounts(entry.recordIndexes, 8),
        prefixes: topCounts(entry.prefixes, 8),
      }))
      .sort(
        (a, b) =>
          b.count - a.count ||
          String(a.encoding).localeCompare(String(b.encoding)) ||
          a.bitOffset - b.bitOffset ||
          a.value - b.value,
      )
      .slice(0, limit);

  return {
    note:
      'Only intPacked and uint32 hits are included here. Exact repeats are much stronger than the uint10-uint16 collision scan in targetKnownGuidScan.',
    payloadRecurrences: finalize(payloadRecurrences),
    recordIndexRecurrences: finalize(recordRecurrences),
    recordLaneRecurrences: finalize(recordLaneRecurrences),
  };
}

function summarizeTargetKnownGuidHits(payloads, records, knownPlayerGuids) {
  const payloadHits = [];
  for (const payload of payloads) {
    const hits = scanKnownGuidHitsInBuffer(payload.buffer, payload.bitCount, knownPlayerGuids, 12);
    if (!hits.length) continue;
    payloadHits.push({
      timeMs: payload.timeMs,
      bitCount: payload.bitCount,
      hits,
      payloadHex: payload.payloadHex.slice(0, 128),
    });
    if (payloadHits.length >= 40) break;
  }

  const recordHits = [];
  for (const record of records) {
    const hits = scanKnownGuidHitsInBuffer(record.buffer, 80, knownPlayerGuids, 12);
    if (!hits.length) continue;
    recordHits.push({
      timeMs: record.timeMs,
      parentPayloadBits: record.parentPayloadBits ?? null,
      recordIndex: record.recordIndex,
      prefix3: record.prefix3,
      hits,
      hex: record.hex,
    });
    if (recordHits.length >= 80) break;
  }

  const hitCounts = new Map();
  for (const entry of [...payloadHits, ...recordHits]) {
    for (const hit of entry.hits) {
      increment(hitCounts, `${hit.encoding}:${hit.value}`);
    }
  }

  return {
    knownPlayerGuids,
    payloadHitCount: payloadHits.length,
    recordHitCount: recordHits.length,
    topHits: topCounts(hitCounts, 40),
    payloadHits,
    recordHits,
  };
}

function stableRanges(stableBits) {
  const ranges = [];
  let start = null;
  for (let bit = 0; bit <= stableBits.length; bit += 1) {
    if (bit < stableBits.length && stableBits[bit]) {
      if (start == null) start = bit;
    } else if (start != null) {
      ranges.push({ start, end: bit - 1, length: bit - start });
      start = null;
    }
  }
  return ranges;
}

function summarizeLaneBitStability(records, limit = 40) {
  const groups = new Map();
  for (const record of records) {
    if (!groups.has(record.prefix3)) groups.set(record.prefix3, []);
    groups.get(record.prefix3).push(record);
  }

  return [...groups.entries()]
    .filter(([, entries]) => entries.length >= 3)
    .map(([prefix3, entries]) => {
      const oneCounts = Array.from({ length: 80 }, () => 0);
      for (const entry of entries) {
        for (let bit = 0; bit < 80; bit += 1) {
          if ((entry.buffer[bit >> 3] >> (bit & 7)) & 1) oneCounts[bit] += 1;
        }
      }
      const stableBits = oneCounts.map((count) => count === 0 || count === entries.length);
      const variableBits = stableBits
        .map((stable, bit) => (stable ? null : bit))
        .filter((bit) => bit != null);
      return {
        prefix3,
        count: entries.length,
        firstTimeMs: Math.min(...entries.map((entry) => entry.timeMs)),
        lastTimeMs: Math.max(...entries.map((entry) => entry.timeMs)),
        stableBitCount: stableBits.filter(Boolean).length,
        variableBitCount: variableBits.length,
        stableRanges: stableRanges(stableBits)
          .sort((a, b) => b.length - a.length || a.start - b.start)
          .slice(0, 12),
        variableBits: variableBits.slice(0, 80),
        samples: entries.slice(0, 8).map((entry) => ({
          timeMs: entry.timeMs,
          parentPayloadBits: entry.parentPayloadBits ?? null,
          recordIndex: entry.recordIndex,
          hex: entry.hex,
        })),
      };
    })
    .sort((a, b) => b.count - a.count || b.stableBitCount - a.stableBitCount)
    .slice(0, limit);
}

function summarizeStrideOffsets(payloads, label, predicate = () => true) {
  const selected = payloads.filter((payload) => payload.bitCount >= 80 && predicate(payload));
  const repeatedGroups = new Map();
  for (const payload of selected) {
    if (!repeatedGroups.has(payload.bitCount)) repeatedGroups.set(payload.bitCount, []);
    repeatedGroups.get(payload.bitCount).push(payload);
  }

  const candidates = [];
  for (let offset = 0; offset < 80; offset += 1) {
    let totalRecords = 0;
    let payloadCount = 0;
    let exactFitPayloadCount = 0;
    const repeatedGroupStats = [];

    for (const [bitCount, groupPayloads] of repeatedGroups.entries()) {
      const recordCount = Math.floor((bitCount - offset) / 80);
      if (recordCount <= 0) continue;
      const trailingBits = bitCount - offset - recordCount * 80;
      payloadCount += groupPayloads.length;
      totalRecords += recordCount * groupPayloads.length;
      if (trailingBits === 0) exactFitPayloadCount += groupPayloads.length;

      if (groupPayloads.length < 2) continue;
      const indexStats = [];
      for (let recordIndex = 0; recordIndex < recordCount; recordIndex += 1) {
        const prefixCounts = new Map();
        const firstIntCounts = new Map();
        for (const payload of groupPayloads) {
          const bitOffset = offset + recordIndex * 80;
          const prefixHex = bitsToHexPrefix(payload.buffer, bitOffset, 24);
          increment(prefixCounts, prefixHex);
          const recordBuffer = copyBits(payload.buffer, bitOffset, 80);
          const firstInt = readIntPacked(recordBuffer, 0, 80);
          if (firstInt.ok) increment(firstIntCounts, firstInt.value);
        }
        const topPrefix = topCounts(prefixCounts, 1)[0] ?? null;
        const topFirstInt = topCounts(firstIntCounts, 1)[0] ?? null;
        indexStats.push({
          recordIndex,
          topPrefix: topPrefix?.key ?? null,
          topPrefixCount: topPrefix?.count ?? 0,
          uniquePrefixCount: prefixCounts.size,
          topFirstInt: topFirstInt?.key ?? null,
          topFirstIntCount: topFirstInt?.count ?? 0,
        });
      }
      const stableIndexCount = indexStats.filter(
        (entry) => entry.topPrefixCount >= Math.max(2, Math.ceil(groupPayloads.length * 0.8)),
      ).length;
      const topPrefixHitCount = indexStats.reduce((sum, entry) => sum + entry.topPrefixCount, 0);
      repeatedGroupStats.push({
        bitCount,
        payloadCount: groupPayloads.length,
        offset,
        recordCount,
        trailingBits,
        stableIndexCount,
        topPrefixHitCount,
        indexStats: indexStats.slice(0, 24),
      });
    }

    const repeatedScore = repeatedGroupStats.reduce(
      (sum, group) => sum + group.stableIndexCount * 100 + group.topPrefixHitCount,
      0,
    );
    candidates.push({
      label,
      offset,
      payloadCount,
      totalRecords,
      exactFitPayloadCount,
      repeatedScore,
      repeatedGroupStats,
    });
  }

  return candidates
    .filter((candidate) => candidate.totalRecords > 0)
    .sort((a, b) => {
      if (b.repeatedScore !== a.repeatedScore) return b.repeatedScore - a.repeatedScore;
      if (b.exactFitPayloadCount !== a.exactFitPayloadCount) {
        return b.exactFitPayloadCount - a.exactFitPayloadCount;
      }
      return a.offset - b.offset;
    })
    .slice(0, 20);
}

function summarizePrefixes(records, limit = 80) {
  const groups = new Map();
  for (const record of records) {
    const key = record.prefix3;
    let group = groups.get(key);
    if (!group) {
      group = {
        prefix3: key,
        firstPackedByteValue: record.firstPackedByteValue,
        firstIntPacked: record.firstIntPacked,
        secondIntPacked: record.secondIntPacked,
        count: 0,
        firstTimeMs: record.timeMs,
        lastTimeMs: record.timeMs,
        parentPayloadBits: new Map(),
        recordIndexes: new Map(),
        samples: [],
      };
      groups.set(key, group);
    }
    group.count += 1;
    group.firstTimeMs = Math.min(group.firstTimeMs, record.timeMs);
    group.lastTimeMs = Math.max(group.lastTimeMs, record.timeMs);
    increment(group.parentPayloadBits, record.parentPayloadBits ?? 'unknown');
    increment(group.recordIndexes, record.recordIndex);
    if (group.samples.length < 8) {
      group.samples.push({
        timeMs: record.timeMs,
        parentPayloadBits: record.parentPayloadBits ?? null,
        recordIndex: record.recordIndex,
        hex: record.hex,
      });
    }
  }

  return [...groups.values()]
    .map((group) => ({
      ...group,
      parentPayloadBits: topCounts(group.parentPayloadBits, 8),
      recordIndexes: topCounts(group.recordIndexes, 12),
    }))
    .sort((a, b) => b.count - a.count || a.prefix3.localeCompare(b.prefix3))
    .slice(0, limit);
}

function summarizePayloadFamilies(payloads, limit = 80) {
  const groups = new Map();
  for (const payload of payloads) {
    const prefixBits = Math.min(32, payload.bitCount);
    const suffixBits = Math.min(24, payload.bitCount);
    const prefixHex = bitsToHexPrefix(payload.buffer, 0, prefixBits);
    const suffixStart = Math.max(0, payload.bitCount - suffixBits);
    const suffixHex = bitsToHexPrefix(payload.buffer, suffixStart, suffixBits);
    const intPacked = readIntPackedSequence(payload.buffer, payload.bitCount).slice(0, 8);
    const key = [payload.bitCount, prefixHex, suffixHex].join('|');
    let group = groups.get(key);
    if (!group) {
      group = {
        bitCount: payload.bitCount,
        prefixHex,
        suffixHex,
        count: 0,
        firstTimeMs: payload.timeMs,
        lastTimeMs: payload.timeMs,
        intPackedHeads: new Map(),
        samples: [],
      };
      groups.set(key, group);
    }
    group.count += 1;
    group.firstTimeMs = Math.min(group.firstTimeMs, payload.timeMs);
    group.lastTimeMs = Math.max(group.lastTimeMs, payload.timeMs);
    increment(
      group.intPackedHeads,
      intPacked
        .map((entry) =>
          entry.ok
            ? `${entry.value}@${entry.bitOffset}/${entry.bitCount}`
            : `bad:${entry.value}@${entry.bitOffset}/${entry.bitCount}`,
        )
        .join(' '),
    );
    if (group.samples.length < 8) {
      group.samples.push({
        timeMs: payload.timeMs,
        payloadHex: payload.payloadHex.slice(0, Math.ceil(payload.bitCount / 4)),
        intPacked: intPacked.map((entry) => ({
          value: entry.value,
          bitOffset: entry.bitOffset,
          bitCount: entry.bitCount,
          ok: entry.ok,
        })),
      });
    }
  }

  return [...groups.values()]
    .map((group) => ({
      ...group,
      intPackedHeads: topCounts(group.intPackedHeads, 6),
    }))
    .sort((a, b) => b.count - a.count || a.bitCount - b.bitCount || a.prefixHex.localeCompare(b.prefixHex))
    .slice(0, limit);
}

function normalizeHexToFullBytes(hex) {
  if (typeof hex !== 'string') return '';
  return hex.length % 2 === 0 ? hex : `${hex}0`;
}

function parseCandidateFieldSamples(diagnostics) {
  const samples = diagnostics.frameSummary?.replayControllerCandidateFieldSamples ?? [];
  return samples
    .filter((sample) => sample.payloadHex != null && sample.numPayloadBits != null)
    .map((sample) => {
      const bitCount = sample.numPayloadBits;
      const payloadHex = normalizeHexToFullBytes(sample.payloadHex);
      const buffer = Buffer.from(payloadHex, 'hex');
      return {
        ...sample,
        bitCount,
        payloadHex,
        buffer,
        hasFullPayload: !sample.payloadHexTruncated && buffer.length * 8 >= bitCount,
      };
    })
    .sort(
      (a, b) =>
        a.fieldHandle - b.fieldHandle ||
        a.bitCount - b.bitCount ||
        a.timeMs - b.timeMs,
    );
}

function bitsToHex(buffer, sourceBitOffset, bitCount) {
  if (bitCount <= 0) return '';
  return bitsToHexPrefix(buffer, sourceBitOffset, bitCount);
}

function rangesFromFlags(flags) {
  return stableRanges(flags);
}

function summarizeNumericValues(values) {
  if (!values.length) return null;
  const counts = new Map();
  for (const value of values) increment(counts, value);
  const sorted = [...values].sort((a, b) => a - b);
  return {
    min: sorted[0],
    max: sorted.at(-1),
    uniqueCount: counts.size,
    topValues: topCounts(counts, 12),
  };
}

function summarizeVariableRangeValues(entries, variableRanges) {
  const primaryRange = variableRanges.find((range) => range.length <= 32);
  if (!primaryRange) return null;

  const unsignedValues = [];
  const signedValues = [];
  const samples = [];
  for (const entry of entries) {
    const unsigned = readBitsUnsigned(entry.buffer, primaryRange.start, primaryRange.length);
    const signed = readBitsSigned(entry.buffer, primaryRange.start, primaryRange.length);
    unsignedValues.push(unsigned);
    signedValues.push(signed);
    if (samples.length < 12) {
      samples.push({
        timeMs: entry.timeMs,
        unsigned,
        signed,
        payloadHex: entry.payloadHex.slice(0, 96),
      });
    }
  }

  return {
    range: primaryRange,
    unsigned: summarizeNumericValues(unsignedValues),
    signed: summarizeNumericValues(signedValues),
    samples,
  };
}

function summarizeCandidateFieldStreams(samples, limit = 140) {
  const fields = new Map();
  for (const sample of samples) {
    const fieldKey = [sample.fieldHandle, sample.fieldName ?? ''].join('|');
    let field = fields.get(fieldKey);
    if (!field) {
      field = {
        fieldHandle: sample.fieldHandle,
        fieldName: sample.fieldName ?? null,
        count: 0,
        firstTimeMs: sample.timeMs,
        lastTimeMs: sample.timeMs,
        bitCounts: new Map(),
        prefixes: new Map(),
        suffixes: new Map(),
        payloadHexes: new Map(),
        timePayloads: new Set(),
        truncatedCount: 0,
        samples: [],
      };
      fields.set(fieldKey, field);
    }

    field.count += 1;
    field.firstTimeMs = Math.min(field.firstTimeMs, sample.timeMs);
    field.lastTimeMs = Math.max(field.lastTimeMs, sample.timeMs);
    increment(field.bitCounts, sample.bitCount);
    field.timePayloads.add(`${sample.timeMs}:${sample.bitCount}:${sample.payloadHex}`);
    if (sample.payloadHexTruncated) field.truncatedCount += 1;
    if (sample.hasFullPayload) {
      const prefixBits = Math.min(32, sample.bitCount);
      const suffixBits = Math.min(24, sample.bitCount);
      const suffixOffset = Math.max(0, sample.bitCount - suffixBits);
      increment(field.prefixes, bitsToHex(sample.buffer, 0, prefixBits));
      increment(field.suffixes, bitsToHex(sample.buffer, suffixOffset, suffixBits));
      increment(field.payloadHexes, sample.payloadHex.slice(0, Math.ceil(sample.bitCount / 8) * 2));
    }
    if (field.samples.length < 10) {
      field.samples.push({
        timeMs: sample.timeMs,
        bitCount: sample.bitCount,
        payloadHex: sample.payloadHex.slice(0, 160),
        payloadHexTruncated: Boolean(sample.payloadHexTruncated),
      });
    }
  }

  return [...fields.values()]
    .map((field) => ({
      fieldHandle: field.fieldHandle,
      fieldName: field.fieldName,
      count: field.count,
      firstTimeMs: field.firstTimeMs,
      lastTimeMs: field.lastTimeMs,
      bitCounts: topCounts(field.bitCounts, 16),
      topPrefixes: topCounts(field.prefixes, 16),
      topSuffixes: topCounts(field.suffixes, 12),
      uniqueTimePayloadCount: field.timePayloads.size,
      duplicateTimePayloadCount: field.count - field.timePayloads.size,
      uniquePayloadCount: field.payloadHexes.size,
      topPayloadHexes: topCounts(field.payloadHexes, 8),
      truncatedCount: field.truncatedCount,
      samples: field.samples,
    }))
    .sort((a, b) => b.count - a.count || a.fieldHandle - b.fieldHandle)
    .slice(0, limit);
}

function summarizeCandidateFieldPrefixSets(samples, limit = 80) {
  const groups = new Map();
  for (const sample of samples) {
    if (!sample.hasFullPayload || sample.bitCount <= 0 || sample.bitCount > 512) continue;
    const key = [sample.fieldHandle, sample.fieldName ?? '', sample.bitCount].join('|');
    let group = groups.get(key);
    if (!group) {
      group = {
        fieldHandle: sample.fieldHandle,
        fieldName: sample.fieldName ?? null,
        bitCount: sample.bitCount,
        count: 0,
        firstTimeMs: sample.timeMs,
        lastTimeMs: sample.timeMs,
        prefixes: new Map(),
        suffixes: new Map(),
      };
      groups.set(key, group);
    }
    group.count += 1;
    group.firstTimeMs = Math.min(group.firstTimeMs, sample.timeMs);
    group.lastTimeMs = Math.max(group.lastTimeMs, sample.timeMs);
    increment(group.prefixes, bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)));
    increment(
      group.suffixes,
      bitsToHex(sample.buffer, Math.max(0, sample.bitCount - Math.min(24, sample.bitCount)), Math.min(24, sample.bitCount)),
    );
  }

  return [...groups.values()]
    .map((group) => {
      const topPrefixes = topCounts(group.prefixes, 20);
      return {
        fieldHandle: group.fieldHandle,
        fieldName: group.fieldName,
        bitCount: group.bitCount,
        count: group.count,
        firstTimeMs: group.firstTimeMs,
        lastTimeMs: group.lastTimeMs,
        uniquePrefixCount: group.prefixes.size,
        uniqueSuffixCount: group.suffixes.size,
        topPrefixes,
        topSuffixes: topCounts(group.suffixes, 12),
        topPrefixCoverage: topPrefixes.reduce((sum, entry) => sum + entry.count, 0),
      };
    })
    .filter((group) => group.count >= 3)
    .sort(
      (a, b) =>
        b.count - a.count ||
        a.uniquePrefixCount - b.uniquePrefixCount ||
        a.fieldHandle - b.fieldHandle,
    )
    .slice(0, limit);
}

function summarizeCandidateLaneStability(samples, limit = 160) {
  const groups = new Map();
  for (const sample of samples) {
    if (!sample.hasFullPayload || sample.bitCount <= 0 || sample.bitCount > 512) continue;
    const prefixBits = Math.min(32, sample.bitCount);
    const prefixHex = bitsToHex(sample.buffer, 0, prefixBits);
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

  return [...groups.values()]
    .filter((group) => group.entries.length >= 3)
    .map((group) => {
      const uniqueEntriesByTimePayload = new Map();
      for (const entry of group.entries) {
        uniqueEntriesByTimePayload.set(`${entry.timeMs}:${entry.payloadHex}`, entry);
      }
      const entries = [...uniqueEntriesByTimePayload.values()];
      const oneCounts = Array.from({ length: group.bitCount }, () => 0);
      for (const entry of entries) {
        for (let bit = 0; bit < group.bitCount; bit += 1) {
          if ((entry.buffer[bit >> 3] >> (bit & 7)) & 1) oneCounts[bit] += 1;
        }
      }

      const stableBits = oneCounts.map(
        (count) => count === 0 || count === entries.length,
      );
      const variableFlags = stableBits.map((stable) => !stable);
      const variableRanges = rangesFromFlags(variableFlags);
      const stableRangeSummary = rangesFromFlags(stableBits)
        .sort((a, b) => b.length - a.length || a.start - b.start)
        .slice(0, 12);
      const intPackedHeads = new Map();
      for (const entry of entries) {
        const head = readIntPackedSequence(entry.buffer, group.bitCount)
          .slice(0, 6)
          .map((item) =>
            item.ok
              ? `${item.value}@${item.bitOffset}/${item.bitCount}`
              : `bad:${item.value}@${item.bitOffset}/${item.bitCount}`,
          )
          .join(' ');
        increment(intPackedHeads, head);
      }

      return {
        fieldHandle: group.fieldHandle,
        fieldName: group.fieldName,
        bitCount: group.bitCount,
        prefixHex: group.prefixHex,
        count: entries.length,
        rawSampleCount: group.entries.length,
        duplicateSampleCount: group.entries.length - entries.length,
        firstTimeMs: Math.min(...entries.map((entry) => entry.timeMs)),
        lastTimeMs: Math.max(...entries.map((entry) => entry.timeMs)),
        stableBitCount: stableBits.filter(Boolean).length,
        variableBitCount: variableFlags.filter(Boolean).length,
        stableRanges: stableRangeSummary,
        variableRanges,
        valueSummary: summarizeVariableRangeValues(entries, variableRanges),
        intPackedHeads: topCounts(intPackedHeads, 8),
        samples: entries.slice(0, 8).map((entry) => ({
          timeMs: entry.timeMs,
          payloadHex: entry.payloadHex.slice(0, 160),
        })),
      };
    })
    .sort((a, b) => {
      if (b.count !== a.count) return b.count - a.count;
      if (a.variableBitCount !== b.variableBitCount) return a.variableBitCount - b.variableBitCount;
      return a.fieldHandle - b.fieldHandle || a.prefixHex.localeCompare(b.prefixHex);
    })
    .slice(0, limit);
}

function summarizeCandidateFieldGuidRecurrences(samples, knownPlayerGuids, limit = 80) {
  const recurrences = new Map();
  for (const sample of samples) {
    if (!sample.hasFullPayload || sample.bitCount <= 0 || sample.bitCount > 512) continue;
    const hits = scanStrongKnownGuidHitsInBuffer(sample.buffer, sample.bitCount, knownPlayerGuids);
    for (const hit of hits) {
      const key = [
        sample.fieldHandle,
        sample.fieldName ?? '',
        sample.bitCount,
        hit.encoding,
        hit.bitOffset,
        hit.bitCount,
        hit.value,
      ].join('|');
      let recurrence = recurrences.get(key);
      if (!recurrence) {
        recurrence = {
          fieldHandle: sample.fieldHandle,
          fieldName: sample.fieldName ?? null,
          payloadBitCount: sample.bitCount,
          encoding: hit.encoding,
          bitOffset: hit.bitOffset,
          bitCount: hit.bitCount,
          value: hit.value,
          count: 0,
          firstTimeMs: sample.timeMs,
          lastTimeMs: sample.timeMs,
          prefixes: new Map(),
          samples: [],
        };
        recurrences.set(key, recurrence);
      }
      recurrence.count += 1;
      recurrence.firstTimeMs = Math.min(recurrence.firstTimeMs, sample.timeMs);
      recurrence.lastTimeMs = Math.max(recurrence.lastTimeMs, sample.timeMs);
      increment(
        recurrence.prefixes,
        bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)),
      );
      if (recurrence.samples.length < 8) {
        recurrence.samples.push({
          timeMs: sample.timeMs,
          payloadHex: sample.payloadHex.slice(0, 160),
        });
      }
    }
  }

  return [...recurrences.values()]
    .filter((recurrence) => recurrence.count >= 2)
    .map((recurrence) => ({
      ...recurrence,
      prefixes: topCounts(recurrence.prefixes, 12),
    }))
    .sort(
      (a, b) =>
        b.count - a.count ||
        a.fieldHandle - b.fieldHandle ||
        a.bitOffset - b.bitOffset ||
        a.value - b.value,
    )
    .slice(0, limit);
}

function summarizeCandidateFields(diagnostics, knownPlayerGuids) {
  const samples = parseCandidateFieldSamples(diagnostics);
  return {
    sampleCount: samples.length,
    capture: diagnostics.frameSummary?.replayControllerCandidateFieldCapture ?? null,
    fieldSummary: summarizeCandidateFieldStreams(samples),
    prefixSetSummary: summarizeCandidateFieldPrefixSets(samples),
    laneStabilitySummary: summarizeCandidateLaneStability(samples),
    strongKnownGuidRecurrences: summarizeCandidateFieldGuidRecurrences(
      samples,
      knownPlayerGuids,
    ),
  };
}

function summarizeIntPacked(records) {
  const firstValues = new Map();
  const secondValues = new Map();
  const sequenceLengths = new Map();
  const firstPairs = new Map();
  const sequenceSamples = [];

  for (const record of records) {
    if (record.firstIntPacked != null) increment(firstValues, record.firstIntPacked);
    if (record.secondIntPacked != null) increment(secondValues, record.secondIntPacked);
    increment(sequenceLengths, record.intPacked.length);
    if (record.firstIntPacked != null && record.secondIntPacked != null) {
      increment(firstPairs, `${record.firstIntPacked}|${record.secondIntPacked}`);
    }
    if (sequenceSamples.length < 24) {
      sequenceSamples.push({
        timeMs: record.timeMs,
        parentPayloadBits: record.parentPayloadBits ?? null,
        recordIndex: record.recordIndex,
        prefix3: record.prefix3,
        hex: record.hex,
        values: record.intPacked.map((entry) => ({
          value: entry.value,
          bitOffset: entry.bitOffset,
          bitCount: entry.bitCount,
          ok: entry.ok,
        })),
      });
    }
  }

  return {
    firstValues: topCounts(firstValues, 30),
    secondValues: topCounts(secondValues, 30),
    sequenceLengths: topCounts(sequenceLengths, 12),
    firstPairs: topCounts(firstPairs, 30),
    sequenceSamples,
  };
}

const PACKED80_FOCUSED_LAYOUT = {
  label: 'id5+s16x4@5/21/37/53',
  id: { bitOffset: 0, bitCount: 5, encoding: 'uint5' },
  x: { bitOffset: 5, bitCount: 16, encoding: 'signed16', scale: 10 },
  y: { bitOffset: 21, bitCount: 16, encoding: 'signed16', scale: 10 },
  z: { bitOffset: 37, bitCount: 16, encoding: 'signed16', scale: 10 },
  w: {
    bitOffset: 53,
    bitCount: 16,
    encoding: 'signed16',
    yawScale: 'degrees = signed * 360 / 2^16',
  },
};

const STRICT_WORLD_Z_RANGE = { min: -500, max: 900 };
const LOOSE_WORLD_Z_RANGE = { min: -1000, max: 2000 };
const HANDLE122_FIELD_HANDLE = 122;
const HANDLE122_PAYLOAD_BITS = 92;
const HANDLE122_YAW_BIT_OFFSET = 50;
const HANDLE122_YAW_BIT_COUNT = 18;

function roundNumber(value, digits = 2) {
  if (value == null || !Number.isFinite(value)) return null;
  return Number(value.toFixed(digits));
}

function summarizeContinuousValues(values, digits = 2) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return {
    min: roundNumber(sorted[0], digits),
    p50: roundNumber(percentile(sorted, 0.5), digits),
    p90: roundNumber(percentile(sorted, 0.9), digits),
    max: roundNumber(sorted.at(-1), digits),
  };
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

function decodeFocusedPacked80Record(record) {
  const id5 = readBitsUnsigned(
    record.buffer,
    PACKED80_FOCUSED_LAYOUT.id.bitOffset,
    PACKED80_FOCUSED_LAYOUT.id.bitCount,
  );
  const xRaw = readBitsSigned(
    record.buffer,
    PACKED80_FOCUSED_LAYOUT.x.bitOffset,
    PACKED80_FOCUSED_LAYOUT.x.bitCount,
  );
  const yRaw = readBitsSigned(
    record.buffer,
    PACKED80_FOCUSED_LAYOUT.y.bitOffset,
    PACKED80_FOCUSED_LAYOUT.y.bitCount,
  );
  const zRaw = readBitsSigned(
    record.buffer,
    PACKED80_FOCUSED_LAYOUT.z.bitOffset,
    PACKED80_FOCUSED_LAYOUT.z.bitCount,
  );
  const wRaw = readBitsSigned(
    record.buffer,
    PACKED80_FOCUSED_LAYOUT.w.bitOffset,
    PACKED80_FOCUSED_LAYOUT.w.bitCount,
  );
  const x = xRaw / PACKED80_FOCUSED_LAYOUT.x.scale;
  const y = yRaw / PACKED80_FOCUSED_LAYOUT.y.scale;
  const z = zRaw / PACKED80_FOCUSED_LAYOUT.z.scale;
  const yawDegrees = (wRaw * 360) / 2 ** PACKED80_FOCUSED_LAYOUT.w.bitCount;

  return {
    timeMs: record.timeMs,
    parentPayloadBits: record.parentPayloadBits ?? null,
    parentFullRecordCount: record.parentFullRecordCount ?? null,
    parentTrailingBits: record.parentTrailingBits ?? null,
    recordIndex: record.recordIndex ?? null,
    recordBitOffset: record.recordBitOffset ?? null,
    prefix3: record.prefix3 ?? null,
    hex: record.hex,
    id5,
    raw: { x: xRaw, y: yRaw, z: zRaw, w: wRaw },
    x,
    y,
    z,
    wYawDegrees: yawDegrees,
    wYawDegrees360: normalizeDegrees360(yawDegrees),
    inAscentBounds: isPlausibleAscentXY(x, y),
    strictZInWorldRange: z >= STRICT_WORLD_Z_RANGE.min && z <= STRICT_WORLD_Z_RANGE.max,
    looseZInWorldRange: z >= LOOSE_WORLD_Z_RANGE.min && z <= LOOSE_WORLD_Z_RANGE.max,
  };
}

function focusedPositionKey(entry) {
  return [
    Math.round(entry.x * 10) / 10,
    Math.round(entry.y * 10) / 10,
    Math.round(entry.z * 10) / 10,
  ].join(':');
}

function summarizeFocusedStepStats(entries) {
  const sorted = [...entries].sort(
    (a, b) => a.timeMs - b.timeMs || (a.recordIndex ?? 0) - (b.recordIndex ?? 0),
  );
  const dtMs = [];
  const step2d = [];
  const step3d = [];
  const speed2d = [];
  const speed3d = [];
  const shortStep2d = [];
  const shortStep3d = [];
  const shortSpeed2d = [];
  const shortSpeed3d = [];
  let zeroOrNegativeDtCount = 0;

  for (let index = 1; index < sorted.length; index += 1) {
    const previous = sorted[index - 1];
    const current = sorted[index];
    const dt = current.timeMs - previous.timeMs;
    if (dt <= 0) {
      zeroOrNegativeDtCount += 1;
      continue;
    }
    const distance2d = Math.hypot(current.x - previous.x, current.y - previous.y);
    const distance3d = Math.hypot(
      current.x - previous.x,
      current.y - previous.y,
      current.z - previous.z,
    );
    const dtSeconds = dt / 1000;
    dtMs.push(dt);
    step2d.push(distance2d);
    step3d.push(distance3d);
    speed2d.push(distance2d / dtSeconds);
    speed3d.push(distance3d / dtSeconds);
    if (dt <= 1000) {
      shortStep2d.push(distance2d);
      shortStep3d.push(distance3d);
      shortSpeed2d.push(distance2d / dtSeconds);
      shortSpeed3d.push(distance3d / dtSeconds);
    }
  }

  const impossibleShortSpeedCount = shortSpeed2d.filter((value) => value > 1500).length;
  const impossibleShort3dSpeedCount = shortSpeed3d.filter((value) => value > 2000).length;
  return {
    consecutivePairCount: dtMs.length,
    shortConsecutivePairCount: shortSpeed2d.length,
    zeroOrNegativeDtCount,
    dtMs: summarizeContinuousValues(dtMs, 0),
    step2d: summarizeContinuousValues(step2d),
    step3d: summarizeContinuousValues(step3d),
    speed2dPerSecond: summarizeContinuousValues(speed2d),
    speed3dPerSecond: summarizeContinuousValues(speed3d),
    shortDtStep2d: summarizeContinuousValues(shortStep2d),
    shortDtStep3d: summarizeContinuousValues(shortStep3d),
    shortDtSpeed2dPerSecond: summarizeContinuousValues(shortSpeed2d),
    shortDtSpeed3dPerSecond: summarizeContinuousValues(shortSpeed3d),
    impossibleShortSpeedCount,
    impossibleShort3dSpeedCount,
  };
}

function summarizeFocusedPacked80Group(key, scope, entries) {
  const xValues = [];
  const yValues = [];
  const zValues = [];
  const yawValues = [];
  const positionKeys = new Set();
  const prefixCounts = new Map();
  const idCounts = new Map();
  const recordIndexCounts = new Map();
  const parentPayloadCounts = new Map();
  const positionsByTime = new Map();
  let inBoundsCount = 0;
  let strictZCount = 0;
  let looseZCount = 0;

  for (const entry of entries) {
    xValues.push(entry.x);
    yValues.push(entry.y);
    zValues.push(entry.z);
    yawValues.push(entry.wYawDegrees360);
    positionKeys.add(focusedPositionKey(entry));
    if (entry.inAscentBounds) inBoundsCount += 1;
    if (entry.strictZInWorldRange) strictZCount += 1;
    if (entry.looseZInWorldRange) looseZCount += 1;
    increment(prefixCounts, entry.prefix3 ?? 'unknown');
    increment(idCounts, entry.id5);
    increment(recordIndexCounts, entry.recordIndex ?? 'unknown');
    increment(parentPayloadCounts, entry.parentPayloadBits ?? 'unknown');

    if (!positionsByTime.has(entry.timeMs)) positionsByTime.set(entry.timeMs, new Set());
    positionsByTime.get(entry.timeMs).add(focusedPositionKey(entry));
  }

  const sameTimeConflictCounts = [...positionsByTime.values()].map((positions) => positions.size);
  const sameTimeConflictCount = sameTimeConflictCounts.filter((count) => count > 1).length;
  const maxPositionsAtSameTime = Math.max(0, ...sameTimeConflictCounts);
  const sorted = [...entries].sort(
    (a, b) => a.timeMs - b.timeMs || (a.recordIndex ?? 0) - (b.recordIndex ?? 0),
  );
  const timeSpanMs =
    sorted.length > 1 ? (sorted.at(-1)?.timeMs ?? 0) - (sorted[0]?.timeMs ?? 0) : 0;
  const stepStats = summarizeFocusedStepStats(sorted);
  const inBoundsRate = entries.length ? inBoundsCount / entries.length : 0;
  const strictZRate = entries.length ? strictZCount / entries.length : 0;
  const looseZRate = entries.length ? looseZCount / entries.length : 0;
  const shortP90Speed = stepStats.shortDtSpeed2dPerSecond?.p90 ?? Infinity;

  const rejectionReasons = [];
  if (entries.length < 20) rejectionReasons.push('fewer than 20 samples');
  if (timeSpanMs < 2000) rejectionReasons.push('covers less than 2 seconds');
  if (inBoundsRate < 0.95) rejectionReasons.push('less than 95% of x/y samples are in Ascent bounds');
  if (strictZRate < 0.8) rejectionReasons.push('less than 80% of z samples are in the strict world-z range');
  if (sameTimeConflictCount > 0) rejectionReasons.push('same timestamp maps to multiple positions');
  if (stepStats.shortConsecutivePairCount < 3) rejectionReasons.push('fewer than 3 short-dt continuity pairs');
  if (shortP90Speed > 1500) rejectionReasons.push('short-dt p90 2d speed exceeds 1500 units/sec');
  if (stepStats.impossibleShortSpeedCount > 0) {
    rejectionReasons.push('one or more short-dt 2d jumps exceed 1500 units/sec');
  }
  if (stepStats.impossibleShort3dSpeedCount > 0) {
    rejectionReasons.push('one or more short-dt 3d jumps exceed 2000 units/sec');
  }
  if (positionKeys.size < Math.max(3, Math.ceil(entries.length * 0.25))) {
    rejectionReasons.push('too few unique positions for the sample count');
  }

  return {
    key,
    scope,
    count: entries.length,
    firstTimeMs: sorted[0]?.timeMs ?? null,
    lastTimeMs: sorted.at(-1)?.timeMs ?? null,
    timeSpanMs,
    uniqueTimeCount: positionsByTime.size,
    uniquePositionCount: positionKeys.size,
    inBoundsCount,
    inBoundsRate: roundNumber(inBoundsRate, 3),
    strictZRange: STRICT_WORLD_Z_RANGE,
    strictZCount,
    strictZRate: roundNumber(strictZRate, 3),
    looseZRange: LOOSE_WORLD_Z_RANGE,
    looseZCount,
    looseZRate: roundNumber(looseZRate, 3),
    sameTimeConflictCount,
    maxPositionsAtSameTime,
    x: summarizeContinuousValues(xValues),
    y: summarizeContinuousValues(yValues),
    z: summarizeContinuousValues(zValues),
    wYawDegrees360: summarizeContinuousValues(yawValues),
    id5Counts: topCounts(idCounts, 8),
    prefix3Counts: topCounts(prefixCounts, 10),
    recordIndexCounts: topCounts(recordIndexCounts, 10),
    parentPayloadBits: topCounts(parentPayloadCounts, 10),
    continuity: stepStats,
    strictLaneHeuristic: {
      passes: rejectionReasons.length === 0,
      rejectionReasons,
    },
    samples: sorted.slice(0, 10).map((entry) => ({
      timeMs: entry.timeMs,
      parentPayloadBits: entry.parentPayloadBits,
      recordIndex: entry.recordIndex,
      prefix3: entry.prefix3,
      id5: entry.id5,
      x: roundNumber(entry.x, 1),
      y: roundNumber(entry.y, 1),
      z: roundNumber(entry.z, 1),
      wYawDegrees: roundNumber(normalizeDegrees180(entry.wYawDegrees), 2),
      hex: entry.hex,
    })),
  };
}

function summarizeFocusedPacked80Groups(decoded, scope, keyForEntry, minCount = 2, limit = 40) {
  const groups = new Map();
  for (const entry of decoded) {
    const key = keyForEntry(entry);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(entry);
  }

  return [...groups.entries()]
    .filter(([, entries]) => entries.length >= minCount)
    .map(([key, entries]) => summarizeFocusedPacked80Group(key, scope, entries))
    .sort((a, b) => {
      if (a.strictLaneHeuristic.passes !== b.strictLaneHeuristic.passes) {
        return a.strictLaneHeuristic.passes ? -1 : 1;
      }
      const aShortP90 = a.continuity.shortDtSpeed2dPerSecond?.p90 ?? Infinity;
      const bShortP90 = b.continuity.shortDtSpeed2dPerSecond?.p90 ?? Infinity;
      if (aShortP90 !== bShortP90) return aShortP90 - bShortP90;
      return b.count - a.count || String(a.key).localeCompare(String(b.key));
    })
    .slice(0, limit);
}

function parseHandle122YawCandidates(diagnostics) {
  const samples = parseCandidateFieldSamples(diagnostics);
  const yawCandidates = [];
  const seen = new Set();
  for (const sample of samples) {
    if (
      sample.fieldHandle !== HANDLE122_FIELD_HANDLE ||
      !sample.hasFullPayload ||
      sample.bitCount !== HANDLE122_PAYLOAD_BITS
    ) {
      continue;
    }
    const key = `${sample.timeMs}:${sample.payloadHex}`;
    if (seen.has(key)) continue;
    seen.add(key);
    const rawSignedValue = readBitsSigned(
      sample.buffer,
      HANDLE122_YAW_BIT_OFFSET,
      HANDLE122_YAW_BIT_COUNT,
    );
    const rawYawDegrees = (rawSignedValue * 360) / 2 ** HANDLE122_YAW_BIT_COUNT;
    const prefixHex = bitsToHex(sample.buffer, 0, 32);
    for (const transform of ['as-read', 'negated', 'plus-90', 'minus-90', 'plus-180']) {
      yawCandidates.push({
        timeMs: sample.timeMs,
        prefixHex,
        transform,
        rawYawDegrees,
        yawDegrees360: normalizeDegrees360(transformYaw(rawYawDegrees, transform)),
      });
    }
  }
  return yawCandidates.sort(
    (a, b) => a.timeMs - b.timeMs || a.prefixHex.localeCompare(b.prefixHex),
  );
}

function summarizeFocusedYawCrossCheck(decoded, diagnostics) {
  const yawCandidates = parseHandle122YawCandidates(diagnostics);
  const windows = [16, 32, 100, 250];
  const summarizeWindow = (windowMs) => {
    const deltas = [];
    const closeSamples = [];
    for (const entry of decoded) {
      let best = null;
      for (const candidate of yawCandidates) {
        const dt = Math.abs(candidate.timeMs - entry.timeMs);
        if (dt > windowMs) continue;
        const delta = circularDegreesDelta(entry.wYawDegrees360, candidate.yawDegrees360);
        if (!best || delta < best.deltaDegrees || (delta === best.deltaDegrees && dt < best.dtMs)) {
          best = {
            deltaDegrees: delta,
            dtMs: dt,
            handle122TimeMs: candidate.timeMs,
            handle122PrefixHex: candidate.prefixHex,
            handle122Transform: candidate.transform,
            handle122YawDegrees360: candidate.yawDegrees360,
          };
        }
      }
      if (!best) continue;
      deltas.push(best.deltaDegrees);
      if (best.deltaDegrees <= 5 && closeSamples.length < 12) {
        closeSamples.push({
          timeMs: entry.timeMs,
          parentPayloadBits: entry.parentPayloadBits,
          recordIndex: entry.recordIndex,
          prefix3: entry.prefix3,
          id5: entry.id5,
          packed80YawDegrees360: roundNumber(entry.wYawDegrees360),
          deltaDegrees: roundNumber(best.deltaDegrees),
          dtMs: best.dtMs,
          handle122TimeMs: best.handle122TimeMs,
          handle122PrefixHex: best.handle122PrefixHex,
          handle122Transform: best.handle122Transform,
          handle122YawDegrees360: roundNumber(best.handle122YawDegrees360),
        });
      }
    }
    deltas.sort((a, b) => a - b);
    return {
      windowMs,
      matchedRecordCount: deltas.length,
      closeWithin2Degrees: deltas.filter((value) => value <= 2).length,
      closeWithin5Degrees: deltas.filter((value) => value <= 5).length,
      medianDeltaDegrees: roundNumber(percentile(deltas, 0.5)),
      p90DeltaDegrees: roundNumber(percentile(deltas, 0.9)),
      closeSamples,
    };
  };

  return {
    status:
      'Yaw-only proximity check. Because there are many handle-122 lanes and five yaw transforms, close matches are expected by chance and do not prove that the 80-bit w field is view yaw.',
    handle122CandidateCount: yawCandidates.length,
    dedupedHandle122SampleCount: yawCandidates.length / 5,
    comparedRecordCount: decoded.length,
    handle122Encoding: {
      fieldHandle: HANDLE122_FIELD_HANDLE,
      payloadBits: HANDLE122_PAYLOAD_BITS,
      yawBitOffset: HANDLE122_YAW_BIT_OFFSET,
      yawBitCount: HANDLE122_YAW_BIT_COUNT,
    },
    windows: windows.map(summarizeWindow),
  };
}

function summarizeFocusedPacked80Layout(records, payloads, diagnostics) {
  const decoded = records.map(decodeFocusedPacked80Record);
  const inBoundsCount = decoded.filter((entry) => entry.inAscentBounds).length;
  const strictZCount = decoded.filter((entry) => entry.strictZInWorldRange).length;
  const looseZCount = decoded.filter((entry) => entry.looseZInWorldRange).length;
  const idCounts = new Map();
  const parentPayloadCounts = new Map();
  const recordIndexCounts = new Map();
  const prefixCounts = new Map();
  for (const entry of decoded) {
    increment(idCounts, entry.id5);
    increment(parentPayloadCounts, entry.parentPayloadBits ?? 'unknown');
    increment(recordIndexCounts, entry.recordIndex ?? 'unknown');
    increment(prefixCounts, entry.prefix3 ?? 'unknown');
  }

  const byId5 = summarizeFocusedPacked80Groups(
    decoded,
    'id5',
    (entry) => String(entry.id5),
    2,
    40,
  );
  const byRecordIndex = summarizeFocusedPacked80Groups(
    decoded,
    'recordIndex',
    (entry) => String(entry.recordIndex ?? 'unknown'),
    2,
    40,
  );
  const byPrefix3 = summarizeFocusedPacked80Groups(
    decoded,
    'prefix3',
    (entry) => entry.prefix3 ?? 'unknown',
    3,
    40,
  );
  const strictLaneCandidates = [...byId5, ...byRecordIndex, ...byPrefix3]
    .filter((entry) => entry.strictLaneHeuristic.passes)
    .slice(0, 20);

  return {
    status: strictLaneCandidates.length
      ? 'strict-lane-candidates-found'
      : 'no-strict-lane-candidates',
    note:
      'Focused test of the top broad fixed-pair lead: first 5 bits as a possible lane id, then four signed16 values at bit offsets 5/21/37/53. It is reported here only as a candidate ComponentDataStream layout.',
    layout: PACKED80_FOCUSED_LAYOUT,
    aggregate: {
      recordCount: decoded.length,
      inBoundsCount,
      inBoundsRate: roundNumber(decoded.length ? inBoundsCount / decoded.length : 0, 3),
      strictZRange: STRICT_WORLD_Z_RANGE,
      strictZCount,
      strictZRate: roundNumber(decoded.length ? strictZCount / decoded.length : 0, 3),
      looseZRange: LOOSE_WORLD_Z_RANGE,
      looseZCount,
      looseZRate: roundNumber(decoded.length ? looseZCount / decoded.length : 0, 3),
      id5Counts: topCounts(idCounts, 32),
      parentPayloadBits: topCounts(parentPayloadCounts, 16),
      recordIndexCounts: topCounts(recordIndexCounts, 32),
      prefix3Counts: topCounts(prefixCounts, 20),
    },
    strictLaneHeuristic:
      'A movement lane must have >=20 samples spanning >=2 seconds, >=95% x/y in Ascent bounds, >=80% z in -500..900, no same-time multi-position conflicts, >=3 short-dt continuity pairs, no impossible short-dt jumps, short-dt p90 speed <=1500 units/sec, and enough unique positions.',
    strictLaneCandidates,
    groupSummaries: {
      byId5,
      byRecordIndex,
      byPrefix3,
    },
    strideOffsetScan: summarizeFocusedPacked80StrideOffsetScan(payloads),
    yawCrossCheck: summarizeFocusedYawCrossCheck(decoded, diagnostics),
    decodedSamples: decoded.slice(0, 32).map((entry) => ({
      timeMs: entry.timeMs,
      parentPayloadBits: entry.parentPayloadBits,
      parentTrailingBits: entry.parentTrailingBits,
      recordIndex: entry.recordIndex,
      prefix3: entry.prefix3,
      id5: entry.id5,
      x: roundNumber(entry.x, 1),
      y: roundNumber(entry.y, 1),
      z: roundNumber(entry.z, 1),
      wYawDegrees: roundNumber(normalizeDegrees180(entry.wYawDegrees), 2),
      inAscentBounds: entry.inAscentBounds,
      strictZInWorldRange: entry.strictZInWorldRange,
      hex: entry.hex,
    })),
  };
}

function recordsFromPayloadsAtStrideOffset(payloads, strideOffset) {
  const records = [];
  for (const payload of payloads) {
    if (payload.bitCount < strideOffset + 80) continue;
    const recordCount = Math.floor((payload.bitCount - strideOffset) / 80);
    const trailingBits = payload.bitCount - strideOffset - recordCount * 80;
    for (let recordIndex = 0; recordIndex < recordCount; recordIndex += 1) {
      const recordBitOffset = strideOffset + recordIndex * 80;
      const buffer = copyBits(payload.buffer, recordBitOffset, 80);
      const hex = buffer.toString('hex');
      records.push({
        timeMs: payload.timeMs,
        parentPayloadBits: payload.bitCount,
        parentFullRecordCount: recordCount,
        parentTrailingBits: trailingBits,
        recordIndex,
        recordBitOffset,
        prefix3: hex.slice(0, 6),
        firstPackedByteValue: readBitsUnsigned(buffer, 0, 8) >> 1,
        hex,
        buffer,
      });
    }
  }
  return records;
}

function summarizeFocusedDecodedAggregate(decoded) {
  const idCounts = new Map();
  const parentPayloadCounts = new Map();
  const recordIndexCounts = new Map();
  const prefixCounts = new Map();
  let inBoundsCount = 0;
  let strictZCount = 0;
  let looseZCount = 0;

  for (const entry of decoded) {
    if (entry.inAscentBounds) inBoundsCount += 1;
    if (entry.strictZInWorldRange) strictZCount += 1;
    if (entry.looseZInWorldRange) looseZCount += 1;
    increment(idCounts, entry.id5);
    increment(parentPayloadCounts, entry.parentPayloadBits ?? 'unknown');
    increment(recordIndexCounts, entry.recordIndex ?? 'unknown');
    increment(prefixCounts, entry.prefix3 ?? 'unknown');
  }

  return {
    recordCount: decoded.length,
    inBoundsCount,
    inBoundsRate: roundNumber(decoded.length ? inBoundsCount / decoded.length : 0, 3),
    strictZCount,
    strictZRate: roundNumber(decoded.length ? strictZCount / decoded.length : 0, 3),
    looseZCount,
    looseZRate: roundNumber(decoded.length ? looseZCount / decoded.length : 0, 3),
    id5Counts: topCounts(idCounts, 8),
    parentPayloadBits: topCounts(parentPayloadCounts, 8),
    recordIndexCounts: topCounts(recordIndexCounts, 8),
    prefix3Counts: topCounts(prefixCounts, 8),
  };
}

function compactFocusedGroupSummary(group) {
  return {
    scope: group.scope,
    key: group.key,
    count: group.count,
    firstTimeMs: group.firstTimeMs,
    lastTimeMs: group.lastTimeMs,
    uniquePositionCount: group.uniquePositionCount,
    inBoundsRate: group.inBoundsRate,
    strictZRate: group.strictZRate,
    looseZRate: group.looseZRate,
    sameTimeConflictCount: group.sameTimeConflictCount,
    shortConsecutivePairCount: group.continuity.shortConsecutivePairCount,
    shortP90Speed2d: group.continuity.shortDtSpeed2dPerSecond?.p90 ?? null,
    impossibleShortSpeedCount: group.continuity.impossibleShortSpeedCount,
    impossibleShort3dSpeedCount: group.continuity.impossibleShort3dSpeedCount,
    rejectionReasons: group.strictLaneHeuristic.rejectionReasons,
    sample: group.samples[0] ?? null,
  };
}

function summarizeFocusedPacked80StrideOffsetScan(payloads) {
  const offsetSummaries = [];
  for (let strideOffset = 0; strideOffset < 80; strideOffset += 1) {
    const records = recordsFromPayloadsAtStrideOffset(payloads, strideOffset);
    if (records.length < 20) continue;
    const decoded = records.map(decodeFocusedPacked80Record);
    const byId5 = summarizeFocusedPacked80Groups(
      decoded,
      'id5',
      (entry) => String(entry.id5),
      4,
      12,
    );
    const byRecordIndex = summarizeFocusedPacked80Groups(
      decoded,
      'recordIndex',
      (entry) => String(entry.recordIndex ?? 'unknown'),
      4,
      12,
    );
    const byPrefix3 = summarizeFocusedPacked80Groups(
      decoded,
      'prefix3',
      (entry) => entry.prefix3 ?? 'unknown',
      4,
      12,
    );
    const strictLaneCandidates = [...byId5, ...byRecordIndex, ...byPrefix3]
      .filter((entry) => entry.strictLaneHeuristic.passes)
      .map(compactFocusedGroupSummary);
    const payloadKeys = new Set(records.map((record) => `${record.timeMs}:${record.parentPayloadBits}`));
    const exactFitPayloadKeys = new Set(
      records
        .filter((record) => record.parentTrailingBits === 0)
        .map((record) => `${record.timeMs}:${record.parentPayloadBits}`),
    );

    offsetSummaries.push({
      strideOffset,
      payloadCount: payloadKeys.size,
      exactFitPayloadCount: exactFitPayloadKeys.size,
      aggregate: summarizeFocusedDecodedAggregate(decoded),
      strictLaneCandidateCount: strictLaneCandidates.length,
      strictLaneCandidates: strictLaneCandidates.slice(0, 8),
      topRejectedGroups: [...byRecordIndex, ...byPrefix3, ...byId5]
        .filter((entry) => !entry.strictLaneHeuristic.passes)
        .sort((a, b) => {
          if (b.strictZRate !== a.strictZRate) return b.strictZRate - a.strictZRate;
          return b.count - a.count;
        })
        .slice(0, 8)
        .map(compactFocusedGroupSummary),
    });
  }

  return {
    status:
      'Focused 80-bit stride scan over target RPC payload samples. A shifted offset is only interesting if it produces strict lane candidates, not just stable prefixes.',
    evaluatedOffsetCount: offsetSummaries.length,
    topOffsets: offsetSummaries
      .sort((a, b) => {
        if (b.strictLaneCandidateCount !== a.strictLaneCandidateCount) {
          return b.strictLaneCandidateCount - a.strictLaneCandidateCount;
        }
        if (b.aggregate.strictZRate !== a.aggregate.strictZRate) {
          return b.aggregate.strictZRate - a.aggregate.strictZRate;
        }
        if (b.aggregate.looseZRate !== a.aggregate.looseZRate) {
          return b.aggregate.looseZRate - a.aggregate.looseZRate;
        }
        return b.aggregate.recordCount - a.aggregate.recordCount;
      })
      .slice(0, 16),
    offsetZero: offsetSummaries.find((entry) => entry.strideOffset === 0) ?? null,
  };
}

function evaluatePairLayout(records, options) {
  const { xOffset, yOffset, bitCount, scale, label } = options;
  const decoded = [];
  const uniqueX = new Set();
  const uniqueY = new Set();
  const uniquePairs = new Set();
  const groupSamples = new Map();
  const absMaxValues = [];
  const xValues = [];
  const yValues = [];
  let inBoundsCount = 0;
  let nearOriginCount = 0;
  let realMagnitudeCount = 0;

  for (const record of records) {
    const x = readBitsSigned(record.buffer, xOffset, bitCount) / scale;
    const y = readBitsSigned(record.buffer, yOffset, bitCount) / scale;
    const inBounds = isPlausibleAscentXY(x, y);
    const absMax = Math.max(Math.abs(x), Math.abs(y));
    const roundedX = Math.round(x * 10) / 10;
    const roundedY = Math.round(y * 10) / 10;
    uniqueX.add(roundedX);
    uniqueY.add(roundedY);
    uniquePairs.add(`${roundedX}:${roundedY}`);
    xValues.push(x);
    yValues.push(y);
    absMaxValues.push(absMax);
    if (inBounds) inBoundsCount += 1;
    if (absMax < 250) nearOriginCount += 1;
    if (absMax >= 500) realMagnitudeCount += 1;

    const groupKey = record.prefix3 ?? String(record.firstIntPacked ?? 'unknown');
    if (!groupSamples.has(groupKey)) groupSamples.set(groupKey, []);
    groupSamples.get(groupKey).push({ ...record, x, y, inBounds });

    if (decoded.length < 24) {
      decoded.push({
        timeMs: record.timeMs,
        parentPayloadBits: record.parentPayloadBits ?? null,
        recordIndex: record.recordIndex,
        prefix3: record.prefix3,
        x: Number(x.toFixed(2)),
        y: Number(y.toFixed(2)),
        inBounds,
      });
    }
  }

  const stepDistances = [];
  const speeds = [];
  for (const samples of groupSamples.values()) {
    samples.sort((a, b) => a.timeMs - b.timeMs || a.recordIndex - b.recordIndex);
    let previous = null;
    for (const sample of samples) {
      if (!sample.inBounds) continue;
      if (previous && sample.timeMs > previous.timeMs) {
        const distance = Math.hypot(sample.x - previous.x, sample.y - previous.y);
        const dtSeconds = (sample.timeMs - previous.timeMs) / 1000;
        stepDistances.push(distance);
        speeds.push(distance / dtSeconds);
      }
      previous = sample;
    }
  }

  stepDistances.sort((a, b) => a - b);
  speeds.sort((a, b) => a - b);
  absMaxValues.sort((a, b) => a - b);
  xValues.sort((a, b) => a - b);
  yValues.sort((a, b) => a - b);
  const inBoundsRate = records.length ? inBoundsCount / records.length : 0;
  const nearOriginRate = records.length ? nearOriginCount / records.length : 0;
  const realMagnitudeRate = records.length ? realMagnitudeCount / records.length : 0;
  const overlapsLikelyIdPrefix =
    overlapsRange(xOffset, bitCount, 0, 24) || overlapsRange(yOffset, bitCount, 0, 24);
  const uniquePairRate = records.length ? uniquePairs.size / records.length : 0;
  const medianSpeed = percentile(speeds, 0.5);
  const p90Speed = percentile(speeds, 0.9);
  const medianAbsMax = percentile(absMaxValues, 0.5);
  const xSpan = xValues.length ? xValues.at(-1) - xValues[0] : 0;
  const ySpan = yValues.length ? yValues.at(-1) - yValues[0] : 0;
  const staticAxisCount = [xSpan, ySpan].filter((span) => span < 25).length;
  const score =
    inBoundsCount * 1000 +
    inBoundsRate * 500 +
    realMagnitudeCount * 120 +
    realMagnitudeRate * 750 +
    Math.min(uniquePairs.size, 40) * 25 +
    uniquePairRate * 250 -
    nearOriginRate * 3000 -
    (medianAbsMax != null && medianAbsMax < 400 ? 2000 : 0) -
    (overlapsLikelyIdPrefix ? 4000 : 0) -
    staticAxisCount * 3000 -
    (medianSpeed != null && medianSpeed > 900 ? Math.min(5000, medianSpeed - 900) : 0) -
    (p90Speed != null && p90Speed > 5000 ? Math.min(5000, (p90Speed - 5000) / 2) : 0);

  return {
    label,
    bitCount,
    scale,
    xOffset,
    yOffset,
    contiguous: yOffset === xOffset + bitCount,
    overlapsLikelyIdPrefix,
    recordCount: records.length,
    inBoundsCount,
    inBoundsRate: Number(inBoundsRate.toFixed(3)),
    realMagnitudeCount,
    realMagnitudeRate: Number(realMagnitudeRate.toFixed(3)),
    nearOriginCount,
    nearOriginRate: Number(nearOriginRate.toFixed(3)),
    medianAbsMax: medianAbsMax == null ? null : Number(medianAbsMax.toFixed(2)),
    xSpan: Number(xSpan.toFixed(2)),
    ySpan: Number(ySpan.toFixed(2)),
    staticAxisCount,
    uniqueXCount: uniqueX.size,
    uniqueYCount: uniqueY.size,
    uniquePairCount: uniquePairs.size,
    medianStepDistance: percentile(stepDistances, 0.5)?.toFixed(2) ?? null,
    p90StepDistance: percentile(stepDistances, 0.9)?.toFixed(2) ?? null,
    medianSpeed: medianSpeed == null ? null : Number(medianSpeed.toFixed(2)),
    p90Speed: p90Speed == null ? null : Number(p90Speed.toFixed(2)),
    score: Number(score.toFixed(2)),
    samples: decoded,
  };
}

function isStrictMovementPairCandidate(candidate) {
  const p90Speed = candidate.p90Speed ?? Number.POSITIVE_INFINITY;
  return (
    !candidate.overlapsLikelyIdPrefix &&
    candidate.inBoundsRate >= 0.9 &&
    candidate.realMagnitudeRate >= 0.6 &&
    candidate.nearOriginRate <= 0.1 &&
    candidate.staticAxisCount === 0 &&
    candidate.uniqueXCount >= 3 &&
    candidate.uniqueYCount >= 3 &&
    candidate.uniquePairCount >= Math.max(3, Math.ceil(candidate.recordCount * 0.25)) &&
    p90Speed <= 1500
  );
}

function strictMovementPairCandidates(candidates, limit = 24) {
  return candidates
    .filter(isStrictMovementPairCandidate)
    .sort((a, b) => {
      const aP90 = a.p90Speed ?? Number.POSITIVE_INFINITY;
      const bP90 = b.p90Speed ?? Number.POSITIVE_INFINITY;
      if (aP90 !== bP90) return aP90 - bP90;
      return b.score - a.score;
    })
    .slice(0, limit);
}

function scanFixedPairLayouts(records, label) {
  if (!records.length) return [];
  const candidates = new Map();
  const addCandidate = (candidate) => {
    const key = [candidate.bitCount, candidate.scale, candidate.xOffset, candidate.yOffset].join('|');
    if (!candidates.has(key)) candidates.set(key, evaluatePairLayout(records, { ...candidate, label }));
  };

  for (const bitCount of [12, 13, 14, 15, 16, 17, 18, 19, 20]) {
    for (const scale of [1, 10, 100]) {
      for (let xOffset = 0; xOffset + bitCount * 2 <= 80; xOffset += 1) {
        addCandidate({ bitCount, scale, xOffset, yOffset: xOffset + bitCount });
      }
    }
  }

  for (const bitCount of [14, 16, 18, 20]) {
    for (const scale of [1, 10]) {
      for (let xOffset = 0; xOffset + bitCount <= 80; xOffset += 8) {
        for (let yOffset = 0; yOffset + bitCount <= 80; yOffset += 8) {
          if (xOffset === yOffset) continue;
          addCandidate({ bitCount, scale, xOffset, yOffset });
        }
      }
    }
  }

  return [...candidates.values()]
    .filter(
      (candidate) =>
        candidate.inBoundsCount >= Math.max(3, Math.floor(records.length * 0.15)) &&
        candidate.realMagnitudeCount >= Math.max(3, Math.floor(records.length * 0.15)),
    )
    .sort((a, b) => b.score - a.score || b.inBoundsCount - a.inBoundsCount)
    .slice(0, 40);
}

function scanPrefixPairLayouts(records, label, perPrefixLimit = 8, totalLimit = 80) {
  const groups = new Map();
  for (const record of records) {
    if (!groups.has(record.prefix3)) groups.set(record.prefix3, []);
    groups.get(record.prefix3).push(record);
  }

  return [...groups.entries()]
    .filter(([, entries]) => entries.length >= 3)
    .flatMap(([prefix3, entries]) =>
      scanFixedPairLayouts(entries, `${label}:${prefix3}`)
        .slice(0, perPrefixLimit)
        .map((candidate) => ({
          ...candidate,
          prefix3,
          prefixRecordCount: entries.length,
          firstTimeMs: Math.min(...entries.map((entry) => entry.timeMs)),
          lastTimeMs: Math.max(...entries.map((entry) => entry.timeMs)),
        })),
    )
    .sort((a, b) => {
      const aP90 = a.p90Speed ?? Number.POSITIVE_INFINITY;
      const bP90 = b.p90Speed ?? Number.POSITIVE_INFINITY;
      if (a.overlapsLikelyIdPrefix !== b.overlapsLikelyIdPrefix) {
        return a.overlapsLikelyIdPrefix ? 1 : -1;
      }
      if (b.realMagnitudeRate !== a.realMagnitudeRate) return b.realMagnitudeRate - a.realMagnitudeRate;
      if (aP90 !== bP90) return aP90 - bP90;
      return b.score - a.score;
    })
    .slice(0, totalLimit);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_native_records.mjs --diagnostics replay.diagnostics.json --out native_records.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const records = parseRecords(diagnostics);
  const payloads = parsePayloadSamples(diagnostics);
  const knownPlayerGuids = knownPlayerGuidsFromDiagnostics(diagnostics);
  const singleRecord80 = records.filter((record) => record.parentPayloadBits === 80);
  const bulkRecords = records.filter(
    (record) => record.parentPayloadBits != null && record.parentPayloadBits !== 80,
  );
  const fixedPairLayoutCandidates = {
    allRecords: scanFixedPairLayouts(records, 'all-records'),
    singleRecord80: scanFixedPairLayouts(singleRecord80, 'single-80-bit-record-payloads'),
    bulkRecords: scanFixedPairLayouts(bulkRecords, 'bulk-payload-records'),
    singleRecord80ByPrefix: scanPrefixPairLayouts(
      singleRecord80,
      'single-80-bit-record-payloads-by-prefix',
    ),
    bulkRecordsByPrefix: scanPrefixPairLayouts(
      bulkRecords,
      'bulk-payload-records-by-prefix',
      4,
      80,
    ),
  };

  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
    },
    notes: [
      'This analyzer treats replay-controller target payloads as native 80-bit record candidates and scores possible fixed-width numeric layouts.',
      'A high fixed-layout score is a lead, not a confirmed decoder; layouts overlapping the first 24 bits likely read record identity bits as coordinates.',
      'candidatePacked80Layout is a focused test of the strongest broad lead, but it is still rejected unless lane grouping, z-range, and short-dt continuity all pass.',
      'IntPacked sequence summaries are included because the first byte of many records cleanly decodes as a small Unreal-style packed integer.',
    ],
    source: {
      rawPacketsScanned: diagnostics.frameSummary?.rawPacketsScanned ?? null,
      movementRpcHitCount: diagnostics.frameSummary?.movementRpcHitCount ?? null,
      targetPayloadStride: summarizePayloadStride(diagnostics),
    },
    recordCount: records.length,
    singleRecord80Count: singleRecord80.length,
    bulkRecordCount: bulkRecords.length,
    payloadSampleCount: payloads.length,
    payloadFamilySummary: summarizePayloadFamilies(payloads),
    candidateFieldSummary: summarizeCandidateFields(diagnostics, knownPlayerGuids),
    prefixSummary: summarizePrefixes(records),
    targetKnownGuidScan: summarizeTargetKnownGuidHits(payloads, records, knownPlayerGuids),
    strongKnownGuidRecurrences: summarizeStrongGuidRecurrences(payloads, records, knownPlayerGuids),
    laneBitStabilitySummary: summarizeLaneBitStability(records),
    strideOffsetSummary: {
      allPayloads: summarizeStrideOffsets(payloads, 'all-payloads'),
      bulkPayloads: summarizeStrideOffsets(
        payloads,
        'bulk-payloads',
        (payload) => payload.bitCount > 80,
      ),
      repeated1498Payloads: summarizeStrideOffsets(
        payloads,
        'repeated-1498-bit-payloads',
        (payload) => payload.bitCount === 1498,
      ),
    },
    intPackedSummary: summarizeIntPacked(records),
    candidatePacked80Layout: summarizeFocusedPacked80Layout(records, payloads, diagnostics),
    fixedPairLayoutCandidates,
    strictMovementPairCandidates: {
      status:
        'Strict candidates require both axes to vary, plausible map bounds, non-origin magnitude, no identity-prefix overlap, and p90 speed <= 1500 units/sec.',
      allRecords: strictMovementPairCandidates(fixedPairLayoutCandidates.allRecords),
      singleRecord80: strictMovementPairCandidates(fixedPairLayoutCandidates.singleRecord80),
      bulkRecords: strictMovementPairCandidates(fixedPairLayoutCandidates.bulkRecords),
      singleRecord80ByPrefix: strictMovementPairCandidates(
        fixedPairLayoutCandidates.singleRecord80ByPrefix,
      ),
      bulkRecordsByPrefix: strictMovementPairCandidates(
        fixedPairLayoutCandidates.bulkRecordsByPrefix,
      ),
    },
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
}

main();
