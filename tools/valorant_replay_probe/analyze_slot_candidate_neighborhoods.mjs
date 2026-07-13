#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    slotReport: null,
    out: null,
    slotCount: 10,
    contextBits: 72,
    minIdentityHits: 3,
    maxIdentityHits: 250,
    candidateScope: 'strict',
    maxFamilies: 40,
    identityWindowBits: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--slot-report') options.slotReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--slot-count') options.slotCount = Number(argv[++index]);
    else if (arg === '--context-bits') options.contextBits = Number(argv[++index]);
    else if (arg === '--min-identity-hits') options.minIdentityHits = Number(argv[++index]);
    else if (arg === '--max-identity-hits') options.maxIdentityHits = Number(argv[++index]);
    else if (arg === '--candidate-scope') options.candidateScope = argv[++index];
    else if (arg === '--max-families') options.maxFamilies = Number(argv[++index]);
    else if (arg === '--identity-window-bits') options.identityWindowBits = Number(argv[++index]);
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
    const bitsAndInfo = this.readSerializedInt(1 << 7);
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
    const { componentBits, extraInfo } = header;
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

function candidateMatchesScope(candidate, scope) {
  if (scope === 'strict') return candidate.passesStrictMovementGate;
  if (scope === 'position3d') return candidate.passesPosition3dGate;
  if (scope === 'position3d-movement') {
    return candidate.passesPosition3dGate && candidate.passesMovementShapeGate;
  }
  if (scope === 'movement') return candidate.passesMovementShapeGate;
  if (scope === 'same-yaw') return candidate.hasSameIdentityYawJoin;
  if (scope === 'all') return true;
  throw new Error(`unknown candidate scope: ${scope}`);
}

function familiesFromReport(slotReport, options) {
  const byKey = new Map();
  for (const candidate of slotReport.candidates ?? []) {
    if (!candidateMatchesScope(candidate, options.candidateScope)) continue;
    const key = [
      candidate.fieldHandle,
      candidate.payloadBitCount,
      candidate.prefixHex,
      candidate.slotIndex,
      candidate.relativeOffset,
      candidate.componentBits,
      candidate.extraInfo,
    ].join('|');
    if (!byKey.has(key)) {
      byKey.set(key, {
        fieldHandle: candidate.fieldHandle,
        fieldName: candidate.fieldName ?? null,
        bitCount: candidate.payloadBitCount,
        prefixHex: candidate.prefixHex,
        slotIndex: candidate.slotIndex,
        slotNetGuid: candidate.slotNetGuid,
        slotChIndex: candidate.slotChIndex,
        slotArchetypePath: candidate.slotArchetypePath,
        headerBits: candidate.headerBits,
        recordBits: candidate.recordBits,
        relativeOffset: candidate.relativeOffset,
        absoluteOffset: candidate.absoluteOffset,
        componentBits: candidate.componentBits,
        extraInfo: candidate.extraInfo,
        passesStrictMovementGate: Boolean(candidate.passesStrictMovementGate),
        passesPosition3dGate: Boolean(candidate.passesPosition3dGate),
        passesMovementShapeGate: Boolean(candidate.passesMovementShapeGate),
        hasSameIdentityYawJoin: Boolean(candidate.hasSameIdentityYawJoin),
        movementRejectionReasons: candidate.movementRejectionReasons ?? [],
        position3dRejectionReasons: candidate.position3dRejectionReasons ?? [],
        transforms: [],
      });
    }
    byKey.get(key).transforms.push({
      scaleFactor: candidate.scaleFactor,
      positionTransform: candidate.positionTransform,
      count: candidate.summary?.count ?? null,
      uniquePositionCount: candidate.summary?.uniquePositionCount ?? null,
      xySpan: candidate.summary?.xySpan ?? null,
      p90AdjacentSpeed: candidate.summary?.p90AdjacentSpeed ?? null,
      sameIdentityYawMatchCount: candidate.sameIdentityYawMatchCount ?? null,
      sameIdentityYawMatchRate: candidate.sameIdentityYawMatchRate ?? null,
    });
  }
  return [...byKey.values()].sort(
    (a, b) =>
      Number(b.passesStrictMovementGate) - Number(a.passesStrictMovementGate) ||
      Number(b.passesPosition3dGate) - Number(a.passesPosition3dGate) ||
      Number(b.passesMovementShapeGate) - Number(a.passesMovementShapeGate) ||
      Number(b.hasSameIdentityYawJoin) - Number(a.hasSameIdentityYawJoin) ||
      a.fieldHandle - b.fieldHandle ||
      a.bitCount - b.bitCount ||
      a.slotIndex - b.slotIndex ||
      a.relativeOffset - b.relativeOffset,
  ).slice(0, options.maxFamilies);
}

