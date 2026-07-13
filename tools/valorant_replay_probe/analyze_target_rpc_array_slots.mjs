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

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    out: null,
    slotCount: 10,
    minLargeBits: 512,
    minIdentityHits: 2,
    maxIdentityHits: 80,
    maxVectorCandidates: 80,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--slot-count') options.slotCount = Number(argv[++index]);
    else if (arg === '--min-large-bits') options.minLargeBits = Number(argv[++index]);
    else if (arg === '--min-identity-hits') options.minIdentityHits = Number(argv[++index]);
    else if (arg === '--max-identity-hits') options.maxIdentityHits = Number(argv[++index]);
    else if (arg === '--max-vector-candidates') options.maxVectorCandidates = Number(argv[++index]);
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
    if (componentBits < 7 || componentBits > 24 || !this.canRead(componentBits * 3)) {
      return null;
    }
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
      endBitOffset: this.offset,
    };
    return this.isError ? null : vector;
  }
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
    .sort((a, b) => a.chIndex - b.chIndex || a.netGuid - b.netGuid);
}

function buildReferenceValues(players) {
  const refs = [];
  const add = (player, label, value) => {
    if (!Number.isInteger(value) || value < 0) return;
    refs.push({
      playerNetGuid: player.netGuid,
      chIndex: player.chIndex,
      archetypePath: player.archetypePath,
      label,
      value,
    });
  };

  for (const player of players) {
    add(player, 'netGuid', player.netGuid);
    add(player, 'netGuid-1', player.netGuid - 1);
    add(player, 'netGuid+1', player.netGuid + 1);
    add(player, 'netGuid>>1', player.netGuid / 2);
    add(player, 'netGuid<<1', player.netGuid * 2);
    add(player, 'netGuid<<1|1', player.netGuid * 2 + 1);
    add(player, 'netGuid&0x7f', player.netGuid & 0x7f);
    add(player, 'chIndex', player.chIndex);
    add(player, 'chIndex-1', player.chIndex - 1);
    add(player, 'chIndex+1', player.chIndex + 1);
    add(player, 'chIndex>>1', player.chIndex / 2);
    add(player, 'chIndex<<1', player.chIndex * 2);
    add(player, 'chIndex<<1|1', player.chIndex * 2 + 1);
    add(player, 'chIndex&0x7f', player.chIndex & 0x7f);
  }

  return refs.filter((ref) => Number.isInteger(ref.value));
}

function splitIntoSlots(sample, slotCount) {
  const headerBits = sample.bitCount % slotCount;
  const recordBits = (sample.bitCount - headerBits) / slotCount;
  if (!Number.isInteger(recordBits) || recordBits <= 0) return null;
  return {
    sample,
    slotCount,
    headerBits,
    headerValue: headerBits > 0 ? readBitsUnsigned(sample.buffer, 0, headerBits) : 0,
    recordBits,
    slots: Array.from({ length: slotCount }, (_, slotIndex) => ({
      slotIndex,
      startBit: headerBits + slotIndex * recordBits,
      endBit: headerBits + (slotIndex + 1) * recordBits,
      bitCount: recordBits,
    })),
  };
}

function summarizeVariableRanges(records) {
  if (!records.length) return null;
  const bitCount = records[0].bitCount;
  const oneCounts = Array.from({ length: bitCount }, () => 0);
  for (const record of records) {
    for (let bit = 0; bit < bitCount; bit += 1) {
      if (readBit(record.sample.buffer, record.startBit + bit)) oneCounts[bit] += 1;
    }
  }
  const stableBits = oneCounts.map((count) => count === 0 || count === records.length);
  return {
    stableBitCount: stableBits.filter(Boolean).length,
    variableBitCount: stableBits.filter((stable) => !stable).length,
    stableRanges: stableRanges(stableBits).slice(0, 20),
    variableRanges: stableRanges(stableBits.map((stable) => !stable)).slice(0, 20),
  };
}

