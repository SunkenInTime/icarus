#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const TARGET_FUNCTION_RE =
  /ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous/i;

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    out: null,
    minHitCount: 4,
    maxHits: 80,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--min-hit-count') options.minHitCount = Number(argv[++index]);
    else if (arg === '--max-hits') options.maxHits = Number(argv[++index]);
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

function topCounts(values, limit = 12) {
  const counts = new Map();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return [...counts.entries()]
    .map(([key, count]) => ({ key, count }))
    .sort((a, b) => b.count - a.count || String(a.key).localeCompare(String(b.key)))
    .slice(0, limit);
}

function addCount(map, key, amount = 1) {
  map.set(key, (map.get(key) ?? 0) + amount);
}

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

function unrealHardcodedName(value) {
  return UNREAL_HARDCODED_NAMES.get(value) ?? null;
}

function parseSamples(diagnostics) {
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

function summarizeTargetPayloadFamilies(samples) {
  const groups = new Map();
  for (const sample of samples) {
    const key = sample.bitCount;
    if (!groups.has(key)) {
      groups.set(key, {
        bitCount: sample.bitCount,
        count: 0,
        firstTimeMs: sample.timeMs,
        lastTimeMs: sample.timeMs,
        prefixes: [],
      });
    }
    const group = groups.get(key);
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
      topPrefixes: topCounts(group.prefixes, 10),
    }))
    .sort((a, b) => b.count - a.count || a.bitCount - b.bitCount);
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

function summarizeNative80Records(samples, players) {
  const records = [];
  for (const sample of samples) {
    const fullRecordCount = Math.floor(sample.bitCount / 80);
    for (let recordIndex = 0; recordIndex < fullRecordCount; recordIndex += 1) {
      const recordOffset = recordIndex * 80;
      const packed = readIntPacked(sample.buffer, recordOffset, sample.bitCount);
      records.push({
        timeMs: sample.timeMs,
        parentPayloadBits: sample.bitCount,
        recordIndex,
        recordOffset,
        prefix3: bitsToHex(sample.buffer, recordOffset, 24),
        prefix4: bitsToHex(sample.buffer, recordOffset, 32),
        firstPackedValue: packed.ok ? packed.value : null,
        firstPackedBitCount: packed.ok ? packed.bitCount : null,
        hex: bitsToHex(sample.buffer, recordOffset, 80),
      });
    }
  }

  const groups = new Map();
  for (const record of records) {
    const key = record.prefix3;
    if (!groups.has(key)) {
      groups.set(key, {
        prefix3: record.prefix3,
        firstPackedValue: record.firstPackedValue,
        firstPackedBitCount: record.firstPackedBitCount,
        count: 0,
        firstTimeMs: record.timeMs,
        lastTimeMs: record.timeMs,
        payloadBitCounts: [],
        recordIndexes: [],
        prefix4Values: [],
        samples: [],
      });
    }
    const group = groups.get(key);
    group.count += 1;
    group.firstTimeMs = Math.min(group.firstTimeMs, record.timeMs);
    group.lastTimeMs = Math.max(group.lastTimeMs, record.timeMs);
    group.payloadBitCounts.push(record.parentPayloadBits);
    group.recordIndexes.push(record.recordIndex);
    group.prefix4Values.push(record.prefix4);
    if (group.samples.length < 12) {
      group.samples.push({
        timeMs: record.timeMs,
        parentPayloadBits: record.parentPayloadBits,
        recordIndex: record.recordIndex,
        hex: record.hex,
      });
    }
  }

  return {
    totalRecordCount: records.length,
    familyCount: groups.size,
    topFamilies: [...groups.values()]
      .map((group) => ({
        prefix3: group.prefix3,
        firstPackedValue: group.firstPackedValue,
        firstPackedUnrealHardcodedName: unrealHardcodedName(group.firstPackedValue),
        firstPackedBitCount: group.firstPackedBitCount,
        firstPackedPlayerRelations: relationForFirstPacked(group.firstPackedValue, players),
        count: group.count,
        firstTimeMs: group.firstTimeMs,
        lastTimeMs: group.lastTimeMs,
        payloadBitCounts: topCounts(group.payloadBitCounts, 8),
        recordIndexes: topCounts(group.recordIndexes, 8),
        topPrefix4Values: topCounts(group.prefix4Values, 8),
        samples: group.samples,
      }))
      .sort((a, b) => b.count - a.count || a.prefix3.localeCompare(b.prefix3))
      .slice(0, 80),
  };
}

