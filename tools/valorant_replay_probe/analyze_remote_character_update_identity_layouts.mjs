#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const TARGET_FUNCTION_RE =
  /ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous/i;

const IDENTITY_ENCODINGS = [
  { name: 'intPacked', kind: 'intPacked', authoritativeWidth: true },
  { name: 'uint8', kind: 'uint', bitCount: 8 },
  { name: 'uint10', kind: 'uint', bitCount: 10 },
  { name: 'uint11', kind: 'uint', bitCount: 11 },
  { name: 'uint12', kind: 'uint', bitCount: 12 },
  { name: 'uint13', kind: 'uint', bitCount: 13 },
  { name: 'uint16', kind: 'uint', bitCount: 16, authoritativeWidth: true },
  { name: 'uint24', kind: 'uint', bitCount: 24, authoritativeWidth: true },
  { name: 'uint32', kind: 'uint', bitCount: 32, authoritativeWidth: true },
];

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    decoderReport: null,
    out: null,
    slotCount: 10,
    minFamilySamples: 3,
    minLayoutSlotCoverage: 2,
    minHitRate: 0.15,
    maxFamilyReports: 80,
    maxLayoutRows: 40,
    maxPerSlotHits: 8,
    targetMinBits: 512,
    h100MinSamples: 20,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--decoder-report') options.decoderReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--slot-count') options.slotCount = Number(argv[++index]);
    else if (arg === '--min-family-samples') options.minFamilySamples = Number(argv[++index]);
    else if (arg === '--min-layout-slot-coverage') {
      options.minLayoutSlotCoverage = Number(argv[++index]);
    } else if (arg === '--min-hit-rate') {
      options.minHitRate = Number(argv[++index]);
    } else if (arg === '--max-family-reports') {
      options.maxFamilyReports = Number(argv[++index]);
    } else if (arg === '--max-layout-rows') {
      options.maxLayoutRows = Number(argv[++index]);
    } else if (arg === '--max-per-slot-hits') {
      options.maxPerSlotHits = Number(argv[++index]);
    } else if (arg === '--target-min-bits') {
      options.targetMinBits = Number(argv[++index]);
    } else if (arg === '--h100-min-samples') {
      options.h100MinSamples = Number(argv[++index]);
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
    .filter((sample) => Number.isInteger(sample.netGuid) && Number.isInteger(sample.chIndex))
    .sort((a, b) => a.chIndex - b.chIndex || a.netGuid - b.netGuid);
}

function identityReferences(players) {
  const refs = [];
  const add = (player, label, value, quality) => {
    if (!Number.isInteger(value) || value < 0) return;
    refs.push({
      label,
      value,
      quality,
      playerNetGuid: player.netGuid,
      chIndex: player.chIndex,
      archetypePath: player.archetypePath,
    });
  };

  for (const player of players) {
    add(player, 'netGuid', player.netGuid, 'actor-netguid');
    add(player, 'netGuid-1', player.netGuid - 1, 'netguid-neighbor');
    add(player, 'netGuid+1', player.netGuid + 1, 'netguid-neighbor');
    add(player, 'netGuid>>1', player.netGuid >> 1, 'netguid-transform');
    add(player, 'netGuid<<1', player.netGuid << 1, 'netguid-transform');
    add(player, 'netGuid<<1|1', (player.netGuid << 1) | 1, 'netguid-transform');
    add(player, 'netGuid&0x7f', player.netGuid & 0x7f, 'low-bit-collision');
    add(player, 'netGuid&0xff', player.netGuid & 0xff, 'low-bit-collision');
    add(player, 'netGuid&0x3ff', player.netGuid & 0x3ff, 'low-bit-collision');
    add(player, 'netGuid&0x7ff', player.netGuid & 0x7ff, 'low-bit-collision');
    add(player, 'chIndex', player.chIndex, 'channel-index');
    add(player, 'chIndex-1', player.chIndex - 1, 'channel-neighbor');
    add(player, 'chIndex+1', player.chIndex + 1, 'channel-neighbor');
    add(player, 'chIndex>>1', player.chIndex >> 1, 'channel-transform');
    add(player, 'chIndex<<1', player.chIndex << 1, 'channel-transform');
    add(player, 'chIndex<<1|1', (player.chIndex << 1) | 1, 'channel-transform');
    add(player, 'chIndex&0x7f', player.chIndex & 0x7f, 'channel-index');
  }

  return refs;
}