function summarizeSlotFraming(slotPayloads, slotCount) {
  const byBitCount = new Map();
  for (const split of slotPayloads) {
    if (!byBitCount.has(split.sample.bitCount)) byBitCount.set(split.sample.bitCount, []);
    byBitCount.get(split.sample.bitCount).push(split);
  }

  return [...byBitCount.entries()]
    .map(([bitCount, entries]) => {
      const headerValues = entries.map((entry) => entry.headerValue);
      const perSlot = [];
      for (let slotIndex = 0; slotIndex < slotCount; slotIndex += 1) {
        const records = entries.map((entry) => ({
          ...entry.slots[slotIndex],
          sample: entry.sample,
        }));
        perSlot.push({
          slotIndex,
          recordBits: records[0]?.bitCount ?? null,
          topPrefixes24: topCounts(
            records.map((record) =>
              bitsToHex(record.sample.buffer, record.startBit, Math.min(24, record.bitCount)),
            ),
            8,
          ),
          ...summarizeVariableRanges(records),
          samples: records.slice(0, 4).map((record) => ({
            timeMs: record.sample.timeMs,
            prefixHex: bitsToHex(record.sample.buffer, record.startBit, Math.min(64, record.bitCount)),
          })),
        });
      }

      return {
        bitCount,
        count: entries.length,
        firstTimeMs: Math.min(...entries.map((entry) => entry.sample.timeMs)),
        lastTimeMs: Math.max(...entries.map((entry) => entry.sample.timeMs)),
        headerBits: entries[0]?.headerBits ?? null,
        recordBits: entries[0]?.recordBits ?? null,
        recordCount: slotCount,
        topHeaderValues: topCounts(headerValues, 12),
        sampleRows: entries.slice(0, 12).map((entry) => ({
          timeMs: entry.sample.timeMs,
          headerValue: entry.headerValue,
          firstSlotPrefixHex: bitsToHex(
            entry.sample.buffer,
            entry.slots[0].startBit,
            Math.min(64, entry.recordBits),
          ),
          lastSlotPrefixHex: bitsToHex(
            entry.sample.buffer,
            entry.slots.at(-1).startBit,
            Math.min(64, entry.recordBits),
          ),
        })),
        slots: perSlot,
      };
    })
    .sort((a, b) => b.count - a.count || a.bitCount - b.bitCount);
}

function compareSlotModels(largeTargetSamples, { minSamples = 3, maxSlotCount = 16 } = {}) {
  const byBitCount = new Map();
  for (const sample of largeTargetSamples) {
    if (!byBitCount.has(sample.bitCount)) byBitCount.set(sample.bitCount, []);
    byBitCount.get(sample.bitCount).push(sample);
  }

  const comparisons = [];
  for (const [bitCount, samples] of byBitCount.entries()) {
    if (samples.length < minSamples) continue;
    const candidates = [];
    for (let slotCount = 2; slotCount <= maxSlotCount; slotCount += 1) {
      const headerBits = bitCount % slotCount;
      const recordBits = (bitCount - headerBits) / slotCount;
      if (!Number.isInteger(recordBits) || recordBits < 32) continue;

      let stablePrefixSlotCount = 0;
      let totalUniquePrefixCount = 0;
      let totalMajorityPrefixCount = 0;
      const slotSummaries = [];
      for (let slotIndex = 0; slotIndex < slotCount; slotIndex += 1) {
        const startBit = headerBits + slotIndex * recordBits;
        const prefixes = samples.map((sample) =>
          bitsToHex(sample.buffer, startBit, Math.min(24, recordBits)),
        );
        const prefixCounts = topCounts(prefixes, 4);
        const uniquePrefixCount = new Set(prefixes).size;
        const majorityPrefixCount = prefixCounts[0]?.count ?? 0;
        if (uniquePrefixCount === 1) stablePrefixSlotCount += 1;
        totalUniquePrefixCount += uniquePrefixCount;
        totalMajorityPrefixCount += majorityPrefixCount;
        slotSummaries.push({
          slotIndex,
          uniquePrefixCount,
          majorityPrefixCount,
          topPrefixes24: prefixCounts,
        });
      }

      candidates.push({
        slotCount,
        headerBits,
        recordBits,
        stablePrefixSlotCount,
        averageUniquePrefixCount: round(totalUniquePrefixCount / slotCount, 3),
        averageMajorityPrefixCount: round(totalMajorityPrefixCount / slotCount, 3),
        slotSummaries,
      });
    }
    comparisons.push({
      bitCount,
      sampleCount: samples.length,
      firstTimeMs: Math.min(...samples.map((sample) => sample.timeMs)),
      lastTimeMs: Math.max(...samples.map((sample) => sample.timeMs)),
      candidates: candidates.sort(
        (a, b) =>
          b.stablePrefixSlotCount - a.stablePrefixSlotCount ||
          a.averageUniquePrefixCount - b.averageUniquePrefixCount ||
          b.averageMajorityPrefixCount - a.averageMajorityPrefixCount ||
          a.slotCount - b.slotCount,
      ),
    });
  }

  return comparisons.sort((a, b) => b.sampleCount - a.sampleCount || a.bitCount - b.bitCount);
}

