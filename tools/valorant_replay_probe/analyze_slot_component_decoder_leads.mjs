#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const DEFAULT_VECTOR_OFFSET_LIMIT = 40;
const DEFAULT_IDENTITY_HIT_LIMIT = 32;
const PLAYER_IDENTITY_ENCODINGS = ['intPacked', 'uint8', 'uint10', 'uint12', 'uint16', 'uint32'];
const PACKED_VECTOR_HEADER_BITS = 7;

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    samples: null,
    out: null,
    slotCount: 10,
    minIdentityHits: 3,
    maxIdentityHitRows: DEFAULT_IDENTITY_HIT_LIMIT,
    minVectorOffsetSamples: 8,
    maxVectorOffsets: DEFAULT_VECTOR_OFFSET_LIMIT,
    maxContextRows: 10,
    maxPairSamples: 12,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--samples') options.samples = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--slot-count') options.slotCount = Number(argv[++index]);
    else if (arg === '--min-identity-hits') options.minIdentityHits = Number(argv[++index]);
    else if (arg === '--max-identity-hit-rows') options.maxIdentityHitRows = Number(argv[++index]);
    else if (arg === '--min-vector-offset-samples') {
      options.minVectorOffsetSamples = Number(argv[++index]);
    } else if (arg === '--max-vector-offsets') {
      options.maxVectorOffsets = Number(argv[++index]);
    } else if (arg === '--max-context-rows') {
      options.maxContextRows = Number(argv[++index]);
    } else if (arg === '--max-pair-samples') {
      options.maxPairSamples = Number(argv[++index]);
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

function increment(map, key, amount = 1) {
  map.set(key, (map.get(key) ?? 0) + amount);
}

function topCounts(map, limit = 12) {
  return [...map.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || String(a.key).localeCompare(String(b.key)))
    .slice(0, limit);
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

  readPackedVectorHeader() {
    const start = this.offset;
    const bitsAndInfo = this.readSerializedInt(1 << PACKED_VECTOR_HEADER_BITS);
    if (this.isError) return null;
    return {
      bitsAndInfo,
      componentBits: bitsAndInfo & 63,
      extraInfo: bitsAndInfo >> 6,
      headerBits: this.offset - start,
    };
  }

  readPackedVectorRaw() {
    const header = this.readPackedVectorHeader();
    if (!header) return null;
    const { componentBits } = header;
    if (componentBits < 7 || componentBits > 24) return null;
    if (!this.canRead(componentBits * 3)) return null;
    const vector = {
      ...header,
      xSigned: this.readBitsSigned(componentBits),
      ySigned: this.readBitsSigned(componentBits),
      zSigned: this.readBitsSigned(componentBits),
    };
    return this.isError ? null : vector;
  }
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
    if ((currentByte & 1) === 0) return { ok: true, value, bitCount: offset - bitOffset };
    shift *= 128;
  }
  return { ok: false, value, bitCount: offset - bitOffset };
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

function familyKey(candidate) {
  return [
    candidate.fieldHandle,
    candidate.payloadBitCount,
    candidate.prefixHex,
    candidate.slotIndex,
    candidate.relativeOffset,
    candidate.scaleFactor,
    candidate.componentBits,
    candidate.extraInfo,
    candidate.positionTransform,
  ].join('|');
}

function selectedFamiliesFromSamples(samplesReport) {
  const families = new Map();
  for (const entry of samplesReport.candidates ?? []) {
    const candidate = entry.candidate;
    if (!candidate) continue;
    const key = familyKey(candidate);
    if (!families.has(key)) families.set(key, candidate);
  }
  return [...families.values()];
}

function samplesForFamily(samples, family) {
  return samples.filter(
    (sample) =>
      sample.fieldHandle === family.fieldHandle &&
      sample.bitCount === family.payloadBitCount &&
      bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)) === family.prefixHex,
  );
}

function decodeVectorAt(sample, bitOffset) {
  const reader = new BitCursor(sample.buffer, sample.bitCount, bitOffset);
  return reader.readPackedVectorRaw();
}