function buildRefsByValue(players) {
  const refsByValue = new Map();
  for (const ref of identityReferences(players)) {
    if (!refsByValue.has(ref.value)) refsByValue.set(ref.value, []);
    refsByValue.get(ref.value).push(ref);
  }
  return refsByValue;
}

function readIdentityValue(sample, bitOffset, bitLimit, encoding) {
  if (encoding.kind === 'intPacked') {
    const packed = readIntPacked(sample.buffer, bitOffset, bitLimit);
    return packed.ok ? { value: packed.value, bitCount: packed.bitCount } : null;
  }
  if (bitOffset + encoding.bitCount > bitLimit) return null;
  return {
    value: readBitsUnsigned(sample.buffer, bitOffset, encoding.bitCount),
    bitCount: encoding.bitCount,
  };
}

function samplePrefix(sample) {
  return bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount));
}

function splitFamilySamples(samples, family) {
  return samples
    .filter((sample) => {
      if (sample.fieldHandle !== family.fieldHandle || sample.bitCount !== family.payloadBits) {
        return false;
      }
      if (family.targetFunction && !TARGET_FUNCTION_RE.test(sample.fieldName ?? '')) return false;
      if (family.prefixHex && samplePrefix(sample) !== family.prefixHex) return false;
      return true;
    })
    .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
}

function makeSlotRecord(family, sample, slotIndex) {
  const startBit = family.headerBits + slotIndex * family.recordBits;
  return {
    sample,
    slotIndex,
    startBit,
    endBit: startBit + family.recordBits,
    bitCount: family.recordBits,
  };
}

function targetRpcFamilies(samples, options) {
  const groups = new Map();
  for (const sample of samples) {
    if (sample.fieldHandle !== 3 || !TARGET_FUNCTION_RE.test(sample.fieldName ?? '')) continue;
    if (sample.bitCount < options.targetMinBits) continue;
    const headerBits = sample.bitCount % options.slotCount;
    const recordBits = (sample.bitCount - headerBits) / options.slotCount;
    if (!Number.isInteger(recordBits) || recordBits <= 0) continue;
    const key = `target-rpc|${sample.bitCount}`;
    if (!groups.has(key)) {
      groups.set(key, {
        sourceKind: 'target-rpc-large-payload',
        familyId: key,
        label: `target RPC payloadBits=${sample.bitCount}`,
        fieldHandle: 3,
        fieldName: sample.fieldName,
        payloadBits: sample.bitCount,
        prefixHex: null,
        targetFunction: true,
        headerBits,
        recordBits,
      });
    }
  }
  return [...groups.values()];
}

function h100Families(samples, options) {
  const groups = new Map();
  for (const sample of samples) {
    if (sample.fieldHandle !== 100 || sample.bitCount !== 1950) continue;
    const prefixHex = samplePrefix(sample);
    const key = `h100|${sample.bitCount}|${prefixHex}`;
    if (!groups.has(key)) {
      groups.set(key, {
        sourceKind: 'h100-slot-array',
        familyId: key,
        label: `h100 payloadBits=${sample.bitCount} prefix=${prefixHex}`,
        fieldHandle: 100,
        fieldName: sample.fieldName ?? null,
        payloadBits: sample.bitCount,
        prefixHex,
        targetFunction: false,
        headerBits: sample.bitCount % options.slotCount,
        recordBits: (sample.bitCount - (sample.bitCount % options.slotCount)) / options.slotCount,
      });
    }
  }
  return [...groups.values()];
}

