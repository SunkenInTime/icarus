#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const TARGET_FUNCTION_RE =
  /ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous/i;

const ASCENT_BOUNDS = {
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
    minFamilySamples: 4,
    maxFamilies: 40,
    maxIdentityCandidates: 80,
    maxMotionCandidates: 80,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--min-family-samples') options.minFamilySamples = Number(argv[++index]);
    else if (arg === '--max-families') options.maxFamilies = Number(argv[++index]);
    else if (arg === '--max-identity-candidates') {
      options.maxIdentityCandidates = Number(argv[++index]);
    } else if (arg === '--max-motion-candidates') {
      options.maxMotionCandidates = Number(argv[++index]);
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

function readBitsSigned(buffer, bitOffset, bitCount) {
  const value = readBitsUnsigned(buffer, bitOffset, bitCount);
  const signBit = 2 ** (bitCount - 1);
  return (value ^ signBit) - signBit;
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

function percentile(values, fraction) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * fraction)));
  return sorted[index];
}

function parseTargetSamples(diagnostics) {
  return (diagnostics.frameSummary?.replayControllerCandidateFieldSamples ?? [])
    .filter(
      (sample) =>
        sample.fieldHandle === 3 &&
        TARGET_FUNCTION_RE.test(sample.fieldName ?? '') &&
        sample.payloadHex != null &&
        Number.isInteger(sample.numPayloadBits) &&
        !sample.payloadHexTruncated,
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
      };
    })
    .filter((sample) => sample.buffer.length * 8 >= sample.bitCount)
    .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
}

function knownPlayers(diagnostics) {
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

function identityRefs(players) {
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
    add(player, 'chIndex', player.chIndex, 'channel-index');
    add(player, 'netGuid&0x7f', player.netGuid & 0x7f, 'low-bit-collision');
    add(player, 'netGuid&0xff', player.netGuid & 0xff, 'low-bit-collision');
    add(player, 'chIndex-1', player.chIndex - 1, 'channel-neighbor');
    add(player, 'chIndex+1', player.chIndex + 1, 'channel-neighbor');
  }
  return refs;
}

function refsByValue(players) {
  const byValue = new Map();
  for (const ref of identityRefs(players)) {
    if (!byValue.has(ref.value)) byValue.set(ref.value, []);
    byValue.get(ref.value).push(ref);
  }
  return byValue;
}

function familyKey(sample) {
  return `${sample.bitCount}|${bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount))}`;
}

function buildFamilies(samples, options) {
  const byKey = new Map();
  for (const sample of samples) {
    const key = familyKey(sample);
    if (!byKey.has(key)) {
      byKey.set(key, {
        key,
        bitCount: sample.bitCount,
        prefixHex: bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)),
        samples: [],
      });
    }
    byKey.get(key).samples.push(sample);
  }
  return [...byKey.values()]
    .filter((family) => family.samples.length >= options.minFamilySamples)
    .sort((a, b) => b.samples.length - a.samples.length || a.bitCount - b.bitCount)
    .slice(0, options.maxFamilies);
}

function summarizePayloadFamilies(samples) {
  const byBits = new Map();
  for (const sample of samples) {
    if (!byBits.has(sample.bitCount)) {
      byBits.set(sample.bitCount, {
        bitCount: sample.bitCount,
        count: 0,
        firstTimeMs: sample.timeMs,
        lastTimeMs: sample.timeMs,
        prefixes: [],
      });
    }
    const family = byBits.get(sample.bitCount);
    family.count += 1;
    family.firstTimeMs = Math.min(family.firstTimeMs, sample.timeMs);
    family.lastTimeMs = Math.max(family.lastTimeMs, sample.timeMs);
    family.prefixes.push(bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)));
  }
  return [...byBits.values()]
    .map((family) => ({
      bitCount: family.bitCount,
      count: family.count,
      firstTimeMs: family.firstTimeMs,
      lastTimeMs: family.lastTimeMs,
      topPrefixes: topCounts(family.prefixes, 8),
    }))
    .sort((a, b) => b.count - a.count || a.bitCount - b.bitCount);
}