function vectorHeaderAt(sample, bitOffset) {
  const reader = new BitCursor(sample.buffer, sample.bitCount, bitOffset);
  return reader.readPackedVectorHeader();
}

function expectedVectorAt(sample, family, slotIndex = family.slotIndex) {
  const absoluteOffset = family.headerBits + slotIndex * family.recordBits + family.relativeOffset;
  const vector = decodeVectorAt(sample, absoluteOffset);
  if (!vector) return null;
  if (vector.componentBits !== family.componentBits || vector.extraInfo !== family.extraInfo) {
    return null;
  }
  return vector;
}

function scaleVector(vector, scaleFactor) {
  const scale = vector.extraInfo ? scaleFactor : 1;
  return {
    x: vector.xSigned / scale,
    y: vector.ySigned / scale,
    z: vector.zSigned / scale,
  };
}

function summarizeNumeric(values, digits = 3) {
  if (!values.length) return null;
  return {
    min: round(Math.min(...values), digits),
    max: round(Math.max(...values), digits),
    median: round(percentile(values, 0.5), digits),
    p90: round(percentile(values, 0.9), digits),
  };
}

function summarizeVectorRows(rows, scaleFactor) {
  const scaled = rows.map((row) => scaleVector(row.vector, scaleFactor));
  const rawKeys = new Set(rows.map((row) => `${row.vector.xSigned}:${row.vector.ySigned}:${row.vector.zSigned}`));
  const gaps = [];
  const steps3d = [];
  for (let index = 1; index < rows.length; index += 1) {
    const dtMs = rows[index].timeMs - rows[index - 1].timeMs;
    if (dtMs > 0) gaps.push(dtMs);
    if (dtMs > 0 && dtMs <= 250) {
      const previous = scaled[index - 1];
      const current = scaled[index];
      steps3d.push(Math.hypot(current.x - previous.x, current.y - previous.y, current.z - previous.z));
    }
  }
  return {
    count: rows.length,
    firstTimeMs: rows[0]?.timeMs ?? null,
    lastTimeMs: rows.at(-1)?.timeMs ?? null,
    uniqueRawVectorCount: rawKeys.size,
    gapMs: summarizeNumeric(gaps, 0),
    adjacentStep3d: summarizeNumeric(steps3d, 3),
    rawBounds: rows.length
      ? {
          minX: Math.min(...rows.map((row) => row.vector.xSigned)),
          maxX: Math.max(...rows.map((row) => row.vector.xSigned)),
          minY: Math.min(...rows.map((row) => row.vector.ySigned)),
          maxY: Math.max(...rows.map((row) => row.vector.ySigned)),
          minZ: Math.min(...rows.map((row) => row.vector.zSigned)),
          maxZ: Math.max(...rows.map((row) => row.vector.zSigned)),
        }
      : null,
    scaledBounds: scaled.length
      ? {
          minX: round(Math.min(...scaled.map((row) => row.x)), 3),
          maxX: round(Math.max(...scaled.map((row) => row.x)), 3),
          minY: round(Math.min(...scaled.map((row) => row.y)), 3),
          maxY: round(Math.max(...scaled.map((row) => row.y)), 3),
          minZ: round(Math.min(...scaled.map((row) => row.z)), 3),
          maxZ: round(Math.max(...scaled.map((row) => row.z)), 3),
        }
      : null,
    firstRows: rows.slice(0, 8).map((row) => ({
      timeMs: row.timeMs,
      bitsAndInfo: row.vector.bitsAndInfo,
      componentBits: row.vector.componentBits,
      extraInfo: row.vector.extraInfo,
      xSigned: row.vector.xSigned,
      ySigned: row.vector.ySigned,
      zSigned: row.vector.zSigned,
      scaled: scaleVector(row.vector, scaleFactor),
    })),
  };
}