function decoderFamilies(decoderReport, options) {
  const families = [];
  const seen = new Set();
  for (const report of decoderReport?.familyReports ?? []) {
    const family = report.family;
    if (!family) continue;
    if (!Number.isInteger(family.fieldHandle) || !Number.isInteger(family.payloadBitCount)) continue;
    if (!family.prefixHex) continue;
    const headerBits =
      Number.isInteger(family.headerBits) ? family.headerBits : family.payloadBitCount % options.slotCount;
    const recordBits =
      Number.isInteger(family.recordBits)
        ? family.recordBits
        : (family.payloadBitCount - headerBits) / options.slotCount;
    if (!Number.isInteger(recordBits) || recordBits <= 0) continue;
    const key = `decoder|${family.fieldHandle}|${family.payloadBitCount}|${family.prefixHex}`;
    if (seen.has(key)) continue;
    seen.add(key);
    families.push({
      sourceKind: 'decoder-selected-family',
      familyId: key,
      label: `decoder h${family.fieldHandle} payloadBits=${family.payloadBitCount} prefix=${family.prefixHex}`,
      fieldHandle: family.fieldHandle,
      fieldName: null,
      payloadBits: family.payloadBitCount,
      prefixHex: family.prefixHex,
      targetFunction: false,
      selectedSlotIndex: family.slotIndex ?? null,
      selectedSlotNetGuid: family.slotNetGuid ?? null,
      selectedSlotChIndex: family.slotChIndex ?? null,
      selectedVectorRelativeOffset: family.relativeOffset ?? null,
      headerBits,
      recordBits,
    });
  }
  return families;
}

function uniqueFamilies(families) {
  const seen = new Set();
  const result = [];
  for (const family of families) {
    const key = [family.fieldHandle, family.payloadBits, family.prefixHex ?? 'all'].join('|');
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(family);
  }
  return result;
}

function isExactLabel(label) {
  return label === 'netGuid' || label === 'chIndex' || label === 'chIndex&0x7f';
}

function isAuthoritativeActorRef(hit) {
  return hit.label === 'netGuid' && (hit.encoding === 'intPacked' || hit.bitCount >= 11);
}

function isCollisionQuality(quality) {
  return /collision|neighbor|transform/.test(quality);
}

function hitSort(a, b) {
  return (
    Number(b.sameAsSlotPlayer) - Number(a.sameAsSlotPlayer) ||
    Number(isAuthoritativeActorRef(b)) - Number(isAuthoritativeActorRef(a)) ||
    Number(isExactLabel(b.label)) - Number(isExactLabel(a.label)) ||
    b.countRate - a.countRate ||
    b.count - a.count ||
    a.relativeOffset - b.relativeOffset ||
    a.encoding.localeCompare(b.encoding)
  );
}

function layoutSort(a, b) {
  return (
    Number(b.authoritativeActorNetGuidLayout) - Number(a.authoritativeActorNetGuidLayout) ||
    b.exactSameSlotCoverageCount - a.exactSameSlotCoverageCount ||
    b.authoritativeSameSlotCoverageCount - a.authoritativeSameSlotCoverageCount ||
    b.sameSlotCoverageCount - a.sameSlotCoverageCount ||
    b.totalSameSlotHits - a.totalSameSlotHits ||
    a.relativeOffset - b.relativeOffset ||
    a.encoding.localeCompare(b.encoding)
  );
}