function directArrayCountModels(samples) {
  const modelStats = [];
  const countReaders = [
    {
      name: 'intPacked-count',
      read(sample, offset) {
        const count = readIntPacked(sample.buffer, offset, sample.bitCount);
        return count?.ok ? { count: count.value, headerBits: count.bitCount } : null;
      },
    },
    ...[4, 5, 6, 8, 10].map((bitCount) => ({
      name: `uint${bitCount}-count`,
      read(sample, offset) {
        if (offset + bitCount > sample.bitCount) return null;
        return { count: readBitsUnsigned(sample.buffer, offset, bitCount), headerBits: bitCount };
      },
    })),
  ];

  for (const leadingBool of [false, true]) {
    for (let offset = 0; offset < 16; offset += 1) {
      for (const reader of countReaders) {
        const counts = [];
        const recordBits = [];
        const nonIntegerRecordBits = [];
        const examples = [];
        let plausibleCount = 0;
        let integerRecordCount = 0;
        let guidBoundaryHitCount = 0;

        for (const sample of samples) {
          const countOffset = offset + (leadingBool ? 1 : 0);
          if (leadingBool && offset + 1 > sample.bitCount) continue;
          const read = reader.read(sample, countOffset);
          if (!read) continue;
          counts.push(read.count);
          const plausible = read.count >= 0 && read.count <= 32;
          if (!plausible) continue;
          plausibleCount += 1;
          const startBit = countOffset + read.headerBits;
          const bitsLeft = sample.bitCount - startBit;
          const perRecordBits = read.count > 0 ? bitsLeft / read.count : bitsLeft;
          if (Number.isInteger(perRecordBits)) {
            integerRecordCount += 1;
            recordBits.push(perRecordBits);
            if (read.count > 0 && scanBoundaryIdentityHits(sample, startBit, perRecordBits, read.count)) {
              guidBoundaryHitCount += 1;
            }
          } else {
            nonIntegerRecordBits.push(round(perRecordBits, 3));
          }
          if (examples.length < 5) {
            examples.push({
              timeMs: sample.timeMs,
              bitCount: sample.bitCount,
              payloadPrefixHex: bitsToHex(sample.buffer, 0, Math.min(48, sample.bitCount)),
              leadingBool: leadingBool ? Boolean(readBit(sample.buffer, offset)) : null,
              count: read.count,
              headerBits: startBit - offset,
              bitsLeft,
              perRecordBits: round(perRecordBits, 3),
            });
          }
        }

        modelStats.push({
          model: `${leadingBool ? 'bool+' : ''}${reader.name}`,
          offset,
          sampleCount: samples.length,
          plausibleCount,
          plausibleRate: round(plausibleCount / samples.length),
          integerRecordCount,
          integerRecordRate: round(integerRecordCount / samples.length),
          guidBoundaryHitCount,
          topCounts: topCounts(counts, 10),
          topRecordBits: topCounts(recordBits, 10),
          topNonIntegerRecordBits: topCounts(nonIntegerRecordBits, 6),
          examples,
        });
      }
    }
  }

  const ranked = modelStats.sort(
    (a, b) =>
      b.integerRecordCount - a.integerRecordCount ||
      b.guidBoundaryHitCount - a.guidBoundaryHitCount ||
      b.plausibleCount - a.plausibleCount ||
      a.offset - b.offset ||
      a.model.localeCompare(b.model),
  );
  const selected = new Map();
  const add = (model) => selected.set(`${model.model}@${model.offset}`, model);
  for (const model of ranked.slice(0, 32)) add(model);
  for (const model of ranked.filter((entry) => entry.model.includes('intPacked')).slice(0, 16)) {
    add(model);
  }
  return [...selected.values()];
}