function analyzeSlotPresence(groupSamples, family, players, slotCount) {
  const slots = [];
  for (let slotIndex = 0; slotIndex < slotCount; slotIndex += 1) {
    const absoluteOffset = family.headerBits + slotIndex * family.recordBits + family.relativeOffset;
    const headerCounts = new Map();
    const expectedRows = [];
    let decodableCount = 0;
    for (const sample of groupSamples) {
      const header = vectorHeaderAt(sample, absoluteOffset);
      if (header) increment(headerCounts, `${header.componentBits}|${header.extraInfo}|${header.bitsAndInfo}`);
      const vector = decodeVectorAt(sample, absoluteOffset);
      if (!vector) continue;
      decodableCount += 1;
      if (vector.componentBits === family.componentBits && vector.extraInfo === family.extraInfo) {
        expectedRows.push({ timeMs: sample.timeMs, vector });
      }
    }
    slots.push({
      slotIndex,
      slotPlayer: players[slotIndex]
        ? {
            netGuid: players[slotIndex].netGuid,
            chIndex: players[slotIndex].chIndex,
            archetypePath: players[slotIndex].archetypePath,
          }
        : null,
      absoluteOffset,
      expectedEncodingCount: expectedRows.length,
      expectedEncodingRate: groupSamples.length ? round(expectedRows.length / groupSamples.length) : 0,
      decodableVectorCount: decodableCount,
      topHeadersAtOffset: topCounts(headerCounts, 6),
    });
  }
  return slots;
}

function scanVectorOffsetsForTargetSlot(groupSamples, family, options) {
  const recordStart = family.headerBits + family.slotIndex * family.recordBits;
  const rowsByKey = new Map();
  const maxRelativeOffset = family.recordBits - (PACKED_VECTOR_HEADER_BITS + 7 * 3);
  for (let relativeOffset = 0; relativeOffset <= maxRelativeOffset; relativeOffset += 1) {
    const absoluteOffset = recordStart + relativeOffset;
    for (const sample of groupSamples) {
      const vector = decodeVectorAt(sample, absoluteOffset);
      if (!vector) continue;
      const key = [
        relativeOffset,
        vector.componentBits,
        vector.extraInfo,
        vector.bitsAndInfo,
        vector.headerBits,
      ].join('|');
      if (!rowsByKey.has(key)) rowsByKey.set(key, []);
      rowsByKey.get(key).push({ timeMs: sample.timeMs, vector });
    }
  }
  return [...rowsByKey.entries()]
    .map(([key, rows]) => {
      const [relativeOffset, componentBits, extraInfo, bitsAndInfo, headerBits] = key
        .split('|')
        .map(Number);
      return {
        relativeOffset,
        absoluteOffset: recordStart + relativeOffset,
        componentBits,
        extraInfo,
        bitsAndInfo,
        headerBits,
        count: rows.length,
        rate: groupSamples.length ? round(rows.length / groupSamples.length) : 0,
        matchesSelectedEncoding:
          relativeOffset === family.relativeOffset &&
          componentBits === family.componentBits &&
          extraInfo === family.extraInfo,
        summary: summarizeVectorRows(rows, family.scaleFactor),
      };
    })
    .filter((entry) => entry.count >= options.minVectorOffsetSamples)
    .sort(
      (a, b) =>
        Number(b.matchesSelectedEncoding) - Number(a.matchesSelectedEncoding) ||
        b.count - a.count ||
        a.relativeOffset - b.relativeOffset,
    )
    .slice(0, options.maxVectorOffsets);
}

function identityReferences(players) {
  const refs = [];
  for (const player of players) {
    refs.push({ label: 'netGuid', value: player.netGuid, player });
    refs.push({ label: 'netGuid+1', value: player.netGuid + 1, player });
    refs.push({ label: 'netGuid-1', value: player.netGuid - 1, player });
    refs.push({ label: 'netGuid>>1', value: player.netGuid >> 1, player });
    refs.push({ label: 'chIndex', value: player.chIndex, player });
  }
  return refs;
}