function scanFamilyIdentity(family, familySamples, players, refsByValue, options) {
  const majoritySlotCoverage = Math.ceil(options.slotCount * 0.6);
  const rawHits = new Map();
  const recordHit = (encoding, ref, record, relativeOffset, bitCount) => {
    const player = players[record.slotIndex] ?? null;
    const sameAsSlotPlayer =
      player != null && (player.netGuid === ref.playerNetGuid || player.chIndex === ref.chIndex);
    const key = [
      encoding.name,
      ref.label,
      ref.value,
      ref.quality,
      ref.playerNetGuid,
      ref.chIndex,
      record.slotIndex,
      relativeOffset,
      bitCount,
    ].join('|');
    if (!rawHits.has(key)) {
      rawHits.set(key, {
        encoding: encoding.name,
        label: ref.label,
        value: ref.value,
        quality: ref.quality,
        playerNetGuid: ref.playerNetGuid,
        chIndex: ref.chIndex,
        archetypePath: ref.archetypePath,
        slotIndex: record.slotIndex,
        slotPlayer: player
          ? {
              netGuid: player.netGuid,
              chIndex: player.chIndex,
              archetypePath: player.archetypePath,
            }
          : null,
        sameAsSlotPlayer,
        relativeOffset,
        absoluteOffset: record.startBit + relativeOffset,
        bitCount,
        count: 0,
        timeSet: new Set(),
        samplePrefixes: new Map(),
        samples: [],
      });
    }
    const hit = rawHits.get(key);
    hit.count += 1;
    hit.timeSet.add(record.sample.timeMs);
    increment(hit.samplePrefixes, samplePrefix(record.sample));
    if (hit.samples.length < 6) {
      hit.samples.push({
        timeMs: record.sample.timeMs,
        payloadBits: record.sample.bitCount,
        slotIndex: record.slotIndex,
        recordPrefixHex: bitsToHex(record.sample.buffer, record.startBit, Math.min(64, record.bitCount)),
      });
    }
  };

  for (const sample of familySamples) {
    for (let slotIndex = 0; slotIndex < options.slotCount; slotIndex += 1) {
      const record = makeSlotRecord(family, sample, slotIndex);
      for (let relativeOffset = 0; relativeOffset < family.recordBits; relativeOffset += 1) {
        const absoluteOffset = record.startBit + relativeOffset;
        for (const encoding of IDENTITY_ENCODINGS) {
          const read = readIdentityValue(sample, absoluteOffset, record.endBit, encoding);
          if (!read) continue;
          for (const ref of refsByValue.get(read.value) ?? []) {
            recordHit(encoding, ref, record, relativeOffset, read.bitCount);
          }
        }
      }
    }
  }

  const minCount = Math.max(1, Math.ceil(familySamples.length * options.minHitRate));
  const hits = [...rawHits.values()]
    .filter((hit) => hit.count >= minCount)
    .map((hit) => ({
      encoding: hit.encoding,
      label: hit.label,
      value: hit.value,
      quality: hit.quality,
      playerNetGuid: hit.playerNetGuid,
      chIndex: hit.chIndex,
      archetypePath: hit.archetypePath,
      slotIndex: hit.slotIndex,
      slotPlayer: hit.slotPlayer,
      sameAsSlotPlayer: hit.sameAsSlotPlayer,
      relativeOffset: hit.relativeOffset,
      absoluteOffset: hit.absoluteOffset,
      bitCount: hit.bitCount,
      count: hit.count,
      countRate: round(hit.count / familySamples.length),
      uniqueTimeCount: hit.timeSet.size,
      topSamplePrefixes: topCounts(hit.samplePrefixes, 6),
      samples: hit.samples,
    }))
    .sort(hitSort);

  const layoutMap = new Map();
  for (const hit of hits) {
    const key = [hit.encoding, hit.label, hit.relativeOffset, hit.bitCount].join('|');
    if (!layoutMap.has(key)) {
      layoutMap.set(key, {
        encoding: hit.encoding,
        label: hit.label,
        relativeOffset: hit.relativeOffset,
        bitCount: hit.bitCount,
        hits: [],
      });
    }
    layoutMap.get(key).hits.push(hit);
  }

  const layouts = [...layoutMap.values()]
    .map((layout) => {
      const sameSlotHits = layout.hits.filter((hit) => hit.sameAsSlotPlayer);
      const exactSameSlotHits = sameSlotHits.filter((hit) => isExactLabel(hit.label));
      const authoritativeSameSlotHits = sameSlotHits.filter(isAuthoritativeActorRef);
      const wrongSlotHits = layout.hits.filter((hit) => !hit.sameAsSlotPlayer);
      const sameSlotCoverage = new Map();
      const exactSameSlotCoverage = new Map();
      const authoritativeSameSlotCoverage = new Map();
      for (const hit of sameSlotHits) {
        if (!sameSlotCoverage.has(hit.slotIndex) || sameSlotCoverage.get(hit.slotIndex).count < hit.count) {
          sameSlotCoverage.set(hit.slotIndex, hit);
        }
      }
      for (const hit of exactSameSlotHits) {
        if (
          !exactSameSlotCoverage.has(hit.slotIndex) ||
          exactSameSlotCoverage.get(hit.slotIndex).count < hit.count
        ) {
          exactSameSlotCoverage.set(hit.slotIndex, hit);
        }
      }
      for (const hit of authoritativeSameSlotHits) {
        if (
          !authoritativeSameSlotCoverage.has(hit.slotIndex) ||
          authoritativeSameSlotCoverage.get(hit.slotIndex).count < hit.count
        ) {
          authoritativeSameSlotCoverage.set(hit.slotIndex, hit);
        }
      }
      const authoritativeActorNetGuidLayout =
        authoritativeSameSlotCoverage.size >= majoritySlotCoverage &&
        wrongSlotHits.filter((hit) => hit.label === 'netGuid' && !isCollisionQuality(hit.quality)).length <=
          authoritativeSameSlotCoverage.size;
      return {
        encoding: layout.encoding,
        label: layout.label,
        relativeOffset: layout.relativeOffset,
        bitCount: layout.bitCount,
        sameSlotCoverageCount: sameSlotCoverage.size,
        exactSameSlotCoverageCount: exactSameSlotCoverage.size,
        authoritativeSameSlotCoverageCount: authoritativeSameSlotCoverage.size,
        authoritativeActorNetGuidLayout,
        totalSameSlotHits: sameSlotHits.reduce((sum, hit) => sum + hit.count, 0),
        totalWrongSlotHits: wrongSlotHits.reduce((sum, hit) => sum + hit.count, 0),
        coveredSlots: [...sameSlotCoverage.values()]
          .sort((a, b) => a.slotIndex - b.slotIndex)
          .map((hit) => ({
            slotIndex: hit.slotIndex,
            playerNetGuid: hit.playerNetGuid,
            chIndex: hit.chIndex,
            label: hit.label,
            value: hit.value,
            count: hit.count,
            countRate: hit.countRate,
          })),
        topWrongSlotHits: wrongSlotHits.sort(hitSort).slice(0, 8),
      };
    })
    .filter(
      (layout) =>
        layout.sameSlotCoverageCount > 0 ||
        layout.exactSameSlotCoverageCount > 0 ||
        layout.authoritativeSameSlotCoverageCount > 0,
    )
    .sort(layoutSort);

  const authoritativeLayouts = layouts.filter((layout) => layout.authoritativeActorNetGuidLayout);
  const multiSlotExactLayouts = layouts.filter(
    (layout) => layout.exactSameSlotCoverageCount >= options.minLayoutSlotCoverage,
  );
  const majorityExactLayouts = layouts.filter(
    (layout) => layout.exactSameSlotCoverageCount >= majoritySlotCoverage,
  );
  const perSlot = players.map((player, slotIndex) => {
    const slotHits = hits
      .filter((hit) => hit.slotIndex === slotIndex && hit.sameAsSlotPlayer && isExactLabel(hit.label))
      .sort(hitSort);
    return {
      slotIndex,
      player: {
        netGuid: player.netGuid,
        chIndex: player.chIndex,
        archetypePath: player.archetypePath,
      },
      exactSameSlotHitCount: slotHits.length,
      bestExactSameSlotHits: slotHits.slice(0, options.maxPerSlotHits),
    };
  });

  return {
    minHitCount: minCount,
    majoritySlotCoverage,
    hitCount: hits.length,
    sameSlotExactHitCount: hits.filter((hit) => hit.sameAsSlotPlayer && isExactLabel(hit.label)).length,
    authoritativeActorHitCount: hits.filter((hit) => hit.sameAsSlotPlayer && isAuthoritativeActorRef(hit)).length,
    authoritativeLayoutCount: authoritativeLayouts.length,
    authoritativeLayouts: authoritativeLayouts.slice(0, options.maxLayoutRows),
    multiSlotExactLayoutCount: multiSlotExactLayouts.length,
    multiSlotExactLayouts: multiSlotExactLayouts.slice(0, options.maxLayoutRows),
    majorityExactLayoutCount: majorityExactLayouts.length,
    majorityExactLayouts: majorityExactLayouts.slice(0, options.maxLayoutRows),
    bestLayouts: layouts.slice(0, options.maxLayoutRows),
    perSlot,
    bestPartialSameSlotHits: hits
      .filter((hit) => hit.sameAsSlotPlayer && isExactLabel(hit.label))
      .sort(hitSort)
      .slice(0, options.maxLayoutRows),
  };
}