function scanBoundaryIdentityHits(sample, startBit, recordBits, recordCount) {
  for (let recordIndex = 0; recordIndex < recordCount; recordIndex += 1) {
    const recordStart = startBit + recordIndex * recordBits;
    if (recordStart + 32 <= sample.bitCount) {
      const value = readBitsUnsigned(sample.buffer, recordStart, 32);
      if (value >= 500 && value <= 2000) return true;
    }
    const packed = readIntPacked(sample.buffer, recordStart, sample.bitCount);
    if (packed?.ok && packed.value >= 500 && packed.value <= 2000) return true;
  }
  return false;
}

function scanFamilyIdentities(family, players, options) {
  const refMap = refsByValue(players);
  const hits = new Map();
  const minimumCount = Math.max(2, Math.ceil(family.samples.length * 0.8));
  const encodings = [
    ...[7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 24, 32].map((bitCount) => ({
      name: `uint${bitCount}`,
      kind: 'uint',
      bitCount,
    })),
    { name: 'intPacked', kind: 'intPacked' },
  ];

  const recordHit = (encoding, ref, offset, bitCount, sample) => {
    const key = [
      encoding,
      ref.label,
      ref.value,
      ref.playerNetGuid,
      ref.chIndex,
      offset,
      bitCount,
    ].join('|');
    if (!hits.has(key)) {
      hits.set(key, {
        encoding,
        label: ref.label,
        value: ref.value,
        quality: ref.quality,
        playerNetGuid: ref.playerNetGuid,
        chIndex: ref.chIndex,
        archetypePath: ref.archetypePath,
        offset,
        bitCount,
        count: 0,
        timeSet: new Set(),
        samples: [],
      });
    }
    const hit = hits.get(key);
    hit.count += 1;
    hit.timeSet.add(sample.timeMs);
    if (hit.samples.length < 5) {
      hit.samples.push({
        timeMs: sample.timeMs,
        payloadHex: bitsToHex(sample.buffer, 0, Math.min(sample.bitCount, 96)),
      });
    }
  };

  for (const sample of family.samples) {
    for (let offset = 0; offset < sample.bitCount; offset += 1) {
      for (const encoding of encodings) {
        if (encoding.kind === 'intPacked') {
          const packed = readIntPacked(sample.buffer, offset, sample.bitCount);
          if (!packed?.ok) continue;
          for (const ref of refMap.get(packed.value) ?? []) {
            recordHit(encoding.name, ref, offset, packed.bitCount, sample);
          }
          continue;
        }
        if (offset + encoding.bitCount > sample.bitCount) continue;
        const value = readBitsUnsigned(sample.buffer, offset, encoding.bitCount);
        for (const ref of refMap.get(value) ?? []) {
          recordHit(encoding.name, ref, offset, encoding.bitCount, sample);
        }
      }
    }
  }

  return [...hits.values()]
    .filter((hit) => hit.count >= minimumCount)
    .map((hit) => ({
      ...hit,
      uniqueTimeCount: hit.timeSet.size,
      fullFamilyRate: round(hit.count / family.samples.length),
      timeSet: undefined,
      exactActorNetGuid: hit.label === 'netGuid',
      authoritativeWidth:
        hit.label === 'netGuid' && (hit.encoding === 'intPacked' || hit.bitCount >= 16),
      narrowExactActorNetGuid:
        hit.label === 'netGuid' && hit.encoding !== 'intPacked' && hit.bitCount < 16,
    }))
    .sort(
      (a, b) =>
        Number(b.exactActorNetGuid) - Number(a.exactActorNetGuid) ||
        Number(b.authoritativeWidth) - Number(a.authoritativeWidth) ||
        b.fullFamilyRate - a.fullFamilyRate ||
        b.bitCount - a.bitCount ||
        a.offset - b.offset,
    )
    .slice(0, options.maxIdentityCandidates);
}

