#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const FIELD_HANDLE = 122;
const PAYLOAD_BITS = 92;
const YAW_BIT_OFFSET = 50;
const YAW_BIT_COUNT = 18;
const YAW_TRANSFORMS = ['as-read', 'negated', 'plus-90', 'minus-90', 'plus-180'];

function parseArgs(argv) {
  const options = {
    diagnostics: null,
    decoderReport: null,
    out: null,
    minLaneSamples: 20,
    maxOpenYawMatches: 5,
    cooccurrenceWindowsMs: [8, 16, 33, 64],
    maxCooccurrenceRows: 12,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--diagnostics') options.diagnostics = argv[++index];
    else if (arg === '--decoder-report') options.decoderReport = argv[++index];
    else if (arg === '--out') options.out = argv[++index];
    else if (arg === '--min-lane-samples') options.minLaneSamples = Number(argv[++index]);
    else if (arg === '--max-open-yaw-matches') options.maxOpenYawMatches = Number(argv[++index]);
    else if (arg === '--cooccurrence-windows-ms') {
      options.cooccurrenceWindowsMs = argv[++index].split(',').map(Number).filter(Number.isFinite);
    } else if (arg === '--max-cooccurrence-rows') {
      options.maxCooccurrenceRows = Number(argv[++index]);
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
    .map((sample, slotIndex) => ({
      slotIndex,
      timeMs: sample.timeMs,
      chIndex: sample.chIndex,
      netGuid: sample.actorNetGuid,
      archetypePath: sample.archetypePath ?? null,
      location: sample.location ?? null,
      yaw: sample.rotation?.yaw ?? null,
    }))
    .filter((sample) => Number.isInteger(sample.netGuid) && Number.isFinite(sample.yaw))
    .sort((a, b) => a.slotIndex - b.slotIndex);
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

  readPackedVectorRaw() {
    const bitsAndInfo = this.readSerializedInt(1 << 7);
    if (this.isError) return null;
    const componentBits = bitsAndInfo & 63;
    const extraInfo = bitsAndInfo >> 6;
    if (componentBits < 7 || componentBits > 24) return null;
    if (!this.canRead(componentBits * 3)) return null;
    const vector = {
      bitsAndInfo,
      componentBits,
      extraInfo,
      xSigned: this.readBitsSigned(componentBits),
      ySigned: this.readBitsSigned(componentBits),
      zSigned: this.readBitsSigned(componentBits),
    };
    return this.isError ? null : vector;
  }
}

function decodeVectorAt(sample, bitOffset) {
  const reader = new BitCursor(sample.buffer, sample.bitCount, bitOffset);
  return reader.readPackedVectorRaw();
}

function selectedFamilies(decoderReport) {
  if (!decoderReport) return [];
  return (decoderReport.familyReports ?? [])
    .map((entry) => entry.family)
    .filter(Boolean)
    .map((family) => ({
      fieldHandle: family.fieldHandle,
      payloadBitCount: family.payloadBitCount,
      prefixHex: family.prefixHex,
      slotIndex: family.slotIndex,
      slotNetGuid: family.slotNetGuid,
      slotChIndex: family.slotChIndex,
      headerBits: family.headerBits,
      recordBits: family.recordBits,
      relativeOffset: family.relativeOffset,
      componentBits: family.componentBits,
      extraInfo: family.extraInfo,
    }));
}

function samplesForFamily(samples, family) {
  return samples.filter(
    (sample) =>
      sample.fieldHandle === family.fieldHandle &&
      sample.bitCount === family.payloadBitCount &&
      bitsToHex(sample.buffer, 0, Math.min(32, sample.bitCount)) === family.prefixHex,
  );
}

function targetVectorRows(samples, family) {
  const absoluteOffset = family.headerBits + family.slotIndex * family.recordBits + family.relativeOffset;
  return samplesForFamily(samples, family)
    .map((sample) => {
      const vector = decodeVectorAt(sample, absoluteOffset);
      if (!vector) return null;
      if (vector.componentBits !== family.componentBits || vector.extraInfo !== family.extraInfo) {
        return null;
      }
      return {
        timeMs: sample.timeMs,
        sampleIndex: sample.sampleIndex,
        payloadHex: sample.payloadHex,
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
}

function buildHandle122Lanes(samples, options) {
  const lanes = new Map();
  for (const sample of samples) {
    if (sample.fieldHandle !== FIELD_HANDLE || sample.bitCount !== PAYLOAD_BITS) continue;
    const prefixHex = bitsToHex(sample.buffer, 0, 32);
    if (!lanes.has(prefixHex)) lanes.set(prefixHex, []);
    const dedupeKey = `${sample.timeMs}:${sample.payloadHex}`;
    if (!lanes.get(prefixHex).some((entry) => entry.dedupeKey === dedupeKey)) {
      lanes.get(prefixHex).push({ ...sample, dedupeKey, prefixHex });
    }
  }
  return [...lanes.entries()]
    .map(([prefixHex, rows]) => {
      rows.sort((a, b) => a.timeMs - b.timeMs || a.sampleIndex - b.sampleIndex);
      return { prefixHex, rows };
    })
    .filter((lane) => lane.rows.length >= options.minLaneSamples)
    .sort((a, b) => b.rows.length - a.rows.length || a.prefixHex.localeCompare(b.prefixHex));
}

function laneKey(prefixBuffer) {
  return {
    offset20Width8: readBitsUnsigned(prefixBuffer, 20, 8),
    highNibble20: readBitsUnsigned(prefixBuffer, 20, 4),
    lowNibble24: readBitsUnsigned(prefixBuffer, 24, 4),
    bits20To27: Array.from({ length: 8 }, (_, bit) => readBit(prefixBuffer, 20 + bit)).join(''),
  };
}

function variablePrefixBits(laneReports) {
  const buffers = laneReports.map((lane) => Buffer.from(lane.prefixHex, 'hex'));
  const bits = [];
  for (let bit = 0; bit < 32; bit += 1) {
    const values = new Set(buffers.map((buffer) => readBit(buffer, bit)));
    if (values.size > 1) bits.push(bit);
  }
  const ranges = [];
  let start = null;
  for (let index = 0; index <= bits.length; index += 1) {
    const bit = bits[index];
    if (bit != null && (start == null || bit === bits[index - 1] + 1)) {
      if (start == null) start = bit;
    } else if (start != null) {
      const end = bits[index - 1];
      ranges.push({ start, end, length: end - start + 1 });
      start = bit ?? null;
    }
  }
  return { bits, ranges };
}

function prefixValueMatches(prefixBuffer, players) {
  const matches = [];
  for (let offset = 0; offset < 32; offset += 1) {
    for (const bitCount of [3, 4, 5, 6, 7, 8, 10, 12, 16]) {
      if (offset + bitCount > 32) continue;
      const value = readBitsUnsigned(prefixBuffer, offset, bitCount);
      for (const player of players) {
        const refs = [
          ['slotIndex', player.slotIndex],
          ['chIndex', player.chIndex],
          ['chIndexMinus76', player.chIndex - 76],
          ['netGuid', player.netGuid],
          ['netGuidLow8', player.netGuid & 0xff],
          ['netGuidShift1', player.netGuid >> 1],
        ];
        for (const [label, refValue] of refs) {
          if (value === refValue) {
            matches.push({
              offset,
              bitCount,
              value,
              label,
              player: {
                slotIndex: player.slotIndex,
                chIndex: player.chIndex,
                netGuid: player.netGuid,
                archetypePath: player.archetypePath,
              },
            });
          }
        }
      }
    }
  }
  return matches
    .sort(
      (a, b) =>
        Number(b.label === 'chIndex') - Number(a.label === 'chIndex') ||
        Number(b.label === 'slotIndex') - Number(a.label === 'slotIndex') ||
        a.offset - b.offset ||
        a.bitCount - b.bitCount,
    )
    .slice(0, 24);
}

function rawYawDegreesFromSample(sample) {
  return (readBitsSigned(sample.buffer, YAW_BIT_OFFSET, YAW_BIT_COUNT) * 360) / 2 ** YAW_BIT_COUNT;
}

function transformedYaw(row, transform) {
  return normalizeDegrees360(transformYaw(rawYawDegreesFromSample(row), transform));
}

function openYawMatches(firstRow, players, maxMatches) {
  if (!firstRow) return [];
  const rawYawDegrees = rawYawDegreesFromSample(firstRow);
  const matches = [];
  for (const transform of YAW_TRANSFORMS) {
    const yawDegrees360 = normalizeDegrees360(transformYaw(rawYawDegrees, transform));
    for (const player of players) {
      matches.push({
        transform,
        yawDegrees: round(normalizeDegrees180(yawDegrees360)),
        yawDegrees360: round(yawDegrees360),
        deltaDegrees: round(circularDegreesDelta(yawDegrees360, player.yaw)),
        player: {
          slotIndex: player.slotIndex,
          chIndex: player.chIndex,
          netGuid: player.netGuid,
          archetypePath: player.archetypePath,
          openYaw: round(player.yaw),
        },
      });
    }
  }
  return matches
    .sort((a, b) => a.deltaDegrees - b.deltaDegrees || a.player.slotIndex - b.player.slotIndex)
    .slice(0, maxMatches);
}

function summarizeLaneRows(rows, bestOpenYawTransform) {
  const dts = [];
  const yawSteps = [];
  const angularSpeeds = [];
  const uniquePayloads = new Set(rows.map((row) => row.payloadHex));
  for (let index = 1; index < rows.length; index += 1) {
    const previous = rows[index - 1];
    const current = rows[index];
    const dtMs = current.timeMs - previous.timeMs;
    if (dtMs <= 0) continue;
    dts.push(dtMs);
    if (dtMs <= 250 && bestOpenYawTransform) {
      const previousYaw = transformedYaw(previous, bestOpenYawTransform);
      const currentYaw = transformedYaw(current, bestOpenYawTransform);
      const step = circularDegreesDelta(previousYaw, currentYaw);
      yawSteps.push(step);
      angularSpeeds.push(step / (dtMs / 1000));
    }
  }
  return {
    count: rows.length,
    uniquePayloadCount: uniquePayloads.size,
    firstTimeMs: rows[0]?.timeMs ?? null,
    lastTimeMs: rows.at(-1)?.timeMs ?? null,
    activeSpanMs: rows.length ? rows.at(-1).timeMs - rows[0].timeMs : 0,
    medianDtMs: round(percentile(dts, 0.5), 0),
    p90DtMs: round(percentile(dts, 0.9), 0),
    medianYawStepDegrees: round(percentile(yawSteps, 0.5)),
    p90YawStepDegrees: round(percentile(yawSteps, 0.9)),
    medianAngularSpeedDps: round(percentile(angularSpeeds, 0.5)),
    p90AngularSpeedDps: round(percentile(angularSpeeds, 0.9)),
    firstPayloadHex: rows[0]?.payloadHex ?? null,
    lastPayloadHex: rows.at(-1)?.payloadHex ?? null,
  };
}

function nearestDelta(rows, timeMs) {
  if (!rows.length) return null;
  let low = 0;
  let high = rows.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (rows[middle].timeMs < timeMs) low = middle + 1;
    else high = middle;
  }
  let best = null;
  for (const index of [low - 1, low]) {
    if (index < 0 || index >= rows.length) continue;
    const deltaMs = Math.abs(rows[index].timeMs - timeMs);
    if (!best || deltaMs < best.deltaMs) best = { deltaMs, row: rows[index] };
  }
  return best;
}

function summarizeCooccurrence(targetRows, laneRows, windowsMs) {
  const deltas = [];
  const counts = Object.fromEntries(windowsMs.map((windowMs) => [`within${windowMs}Ms`, 0]));
  for (const row of targetRows) {
    const nearest = nearestDelta(laneRows, row.timeMs);
    if (!nearest) continue;
    deltas.push(nearest.deltaMs);
    for (const windowMs of windowsMs) {
      if (nearest.deltaMs <= windowMs) counts[`within${windowMs}Ms`] += 1;
    }
  }
  const rates = Object.fromEntries(
    windowsMs.map((windowMs) => [
      `within${windowMs}MsRate`,
      targetRows.length ? round(counts[`within${windowMs}Ms`] / targetRows.length) : 0,
    ]),
  );
  return {
    targetRowCount: targetRows.length,
    ...counts,
    ...rates,
    deltaMs: deltas.length
      ? {
          median: round(percentile(deltas, 0.5), 0),
          p90: round(percentile(deltas, 0.9), 0),
          min: round(Math.min(...deltas), 0),
          max: round(Math.max(...deltas), 0),
        }
      : null,
  };
}

function selectedFamilyCooccurrence(lane, selectedFamilyRows, options) {
  return selectedFamilyRows
    .map((familyRows) => ({
      family: familyRows.family,
      cooccurrence: summarizeCooccurrence(
        familyRows.rows,
        lane.rows,
        options.cooccurrenceWindowsMs,
      ),
    }))
    .sort(
      (a, b) =>
        (b.cooccurrence.within64MsRate ?? 0) - (a.cooccurrence.within64MsRate ?? 0) ||
        (b.cooccurrence.within33MsRate ?? 0) - (a.cooccurrence.within33MsRate ?? 0),
    )
    .slice(0, options.maxCooccurrenceRows);
}

function analyzeHandle122Lanes(diagnostics, decoderReport, options) {
  const samples = parseCandidateFieldSamples(diagnostics);
  const players = knownPlayerOpenSamplesFromDiagnostics(diagnostics);
  const lanes = buildHandle122Lanes(samples, options);
  const selectedFamilyRows = selectedFamilies(decoderReport).map((family) => ({
    family,
    rows: targetVectorRows(samples, family),
  }));

  const laneReports = lanes.map((lane) => {
    const prefixBuffer = Buffer.from(lane.prefixHex, 'hex');
    const openMatches = openYawMatches(lane.rows[0], players, options.maxOpenYawMatches);
    const bestOpenYawMatch = openMatches[0] ?? null;
    const report = {
      prefixHex: lane.prefixHex,
      laneKey: laneKey(prefixBuffer),
      prefixValueMatches: prefixValueMatches(prefixBuffer, players),
      openYawMatches: openMatches,
      summary: summarizeLaneRows(lane.rows, bestOpenYawMatch?.transform ?? null),
      selectedFamilyCooccurrence: selectedFamilyCooccurrence(lane, selectedFamilyRows, options),
    };
    return report;
  });

  const bestOpenCounts = new Map();
  for (const lane of laneReports) {
    const netGuid = lane.openYawMatches[0]?.player.netGuid;
    if (!Number.isInteger(netGuid)) continue;
    bestOpenCounts.set(netGuid, (bestOpenCounts.get(netGuid) ?? 0) + 1);
  }
  const prefixVariation = variablePrefixBits(laneReports);
  for (const lane of laneReports) {
    const best = lane.openYawMatches[0];
    lane.openYawIdentityStatus =
      best && bestOpenCounts.get(best.player.netGuid) > 1
        ? 'ambiguous-best-open-yaw-netguid'
        : best
          ? 'unique-best-open-yaw-netguid'
          : 'no-open-yaw-match';
  }

  const selectedFamilyReports = selectedFamilyRows.map((familyRows) => {
    const laneRows = laneReports
      .map((lane) => ({
        prefixHex: lane.prefixHex,
        laneKey: lane.laneKey,
        openYawBestMatch: lane.openYawMatches[0] ?? null,
        openYawIdentityStatus: lane.openYawIdentityStatus,
        cooccurrence: lane.selectedFamilyCooccurrence.find(
          (entry) =>
            entry.family.fieldHandle === familyRows.family.fieldHandle &&
            entry.family.payloadBitCount === familyRows.family.payloadBitCount &&
            entry.family.prefixHex === familyRows.family.prefixHex,
        )?.cooccurrence ?? summarizeCooccurrence(familyRows.rows, [], options.cooccurrenceWindowsMs),
      }))
      .sort(
        (a, b) =>
          (b.cooccurrence.within64MsRate ?? 0) - (a.cooccurrence.within64MsRate ?? 0) ||
          (b.cooccurrence.within33MsRate ?? 0) - (a.cooccurrence.within33MsRate ?? 0) ||
          (b.cooccurrence.within16MsRate ?? 0) - (a.cooccurrence.within16MsRate ?? 0),
      );
    return {
      family: familyRows.family,
      targetVectorRowCount: familyRows.rows.length,
      topCooccurringHandle122Lanes: laneRows.slice(0, options.maxCooccurrenceRows),
    };
  });

  const conclusions = [];
  conclusions.push(
    `Handle 122 has ${laneReports.length} recurring full-payload prefix lanes at minLaneSamples=${options.minLaneSamples}; variable prefix ranges are ${prefixVariation.ranges.map((range) => `${range.start}..${range.end}`).join(', ') || 'none'}.`,
  );
  const ambiguousCount = laneReports.filter(
    (lane) => lane.openYawIdentityStatus === 'ambiguous-best-open-yaw-netguid',
  ).length;
  conclusions.push(
    `${ambiguousCount}/${laneReports.length} lanes have best-open-yaw NetGUID collisions, so first-open-yaw matching is not an authoritative identity decoder.`,
  );
  for (const familyReport of selectedFamilyReports) {
    const best = familyReport.topCooccurringHandle122Lanes[0];
    conclusions.push(
      `Selected h${familyReport.family.fieldHandle}/${familyReport.family.prefixHex}/slot${familyReport.family.slotIndex} overlaps handle122 ${best?.prefixHex ?? 'none'} most strongly within 64ms at rate ${best?.cooccurrence.within64MsRate ?? 0}.`,
    );
  }

  return {
    generatedAt: new Date().toISOString(),
    options: {
      minLaneSamples: options.minLaneSamples,
      cooccurrenceWindowsMs: options.cooccurrenceWindowsMs,
      maxOpenYawMatches: options.maxOpenYawMatches,
      maxCooccurrenceRows: options.maxCooccurrenceRows,
    },
    notes: [
      'This report characterizes handle-122 lane identity without promoting any lane to a confirmed NetGUID.',
      'Open-yaw matching is treated as a weak heuristic because several prefixes can map to the same player.',
      'Selected-family co-occurrence uses the h24/h100 target-slot packed-vector rows from the decoder-lead report.',
    ],
    source: {
      candidateFieldSampleCount: samples.length,
      handle122LaneCount: laneReports.length,
      playerReferenceCount: players.length,
      selectedFamilyCount: selectedFamilyRows.length,
      prefixVariation,
      players,
    },
    status: 'handle122 lane identity remains ambiguous; co-occurrence gives prefix leads only',
    conclusions,
    selectedFamilyReports,
    laneReports,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const diagnosticsPath = resolveUserPath(options.diagnostics);
  const decoderReportPath = resolveUserPath(options.decoderReport);
  if (!diagnosticsPath) {
    console.error(
      'usage: node analyze_handle122_lane_identity.mjs --diagnostics replay.diagnostics.json [--decoder-report decoder_leads.report.json] --out handle122_identity.report.json',
    );
    process.exitCode = 1;
    return;
  }

  const diagnostics = JSON.parse(fs.readFileSync(diagnosticsPath, 'utf8'));
  const decoderReport = decoderReportPath
    ? JSON.parse(fs.readFileSync(decoderReportPath, 'utf8'))
    : null;
  const report = analyzeHandle122Lanes(diagnostics, decoderReport, options);
  report.input = { diagnostics: diagnosticsPath, decoderReport: decoderReportPath };

  const outPath = resolveUserPath(options.out);
  if (outPath) writeJson(outPath, report);
  else process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);

  console.error(
    `analyzed ${report.source.handle122LaneCount} handle122 lanes; selectedFamilies=${report.source.selectedFamilyCount}`,
  );
}

main();