function familyStatus(scan, options) {
  if (scan.authoritativeLayoutCount > 0) {
    return 'authoritative majority-slot actor NetGUID layout candidate found';
  }
  if (scan.majorityExactLayoutCount > 0) {
    return 'majority-slot exact identity-like layout found, but it is not authoritative actor NetGUID';
  }
  if (scan.multiSlotExactLayoutCount > 0) {
    return 'low-coverage multi-slot exact identity-like layout found, but no majority identity layout';
  }
  if (scan.sameSlotExactHitCount > 0) {
    return 'partial same-slot identity clues found, but no shared multi-slot layout';
  }
  return 'no recurring same-slot identity clues found';
}

function familyConclusions(family, scan, options) {
  const conclusions = [];
  const bestLayout = scan.bestLayouts[0] ?? null;
  const bestPartial = scan.bestPartialSameSlotHits[0] ?? null;
  if (scan.authoritativeLayoutCount > 0) {
    const layout = scan.authoritativeLayouts[0];
    conclusions.push(
      `${family.label} has a possible actor-NetGUID layout at rel${layout.relativeOffset} (${layout.encoding}) covering ${layout.authoritativeSameSlotCoverageCount}/${options.slotCount} slots.`,
    );
  } else if (scan.majorityExactLayoutCount > 0) {
    const layout = scan.majorityExactLayouts[0];
    conclusions.push(
      `${family.label} has a majority exact identity-like layout at rel${layout.relativeOffset} (${layout.encoding} ${layout.label}) covering ${layout.exactSameSlotCoverageCount}/${options.slotCount} slots, but it is not actor-NetGUID-shaped.`,
    );
  } else if (bestLayout && bestLayout.exactSameSlotCoverageCount >= options.minLayoutSlotCoverage) {
    conclusions.push(
      `${family.label} has a shared exact identity-like layout at rel${bestLayout.relativeOffset} (${bestLayout.encoding} ${bestLayout.label}) covering ${bestLayout.exactSameSlotCoverageCount}/${options.slotCount} slots, but it is not authoritative actor-NetGUID-shaped.`,
    );
  } else if (bestPartial) {
    conclusions.push(
      `${family.label} only has partial same-slot clues; best is slot ${bestPartial.slotIndex} ${bestPartial.encoding} ${bestPartial.label}=${bestPartial.value} at rel${bestPartial.relativeOffset} in ${bestPartial.count}/${family.sampleCount} rows.`,
    );
  } else {
    conclusions.push(`${family.label} has no recurring same-slot identity clue above the hit-rate gate.`);
  }

  const coveredSlots = scan.perSlot.filter((slot) => slot.exactSameSlotHitCount > 0).length;
  conclusions.push(
    `same-slot exact clues appear in ${coveredSlots}/${options.slotCount} slots; a decoded RemoteCharacterUpdate identity field should cover most active slots at one layout, not just isolated offsets.`,
  );
  return conclusions;
}