function projectAscent(point) {
  return {
    u: point.y * ASCENT_BOUNDS.xMultiplier + ASCENT_BOUNDS.xScalarToAdd,
    v: point.x * ASCENT_BOUNDS.yMultiplier + ASCENT_BOUNDS.yScalarToAdd,
  };
}

function isPlausibleAscentPoint(point) {
  const percent = projectAscent(point);
  return (
    percent.u >= ASCENT_BOUNDS.minPercent &&
    percent.u <= ASCENT_BOUNDS.maxPercent &&
    percent.v >= ASCENT_BOUNDS.minPercent &&
    percent.v <= ASCENT_BOUNDS.maxPercent &&
    point.z >= ASCENT_BOUNDS.minZ &&
    point.z <= ASCENT_BOUNDS.maxZ
  );
}

function summarizeRows(rows) {
  const ordered = [...rows].sort((a, b) => a.timeMs - b.timeMs);
  const uniquePositions = new Set(
    ordered.map((row) => `${Math.round(row.x * 10)}:${Math.round(row.y * 10)}:${Math.round(row.z * 10)}`),
  );
  const xs = ordered.map((row) => row.x);
  const ys = ordered.map((row) => row.y);
  const zs = ordered.map((row) => row.z);
  const speeds = [];
  const steps = [];
  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const dtSeconds = (current.timeMs - previous.timeMs) / 1000;
    if (dtSeconds <= 0 || dtSeconds > 1) continue;
    const distance = Math.hypot(current.x - previous.x, current.y - previous.y, current.z - previous.z);
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
    activeSpanMs: ordered.length ? ordered.at(-1).timeMs - ordered[0].timeMs : 0,
    uniquePositionCount: uniquePositions.size,
    inAscentBoundsRate: ordered.length
      ? round(ordered.filter(isPlausibleAscentPoint).length / ordered.length)
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
    xySpan: round(Math.hypot(xSpan, ySpan), 2),
    zSpan: round(zSpan, 2),
    staticAxisCount: [xSpan, ySpan, zSpan].filter((span) => span < 5).length,
    adjacentStepCount: steps.length,
    p90Step: round(percentile(steps, 0.9), 2),
    p90Speed: round(percentile(speeds, 0.9), 1),
    maxSpeed: round(speeds.length ? Math.max(...speeds) : null, 1),
    samples: ordered.slice(0, 8).map((row) => ({
      timeMs: row.timeMs,
      x: round(row.x, 3),
      y: round(row.y, 3),
      z: round(row.z, 3),
    })),
  };
}

function scoreMotionCandidate(candidate) {
  const summary = candidate.summary;
  const p90Speed = summary.p90Speed ?? 25_000;
  return (
    summary.count * 20 +
    summary.uniquePositionCount * 30 +
    summary.inAscentBoundsRate * 400 +
    Math.min(summary.xySpan, 2000) * 0.2 +
    Math.min(summary.activeSpanMs / 1000, 30) * 10 -
    summary.staticAxisCount * 250 -
    Math.min(p90Speed, 25_000) * 0.04
  );
}

function strictMotionRejectionReasons(candidate) {
  const summary = candidate.summary;
  const reasons = [];
  if (candidate.identity.quality !== 'actor-netguid') reasons.push('identity-not-actor-netguid');
  if (!candidate.identity.authoritativeWidth) reasons.push('identity-is-narrow-custom-or-collision-prone');
  if (candidate.mode !== 'direct-position') reasons.push('not-absolute-position');
  if (summary.count < 12) reasons.push('too-few-samples');
  if (summary.uniquePositionCount < 8) reasons.push('too-few-unique-positions');
  if (summary.inAscentBoundsRate < 0.9) reasons.push('out-of-map-or-z-bounds');
  if (summary.xySpan < 100) reasons.push('low-xy-span');
  if (summary.staticAxisCount > 0) reasons.push('static-axis');
  if (summary.adjacentStepCount < Math.min(6, summary.count - 1)) reasons.push('too-few-adjacent-steps');
  if (summary.p90Speed == null || summary.p90Speed > 3000) reasons.push('high-or-missing-speed');
  return reasons;
}