function parsePropertyStreamAt(sample, offset, maxFields = 8) {
  const fields = [];
  let bitOffset = offset;
  for (let index = 0; index < maxFields && bitOffset < sample.bitCount; index += 1) {
    const rawHandle = readIntPacked(sample.buffer, bitOffset, sample.bitCount);
    if (!rawHandle.ok) {
      fields.push({ bad: true, reason: 'bad-handle', bitOffset });
      break;
    }
    bitOffset += rawHandle.bitCount;
    if (rawHandle.value === 0) {
      fields.push({ terminator: true, rawHandle: 0, bitOffset });
      break;
    }
    const numBits = readIntPacked(sample.buffer, bitOffset, sample.bitCount);
    if (!numBits.ok) {
      fields.push({ bad: true, reason: 'bad-numBits', bitOffset });
      break;
    }
    bitOffset += numBits.bitCount;
    const handle = rawHandle.value - 1;
    const validPayload = numBits.value <= sample.bitCount - bitOffset;
    fields.push({
      handle,
      rawHandle: rawHandle.value,
      numBits: numBits.value,
      payloadBitOffset: bitOffset,
      validPayload,
    });
    if (!validPayload) break;
    bitOffset += numBits.value;
  }
  return fields;
}

function summarizePropertyAlignment(samples) {
  const offsets = [];
  for (let offset = 0; offset < 16; offset += 1) {
    const layouts = [];
    let plausibleCount = 0;
    let terminatorOnlyCount = 0;
    let handlesInRangeCount = 0;
    for (const sample of samples) {
      const fields = parsePropertyStreamAt(sample, offset, 6);
      const nonTerminator = fields.filter((field) => !field.terminator && !field.bad);
      const plausible =
        fields.length > 0 &&
        fields.every((field) => !field.bad) &&
        nonTerminator.every((field) => field.handle >= 0 && field.handle <= 3 && field.validPayload);
      if (plausible) plausibleCount += 1;
      if (fields.length === 1 && fields[0].terminator) terminatorOnlyCount += 1;
      if (nonTerminator.length && nonTerminator.every((field) => field.handle >= 0 && field.handle <= 3)) {
        handlesInRangeCount += 1;
      }
      layouts.push(
        fields
          .map((field) =>
            field.terminator
              ? 'term'
              : field.bad
                ? `bad:${field.reason}`
                : `${field.handle}:${field.numBits}${field.validPayload ? '' : ':bad'}`,
          )
          .join(','),
      );
    }
    offsets.push({
      offset,
      plausibleCount,
      terminatorOnlyCount,
      handlesInRangeCount,
      topLayouts: topCounts(layouts, 10),
    });
  }
  return offsets.sort(
    (a, b) =>
      b.plausibleCount - a.plausibleCount ||
      b.handlesInRangeCount - a.handlesInRangeCount ||
      a.offset - b.offset,
  );
}

function summarizeFirstPackedOffsets(samples) {
  const offsets = [];
  for (let offset = 0; offset < 16; offset += 1) {
    const values = [];
    for (const sample of samples) {
      const packed = readIntPacked(sample.buffer, offset, sample.bitCount);
      if (packed.ok) values.push(`${packed.value}/${packed.bitCount}`);
      else values.push(`bad/${packed.bitCount}`);
    }
    offsets.push({ offset, topValues: topCounts(values, 16) });
  }
  return offsets;
}