function samplesForFamily(samples, family) {
  return samples.filter(
    (sample) =>
      sample.fieldHandle === family.fieldHandle &&
      sample.bitCount === family.bitCount &&
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

function summarizeVectorRows(rows) {
  const xs = rows.map((row) => row.vector.xSigned);
  const ys = rows.map((row) => row.vector.ySigned);
  const zs = rows.map((row) => row.vector.zSigned);
  const headerCounts = new Map();
  const uniqueVectors = new Set();
  for (const row of rows) {
    increment(headerCounts, row.vector.bitsAndInfo);
    uniqueVectors.add(`${row.vector.xSigned}:${row.vector.ySigned}:${row.vector.zSigned}`);
  }
  return {
    count: rows.length,
    firstTimeMs: rows[0]?.timeMs ?? null,
    lastTimeMs: rows.at(-1)?.timeMs ?? null,
    uniqueTimeCount: new Set(rows.map((row) => row.timeMs)).size,
    uniqueVectorCount: uniqueVectors.size,
    topBitsAndInfo: topCounts(headerCounts, 8),
    rawBounds: rows.length
      ? {
          minX: Math.min(...xs),
          maxX: Math.max(...xs),
          minY: Math.min(...ys),
          maxY: Math.max(...ys),
          minZ: Math.min(...zs),
          maxZ: Math.max(...zs),
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
    })),
  };
}

function analyzeSlots(groupSamples, family, players, slotCount) {
  const slots = [];
  for (let slotIndex = 0; slotIndex < slotCount; slotIndex += 1) {
    const absoluteOffset = family.headerBits + slotIndex * family.recordBits + family.relativeOffset;
    const expectedRows = [];
    const decodableRows = [];
    const headerCounts = new Map();
    for (const sample of groupSamples) {
      const header = vectorHeaderAt(sample, absoluteOffset);
      if (header) increment(headerCounts, header.bitsAndInfo);
      const vector = decodeVectorAt(sample, absoluteOffset);
      if (!vector) continue;
      decodableRows.push({ timeMs: sample.timeMs, vector });
      if (
        vector.componentBits === family.componentBits &&
        vector.extraInfo === family.extraInfo
      ) {
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
      relativeOffset: family.relativeOffset,
      decodableCount: decodableRows.length,
      expectedEncodingCount: expectedRows.length,
      expectedEncodingRate: groupSamples.length ? round(expectedRows.length / groupSamples.length) : 0,
      topHeadersAtOffset: topCounts(headerCounts, 10),
      expectedSummary: summarizeVectorRows(expectedRows),
    });
  }
  return slots;
}

function contextForRow(sample, family) {
  const recordStart = family.headerBits + family.slotIndex * family.recordBits;
  const contextStartRel = Math.max(0, family.relativeOffset - 32);
  const vectorEndRel =
    family.relativeOffset + 1 + family.componentBits * 3;
  const contextEndRel = Math.min(family.recordBits, vectorEndRel + 32);
  return {
    timeMs: sample.timeMs,
    beforeHex: bitsToHex(
      sample.buffer,
      recordStart + contextStartRel,
      family.relativeOffset - contextStartRel,
    ),
    vectorHex: bitsToHex(
      sample.buffer,
      recordStart + family.relativeOffset,
      Math.min(family.recordBits - family.relativeOffset, vectorEndRel - family.relativeOffset),
    ),
    afterHex: bitsToHex(
      sample.buffer,
      recordStart + vectorEndRel,
      Math.max(0, contextEndRel - vectorEndRel),
    ),
  };
}