function scanMotionAfterIdentities(family, identities, options) {
  const exactActorIdentities = identities.filter((identity) => identity.label === 'netGuid');
  const candidates = [];
  for (const identity of exactActorIdentities) {
    for (let startBit = 0; startBit <= family.bitCount - 18; startBit += 1) {
      const overlapsIdentity =
        startBit < identity.offset + identity.bitCount && startBit + 18 > identity.offset;
      if (overlapsIdentity) continue;
      for (const componentBits of [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]) {
        if (startBit + componentBits * 3 > family.bitCount) continue;
        for (const scale of [1, 10, 100, 1000]) {
          const rows = family.samples.map((sample) => ({
            timeMs: sample.timeMs,
            x: readBitsSigned(sample.buffer, startBit, componentBits) / scale,
            y: readBitsSigned(sample.buffer, startBit + componentBits, componentBits) / scale,
            z: readBitsSigned(sample.buffer, startBit + componentBits * 2, componentBits) / scale,
          }));
          const summary = summarizeRows(rows);
          if (summary.uniquePositionCount < 3) continue;
          if (summary.inAscentBoundsRate < 0.5 && summary.xySpan < 25) continue;
          const candidate = {
            familyKey: family.key,
            bitCount: family.bitCount,
            prefixHex: family.prefixHex,
            mode: 'direct-position',
            identity,
            layout: { startBit, componentBits, scale },
            summary,
          };
          candidate.score = scoreMotionCandidate(candidate);
          candidate.strictRejectionReasons = strictMotionRejectionReasons(candidate);
          candidate.strictTrackCandidate = candidate.strictRejectionReasons.length === 0;
          candidates.push(candidate);
        }
      }
    }
  }
  return candidates
    .sort((a, b) => b.score - a.score || b.summary.count - a.summary.count)
    .slice(0, options.maxMotionCandidates)
    .map((candidate) => ({
      ...candidate,
      score: round(candidate.score, 2),
    }));
}

function componentMagicScan(samples) {
  const hits = new Map();
  for (const sample of samples) {
    for (let offset = 0; offset + 8 <= sample.bitCount; offset += 1) {
      if (readBitsUnsigned(sample.buffer, offset, 8) === 0x52) {
        const key = `${sample.bitCount}@${offset}`;
        if (!hits.has(key)) {
          hits.set(key, {
            bitCount: sample.bitCount,
            offset,
            count: 0,
            firstTimeMs: sample.timeMs,
            lastTimeMs: sample.timeMs,
            prefixes: [],
          });
        }
        const hit = hits.get(key);
        hit.count += 1;
        hit.firstTimeMs = Math.min(hit.firstTimeMs, sample.timeMs);
        hit.lastTimeMs = Math.max(hit.lastTimeMs, sample.timeMs);
        hit.prefixes.push(bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)));
      }
    }
  }
  return [...hits.values()]
    .map((hit) => ({
      ...hit,
      topPrefixes: topCounts(hit.prefixes, 8),
      prefixes: undefined,
    }))
    .sort((a, b) => b.count - a.count || a.bitCount - b.bitCount || a.offset - b.offset)
    .slice(0, 40);
}

