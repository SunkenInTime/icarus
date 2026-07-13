#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const BASE_REPLAY_CONTROLLER_CLASS_NET_CACHE_RE = /BaseReplayController.*ClassNetCache/i;

const RPC_GROUP_BY_FIELD_NAME = new Map([
  [
    'ClientReplayReceiveInputEventProcessingCapture',
    '/Script/ShooterGame.ReplayPlayerController:ClientReplayReceiveInputEventProcessingCapture',
  ],
  [
    'ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous',
    '/Script/ShooterGame.ReplayPlayerController:ReplaysClientReceiveRemoteCharacterUpdatesSingleArrayNoAutonomous',
  ],
  ['ClientGamePhaseBegin', '/Script/ShooterGame.AresPlayerController:ClientGamePhaseBegin'],
  ['ClientGamePhaseEnded', '/Script/ShooterGame.AresPlayerController:ClientGamePhaseEnded'],
  ['ClientOnWinningTeam', '/Script/ShooterGame.AresPlayerController:ClientOnWinningTeam'],
  ['ClientFlushLevelStreaming', '/Script/Engine.PlayerController:ClientFlushLevelStreaming'],
  [
    'ClientUpdateMultipleLevelsStreamingStatus',
    '/Script/Engine.PlayerController:ClientUpdateMultipleLevelsStreamingStatus',
  ],
]);

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    out: null,
    maxSamplesPerField: 256,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--max-samples-per-field') options.maxSamplesPerField = Number(argv[++index]);
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
    if ((currentByte & 1) === 0) return { ok: true, value, bitCount: offset - bitOffset };
    shift *= 128;
  }
  return { ok: false, value, bitCount: offset - bitOffset };
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

function exportGroupsByPath(diagnostics) {
  const groups = new Map();
  for (const group of diagnostics.frameSummary?.exportGroups ?? []) {
    groups.set(group.pathName, group);
  }
  return groups;
}

function parsePropertyStream(sample, group, offset, maxFields = 12) {
  const fields = [];
  let bitOffset = offset;
  let sawTerminator = false;
  let error = null;

  for (let index = 0; index < maxFields && bitOffset < sample.bitCount; index += 1) {
    const rawHandle = readIntPacked(sample.buffer, bitOffset, sample.bitCount);
    if (!rawHandle.ok) {
      error = 'bad-handle';
      fields.push({ bad: true, reason: error, bitOffset });
      break;
    }
    bitOffset += rawHandle.bitCount;
    if (rawHandle.value === 0) {
      sawTerminator = true;
      fields.push({ terminator: true, rawHandle: 0, bitOffset });
      break;
    }

    const numBits = readIntPacked(sample.buffer, bitOffset, sample.bitCount);
    if (!numBits.ok) {
      error = 'bad-numBits';
      fields.push({ bad: true, reason: error, bitOffset });
      break;
    }
    bitOffset += numBits.bitCount;

    const handle = rawHandle.value - 1;
    const validHandle = handle >= 0 && handle < (group?.netFieldExportsLength ?? 0);
    const exportName = group?.knownExports?.find((entry) => entry.handle === handle)?.name ?? null;
    const validPayload = numBits.value <= sample.bitCount - bitOffset;
    fields.push({
      handle,
      rawHandle: rawHandle.value,
      exportName,
      numBits: numBits.value,
      payloadBitOffset: bitOffset,
      validHandle,
      validPayload,
      payloadPrefixHex: validPayload ? bitsToHex(sample.buffer, bitOffset, Math.min(numBits.value, 48)) : null,
    });
    if (!validHandle) {
      error = 'handle-out-of-range';
      break;
    }
    if (!validPayload) {
      error = 'field-bitcount-out-of-range';
      break;
    }
    bitOffset += numBits.value;
  }

  const nonTerminator = fields.filter((field) => !field.terminator && !field.bad);
  const invalid = fields.find((field) => field.bad || field.validHandle === false || field.validPayload === false);
  return {
    offset,
    ok: !invalid && sawTerminator,
    plausiblePrefix: !invalid && nonTerminator.length > 0,
    empty: sawTerminator && nonTerminator.length === 0,
    consumedBits: bitOffset - offset,
    remainingBits: sample.bitCount - bitOffset,
    error,
    fieldCount: nonTerminator.length,
    fields,
  };
}