function bitCorrelation(groupSamples, family, options) {
  const recordStart = family.headerBits + family.slotIndex * family.recordBits;
  const absoluteOffset = recordStart + family.relativeOffset;
  const present = [];
  const absent = [];
  for (const sample of groupSamples) {
    const vector = decodeVectorAt(sample, absoluteOffset);
    const isPresent =
      vector?.componentBits === family.componentBits && vector?.extraInfo === family.extraInfo;
    (isPresent ? present : absent).push(sample);
  }
  const startRel = Math.max(0, family.relativeOffset - options.contextBits);
  const endRel = Math.min(
    family.recordBits,
    family.relativeOffset + 1 + family.componentBits * 3 + options.contextBits,
  );
  const rows = [];
  for (let rel = startRel; rel < endRel; rel += 1) {
    const absolute = recordStart + rel;
    const presentOneCount = present.reduce((sum, sample) => sum + readBit(sample.buffer, absolute), 0);
    const absentOneCount = absent.reduce((sum, sample) => sum + readBit(sample.buffer, absolute), 0);
    const presentRate = present.length ? presentOneCount / present.length : 0;
    const absentRate = absent.length ? absentOneCount / absent.length : 0;
    rows.push({
      relativeBit: rel,
      absoluteBit: absolute,
      role:
        rel < family.relativeOffset
          ? 'before-vector'
          : rel < family.relativeOffset + 1 + family.componentBits * 3
            ? 'vector'
            : 'after-vector',
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
    contextRange: { startRel, endRel },
    strongestBits: rows
      .filter((row) => row.role !== 'vector')
      .sort((a, b) => b.absRateDelta - a.absRateDelta || a.relativeBit - b.relativeBit)
      .slice(0, 40),
  };
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
  const encodings = ['intPacked', 'uint8', 'uint10', 'uint12', 'uint16', 'uint32'];
  const rows = [];
  for (let slotIndex = 0; slotIndex < options.slotCount; slotIndex += 1) {
    const recordStart = family.headerBits + slotIndex * family.recordBits;
    const relStart = Number.isFinite(options.identityWindowBits)
      ? Math.max(0, family.relativeOffset - options.identityWindowBits)
      : 0;
    const relEnd = Number.isFinite(options.identityWindowBits)
      ? Math.min(
          family.recordBits,
          family.relativeOffset + 1 + family.componentBits * 3 + options.identityWindowBits,
        )
      : family.recordBits;
    for (const encoding of encodings) {
      const maxBits = encoding === 'intPacked' ? 40 : Number(encoding.slice(4));
      for (let rel = relStart; rel + maxBits <= relEnd; rel += 1) {
        const absolute = recordStart + rel;
        const hitCounts = new Map();
        for (const sample of groupSamples) {
          const value = readEncodingValue(sample, absolute, encoding);
          if (value == null) continue;
          for (const ref of refs) {
            if (value === ref.value) {
              const key = `${encoding}|${ref.label}|${ref.player.netGuid}|${ref.player.chIndex}|${ref.value}`;
              increment(hitCounts, key);
            }
          }
        }
        for (const [key, count] of hitCounts.entries()) {
          if (count < options.minIdentityHits || count > options.maxIdentityHits) continue;
          const [, label, netGuidText, chIndexText, valueText] = key.split('|');
          rows.push({
            slotIndex,
            relativeOffset: rel,
            absoluteOffset: absolute,
            encoding,
            label,
            value: Number(valueText),
            playerNetGuid: Number(netGuidText),
            playerChIndex: Number(chIndexText),
            count,
            sameAsSlotPlayer:
              players[slotIndex]?.netGuid === Number(netGuidText) ||
              players[slotIndex]?.chIndex === Number(chIndexText),
            isTargetSlot: slotIndex === family.slotIndex,
          });
        }
      }
    }
  }
  return rows
    .sort(
      (a, b) =>
        Number(b.isTargetSlot) - Number(a.isTargetSlot) ||
        Number(b.sameAsSlotPlayer) - Number(a.sameAsSlotPlayer) ||
        b.count - a.count ||
        a.slotIndex - b.slotIndex ||
        a.relativeOffset - b.relativeOffset,
    )
    .slice(0, 120);
}

function analyzeFamily(family, samples, players, options) {
  const groupSamples = samplesForFamily(samples, family);
  const slots = analyzeSlots(groupSamples, family, players, options.slotCount);
  const targetRecordStart = family.headerBits + family.slotIndex * family.recordBits;
  const targetAbs = targetRecordStart + family.relativeOffset;
  const expectedSamples = groupSamples.filter((sample) => {
    const vector = decodeVectorAt(sample, targetAbs);
    return vector?.componentBits === family.componentBits && vector?.extraInfo === family.extraInfo;
  });
  const expectedContextCounts = new Map();
  for (const sample of expectedSamples) {
    const context = contextForRow(sample, family);
    increment(expectedContextCounts, `${context.beforeHex}|${context.afterHex}`);
  }
  return {
    family,
    groupSampleCount: groupSamples.length,
    firstTimeMs: groupSamples[0]?.timeMs ?? null,
    lastTimeMs: groupSamples.at(-1)?.timeMs ?? null,
    targetExpectedSampleCount: expectedSamples.length,
    targetExpectedRate: groupSamples.length ? round(expectedSamples.length / groupSamples.length) : 0,
    slots,
    targetContexts: expectedSamples.slice(0, 12).map((sample) => contextForRow(sample, family)),
    topTargetContextPairs: topCounts(expectedContextCounts, 12),
    bitCorrelation: bitCorrelation(groupSamples, family, options),
    identityHits: scanIdentityHits(groupSamples, family, players, options),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const slotReportPath = resolveUserPath(options.slotReport);
  if (!diagnosticsPath || !slotReportPath) {
    console.error(
      'usage: node analyze_slot_candidate_neighborhoods.mjs --diagnostics replay.diagnostics.json --slot-report slot_component_stream_candidates.report.json --out neighborhoods.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const slotReport = JSON.parse(fs.readFileSync(slotReportPath, 'utf8'));
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const families = familiesFromReport(slotReport, options);
  const familyReports = families.map((family) => analyzeFamily(family, samples, players, options));
  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
      slotReport: slotReportPath,
    },
    options: {
      slotCount: options.slotCount,
      contextBits: options.contextBits,
      minIdentityHits: options.minIdentityHits,
      maxIdentityHits: options.maxIdentityHits,
      candidateScope: options.candidateScope,
      maxFamilies: options.maxFamilies,
      identityWindowBits: options.identityWindowBits,
    },
    notes: [
      'This report inspects selected slot-component candidates around their slot-relative packed-vector offset.',
      'candidateScope can be strict, position3d, position3d-movement, movement, same-yaw, or all.',
      'Identity hits are bit-pattern clues only; they are not authoritative without a native record parse.',
      'Slot identity is still inferred from actor channel order.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      playerReferenceCount: players.length,
      candidateScope: options.candidateScope,
      familyCount: families.length,
      players,
    },
    status:
      familyReports.length > 0
        ? 'slot candidate neighborhoods summarized'
        : 'no slot candidate neighborhoods found',
    familyReports,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  console.error(
    `analyzed ${families.length} ${options.candidateScope} families; groupSamples=${familyReports.map((entry) => entry.groupSampleCount).join(',')}`,
  );
}

main();