function readEncodingValue(sample, absolute, encoding) {
  if (encoding === 'intPacked') {
    const packed = readIntPacked(sample.buffer, absolute, sample.bitCount);
    return packed.ok ? packed.value : null;
  }
  const bitCount = Number(encoding.slice(4));
  if (absolute + bitCount > sample.bitCount) return null;
  return readBitsUnsigned(sample.buffer, absolute, bitCount);
}

function scanIdentityHits(groupSamples, family, players, options) {
  const refs = identityReferences(players);
  const rows = [];
  for (let slotIndex = 0; slotIndex < options.slotCount; slotIndex += 1) {
    const recordStart = family.headerBits + slotIndex * family.recordBits;
    for (const encoding of PLAYER_IDENTITY_ENCODINGS) {
      const maxBits = encoding === 'intPacked' ? 40 : Number(encoding.slice(4));
      for (let relativeOffset = 0; relativeOffset + maxBits <= family.recordBits; relativeOffset += 1) {
        const absoluteOffset = recordStart + relativeOffset;
        const hitCounts = new Map();
        for (const sample of groupSamples) {
          const value = readEncodingValue(sample, absoluteOffset, encoding);
          if (value == null) continue;
          for (const ref of refs) {
            if (value === ref.value) {
              const key = `${encoding}|${ref.label}|${ref.player.netGuid}|${ref.player.chIndex}|${ref.value}`;
              increment(hitCounts, key);
            }
          }
        }
        for (const [key, count] of hitCounts.entries()) {
          if (count < options.minIdentityHits) continue;
          const [, label, netGuidText, chIndexText, valueText] = key.split('|');
          const playerNetGuid = Number(netGuidText);
          const playerChIndex = Number(chIndexText);
          rows.push({
            slotIndex,
            relativeOffset,
            absoluteOffset,
            encoding,
            label,
            value: Number(valueText),
            playerNetGuid,
            playerChIndex,
            count,
            countRate: groupSamples.length ? round(count / groupSamples.length) : 0,
            sameAsSlotPlayer:
              players[slotIndex]?.netGuid === playerNetGuid ||
              players[slotIndex]?.chIndex === playerChIndex,
            sameAsTargetSlot:
              slotIndex === family.slotIndex &&
              (players[family.slotIndex]?.netGuid === playerNetGuid ||
                players[family.slotIndex]?.chIndex === playerChIndex),
            isTargetSlot: slotIndex === family.slotIndex,
          });
        }
      }
    }
  }
  const sortHits = (a, b) =>
    Number(b.isTargetSlot) - Number(a.isTargetSlot) ||
    Number(b.sameAsTargetSlot) - Number(a.sameAsTargetSlot) ||
    Number(b.sameAsSlotPlayer) - Number(a.sameAsSlotPlayer) ||
    b.count - a.count ||
    a.slotIndex - b.slotIndex ||
    a.relativeOffset - b.relativeOffset;

  return {
    targetSlotSameIdentityHits: rows
      .filter((row) => row.isTargetSlot && row.sameAsTargetSlot)
      .sort(sortHits)
      .slice(0, options.maxIdentityHitRows),
    targetSlotOtherIdentityHits: rows
      .filter((row) => row.isTargetSlot && !row.sameAsTargetSlot)
      .sort((a, b) => b.count - a.count || a.relativeOffset - b.relativeOffset)
      .slice(0, Math.min(16, options.maxIdentityHitRows)),
    allSlotSameIdentityHits: rows
      .filter((row) => row.sameAsSlotPlayer)
      .sort(sortHits)
      .slice(0, options.maxIdentityHitRows),
  };
}

function packedVectorBitLength(family) {
  return PACKED_VECTOR_HEADER_BITS + family.componentBits * 3;
}