function isExactIdentityLabel(label) {
  return label === 'netGuid' || label === 'chIndex' || label === 'chIndex&0x7f';
}

function summarizeSameSlotIdentityHits(recurringHits, players) {
  const sameSlotIdentityHits = recurringHits.filter((hit) => {
    const player = players[hit.slotIndex];
    if (!player) return false;
    return hit.playerNetGuid === player.netGuid || hit.chIndex === player.chIndex;
  });
  const exactSameSlotIdentityHits = sameSlotIdentityHits.filter((hit) =>
    isExactIdentityLabel(hit.label),
  );
  const perSlot = players.map((player, slotIndex) => {
    const slotHits = sameSlotIdentityHits.filter((hit) => hit.slotIndex === slotIndex);
    const exactHits = exactSameSlotIdentityHits.filter((hit) => hit.slotIndex === slotIndex);
    return {
      slotIndex,
      player: {
        netGuid: player.netGuid,
        chIndex: player.chIndex,
        archetypePath: player.archetypePath,
      },
      sameSlotHitCount: slotHits.length,
      exactSameSlotHitCount: exactHits.length,
      topExactHits: exactHits.slice(0, 8),
      topHits: slotHits.slice(0, 8),
    };
  });
  return {
    note:
      'Same-slot identity hits are layout clues. Narrow uint/intPacked encodings can be collisions and are not final authoritative actor attribution by themselves.',
    sameSlotIdentityHitCount: sameSlotIdentityHits.length,
    exactSameSlotIdentityHitCount: exactSameSlotIdentityHits.length,
    exactSameSlotIdentityHits: exactSameSlotIdentityHits.slice(0, 40),
    sameSlotIdentityHits: sameSlotIdentityHits.slice(0, 80),
    perSlot,
  };
}