function collectSamples(diagnostics, options) {
  const rows = [];
  const byKey = new Map();
  const add = (sourceKind, sample) => {
    if (!sample?.fieldName || !RPC_GROUP_BY_FIELD_NAME.has(sample.fieldName)) return;
    if (!BASE_REPLAY_CONTROLLER_CLASS_NET_CACHE_RE.test(sample.classNetCache ?? '')) return;
    if (!Number.isInteger(sample.numPayloadBits) || !sample.payloadHex) return;
    const key = `${sample.fieldHandle}|${sample.fieldName}`;
    const currentCount = byKey.get(key) ?? 0;
    if (currentCount >= options.maxSamplesPerField) return;
    const buffer = Buffer.from(normalizeHexToFullBytes(sample.payloadHex), 'hex');
    if (buffer.length * 8 < sample.numPayloadBits) return;
    byKey.set(key, currentCount + 1);
    rows.push({
      sourceKind,
      timeMs: sample.timeMs,
      chIndex: sample.chIndex ?? null,
      actorNetGuid: sample.actorNetGuid ?? null,
      fieldHandle: sample.fieldHandle,
      fieldName: sample.fieldName,
      bitCount: sample.numPayloadBits,
      payloadHex: sample.payloadHex,
      buffer,
    });
  };

  for (const sample of diagnostics.frameSummary?.replayControllerCandidateFieldSamples ?? []) {
    add('replayControllerCandidateFieldSamples', sample);
  }
  for (const summary of diagnostics.frameSummary?.replayControllerClassNetCacheFieldSummary ?? []) {
    for (const sample of summary.samples ?? []) {
      add('replayControllerClassNetCacheFieldSummary.samples', {
        ...sample,
        classNetCache: summary.classNetCache,
        fieldHandle: summary.fieldHandle,
        fieldName: summary.fieldName,
      });
    }
  }

  return rows.sort(
    (a, b) =>
      a.fieldHandle - b.fieldHandle ||
      a.timeMs - b.timeMs ||
      a.bitCount - b.bitCount ||
      a.sourceKind.localeCompare(b.sourceKind),
  );
}

function analyzeField(samples, group) {
  const offsetStats = Array.from({ length: 16 }, (_, offset) => ({
    offset,
    sampleCount: 0,
    okCount: 0,
    plausiblePrefixCount: 0,
    emptyCount: 0,
    fieldCountValues: [],
    firstHandleValues: [],
    errorCounts: new Map(),
    layoutCounts: new Map(),
    examples: [],
  }));

  for (const sample of samples) {
    for (let offset = 0; offset < 16; offset += 1) {
      const parsed = parsePropertyStream(sample, group, offset);
      const stat = offsetStats[offset];
      stat.sampleCount += 1;
      if (parsed.ok) stat.okCount += 1;
      if (parsed.plausiblePrefix) stat.plausiblePrefixCount += 1;
      if (parsed.empty) stat.emptyCount += 1;
      stat.fieldCountValues.push(parsed.fieldCount);
      if (parsed.error) increment(stat.errorCounts, parsed.error);
      const firstField = parsed.fields.find((field) => !field.terminator && !field.bad);
      if (firstField) stat.firstHandleValues.push(`${firstField.handle}:${firstField.numBits}`);
      const layout = parsed.fields
        .map((field) =>
          field.terminator
            ? 'term'
            : field.bad
              ? `bad:${field.reason}`
              : `${field.handle}:${field.numBits}${field.validHandle && field.validPayload ? '' : ':bad'}`,
        )
        .join(',');
      increment(stat.layoutCounts, layout);
      if ((parsed.ok || parsed.plausiblePrefix || parsed.error) && stat.examples.length < 4) {
        stat.examples.push({
          timeMs: sample.timeMs,
          bitCount: sample.bitCount,
          payloadPrefixHex: bitsToHex(sample.buffer, 0, Math.min(96, sample.bitCount)),
          parsed: {
            ok: parsed.ok,
            plausiblePrefix: parsed.plausiblePrefix,
            empty: parsed.empty,
            consumedBits: parsed.consumedBits,
            remainingBits: parsed.remainingBits,
            error: parsed.error,
            fields: parsed.fields.slice(0, 4),
          },
        });
      }
    }
  }

  return offsetStats
    .map((stat) => ({
      offset: stat.offset,
      sampleCount: stat.sampleCount,
      okCount: stat.okCount,
      plausiblePrefixCount: stat.plausiblePrefixCount,
      emptyCount: stat.emptyCount,
      topFieldCounts: topCounts(stat.fieldCountValues, 8),
      topFirstHandles: topCounts(stat.firstHandleValues, 8),
      topErrors: topCounts(stat.errorCounts, 8),
      topLayouts: topCounts(stat.layoutCounts, 8),
      examples: stat.examples,
    }))
    .sort(
      (a, b) =>
        b.okCount - a.okCount ||
        b.plausiblePrefixCount - a.plausiblePrefixCount ||
        b.emptyCount - a.emptyCount ||
        a.offset - b.offset,
    );
}