function targetContextHexRows(groupSamples, family, options) {
  const recordStart = family.headerBits + family.slotIndex * family.recordBits;
  const vectorStart = family.relativeOffset;
  const vectorEnd = Math.min(family.recordBits, vectorStart + packedVectorBitLength(family));
  const contextStart = Math.max(0, vectorStart - 40);
  const contextEnd = Math.min(family.recordBits, vectorEnd + 40);
  const counts = new Map();
  const rows = [];
  for (const sample of groupSamples) {
    const vector = expectedVectorAt(sample, family);
    if (!vector) continue;
    const beforeHex = bitsToHex(sample.buffer, recordStart + contextStart, vectorStart - contextStart);
    const vectorHex = bitsToHex(sample.buffer, recordStart + vectorStart, vectorEnd - vectorStart);
    const afterHex = bitsToHex(sample.buffer, recordStart + vectorEnd, contextEnd - vectorEnd);
    const key = `${beforeHex}|${afterHex}`;
    increment(counts, key);
    if (rows.length < options.maxContextRows) {
      rows.push({
        timeMs: sample.timeMs,
        contextRange: { startRel: contextStart, vectorStartRel: vectorStart, vectorEndRel: vectorEnd, endRel: contextEnd },
        beforeHex,
        vectorHex,
        afterHex,
      });
    }
  }
  return {
    vectorBitLength: packedVectorBitLength(family),
    topContextPairs: topCounts(counts, 12),
    rows,
  };
}

function bitPresenceCorrelation(groupSamples, family) {
  const recordStart = family.headerBits + family.slotIndex * family.recordBits;
  const vectorStart = family.relativeOffset;
  const vectorEnd = Math.min(family.recordBits, vectorStart + packedVectorBitLength(family));
  const present = [];
  const absent = [];
  for (const sample of groupSamples) {
    const vector = expectedVectorAt(sample, family);
    (vector ? present : absent).push(sample);
  }
  if (!present.length || !absent.length) {
    return {
      presentCount: present.length,
      absentCount: absent.length,
      note: 'correlation unavailable when selected vector is always present or always absent',
      strongestBits: [],
    };
  }

  const rows = [];
  for (let relativeOffset = 0; relativeOffset < family.recordBits; relativeOffset += 1) {
    if (relativeOffset >= vectorStart && relativeOffset < vectorEnd) continue;
    const absoluteOffset = recordStart + relativeOffset;
    const presentOneCount = present.reduce(
      (sum, sample) => sum + readBit(sample.buffer, absoluteOffset),
      0,
    );
    const absentOneCount = absent.reduce(
      (sum, sample) => sum + readBit(sample.buffer, absoluteOffset),
      0,
    );
    const presentRate = presentOneCount / present.length;
    const absentRate = absentOneCount / absent.length;
    rows.push({
      relativeOffset,
      absoluteOffset,
      role: relativeOffset < vectorStart ? 'before-vector' : 'after-vector',
      presentOneCount,
      absentOneCount,
      presentRate: round(presentRate),
      absentRate: round(absentRate),
      rateDelta: round(presentRate - absentRate),
      absRateDelta: round(Math.abs(presentRate - absentRate)),
    });
  }
  return {
    presentCount: present.length,
    absentCount: absent.length,
    strongestBits: rows
      .sort((a, b) => b.absRateDelta - a.absRateDelta || a.relativeOffset - b.relativeOffset)
      .slice(0, 40),
  };
}