function analyzeFamilies(samples, players, families, options) {
  const refsByValue = buildRefsByValue(players);
  const reports = [];
  const skipped = [];
  for (const family of families) {
    const familySamples = splitFamilySamples(samples, family);
    if (family.sourceKind === 'h100-slot-array' && familySamples.length < options.h100MinSamples) {
      skipped.push({ family, sampleCount: familySamples.length, reason: 'below-h100-min-samples' });
      continue;
    }
    if (familySamples.length < options.minFamilySamples) {
      skipped.push({ family, sampleCount: familySamples.length, reason: 'below-min-family-samples' });
      continue;
    }
    if (!Number.isInteger(family.recordBits) || family.recordBits <= 0) {
      skipped.push({ family, sampleCount: familySamples.length, reason: 'invalid-record-bits' });
      continue;
    }
    const scan = scanFamilyIdentity(family, familySamples, players, refsByValue, options);
    reports.push({
      family: {
        ...family,
        sampleCount: familySamples.length,
        firstTimeMs: familySamples[0]?.timeMs ?? null,
        lastTimeMs: familySamples.at(-1)?.timeMs ?? null,
        topPrefixes: topCounts(familySamples.map(samplePrefix), 8),
      },
      status: familyStatus(scan, options),
      conclusions: familyConclusions({ ...family, sampleCount: familySamples.length }, scan, options),
      identityScan: scan,
    });
  }
  return {
    skippedFamilies: skipped,
    familyReports: reports
      .sort(
        (a, b) =>
          b.identityScan.authoritativeLayoutCount - a.identityScan.authoritativeLayoutCount ||
          b.identityScan.multiSlotExactLayoutCount - a.identityScan.multiSlotExactLayoutCount ||
          b.identityScan.sameSlotExactHitCount - a.identityScan.sameSlotExactHitCount ||
          b.family.sampleCount - a.family.sampleCount,
      )
      .slice(0, options.maxFamilyReports),
  };
}