function analyzeFamilies(families, players, options) {
  return families.map((family) => {
    const identities = scanFamilyIdentities(family, players, options);
    const motionCandidates = scanMotionAfterIdentities(family, identities, options);
    const strictMotionCandidateCount = motionCandidates.filter(
      (candidate) => candidate.strictTrackCandidate,
    ).length;
    const exactNarrowGuidCount = identities.filter((identity) => identity.narrowExactActorNetGuid).length;
    const exactAuthoritativeGuidCount = identities.filter(
      (identity) => identity.authoritativeWidth,
    ).length;
    return {
      family: {
        key: family.key,
        bitCount: family.bitCount,
        prefixHex: family.prefixHex,
        sampleCount: family.samples.length,
        firstTimeMs: family.samples[0]?.timeMs ?? null,
        lastTimeMs: family.samples.at(-1)?.timeMs ?? null,
        samplePayloads: family.samples.slice(0, 5).map((sample) => ({
          timeMs: sample.timeMs,
          payloadHex: bitsToHex(sample.buffer, 0, Math.min(128, sample.bitCount)),
        })),
      },
      status:
        strictMotionCandidateCount > 0
          ? 'strict direct-position movement candidates found'
          : exactAuthoritativeGuidCount > 0
            ? 'authoritative-width actor identity found, but no strict direct-position lane'
            : exactNarrowGuidCount > 0
              ? 'narrow exact actor identity found; motion lanes remain diagnostic'
              : 'no recurring exact actor identity found',
      identityCandidates: identities,
      motionCandidateCount: motionCandidates.length,
      strictMotionCandidateCount,
      bestMotionCandidates: motionCandidates.slice(0, options.maxMotionCandidates),
    };
  });
}

function globalStatus(familyReports, arrayModels) {
  const strictMotion = familyReports.reduce(
    (sum, report) => sum + report.strictMotionCandidateCount,
    0,
  );
  const narrowGuidFamilies = familyReports.filter((report) =>
    report.identityCandidates.some((identity) => identity.narrowExactActorNetGuid),
  ).length;
  const bestArrayModel = arrayModels[0];
  if (strictMotion > 0) return 'strict direct target-RPC movement candidates found';
  if (narrowGuidFamilies > 0) {
    return 'target RPC is custom/direct: compact families expose narrow exact actor identities, but no strict absolute movement lane';
  }
  if (bestArrayModel?.integerRecordRate >= 0.8) {
    return 'direct array-count model may fit; inspect boundary identity and record bits';
  }
  return 'no direct count/identity/movement layout proved';
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_target_rpc_direct_layouts.mjs --diagnostics replay.diagnostics.json --out target_rpc_direct_layouts.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const samples = parseTargetSamples(diagnostics);
  const players = knownPlayers(diagnostics);
  const repeatedFamilies = buildFamilies(samples, options);
  const arrayModels = directArrayCountModels(samples);
  const familyReports = analyzeFamilies(repeatedFamilies, players, options);
  const magicHits = componentMagicScan(samples);

  const report = {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: diagnosticsPath,
    },
    options: {
      minFamilySamples: options.minFamilySamples,
      maxFamilies: options.maxFamilies,
      maxIdentityCandidates: options.maxIdentityCandidates,
      maxMotionCandidates: options.maxMotionCandidates,
    },
    notes: [
      'This report treats the target RPC payload as custom/direct function data instead of a reflected ReceiveProperties stream.',
      'The array-count models test bool + count + fixed elements hypotheses. A real TArray-like model should produce plausible counts and stable record widths across most samples.',
      'Narrow exact actor NetGUID hits are reported as custom-layout clues, not authoritative track attribution, until they are tied to a strict movement layout or independent identity source.',
    ],
    source: {
      targetSampleCount: samples.length,
      repeatedFamilyCount: repeatedFamilies.length,
      playerReferenceCount: players.length,
      players,
      payloadFamilies: summarizePayloadFamilies(samples),
    },
    status: globalStatus(familyReports, arrayModels),
    directArrayCountModels: arrayModels,
    componentMagicHits: magicHits,
    familyReports,
  };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  const narrowGuidFamilies = familyReports.filter((family) =>
    family.identityCandidates.some((identity) => identity.narrowExactActorNetGuid),
  ).length;
  const strictMotion = familyReports.reduce(
    (sum, family) => sum + family.strictMotionCandidateCount,
    0,
  );
  console.error(
    `direct target RPC scan: samples=${samples.length}; repeatedFamilies=${repeatedFamilies.length}; narrowGuidFamilies=${narrowGuidFamilies}; strictMotionCandidates=${strictMotion}`,
  );
}

main();