function scanIdentity(slotPayloads, refs, players, options) {
  const refsByValue = new Map();
  for (const ref of refs) {
    if (!refsByValue.has(ref.value)) refsByValue.set(ref.value, []);
    refsByValue.get(ref.value).push(ref);
  }

  const hits = new Map();
  const recordHit = (encoding, ref, split, slot, relativeOffset, bitCount) => {
    const key = [
      encoding,
      ref.label,
      ref.value,
      ref.playerNetGuid,
      slot.slotIndex,
      relativeOffset,
      bitCount,
    ].join('|');
    if (!hits.has(key)) {
      hits.set(key, {
        encoding,
        label: ref.label,
        value: ref.value,
        playerNetGuid: ref.playerNetGuid,
        chIndex: ref.chIndex,
        archetypePath: ref.archetypePath,
        slotIndex: slot.slotIndex,
        relativeOffset,
        bitCount,
        count: 0,
        timeSet: new Set(),
        payloadBitCounts: new Map(),
        recordBitCounts: new Map(),
        samples: [],
      });
    }
    const hit = hits.get(key);
    hit.count += 1;
    hit.timeSet.add(split.sample.timeMs);
    increment(hit.payloadBitCounts, split.sample.bitCount);
    increment(hit.recordBitCounts, slot.bitCount);
    if (hit.samples.length < 6) {
      hit.samples.push({
        timeMs: split.sample.timeMs,
        payloadBits: split.sample.bitCount,
        slotIndex: slot.slotIndex,
        recordBits: slot.bitCount,
        relativeOffset,
        recordPrefixHex: bitsToHex(
          split.sample.buffer,
          slot.startBit,
          Math.min(64, slot.bitCount),
        ),
      });
    }
  };

  const encodings = [
    { name: 'uint10', kind: 'uint', bitCount: 10 },
    { name: 'uint12', kind: 'uint', bitCount: 12 },
    { name: 'uint16', kind: 'uint', bitCount: 16 },
    { name: 'uint32', kind: 'uint', bitCount: 32 },
    { name: 'intPacked', kind: 'packed' },
  ];

  for (const split of slotPayloads) {
    for (const slot of split.slots) {
      for (let relativeOffset = 0; relativeOffset < slot.bitCount; relativeOffset += 1) {
        const absoluteOffset = slot.startBit + relativeOffset;
        for (const encoding of encodings) {
          if (encoding.kind === 'packed') {
            const packed = readIntPacked(split.sample.buffer, absoluteOffset, slot.endBit);
            if (!packed.ok) continue;
            for (const ref of refsByValue.get(packed.value) ?? []) {
              recordHit(encoding.name, ref, split, slot, relativeOffset, packed.bitCount);
            }
            continue;
          }
          if (absoluteOffset + encoding.bitCount > slot.endBit) continue;
          const value = readBitsUnsigned(split.sample.buffer, absoluteOffset, encoding.bitCount);
          for (const ref of refsByValue.get(value) ?? []) {
            recordHit(encoding.name, ref, split, slot, relativeOffset, encoding.bitCount);
          }
        }
      }
    }
  }

  const recurringHits = [...hits.values()]
    .filter((hit) => hit.count >= options.minIdentityHits)
    .map((hit) => ({
      encoding: hit.encoding,
      label: hit.label,
      value: hit.value,
      playerNetGuid: hit.playerNetGuid,
      chIndex: hit.chIndex,
      archetypePath: hit.archetypePath,
      slotIndex: hit.slotIndex,
      relativeOffset: hit.relativeOffset,
      bitCount: hit.bitCount,
      count: hit.count,
      uniqueTimeCount: hit.timeSet.size,
      payloadBitCounts: topCounts(hit.payloadBitCounts, 8),
      recordBitCounts: topCounts(hit.recordBitCounts, 8),
      samples: hit.samples,
    }))
    .sort(
      (a, b) =>
        b.count - a.count ||
        b.uniqueTimeCount - a.uniqueTimeCount ||
        a.slotIndex - b.slotIndex ||
        a.relativeOffset - b.relativeOffset,
    )
    .slice(0, options.maxIdentityHits);

  const authoritativeActorNetGuidHits = recurringHits.filter(
    (hit) => hit.label === 'netGuid' && (hit.encoding === 'uint32' || hit.bitCount >= 16),
  );
  const sameSlotIdentitySummary = summarizeSameSlotIdentityHits(recurringHits, players);
  return {
    status:
      authoritativeActorNetGuidHits.length > 0
        ? 'possible authoritative actor NetGUID hits found inside target slots'
        : sameSlotIdentitySummary.exactSameSlotIdentityHitCount > 0
          ? 'exact same-slot narrow identity clues found, but no authoritative actor NetGUID layout'
        : 'no authoritative actor NetGUID hit was found inside target slots; narrow/channel-shaped hits remain collision-level',
    recurringHitCount: recurringHits.length,
    authoritativeActorNetGuidHitCount: authoritativeActorNetGuidHits.length,
    authoritativeActorNetGuidHits: authoritativeActorNetGuidHits.slice(0, 20),
    sameSlotIdentitySummary,
    recurringHits,
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
    point.z <= ASCENT_TRANSFORM.maxZ &&
    Math.max(Math.abs(point.x), Math.abs(point.y)) > 50
  );
}

function summarizeVectorRows(rows) {
  const ordered = [...rows].sort((a, b) => a.timeMs - b.timeMs);
  const xs = ordered.map((row) => row.x);
  const ys = ordered.map((row) => row.y);
  const zs = ordered.map((row) => row.z);
  const uniquePositions = new Set(
    ordered.map((row) => `${Math.round(row.x)}:${Math.round(row.y)}:${Math.round(row.z)}`),
  );
  const speeds = [];
  const steps = [];
  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtSeconds = (current.timeMs - previous.timeMs) / 1000;
    if (dtSeconds <= 0) continue;
    const distance = Math.hypot(current.x - previous.x, current.y - previous.y);
    steps.push(distance);
    speeds.push(distance / dtSeconds);
  }
  const xSpan = xs.length ? Math.max(...xs) - Math.min(...xs) : 0;
  const ySpan = ys.length ? Math.max(...ys) - Math.min(...ys) : 0;
  const zSpan = zs.length ? Math.max(...zs) - Math.min(...zs) : 0;
  return {
    count: ordered.length,
    firstTimeMs: ordered[0]?.timeMs ?? null,
    lastTimeMs: ordered.at(-1)?.timeMs ?? null,
    uniquePositionCount: uniquePositions.size,
    inAscentBoundsRate: ordered.length
      ? round(ordered.filter(isPlausibleAscentPoint).length / ordered.length, 3)
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
    xSpan: round(xSpan, 2),
    ySpan: round(ySpan, 2),
    zSpan: round(zSpan, 2),
    xySpan: round(Math.hypot(xSpan, ySpan), 2),
    staticAxisCount: [xSpan, ySpan, zSpan].filter((span) => span < 25).length,
    p90StepDistance: round(percentile(steps, 0.9), 2),
    p90Speed: round(percentile(speeds, 0.9), 1),
    maxSpeed: round(speeds.length ? Math.max(...speeds) : null, 1),
    samples: ordered.slice(0, 8).map((row) => ({
      timeMs: row.timeMs,
      x: round(row.x, 2),
      y: round(row.y, 2),
      z: round(row.z, 2),
      payloadBits: row.payloadBits,
      recordBits: row.recordBits,
    })),
  };
}