function summarizeIdentityHits(samples, refs, options) {
  const refsByValue = new Map();
  for (const ref of refs) {
    if (!refsByValue.has(ref.value)) refsByValue.set(ref.value, []);
    refsByValue.get(ref.value).push(ref);
  }

  const hits = new Map();
  const layoutGroups = new Map();
  const recordHit = (encoding, ref, offset, bitCount, sample) => {
    const key = [
      encoding,
      ref.playerNetGuid,
      ref.chIndex,
      ref.label,
      ref.value,
      offset,
      bitCount,
    ].join('|');
    if (!hits.has(key)) {
      hits.set(key, {
        encoding,
        playerNetGuid: ref.playerNetGuid,
        chIndex: ref.chIndex,
        archetypePath: ref.archetypePath,
        label: ref.label,
        value: ref.value,
        offset,
        bitCount,
        count: 0,
        timeSet: new Set(),
        firstTimeMs: sample.timeMs,
        lastTimeMs: sample.timeMs,
        payloadBitCounts: [],
        samples: [],
      });
    }
    const hit = hits.get(key);
    hit.count += 1;
    hit.timeSet.add(sample.timeMs);
    hit.firstTimeMs = Math.min(hit.firstTimeMs, sample.timeMs);
    hit.lastTimeMs = Math.max(hit.lastTimeMs, sample.timeMs);
    hit.payloadBitCounts.push(sample.bitCount);
    if (hit.samples.length < 4) {
      hit.samples.push({
        timeMs: sample.timeMs,
        payloadBits: sample.bitCount,
        payloadHex: sample.payloadHex.slice(0, 64),
      });
    }

    const layoutKey = [encoding, ref.label, offset, bitCount].join('|');
    if (!layoutGroups.has(layoutKey)) {
      layoutGroups.set(layoutKey, {
        encoding,
        label: ref.label,
        offset,
        bitCount,
        playerCounts: new Map(),
        sampleCount: 0,
      });
    }
    const layout = layoutGroups.get(layoutKey);
    addCount(layout.playerCounts, `${ref.playerNetGuid}/ch${ref.chIndex}`);
    layout.sampleCount += 1;
  };

  for (const sample of samples) {
    for (let offset = 0; offset < sample.bitCount; offset += 1) {
      const packed = readIntPacked(sample.buffer, offset, sample.bitCount);
      if (packed.ok) {
        for (const ref of refsByValue.get(packed.value) ?? []) {
          recordHit('intPacked', ref, offset, packed.bitCount, sample);
        }
      }

      for (const bitCount of [10, 12, 16, 32]) {
        if (offset + bitCount > sample.bitCount) continue;
        const value = readBitsUnsigned(sample.buffer, offset, bitCount);
        for (const ref of refsByValue.get(value) ?? []) {
          recordHit(`uint${bitCount}`, ref, offset, bitCount, sample);
        }
      }
    }
  }

  const recurringHits = [...hits.values()]
    .filter((hit) => hit.count >= options.minHitCount)
    .map((hit) => ({
      encoding: hit.encoding,
      playerNetGuid: hit.playerNetGuid,
      chIndex: hit.chIndex,
      archetypePath: hit.archetypePath,
      label: hit.label,
      value: hit.value,
      offset: hit.offset,
      bitCount: hit.bitCount,
      count: hit.count,
      uniqueTimeCount: hit.timeSet.size,
      firstTimeMs: hit.firstTimeMs,
      lastTimeMs: hit.lastTimeMs,
      payloadBitCounts: topCounts(hit.payloadBitCounts, 8),
      samples: hit.samples,
    }))
    .sort(
      (a, b) =>
        b.count - a.count ||
        b.uniqueTimeCount - a.uniqueTimeCount ||
        a.offset - b.offset ||
        a.playerNetGuid - b.playerNetGuid,
    )
    .slice(0, options.maxHits);

  const multiPlayerLayouts = [...layoutGroups.values()]
    .map((layout) => ({
      encoding: layout.encoding,
      label: layout.label,
      offset: layout.offset,
      bitCount: layout.bitCount,
      sampleCount: layout.sampleCount,
      playerCounts: topCounts([...layout.playerCounts.entries()].flatMap(([key, count]) =>
        Array.from({ length: count }, () => key),
      ), 12),
      uniquePlayerCount: layout.playerCounts.size,
    }))
    .filter((layout) => layout.uniquePlayerCount >= 2 && layout.sampleCount >= options.minHitCount)
    .sort(
      (a, b) =>
        b.uniquePlayerCount - a.uniquePlayerCount ||
        b.sampleCount - a.sampleCount ||
        a.offset - b.offset,
    )
    .slice(0, options.maxHits);

  return {
    recurringHits,
    multiPlayerLayouts,
  };
}

function isAuthoritativeActorNetGuidShape(item) {
  return item.label === 'netGuid' && (item.encoding === 'uint32' || item.bitCount >= 16);
}