function analyze(diagnostics, options) {
  const groups = exportGroupsByPath(diagnostics);
  const samples = collectSamples(diagnostics, options);
  const samplesByField = new Map();
  for (const sample of samples) {
    const key = `${sample.fieldHandle}|${sample.fieldName}`;
    if (!samplesByField.has(key)) samplesByField.set(key, []);
    samplesByField.get(key).push(sample);
  }

  const rpcReports = [...samplesByField.entries()].map(([key, rows]) => {
    const [, fieldName] = key.split('|');
    const groupPath = RPC_GROUP_BY_FIELD_NAME.get(fieldName);
    const group = groups.get(groupPath) ?? null;
    const offsetSummary = analyzeField(rows, group);
    return {
      fieldHandle: rows[0].fieldHandle,
      fieldName,
      groupPath,
      groupFound: Boolean(group),
      groupNetFieldExportsLength: group?.netFieldExportsLength ?? null,
      groupKnownExports: group?.knownExports ?? [],
      sampleCount: rows.length,
      payloadBitCounts: topCounts(rows.map((row) => row.bitCount), 12),
      sourceCounts: topCounts(rows.map((row) => row.sourceKind), 4),
      bestOffsets: offsetSummary.slice(0, 6),
    };
  });

  return {
    generatedAt: new Date().toISOString(),
    input: {
      diagnostics: options.diagnostics,
      maxSamplesPerField: options.maxSamplesPerField,
    },
    notes: [
      'Scores whether named BaseReplayController ClassNetCache function payloads look like normal Unreal ReceiveProperties streams.',
      'Offsets 0..15 include the normal RPC checksum bit at offset 1 plus nearby drift hypotheses.',
      'A field can be custom/native even when the ClassNetCache function handle is correct; this report only verifies property-stream framing.',
    ],
    source: {
      sampleCount: samples.length,
      fieldCount: rpcReports.length,
    },
    rpcReports: rpcReports.sort((a, b) => a.fieldHandle - b.fieldHandle),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_replay_controller_rpc_property_alignment.mjs --diagnostics replay.diagnostics.json --out rpc_property_alignment.report.json',
    );
    process.exitCode = 1;
    return;
  }
  options.diagnostics = diagnosticsPath;
  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const report = analyze(diagnostics, options);
  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else console.log(JSON.stringify(report, null, 2));
  console.error(
    `analyzed ${report.source.sampleCount} named ReplayController RPC payload samples across ${report.source.fieldCount} fields`,
  );
}

main();