function vectorRejectionReasons(candidate) {
  const summary = candidate.summary;
  const reasons = [];
  if (summary.count < 8) reasons.push('too-few-samples');
  if (summary.uniquePositionCount < 5) reasons.push('too-few-unique-positions');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-or-z-bounds');
  if (summary.xySpan < 50) reasons.push('low-xy-span');
  if (summary.staticAxisCount > 1) reasons.push('static-axes');
  if (summary.p90Speed == null || summary.p90Speed > 5_000) {
    reasons.push('high-or-missing-p90-speed');
  }
  return reasons;
}

function scanPackedVectorSlots(slotPayloads, options) {
  const groups = new Map();
  const scaleFactors = [1, 10, 100, 1000];
  for (const split of slotPayloads) {
    for (const slot of split.slots) {
      for (
        let relativeOffset = 0;
        relativeOffset <= Math.max(0, slot.bitCount - 28);
        relativeOffset += 1
      ) {
        const absoluteOffset = slot.startBit + relativeOffset;
        for (const scaleFactor of scaleFactors) {
          const reader = new BitCursor(split.sample.buffer, slot.endBit, absoluteOffset);
          const vector = reader.readPackedVector(scaleFactor);
          if (!vector || reader.isError) continue;
          if (vector.extraInfo === 0 && scaleFactor !== 1) continue;
          const normalizedScaleFactor = vector.extraInfo ? scaleFactor : 1;
          const key = [
            split.sample.bitCount,
            split.recordBits,
            slot.slotIndex,
            relativeOffset,
            normalizedScaleFactor,
            vector.componentBits,
            vector.extraInfo,
          ].join('|');
          if (!groups.has(key)) {
            groups.set(key, {
              payloadBits: split.sample.bitCount,
              recordBits: split.recordBits,
              slotIndex: slot.slotIndex,
              relativeOffset,
              scaleFactor: normalizedScaleFactor,
              componentBits: vector.componentBits,
              extraInfo: vector.extraInfo,
              rows: [],
            });
          }
          groups.get(key).rows.push({
            timeMs: split.sample.timeMs,
            x: vector.x,
            y: vector.y,
            z: vector.z,
            payloadBits: split.sample.bitCount,
            recordBits: split.recordBits,
          });
        }
      }
    }
  }

  const candidates = [...groups.values()]
    .filter((group) => group.rows.length >= 3)
    .map((group) => {
      const summary = summarizeVectorRows(group.rows);
      return {
        payloadBits: group.payloadBits,
        recordBits: group.recordBits,
        slotIndex: group.slotIndex,
        relativeOffset: group.relativeOffset,
        vectorEncoding: {
          scaleFactor: group.scaleFactor,
          componentBits: group.componentBits,
          extraInfo: group.extraInfo,
        },
        summary,
      };
    })
    .map((candidate) => ({
      ...candidate,
      strictPositionCandidate: vectorRejectionReasons(candidate).length === 0,
      rejectionReasons: vectorRejectionReasons(candidate),
      score:
        candidate.summary.count * 20 +
        candidate.summary.uniquePositionCount * 30 +
        candidate.summary.inAscentBoundsRate * 500 +
        Math.min(candidate.summary.xySpan, 1500) -
        Math.min(candidate.summary.p90Speed ?? 50_000, 50_000) * 0.05 -
        candidate.summary.staticAxisCount * 200,
    }))
    .sort((a, b) => b.score - a.score || b.summary.count - a.summary.count);

  const strictPositionCandidates = candidates.filter((candidate) => candidate.strictPositionCandidate);
  return {
    status:
      strictPositionCandidates.length > 0
        ? 'strict packed-vector target-slot candidates found; still require actor identity before track emission'
        : 'no packed-vector target-slot candidate passed continuity and map gates',
    candidateCount: candidates.length,
    strictPositionCandidateCount: strictPositionCandidates.length,
    strictPositionCandidates: strictPositionCandidates.slice(0, options.maxVectorCandidates),
    bestRejectedCandidates: candidates
      .filter((candidate) => !candidate.strictPositionCandidate)
      .slice(0, options.maxVectorCandidates),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_target_rpc_array_slots.mjs --diagnostics replay.diagnostics.json --out target_rpc_array_slots.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const targetSamples = parseTargetSamples(diagnostics);
  const largeTargetSamples = targetSamples.filter((sample) => sample.bitCount >= options.minLargeBits);
  const slotPayloads = largeTargetSamples
    .map((sample) => splitIntoSlots(sample, options.slotCount))
    .filter(Boolean);
  const players = knownPlayerRefs(diagnostics);
  const refs = buildReferenceValues(players);
  const identityScan = scanIdentity(slotPayloads, refs, players, options);
  const packedVectorSlotScan = scanPackedVectorSlots(slotPayloads, options);
  const allLargePayloadsFitSlotModel =
    largeTargetSamples.length > 0 && slotPayloads.length === largeTargetSamples.length;

  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
    },
    options: {
      slotCount: options.slotCount,
      minLargeBits: options.minLargeBits,
      minIdentityHits: options.minIdentityHits,
      maxIdentityHits: options.maxIdentityHits,
      maxVectorCandidates: options.maxVectorCandidates,
    },
    notes: [
      'This report treats large target-RPC payloads as fixed RemoteCharacterUpdates array candidates.',
      'The 10-slot split is motivated by the 10 known player actors and RemoteCharacterUpdates schema; splitModelComparison reports competing record-count scores so this is not overclaimed.',
      'Identity and packed-vector scans are diagnostic only. Track emission still requires authoritative actor NetGUID attribution plus a strict position/yaw layout.',
    ],
    source: {
      targetSampleCount: targetSamples.length,
      largeTargetSampleCount: largeTargetSamples.length,
      slotPayloadCount: slotPayloads.length,
      allLargePayloadsFitSlotModel,
      playerReferenceCount: players.length,
      players,
      targetPayloadBitCounts: topCounts(targetSamples.map((sample) => sample.bitCount), 30),
      largeTargetSamples: slotPayloads.map((split) => ({
        timeMs: split.sample.timeMs,
        bitCount: split.sample.bitCount,
        headerBits: split.headerBits,
        headerValue: split.headerValue,
        recordBits: split.recordBits,
        slotCount: split.slotCount,
        prefixHex: split.sample.payloadHex.slice(0, 48),
      })),
    },
    status:
      allLargePayloadsFitSlotModel && identityScan.authoritativeActorNetGuidHitCount === 0
        ? identityScan.sameSlotIdentitySummary?.exactSameSlotIdentityHitCount > 0
          ? 'large target-RPC payloads fit ten-slot RemoteCharacterUpdates framing with partial same-slot identity clues, but content is still unresolved'
          : 'large target-RPC payloads fit ten-slot RemoteCharacterUpdates framing, but slot identity/content is still unresolved'
        : allLargePayloadsFitSlotModel
          ? 'large target-RPC payloads fit ten-slot RemoteCharacterUpdates framing; inspect identity/vector candidates'
          : 'large target-RPC payloads did not all fit the ten-slot framing model',
    slotFramingSummary: summarizeSlotFraming(slotPayloads, options.slotCount),
    splitModelComparison: compareSlotModels(largeTargetSamples),
    identityScan,
    packedVectorSlotScan,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  console.error(
    `analyzed ${targetSamples.length} target RPC samples; ${slotPayloads.length}/${largeTargetSamples.length} large payloads fit ${options.slotCount}-slot framing; authoritativeGuidHits=${identityScan.authoritativeActorNetGuidHitCount}; strictVectorCandidates=${packedVectorSlotScan.strictPositionCandidateCount}`,
  );
}

main();