function summarizeIdentityClassification(identity, options) {
  const summaryLimit = Math.min(options.maxHits, 12);
  const authoritativeActorNetGuidRecurringHits = identity.recurringHits.filter(
    isAuthoritativeActorNetGuidShape,
  );
  const authoritativeActorNetGuidLayouts = identity.multiPlayerLayouts.filter(
    isAuthoritativeActorNetGuidShape,
  );
  const exactActorNetGuidRecurringHits = identity.recurringHits.filter(
    (hit) => hit.label === 'netGuid',
  );
  const exactChannelIndexLayouts = identity.multiPlayerLayouts.filter(
    (layout) => layout.label === 'chIndex',
  );
  const transformedOrNeighborLayouts = identity.multiPlayerLayouts.filter(
    (layout) => layout.label !== 'netGuid' && layout.label !== 'chIndex',
  );

  const notes = [];
  if (authoritativeActorNetGuidLayouts.length === 0) {
    notes.push('No same-offset multi-player actor NetGUID layout was found in a >=16-bit or uint32 shape.');
  }
  if (authoritativeActorNetGuidRecurringHits.length === 0) {
    notes.push('No recurring exact actor NetGUID value was found in a >=16-bit or uint32 shape.');
  }
  if (exactActorNetGuidRecurringHits.length > 0) {
    notes.push(
      'Exact actor NetGUID recurring hits are narrower fragments; treat them as collision-level until externally validated.',
    );
  }
  if (transformedOrNeighborLayouts.length > 0) {
    notes.push(
      'Most multi-player layouts are channel-neighbor, shift, or low-bit transforms and are useful only as collision probes.',
    );
  }

  return {
    authoritativeActorNetGuidLayoutCount: authoritativeActorNetGuidLayouts.length,
    authoritativeActorNetGuidLayouts: authoritativeActorNetGuidLayouts.slice(0, summaryLimit),
    authoritativeActorNetGuidRecurringHitCount: authoritativeActorNetGuidRecurringHits.length,
    authoritativeActorNetGuidRecurringHits: authoritativeActorNetGuidRecurringHits.slice(0, summaryLimit),
    exactActorNetGuidRecurringHitCount: exactActorNetGuidRecurringHits.length,
    exactActorNetGuidRecurringHits: exactActorNetGuidRecurringHits.slice(0, summaryLimit),
    exactChannelIndexMultiLayoutCount: exactChannelIndexLayouts.length,
    exactChannelIndexMultiLayouts: exactChannelIndexLayouts.slice(0, summaryLimit),
    transformedOrNeighborMultiLayoutCount: transformedOrNeighborLayouts.length,
    transformedOrNeighborMultiLayouts: transformedOrNeighborLayouts.slice(0, summaryLimit),
    notes,
  };
}

function statusForIdentityClassification(classification) {
  if (classification.authoritativeActorNetGuidLayoutCount > 0) {
    return 'possible authoritative actor NetGUID layout found; inspect native target record framing';
  }
  if (classification.exactChannelIndexMultiLayoutCount > 0) {
    return 'only channel-index-shaped/collision-level layouts found; no authoritative actor NetGUID layout found in target payloads';
  }
  if (classification.transformedOrNeighborMultiLayoutCount > 0) {
    return 'only collision-level transformed identity-like layouts found; no authoritative actor NetGUID layout found in target payloads';
  }
  return 'no recurring identity-like layout found across target payloads';
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_target_rpc_framing.mjs --diagnostics replay.diagnostics.json --out target_rpc_framing.report.json',
    );
    process.exit(1);
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const samples = parseSamples(diagnostics);
  const players = knownPlayerRefs(diagnostics);
  const refs = buildReferenceValues(players);
  const identity = summarizeIdentityHits(samples, refs, options);
  const identityClassification = summarizeIdentityClassification(identity, options);
  const native80 = summarizeNative80Records(samples, players);

  const report = {
    generatedAt: new Date().toISOString(),
    input: { diagnostics: diagnosticsPath },
    options: {
      minHitCount: options.minHitCount,
      maxHits: options.maxHits,
    },
    source: {
      targetSampleCount: samples.length,
      playerReferenceCount: players.length,
      players,
    },
    notes: [
      'Focused framing report for ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous target payloads.',
      'Identity scans include exact actor NetGUIDs, player channel indexes, +/-1, shifts, and low-7-bit transforms to test common packed FNetworkGUID/channel hypotheses.',
      'Recurring hits are not proof by themselves; same-offset multi-player layouts are only useful when the value shape is authoritative enough to survive collision checks.',
    ],
    targetPayloadFamilies: summarizeTargetPayloadFamilies(samples),
    firstPackedOffsetSummary: summarizeFirstPackedOffsets(samples),
    propertyStreamAlignmentSummary: summarizePropertyAlignment(samples),
    native80RecordSummary: native80,
    transformedIdentitySummary: identity,
    transformedIdentityClassification: identityClassification,
    status: statusForIdentityClassification(identityClassification),
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else console.log(JSON.stringify(report, null, 2));
}

main();