function targetVectorRows(groupSamples, family) {
  const recordStart = family.headerBits + family.slotIndex * family.recordBits;
  const absoluteOffset = recordStart + family.relativeOffset;
  return groupSamples
    .map((sample) => {
      const vector = decodeVectorAt(sample, absoluteOffset);
      if (!vector) return null;
      if (vector.componentBits !== family.componentBits || vector.extraInfo !== family.extraInfo) {
        return null;
      }
      const scaled = scaleVector(vector, family.scaleFactor);
      return {
        timeMs: sample.timeMs,
        vector,
        scaled,
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.timeMs - b.timeMs);
}

function analyzeFamily(family, samples, players, options) {
  const groupSamples = samplesForFamily(samples, family);
  const vectorRows = targetVectorRows(groupSamples, family);
  return {
    family: {
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
      positionTransform: family.positionTransform,
      passesPosition3dGate: family.passesPosition3dGate,
      passesMovementShapeGate: family.passesMovementShapeGate,
      movementRejectionReasons: family.movementRejectionReasons ?? [],
      summary: family.summary ?? null,
    },
    groupSampleCount: groupSamples.length,
    groupTimeRange: {
      firstTimeMs: groupSamples[0]?.timeMs ?? null,
      lastTimeMs: groupSamples.at(-1)?.timeMs ?? null,
    },
    slotVectorPresence: analyzeSlotPresence(groupSamples, family, players, options.slotCount),
    targetVector: {
      vectorBitLength: packedVectorBitLength(family),
      expectedEncodingCount: vectorRows.length,
      expectedEncodingRate: groupSamples.length ? round(vectorRows.length / groupSamples.length) : 0,
      summary: summarizeVectorRows(vectorRows, family.scaleFactor),
    },
    targetSlotVectorOffsetScan: scanVectorOffsetsForTargetSlot(groupSamples, family, options),
    identity: scanIdentityHits(groupSamples, family, players, options),
    targetContext: targetContextHexRows(groupSamples, family, options),
    bitPresenceCorrelation: bitPresenceCorrelation(groupSamples, family),
  };
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

function compareFamilyPair(a, b, groupRowsByKey, options) {
  const aRows = groupRowsByKey.get(familyKey(a)) ?? [];
  const bRows = groupRowsByKey.get(familyKey(b)) ?? [];
  const deltas = [];
  const distances = [];
  const samplePairs = [];
  for (const row of aRows) {
    const nearest = nearestByTime(bRows, row.timeMs);
    if (!nearest) continue;
    deltas.push(nearest.deltaMs);
    const distance3d = Math.hypot(
      row.scaled.x - nearest.row.scaled.x,
      row.scaled.y - nearest.row.scaled.y,
      row.scaled.z - nearest.row.scaled.z,
    );
    distances.push(distance3d);
    if (nearest.deltaMs <= 16 && samplePairs.length < options.maxPairSamples) {
      samplePairs.push({
        aTimeMs: row.timeMs,
        bTimeMs: nearest.row.timeMs,
        deltaMs: nearest.deltaMs,
        distance3d: round(distance3d, 3),
        aScaled: row.scaled,
        bScaled: nearest.row.scaled,
      });
    }
  }
  return {
    a: { fieldHandle: a.fieldHandle, prefixHex: a.prefixHex, slotIndex: a.slotIndex },
    b: { fieldHandle: b.fieldHandle, prefixHex: b.prefixHex, slotIndex: b.slotIndex },
    aSampleCount: aRows.length,
    bSampleCount: bRows.length,
    nearestDeltaMs: summarizeNumeric(deltas, 0),
    nearestDistance3d: summarizeNumeric(distances, 3),
    within16msCount: deltas.filter((value) => value <= 16).length,
    within32msCount: deltas.filter((value) => value <= 32).length,
    samplePairs,
  };
}

function compareFamilies(families, samples, options) {
  const comparableGroups = new Map();
  const rowsByKey = new Map();
  for (const family of families) {
    const key = [
      family.fieldHandle,
      family.payloadBitCount,
      family.slotIndex,
      family.relativeOffset,
      family.scaleFactor,
      family.componentBits,
      family.extraInfo,
      family.positionTransform,
    ].join('|');
    if (!comparableGroups.has(key)) comparableGroups.set(key, []);
    comparableGroups.get(key).push(family);
    rowsByKey.set(familyKey(family), targetVectorRows(samplesForFamily(samples, family), family));
  }

  const comparisons = [];
  for (const familyGroup of comparableGroups.values()) {
    if (familyGroup.length < 2) continue;
    for (let left = 0; left < familyGroup.length; left += 1) {
      for (let right = left + 1; right < familyGroup.length; right += 1) {
        comparisons.push(compareFamilyPair(familyGroup[left], familyGroup[right], rowsByKey, options));
      }
    }
  }
  return comparisons;
}

function buildConclusions(familyReports, pairComparisons) {
  const conclusions = [];
  for (const report of familyReports) {
    const selectedSlot = report.family.slotIndex;
    const selectedPresence = report.slotVectorPresence.find((slot) => slot.slotIndex === selectedSlot);
    const otherPresence = report.slotVectorPresence
      .filter((slot) => slot.slotIndex !== selectedSlot)
      .reduce((sum, slot) => sum + slot.expectedEncodingCount, 0);
    conclusions.push(
      `h${report.family.fieldHandle}/${report.family.payloadBitCount}/${report.family.prefixHex} decodes the selected packed-vector encoding in slot ${selectedSlot} ${selectedPresence?.expectedEncodingCount ?? 0}/${report.groupSampleCount} times; other slots total ${otherPresence} hits at the same relative offset.`,
    );
    const firstIdentity = report.identity.targetSlotSameIdentityHits[0];
    if (firstIdentity) {
      conclusions.push(
        `same target slot carries ${firstIdentity.encoding} ${firstIdentity.label}=${firstIdentity.value} at relative bit ${firstIdentity.relativeOffset} in ${firstIdentity.count}/${report.groupSampleCount} rows.`,
      );
    }
    if (report.bitPresenceCorrelation.absentCount > 0) {
      const firstBit = report.bitPresenceCorrelation.strongestBits[0];
      if (firstBit) {
        conclusions.push(
          `vector presence for h${report.family.fieldHandle}/${report.family.prefixHex} is separable by bit ${firstBit.relativeOffset} (${firstBit.presentRate} present rate vs ${firstBit.absentRate} absent rate).`,
        );
      }
    }
  }
  for (const pair of pairComparisons) {
    conclusions.push(
      `h${pair.a.fieldHandle} prefixes ${pair.a.prefixHex} and ${pair.b.prefixHex} are paired: ${pair.within16msCount}/${pair.aSampleCount} samples have a nearest counterpart within 16ms.`,
    );
  }
  conclusions.push(
    'These decoder leads prove slot-local ComponentDataStream structure, but the selected vectors are still low-magnitude local/component values until the native world-position transform and authoritative ShooterCharacterNetGuidValue field are decoded.',
  );
  return conclusions;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const samplesPath = resolveUserPath(options.samples);
  if (!diagnosticsPath || !samplesPath) {
    console.error(
      'usage: node analyze_slot_component_decoder_leads.mjs --diagnostics replay.diagnostics.json --samples position3d_movement.samples.json --out decoder_leads.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const samplesReport = JSON.parse(fs.readFileSync(samplesPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const families = selectedFamiliesFromSamples(samplesReport);
  const familyReports = families.map((family) => analyzeFamily(family, samples, players, options));
  const pairComparisons = compareFamilies(families, samples, options);
  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
      samples: samplesPath,
    },
    options: {
      slotCount: options.slotCount,
      minIdentityHits: options.minIdentityHits,
      maxIdentityHitRows: options.maxIdentityHitRows,
      minVectorOffsetSamples: options.minVectorOffsetSamples,
      maxVectorOffsets: options.maxVectorOffsets,
      maxContextRows: options.maxContextRows,
      maxPairSamples: options.maxPairSamples,
    },
    notes: [
      'This report starts from the selected position3d-movement sample families and inspects their native slot records.',
      'Slot identity is still inferred from actor channel order; identity hits here are bit-level decoder leads.',
      'Packed-vector lengths use a 7-bit SerializeInt(128) header plus three signed components.',
      'The selected vectors remain diagnostic ComponentDataStream leads, not promoted player world positions.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      selectedFamilyCount: families.length,
      playerReferenceCount: players.length,
      players,
    },
    status:
      familyReports.length > 0
        ? 'slot component decoder leads summarized'
        : 'no selected slot component families found',
    conclusions: buildConclusions(familyReports, pairComparisons),
    familyReports,
    pairComparisons,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  console.error(
    `analyzed ${familyReports.length} selected slot-component families; pairComparisons=${pairComparisons.length}`,
  );
}

main();