function globalStatus(familyReports) {
  const authoritativeCount = familyReports.reduce(
    (sum, report) => sum + report.identityScan.authoritativeLayoutCount,
    0,
  );
  const majorityExactCount = familyReports.reduce(
    (sum, report) => sum + report.identityScan.majorityExactLayoutCount,
    0,
  );
  const multiSlotExactCount = familyReports.reduce(
    (sum, report) => sum + report.identityScan.multiSlotExactLayoutCount,
    0,
  );
  const partialCount = familyReports.reduce((sum, report) => sum + report.identityScan.sameSlotExactHitCount, 0);
  if (authoritativeCount > 0) {
    return 'possible authoritative RemoteCharacterUpdate actor NetGUID layout found; inspect candidates';
  }
  if (majorityExactCount > 0) {
    return 'majority-slot identity-like layouts found, but none are authoritative actor NetGUID layouts';
  }
  if (multiSlotExactCount > 0) {
    return 'only low-coverage identity-like layouts found; no shared ShooterCharacterNetGuidValue layout proved';
  }
  if (partialCount > 0) {
    return 'only partial same-slot identity clues found; no shared ShooterCharacterNetGuidValue layout proved';
  }
  return 'no same-slot RemoteCharacterUpdate identity layout found';
}

function globalConclusions(familyReports, options) {
  const conclusions = [];
  const authoritativeCount = familyReports.reduce(
    (sum, report) => sum + report.identityScan.authoritativeLayoutCount,
    0,
  );
  const majorityExactCount = familyReports.reduce(
    (sum, report) => sum + report.identityScan.majorityExactLayoutCount,
    0,
  );
  const multiSlotExactCount = familyReports.reduce(
    (sum, report) => sum + report.identityScan.multiSlotExactLayoutCount,
    0,
  );
  const bestCoverage = familyReports
    .flatMap((report) =>
      report.identityScan.bestLayouts.map((layout) => ({
        family: report.family.label,
        ...layout,
      })),
    )
    .sort(layoutSort)[0];
  conclusions.push(
    `authoritative actor-NetGUID layout candidates: ${authoritativeCount}; majority exact identity-like layouts: ${majorityExactCount}; low-coverage multi-slot exact layouts: ${multiSlotExactCount}.`,
  );
  if (bestCoverage) {
    conclusions.push(
      `best shared layout is ${bestCoverage.family} rel${bestCoverage.relativeOffset} ${bestCoverage.encoding} ${bestCoverage.label}, covering ${bestCoverage.exactSameSlotCoverageCount}/${options.slotCount} exact same-slot slots.`,
    );
  }
  conclusions.push(
    'This keeps the h24/h100 movement-shaped vectors diagnostic: a real replay-track emitter still needs a native ShooterCharacterNetGuidValue layout or another non-ambiguous slot identity signal.',
  );
  return conclusions;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_remote_character_update_identity_layouts.mjs --diagnostics replay.diagnostics.json [--decoder-report decoder.report.json] --out identity_layouts.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const decoderReport = options.decoderReport
    ? JSON.parse(fs.readFileSync(resolveUserPath(options.decoderReport), 'utf8'))
    : null;
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const families = uniqueFamilies([
    ...targetRpcFamilies(samples, options),
    ...h100Families(samples, options),
    ...decoderFamilies(decoderReport, options),
  ]);
  const { skippedFamilies, familyReports } = analyzeFamilies(samples, players, families, options);

  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
      decoderReport: resolveUserPath(options.decoderReport),
    },
    options: {
      slotCount: options.slotCount,
      minFamilySamples: options.minFamilySamples,
      minLayoutSlotCoverage: options.minLayoutSlotCoverage,
      minHitRate: options.minHitRate,
      maxFamilyReports: options.maxFamilyReports,
      maxLayoutRows: options.maxLayoutRows,
      maxPerSlotHits: options.maxPerSlotHits,
      targetMinBits: options.targetMinBits,
      h100MinSamples: options.h100MinSamples,
    },
    notes: [
      'This report scans target RemoteCharacterUpdates payloads plus h100/selected slot-array families for a repeated identity layout.',
      'A partial hit means one slot contains a value matching its inferred actor/channel. A layout candidate requires the same encoding and relative offset to identify multiple correct slots.',
      'Authoritative actor-NetGUID layouts require exact netGuid values in intPacked or >=11-bit shape and coverage across at least minLayoutSlotCoverage slots.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      playerReferenceCount: players.length,
      players,
      familyCandidateCount: families.length,
      skippedFamilyCount: skippedFamilies.length,
      skippedFamilies,
    },
    status: globalStatus(familyReports),
    conclusions: globalConclusions(familyReports, options),
    familyReports,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  const authoritativeCount = familyReports.reduce(
    (sum, family) => sum + family.identityScan.authoritativeLayoutCount,
    0,
  );
  const multiSlotExactCount = familyReports.reduce(
    (sum, family) => sum + family.identityScan.multiSlotExactLayoutCount,
    0,
  );
  console.error(
    `scanned ${familyReports.length} identity families; authoritativeLayouts=${authoritativeCount}; multiSlotExactLayouts=${multiSlotExactCount}`,
  );
}

main();
